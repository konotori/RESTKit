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
        if let refreshTask { return try await refreshTask.value }   // proactive: join an in-flight refresh
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

// Level 1 — just cap concurrency (no priority). ~15 lines.
actor ConcurrencyLimiter {
    private let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if inUse < limit { inUse += 1; return }
        await withCheckedContinuation { waiters.append($0) }   // park (FIFO)
    }

    func release() {
        if waiters.isEmpty { inUse -= 1 } else { waiters.removeFirst().resume() }
    }
}

struct ConcurrencyLimitedClient: APIClientProtocol {
    let base: any APIClientProtocol
    let limiter: ConcurrencyLimiter

    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response.Output {
        await limiter.acquire()
        do {
            let result = try await base.request(endpoint)
            await limiter.release()
            return result
        } catch {
            await limiter.release()
            throw error
        }
    }
}

// Level 2 — cap AND prioritize (+ prompt cancellation of queued requests).
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

// MARK: - Pattern 6: Pre-emptive token refresh --------------------------------

struct AccessToken: Sendable {
    let value: String
    let expiresAt: Date
}

protocol ExpiringTokenService: Sendable {
    func refresh() async throws -> AccessToken
}

actor PreemptiveTokenStore {
    private let service: ExpiringTokenService
    private var token: AccessToken?
    private var refreshTask: Task<AccessToken, Error>?
    private let leeway: TimeInterval

    init(service: ExpiringTokenService, initial: AccessToken? = nil, leeway: TimeInterval = 30) {
        self.service = service
        self.token = initial
        self.leeway = leeway
    }

    /// Refreshes *before* the token expires (within `leeway`), so requests rarely
    /// send a token that is about to be rejected.
    func token() async throws -> String {
        if let refreshTask { return try await refreshTask.value.value }   // join in-flight refresh
        if let token, token.expiresAt.timeIntervalSinceNow > leeway {
            return token.value                                            // still comfortably valid
        }
        return try await performRefresh().value
    }

    /// Reactive safety net for a 401 that still slips through (e.g. server-side revocation).
    func refresh(replacing staleValue: String) async throws -> String {
        if let token, token.value != staleValue { return token.value }
        return try await performRefresh().value
    }

    private func performRefresh() async throws -> AccessToken {
        if let refreshTask { return try await refreshTask.value }
        let task = Task<AccessToken, Error> {
            let new = try await service.refresh()
            token = new
            return new
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}

struct PreemptiveAuthInterceptor: RequestInterceptor {
    let store: PreemptiveTokenStore

    func adapt(_ request: URLRequest, for endpoint: any Endpoint) async throws -> URLRequest {
        guard endpoint.needsAuthentication else { return request }
        var request = request
        request.setValue("Bearer \(try await store.token())", forHTTPHeaderField: "Authorization")
        return request
    }
}

// MARK: - Pattern 7: Idempotency key ------------------------------------------

protocol IdempotentEndpoint: Endpoint {
    var idempotencyKey: String { get }
}

struct IdempotencyKeyInterceptor: RequestInterceptor {
    func adapt(_ request: URLRequest, for endpoint: any Endpoint) async throws -> URLRequest {
        guard let endpoint = endpoint as? any IdempotentEndpoint else { return request }
        var request = request
        request.setValue(endpoint.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        return request
    }
}

/// Like RetryingClient, but also retries an endpoint carrying an idempotency key —
/// the server dedupes replays, so a keyed POST/PATCH is safe to retry.
struct IdempotentRetryingClient: APIClientProtocol {
    let base: any APIClientProtocol
    let maxAttempts: Int
    let baseDelay: TimeInterval

    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response.Output {
        var attempt = 1
        while true {
            do {
                return try await base.request(endpoint)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError {
                let safeToRetry = HTTPMethod.idempotentMethods.contains(endpoint.method)
                    || endpoint is any IdempotentEndpoint       // key makes a mutation replay-safe
                guard attempt < maxAttempts, safeToRetry, RetryingClient.isRetryable(error)
                else { throw error }
                let ceiling = baseDelay * Double(1 << (attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(Double.random(in: 0 ... ceiling) * 1_000_000_000))
                attempt += 1
            }
        }
    }
}

// MARK: - Pattern 8: Client-side rate limiting (token bucket) ------------------

actor RateLimiter {
    private let spacing: TimeInterval        // average gap between requests = 1 / rate
    private let burstWindow: TimeInterval    // how far `cursor` may sit behind now = the burst budget
    private var cursor: Date = .distantPast  // when the most-recently-admitted request was scheduled

    /// `rate` = requests/sec sustained; `burst` = how many may go back-to-back after idle.
    init(rate: Double, burst: Int) {
        self.spacing = 1 / rate
        self.burstWindow = Double(burst - 1) / rate
    }

    func acquire() async throws {
        let now = Date()
        // Reserve the next slot synchronously (before sleeping) so concurrent callers
        // queue in order; never let the schedule fall more than `burstWindow` behind now.
        let scheduled = max(cursor + spacing, now - burstWindow)
        cursor = scheduled
        let wait = scheduled.timeIntervalSince(now)
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}

struct RateLimitedClient: APIClientProtocol {
    let base: any APIClientProtocol
    let limiter: RateLimiter

    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response.Output {
        try await limiter.acquire()
        return try await base.request(endpoint)
    }
}

// MARK: - Pattern 9: Offline queue / replay (outbox) --------------------------

/// Fire-and-forget queue for mutations that must survive being offline. NOT an
/// APIClientProtocol decorator: an offline mutation has no response to return, so
/// the caller gets an enqueue acknowledgement and `drain()` replays it later.
actor Outbox {
    enum Outcome: Sendable { case sent, dropped(APIError) }

    private struct Item {
        let label: String
        let send: @Sendable () async throws -> Void
    }

    private let client: any APIClientProtocol
    private let onResult: @Sendable (String, Outcome) -> Void
    private var pending: [Item] = []

    init(client: any APIClientProtocol, onResult: @escaping @Sendable (String, Outcome) -> Void = { _, _ in }) {
        self.client = client
        self.onResult = onResult
    }

    var pendingCount: Int { pending.count }

    /// Enqueue a mutation (fire-and-forget). `label` identifies it in `onResult`.
    func submit<E: Endpoint>(_ endpoint: E, label: String) {
        let client = self.client
        pending.append(Item(label: label, send: { _ = try await client.request(endpoint) }))
    }

    /// Replay in order. Call when connectivity returns. A connectivity error keeps
    /// the item and stops (retry on the next drain); any other failure is permanent,
    /// so the item is dropped and reported — it can't block the queue forever.
    func drain() async {
        while let item = pending.first {
            do {
                try await item.send()
                pending.removeFirst()
                onResult(item.label, .sent)
            } catch let error as APIError where Self.isConnectivity(error) {
                break
            } catch let error as APIError {
                pending.removeFirst()
                onResult(item.label, .dropped(error))
            } catch {
                break   // cancellation / unknown → keep, try later
            }
        }
    }

    static func isConnectivity(_ error: APIError) -> Bool {
        guard case let .requestFailed(underlying) = error, let urlError = underlying as? URLError else {
            return false
        }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost]
            .contains(urlError.code)
    }
}

// MARK: - Test infrastructure -------------------------------------------------

/// Stand-in for the README's "Logging / metrics" interceptor — no-op here so the
/// composition test stays quiet; only needed so the flagship wiring compiles.
struct LoggingInterceptor: RequestInterceptor {}

/// Endpoints used by the pattern 6–9 tests.
struct CreateCharge: IdempotentEndpoint {
    typealias Response = JSON<User>
    let idempotencyKey = UUID().uuidString          // generated ONCE per endpoint value
    let amount: Int
    var baseURL: String { "https://api.test.com" }
    var path: String { "/charges" }
    var method: HTTPMethod { .post }
}

struct PostEvent: Endpoint {
    typealias Response = Raw
    let id: Int
    var baseURL: String { "https://api.test.com" }
    var path: String { "/events/\(id)" }
    var method: HTTPMethod { .post }
}

/// Expiring-token refresh service that signals when it starts and blocks until released.
final class GatedExpiringService: ExpiringTokenService, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    private func bump() { lock.lock(); defer { lock.unlock() }; _count += 1 }

    private let token: AccessToken
    let entered: Gate
    let release: Gate

    init(token: AccessToken, entered: Gate, release: Gate) {
        self.token = token
        self.entered = entered
        self.release = release
    }

    func refresh() async throws -> AccessToken {
        bump()
        entered.open()
        await release.wait()
        return token
    }
}

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

/// Tracks peak concurrency.
actor ConcurrencyTracker {
    private(set) var peak = 0
    private var current = 0
    func enter() { current += 1; peak = Swift.max(peak, current) }
    func leave() { current -= 1 }
}

/// Manual latch that releases ALL waiters on `open()` (unlike the single-waiter `Gate`).
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock(); defer { lock.unlock() }
            if opened { cont.resume() } else { waiters.append(cont) }
        }
    }

    func open() {
        lock.lock(); let resume = waiters; waiters = []; opened = true; lock.unlock()
        resume.forEach { $0.resume() }
    }
}

/// Refresh service that signals when it starts and blocks until the test releases
/// it — lets a test hold a refresh "in flight" while another request arrives.
final class GatedRefreshService: TokenRefreshService, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    private func bump() { lock.lock(); defer { lock.unlock() }; _count += 1 }

    private let newToken: String
    let entered: Gate
    let release: Gate

    init(newToken: String, entered: Gate, release: Gate) {
        self.newToken = newToken
        self.entered = entered
        self.release = release
    }

    func refresh() async throws -> String {
        bump()
        entered.open()          // signal: a refresh is now in flight
        await release.wait()    // block until the test lets it finish
        return newToken
    }
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

    /// Proactive `token()`: a request arriving WHILE a refresh is in flight waits for
    /// it and fires once with the fresh token — instead of firing a doomed stale call.
    @Test func proactiveTokenWaitsForInFlightRefresh() async throws {
        let entered = Gate()
        let release = Gate()
        let refresh = GatedRefreshService(newToken: "v1", entered: entered, release: release)
        let store = AuthTokenStore(service: refresh, initialToken: "v0")
        let body = userData(id: 1, name: "Alice")
        let staleCalls = LockedBox(0)

        let stub = StubHTTPClient { request, _ in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer v1" {
                return (body, 200)
            }
            staleCalls.value += 1                               // a request fired with the stale token
            return (Data(#"{"message":"unauthorized"}"#.utf8), 401)
        }
        let core = APIClient(client: stub, interceptors: [BearerAuthInterceptor(store: store)])
        let client = AuthRefreshingClient(base: core, store: store)
        let endpoint = APIEndpoint<JSON<User>>(
            baseURL: "https://api.test.com", path: "/me", method: .get, needsAuthentication: true
        )

        // A fires with the stale token, 401s, and starts the refresh (which blocks).
        let a = Task { try await client.request(endpoint) }
        await entered.wait()                                    // refresh is now in flight

        // B arrives mid-refresh. Proactive token() makes it WAIT, not fire a doomed call.
        let b = Task { try await client.request(endpoint) }
        try await Task.sleep(nanoseconds: 150_000_000)          // give B time to park in token()
        release.open()                                          // let the refresh complete

        let userA = try await a.value
        let userB = try await b.value
        #expect(userA.name == "Alice")
        #expect(userB.name == "Alice")
        #expect(refresh.count == 1)                             // one refresh
        #expect(staleCalls.value == 1)                          // only A's discovery 401 — B never sent a stale call
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

    @Test func concurrencyLimiterCapsInFlight() async throws {
        let limit = 2
        let tracker = ConcurrencyTracker()
        let hold = Latch()
        let body = userData(id: 10, name: "Judy")
        let stub = StubHTTPClient { _, _ in
            await tracker.enter()
            await hold.wait()                                   // hold every admitted request in flight
            await tracker.leave()
            return (body, 200)
        }
        let client = ConcurrencyLimitedClient(base: APIClient(client: stub), limiter: ConcurrencyLimiter(limit: limit))
        let endpoint = APIEndpoint<JSON<User>>(baseURL: "https://api.test.com", path: "/u", method: .get)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 6 { group.addTask { _ = try await client.request(endpoint) } }
            try await Task.sleep(nanoseconds: 200_000_000)      // limiter admits `limit`, the rest queue
            #expect(await tracker.peak == limit)                // only `limit` got past acquire()
            hold.open()                                         // release them; queued ones flow in
            try await group.waitForAll()
        }
        #expect(await tracker.peak == limit)                    // never exceeded the cap
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

    // MARK: Pattern 6 — pre-emptive refresh

    @Test func preemptiveRefreshSendsNoStaleTokenAndIsSingleFlight() async throws {
        let n = 5
        let entered = Gate()
        let release = Gate()
        let service = GatedExpiringService(
            token: AccessToken(value: "v1", expiresAt: .distantFuture), entered: entered, release: release
        )
        // Start with an ALREADY-EXPIRED token so the first request must refresh first.
        let store = PreemptiveTokenStore(
            service: service, initial: AccessToken(value: "v0", expiresAt: Date().addingTimeInterval(-60))
        )
        let staleCalls = LockedBox(0)
        let body = userData(id: 9, name: "Ivy")
        let stub = StubHTTPClient { request, _ in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer v1" { return (body, 200) }
            staleCalls.value += 1
            return (Data(#"{"message":"unauthorized"}"#.utf8), 401)
        }
        let core = APIClient(client: stub, interceptors: [PreemptiveAuthInterceptor(store: store)])
        let endpoint = APIEndpoint<JSON<User>>(
            baseURL: "https://api.test.com", path: "/me", method: .get, needsAuthentication: true
        )

        let users = try await withThrowingTaskGroup(of: User.self) { group -> [User] in
            for _ in 0 ..< n { group.addTask { try await core.request(endpoint) } }
            await entered.wait()                                // a pre-emptive refresh is in flight
            try await Task.sleep(nanoseconds: 150_000_000)      // let the others reach token() and join
            release.open()
            var result: [User] = []
            for try await user in group { result.append(user) }
            return result
        }

        #expect(users.count == n)
        #expect(staleCalls.value == 0)                          // nobody ever sent the expired token
        #expect(service.count == 1)                             // single-flight refresh
    }

    // MARK: Pattern 7 — idempotency key

    @Test func idempotencyKeyIsStableAcrossRetries() async throws {
        let seenKeys = LockedBox<[String]>([])
        let body = userData(id: 7, name: "Grace")
        let stub = StubHTTPClient { request, attempt in
            if let key = request.value(forHTTPHeaderField: "Idempotency-Key") { seenKeys.value.append(key) }
            return attempt < 2 ? (Data(), 503) : (body, 200)    // fail once, then succeed
        }
        let core = APIClient(client: stub, interceptors: [IdempotencyKeyInterceptor()])
        let client = IdempotentRetryingClient(base: core, maxAttempts: 3, baseDelay: 0)

        let user = try await client.request(CreateCharge(amount: 100))   // POST, retried because it carries a key
        #expect(user.name == "Grace")
        #expect(seenKeys.value.count == 2)                      // two attempts
        #expect(seenKeys.value.first == seenKeys.value.last)    // ← SAME key across the retry
    }

    // MARK: Pattern 8 — rate limiting

    @Test func rateLimiterPacesRequests() async throws {
        let body = userData(id: 8, name: "Heidi")
        let stub = StubHTTPClient { _, _ in (body, 200) }
        let limiter = RateLimiter(rate: 20, burst: 1)           // 1 immediate, then ~50ms apart
        let client = RateLimitedClient(base: APIClient(client: stub), limiter: limiter)
        let endpoint = APIEndpoint<JSON<User>>(baseURL: "https://api.test.com", path: "/u", method: .get)

        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 10 { group.addTask { _ = try await client.request(endpoint) } }
            try await group.waitForAll()
        }
        // 10 requests @ ~50ms spacing ≈ 0.45s. Lower bound only — Task.sleep can only
        // overshoot, so `elapsed ≥ 0.2` cannot flake low (no-limiting would be ≈ 0).
        #expect(Date().timeIntervalSince(start) >= 0.2)
    }

    // MARK: Pattern 9 — offline queue / replay

    @Test func outboxReplaysInOrderWhenOnline() async throws {
        let online = LockedBox(false)
        let sent = LockedBox<[String]>([])
        let stub = StubHTTPClient { request, _ in
            if !online.value { throw URLError(.notConnectedToInternet) }
            sent.value.append(request.url!.path)
            return (Data("{}".utf8), 200)
        }
        let outbox = Outbox(client: APIClient(client: stub))
        await outbox.submit(PostEvent(id: 1), label: "e1")
        await outbox.submit(PostEvent(id: 2), label: "e2")
        await outbox.submit(PostEvent(id: 3), label: "e3")

        await outbox.drain()                                    // offline → all kept
        #expect(sent.value.isEmpty)
        #expect(await outbox.pendingCount == 3)

        online.value = true
        await outbox.drain()                                    // online → replay in order
        #expect(sent.value == ["/events/1", "/events/2", "/events/3"])
        #expect(await outbox.pendingCount == 0)
    }

    @Test func outboxDropsPermanentFailureInsteadOfBlocking() async throws {
        let sent = LockedBox<[String]>([])
        let dropped = LockedBox<[String]>([])
        let stub = StubHTTPClient { request, _ in
            let path = request.url!.path
            if path == "/events/2" { return (Data(), 422) }     // item 2 is poison (permanent 4xx)
            sent.value.append(path)
            return (Data("{}".utf8), 200)
        }
        let outbox = Outbox(client: APIClient(client: stub)) { label, outcome in
            if case .dropped = outcome { dropped.value.append(label) }
        }
        await outbox.submit(PostEvent(id: 1), label: "e1")
        await outbox.submit(PostEvent(id: 2), label: "e2")
        await outbox.submit(PostEvent(id: 3), label: "e3")

        await outbox.drain()
        #expect(sent.value == ["/events/1", "/events/3"])       // e2 dropped, e3 NOT blocked behind it
        #expect(dropped.value == ["e2"])
        #expect(await outbox.pendingCount == 0)
    }
}
