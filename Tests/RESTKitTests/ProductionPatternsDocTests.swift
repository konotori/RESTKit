import Foundation
import Testing
@testable import RESTKit

// =============================================================================
// Documentation examples. The types below mirror the README's "Production
// Patterns" section verbatim. This suite guards that the documented code keeps
// compiling AND behaving correctly under concurrency as the package evolves
// (single-flight refresh, in-flight coalescing, breaker transitions, priority
// ordering). These are reference recipes — NOT part of RESTKit's public API.
// =============================================================================

// MARK: - Pattern 1: Token Refresh (single-flight) ----------------------------

protocol TokenRefreshService: Sendable {
    func refresh() async throws -> String
}

actor AuthTokenStore {
    private let service: TokenRefreshService
    private var accessToken: String?
    private var refreshTask: Task<String, Error>?

    init(service: TokenRefreshService, initialToken: String? = nil) {
        self.service = service
        self.accessToken = initialToken
    }

    /// The token to attach to a request (refreshes once if we have none yet).
    func token() async throws -> String {
        if let accessToken { return accessToken }
        return try await performRefresh()
    }

    /// Called after a 401. `staleToken` is the token that was rejected. If someone
    /// already rotated past it, return the new one without refreshing again;
    /// otherwise refresh once, coalescing concurrent callers onto a single call.
    func refresh(replacing staleToken: String) async throws -> String {
        if let accessToken, accessToken != staleToken { return accessToken }
        return try await performRefresh()
    }

    private func performRefresh() async throws -> String {
        if let refreshTask { return try await refreshTask.value }   // join in-flight refresh
        let task = Task<String, Error> {
            let newToken = try await service.refresh()
            // Store the token INSIDE the task, before its value is delivered to any
            // awaiter. A coalesced caller resumes from `refreshTask.value` and then
            // re-reads the token (via the interceptor). If we instead assigned in the
            // original caller's continuation, that joiner could retry before the
            // assignment ran and resend the stale token.
            accessToken = newToken
            return newToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}

struct BearerAuthInterceptor: RequestInterceptor {
    let store: AuthTokenStore

    func adapt(_ request: URLRequest, for endpoint: any Endpoint) async throws -> URLRequest {
        guard endpoint.needsAuthentication else { return request }
        var request = request
        request.setValue("Bearer \(try await store.token())", forHTTPHeaderField: "Authorization")
        return request
    }
}

struct AuthRefreshingClient: APIClientProtocol {
    let base: any APIClientProtocol
    let store: AuthTokenStore

    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response.Output {
        guard endpoint.needsAuthentication else { return try await base.request(endpoint) }
        // Snapshot the token the interceptor is about to attach. (Rare TOCTOU: a
        // concurrent refresh between here and adapt() may attach a newer token;
        // worst case is one wasted retry.)
        let tokenInUse = try await store.token()
        do {
            return try await base.request(endpoint)
        } catch let error as APIError {
            guard case .clientError(401, _) = error else { throw error }
            _ = try await store.refresh(replacing: tokenInUse)   // single-flight
            return try await base.request(endpoint)              // adapt() re-reads fresh token
        }
    }
}

// MARK: - Pattern 2: Retry (backoff + jitter) ---------------------------------

struct RetryingClient: APIClientProtocol {
    let base: any APIClientProtocol
    let maxAttempts: Int
    let baseDelay: TimeInterval

    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response.Output {
        var attempt = 1
        while true {
            do {
                return try await base.request(endpoint)
            } catch is CancellationError {
                throw CancellationError()                       // never retry cancellation
            } catch let error as APIError {
                guard attempt < maxAttempts,
                      HTTPMethod.idempotentMethods.contains(endpoint.method),
                      Self.isRetryable(error)
                else { throw error }
                // Exponential backoff with full jitter. APIError carries the body
                // (Data?) but not headers, so a server's Retry-After can't be
                // honored here — back off on attempt number alone.
                let ceiling = baseDelay * Double(1 << (attempt - 1))
                let delay = Double.random(in: 0 ... ceiling)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }

    static func isRetryable(_ error: APIError) -> Bool {
        switch error {
        case .serverError:
            return true                                         // 5xx
        case let .clientError(code, _):
            return code == 408 || code == 429                   // timeout / rate limit
        case let .requestFailed(underlying):
            guard let urlError = underlying as? URLError else { return false }
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet]
                .contains(urlError.code)
        default:
            return false                                        // decoding/encoding/invalidURL/...
        }
    }
}

// MARK: - Pattern 3: Circuit Breaker ------------------------------------------

enum CircuitBreakerError: Error { case open }

actor CircuitBreaker {
    enum State: Sendable { case closed, open(since: Date), halfOpen }

    private let failureThreshold: Int
    private let cooldown: TimeInterval
    private var state: State = .closed
    private var failureCount = 0

    init(failureThreshold: Int, cooldown: TimeInterval) {
        self.failureThreshold = failureThreshold
        self.cooldown = cooldown
    }

    /// Throws if the circuit is open and still cooling down; otherwise allows the
    /// request (flipping open → half-open once the cooldown elapses).
    func willAllowRequest() throws {
        switch state {
        case .closed, .halfOpen:
            return
        case let .open(since):
            guard Date().timeIntervalSince(since) >= cooldown else {
                throw CircuitBreakerError.open
            }
            state = .halfOpen                                   // allow a trial request
        }
    }

    func recordSuccess() {
        failureCount = 0
        state = .closed
    }

    func recordFailure() {
        if case .halfOpen = state {
            state = .open(since: Date())                        // trial failed → reopen
            return
        }
        failureCount += 1
        if failureCount >= failureThreshold {
            state = .open(since: Date())
        }
    }
}

struct CircuitBreakingClient: APIClientProtocol {
    let base: any APIClientProtocol
    let breaker: CircuitBreaker

    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response.Output {
        try await breaker.willAllowRequest()                    // fail fast if open
        do {
            let result = try await base.request(endpoint)
            await breaker.recordSuccess()
            return result
        } catch is CancellationError {
            throw CancellationError()                           // not a backend fault
        } catch let error as APIError {
            if Self.countsAsFailure(error) { await breaker.recordFailure() }
            throw error
        }
    }

    static func countsAsFailure(_ error: APIError) -> Bool {
        switch error {
        case .serverError, .requestFailed, .invalidResponse:
            return true                                         // backend is unhealthy
        default:
            return false                                        // 4xx etc.: backend responded
        }
    }
}

// MARK: - Pattern 4: Deduplication (in-flight coalescing) ---------------------

actor RequestCoalescer {
    private var inFlight: [String: Task<any Sendable, Error>] = [:]

    func shared(_ key: String, _ work: @escaping @Sendable () async throws -> any Sendable) -> Task<any Sendable, Error> {
        if let existing = inFlight[key] { return existing }
        let task = Task<any Sendable, Error> {
            do {
                let value = try await work()
                self.clear(key)
                return value
            } catch {
                self.clear(key)
                throw error
            }
        }
        inFlight[key] = task
        return task
    }

    private func clear(_ key: String) { inFlight.removeValue(forKey: key) }
}

struct DeduplicatingClient: APIClientProtocol {
    let base: any APIClientProtocol
    let coalescer = RequestCoalescer()

    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response.Output {
        guard endpoint.method == .get else { return try await base.request(endpoint) }
        let key = Self.cacheKey(for: endpoint)
        let task = await coalescer.shared(key) {
            try await base.request(endpoint) as any Sendable
        }
        let value = try await task.value
        if let typed = value as? E.Response.Output { return typed }
        return try await base.request(endpoint)                 // key collision → direct call
    }

    static func cacheKey(for endpoint: any Endpoint) -> String {
        let url = (try? endpoint.asURLRequest())?.url?.absoluteString ?? endpoint.path
        return "\(endpoint.method.rawValue) \(url)"
    }
}

// MARK: - Pattern 5: Prioritization -------------------------------------------

actor PriorityGate {
    enum Priority: Int, Sendable, Comparable {
        case low = 0, normal = 1, high = 2
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Waiter {
        let priority: Priority
        let seq: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maxConcurrent: Int
    private var inUse = 0
    private var waiters: [Waiter] = []
    private var nextSeq: UInt64 = 0

    init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

    func acquire(priority: Priority) async throws {
        if inUse < maxConcurrent {
            inUse += 1
            return
        }
        nextSeq += 1
        let seq = nextSeq
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enqueue(Waiter(priority: priority, seq: seq, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(seq) }
        }
    }

    func release() {
        guard let index = highestPriorityWaiterIndex() else {
            inUse -= 1                                           // no one waiting → free the slot
            return
        }
        waiters.remove(at: index).continuation.resume()         // hand the slot to the next waiter
    }

    private func enqueue(_ waiter: Waiter) {
        if Task.isCancelled {
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            waiters.append(waiter)
        }
    }

    private func cancelWaiter(_ seq: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.seq == seq }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func highestPriorityWaiterIndex() -> Int? {
        guard !waiters.isEmpty else { return nil }
        return waiters.indices.max { lhs, rhs in
            waiters[lhs].priority != waiters[rhs].priority
                ? waiters[lhs].priority < waiters[rhs].priority
                : waiters[lhs].seq > waiters[rhs].seq           // ties: FIFO (lower seq wins)
        }
    }
}

struct PrioritizedClient: APIClientProtocol {
    let base: any APIClientProtocol
    let gate: PriorityGate
    let priorityFor: @Sendable (any Endpoint) -> PriorityGate.Priority

    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response.Output {
        try await gate.acquire(priority: priorityFor(endpoint))
        do {
            let result = try await base.request(endpoint)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }
}

// MARK: - Test infrastructure -------------------------------------------------

/// Stand-in for the README's "Logging / metrics" interceptor — no-op here so the
/// composition test stays quiet; only needed so the flagship wiring compiles.
struct LoggingInterceptor: RequestInterceptor {}

/// Closure-driven transport that counts calls and can block (for concurrency tests).
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let handler: @Sendable (URLRequest, Int) async throws -> (Data, Int)
    private let lock = NSLock()
    private var _count = 0

    var count: Int { read() }
    private func read() -> Int { lock.lock(); defer { lock.unlock() }; return _count }
    private func bump() -> Int { lock.lock(); defer { lock.unlock() }; _count += 1; return _count }

    init(handler: @escaping @Sendable (URLRequest, Int) async throws -> (Data, Int)) {
        self.handler = handler
    }

    func perform(request: URLRequest) async throws -> (Data, URLResponse) {
        let index = bump()
        let (data, status) = try await handler(request, index)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

/// Releases all waiters once `target` of them have arrived.
actor Barrier {
    private let target: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: Int) { self.target = target }

    func arriveAndWait() async {
        arrived += 1
        if arrived >= target {
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// One-shot async gate the test opens manually.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock(); defer { lock.unlock() }
            if opened { cont.resume() } else { continuation = cont }
        }
    }

    func open() {
        lock.lock(); let cont = continuation; continuation = nil; opened = true; lock.unlock()
        cont?.resume()
    }
}

final class CountingRefreshService: TokenRefreshService, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private let newToken: String

    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    private func bump() { lock.lock(); defer { lock.unlock() }; _count += 1 }

    init(newToken: String) { self.newToken = newToken }

    func refresh() async throws -> String {
        bump()
        return newToken
    }
}

actor OrderRecorder {
    private(set) var order: [String] = []
    func add(_ name: String) { order.append(name) }
}

private func userData(id: Int, name: String) -> Data {
    Data(#"{"id":\#(id),"name":"\#(name)","email":null}"#.utf8)
}

// MARK: - Tests ---------------------------------------------------------------

@Suite("README · Production Patterns")
struct ProductionPatternsDocTests {

    @Test func tokenRefreshIsSingleFlight() async throws {
        let n = 8
        let barrier = Barrier(target: n)
        let refresh = CountingRefreshService(newToken: "token-v1")
        let store = AuthTokenStore(service: refresh, initialToken: "token-v0")
        let body = userData(id: 1, name: "Alice")

        let stub = StubHTTPClient { request, _ in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer token-v1" {
                return (body, 200)
            }
            await barrier.arriveAndWait()                       // hold all v0 attempts together
            return (Data(#"{"message":"unauthorized"}"#.utf8), 401)
        }
        let core = APIClient(client: stub, interceptors: [BearerAuthInterceptor(store: store)])
        let client = AuthRefreshingClient(base: core, store: store)
        let endpoint = APIEndpoint<JSON<User>>(
            baseURL: "https://api.test.com", path: "/me", method: .get, needsAuthentication: true
        )

        let users = try await withThrowingTaskGroup(of: User.self) { group -> [User] in
            for _ in 0 ..< n { group.addTask { try await client.request(endpoint) } }
            var result: [User] = []
            for try await user in group { result.append(user) }
            return result
        }

        #expect(users.count == n)
        #expect(users.allSatisfy { $0.name == "Alice" })
        #expect(refresh.count == 1)                             // ← single-flight
    }

    @Test func deduplicationCoalescesInFlightGETs() async throws {
        let n = 6
        let hold = Gate()
        let body = userData(id: 2, name: "Bob")
        let stub = StubHTTPClient { _, _ in
            await hold.wait()                                   // block the single network call
            return (body, 200)
        }
        let client = DeduplicatingClient(base: APIClient(client: stub))
        let endpoint = APIEndpoint<JSON<User>>(baseURL: "https://api.test.com", path: "/users/2", method: .get)

        let users = try await withThrowingTaskGroup(of: User.self) { group -> [User] in
            for _ in 0 ..< n { group.addTask { try await client.request(endpoint) } }
            try await Task.sleep(nanoseconds: 200_000_000)      // let all n coalesce
            hold.open()
            var result: [User] = []
            for try await user in group { result.append(user) }
            return result
        }

        #expect(users.count == n)
        #expect(users.allSatisfy { $0.name == "Bob" })
        #expect(stub.count == 1)                                // ← one network call for n GETs
    }

    @Test func retryRecoversFromTransientServerErrors() async throws {
        let body = userData(id: 3, name: "Cara")
        let stub = StubHTTPClient { _, attempt in
            attempt < 3 ? (Data(), 503) : (body, 200)
        }
        let client = RetryingClient(base: APIClient(client: stub), maxAttempts: 3, baseDelay: 0)
        let endpoint = APIEndpoint<JSON<User>>(baseURL: "https://api.test.com", path: "/users/3", method: .get)

        let user = try await client.request(endpoint)
        #expect(user.name == "Cara")
        #expect(stub.count == 3)
    }

    @Test func retryGivesUpAfterMaxAttempts() async throws {
        let stub = StubHTTPClient { _, _ in (Data(), 503) }
        let client = RetryingClient(base: APIClient(client: stub), maxAttempts: 3, baseDelay: 0)
        let endpoint = APIEndpoint<JSON<User>>(baseURL: "https://api.test.com", path: "/x", method: .get)

        await #expect(throws: APIError.self) { _ = try await client.request(endpoint) }
        #expect(stub.count == 3)
    }

    @Test func retrySkipsNonIdempotentMethods() async throws {
        let stub = StubHTTPClient { _, _ in (Data(), 503) }
        let client = RetryingClient(base: APIClient(client: stub), maxAttempts: 3, baseDelay: 0)
        let endpoint = APIEndpoint<JSON<User>>(baseURL: "https://api.test.com", path: "/x", method: .post)

        await #expect(throws: APIError.self) { _ = try await client.request(endpoint) }
        #expect(stub.count == 1)                                // POST not retried
    }

    @Test func retrySkipsNonRetryableStatus() async throws {
        let stub = StubHTTPClient { _, _ in (Data(), 404) }
        let client = RetryingClient(base: APIClient(client: stub), maxAttempts: 3, baseDelay: 0)
        let endpoint = APIEndpoint<JSON<User>>(baseURL: "https://api.test.com", path: "/x", method: .get)

        await #expect(throws: APIError.self) { _ = try await client.request(endpoint) }
        #expect(stub.count == 1)                                // 404 not retryable
    }

    @Test func circuitBreakerTripsAndRecovers() async throws {
        let status = LockedBox(500)
        let body = userData(id: 4, name: "Dev")
        let stub = StubHTTPClient { _, _ in
            let code = status.value
            return code == 200 ? (body, 200) : (Data(), code)
        }
        let breaker = CircuitBreaker(failureThreshold: 3, cooldown: 0.05)
        let client = CircuitBreakingClient(base: APIClient(client: stub), breaker: breaker)
        let endpoint = APIEndpoint<JSON<User>>(baseURL: "https://api.test.com", path: "/x", method: .get)

        for _ in 0 ..< 3 {
            await #expect(throws: APIError.self) { _ = try await client.request(endpoint) }
        }
        #expect(stub.count == 3)

        await #expect(throws: CircuitBreakerError.self) { _ = try await client.request(endpoint) }
        #expect(stub.count == 3)                                // open → no network call

        status.value = 200
        try await Task.sleep(nanoseconds: 100_000_000)          // > cooldown
        let user = try await client.request(endpoint)
        #expect(user.name == "Dev")
        #expect(stub.count == 4)                                // half-open trial hit the network
    }

    @Test func priorityGateServesHighestFirst() async throws {
        let gate = PriorityGate(maxConcurrent: 1)
        let hold = Gate()
        let recorder = OrderRecorder()

        let holder = Task { try await gate.acquire(priority: .normal); await hold.wait(); await gate.release() }
        try await Task.sleep(nanoseconds: 100_000_000)          // holder takes the only slot

        func waiter(_ name: String, _ priority: PriorityGate.Priority) -> Task<Void, Error> {
            Task {
                try await gate.acquire(priority: priority)
                await recorder.add(name)
                await gate.release()
            }
        }
        let low = waiter("low", .low)
        let high = waiter("high", .high)
        let normal = waiter("normal", .normal)

        try await Task.sleep(nanoseconds: 150_000_000)          // let all three queue
        hold.open()
        _ = try await (holder.value, low.value, high.value, normal.value)

        #expect(await recorder.order == ["high", "normal", "low"])
    }

    @Test func priorityGateRemovesCancelledWaiterCleanly() async throws {
        let gate = PriorityGate(maxConcurrent: 1)
        let hold = Gate()

        // Holder takes the only slot and blocks, so everything else must queue.
        let holder = Task { try await gate.acquire(priority: .normal); await hold.wait(); await gate.release() }
        try await Task.sleep(nanoseconds: 100_000_000)

        // A queued waiter that gets cancelled must throw CancellationError.
        let cancelled = Task { try await gate.acquire(priority: .high) }
        try await Task.sleep(nanoseconds: 100_000_000)          // ensure it is queued
        cancelled.cancel()

        var threwCancellation = false
        do { try await cancelled.value } catch is CancellationError { threwCancellation = true }
        #expect(threwCancellation)

        // A second waiter must still be served when the holder releases — proving the
        // cancelled waiter was removed cleanly (no orphan, no double-resume crash).
        let served = LockedBox(false)
        let other = Task { try await gate.acquire(priority: .low); served.value = true; await gate.release() }
        try await Task.sleep(nanoseconds: 100_000_000)          // ensure it is queued
        hold.open()
        try await other.value
        #expect(served.value == true)
        _ = await holder.result
    }

    @Test func patternsComposeIntoOneClient() async throws {
        let body = userData(id: 5, name: "Eve")
        let stub = StubHTTPClient { _, _ in (body, 200) }
        let refresh = CountingRefreshService(newToken: "t1")
        let store = AuthTokenStore(service: refresh, initialToken: "t0")

        // Mirrors the README "Composing them" flagship snippet verbatim.
        let core = APIClient(client: stub, interceptors: [BearerAuthInterceptor(store: store), LoggingInterceptor()])
        let client = PrioritizedClient(
            base: DeduplicatingClient(
                base: RetryingClient(
                    base: CircuitBreakingClient(
                        base: AuthRefreshingClient(base: core, store: store),
                        breaker: CircuitBreaker(failureThreshold: 5, cooldown: 30)
                    ),
                    maxAttempts: 3, baseDelay: 0.3
                )
            ),
            gate: PriorityGate(maxConcurrent: 4),
            priorityFor: { $0.needsAuthentication ? .high : .normal }
        )
        let endpoint = APIEndpoint<JSON<User>>(
            baseURL: "https://api.test.com", path: "/users/5", method: .get, needsAuthentication: true
        )

        let user = try await client.request(endpoint)
        #expect(user.name == "Eve")
    }
}
