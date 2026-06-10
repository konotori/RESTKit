# RESTKit

**A lightweight, Swift 6-native networking foundation — compile-time typed, fully `Sendable`, zero dependencies.**

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2013%2B%20%7C%20macOS%2011%2B-blue?logo=apple)](#requirements)
[![SPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](#installation)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey)](LICENSE)

> English | [Tiếng Việt](README.vi.md)

An endpoint declares what it returns, so requesting the wrong type is a build error — not a runtime surprise. Data-race safe under strict concurrency, with one place to configure your API's conventions.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
  - [Endpoint](#endpoint)
  - [ResponseStrategy](#responsestrategy)
  - [RequestBody](#requestbody)
  - [APIClient](#apiclient)
  - [Error handling](#error-handling)
- [Organizing Endpoints](#organizing-endpoints)
- [Interceptors](#interceptors)
- [Production Patterns](#production-patterns)
  - [Token refresh (single-flight)](#token-refresh-single-flight)
  - [Pre-emptive token refresh](#pre-emptive-token-refresh)
  - [Retry with backoff & jitter](#retry-with-backoff--jitter)
  - [Idempotency keys](#idempotency-keys)
  - [Circuit breaker](#circuit-breaker)
  - [Rate limiting (token bucket)](#rate-limiting-token-bucket)
  - [Deduplication (in-flight coalescing)](#deduplication-in-flight-coalescing)
  - [Prioritization](#prioritization)
  - [Offline queue / replay (outbox)](#offline-queue--replay-outbox)
  - [Composing them](#composing-them)
- [Testing](#testing)
- [Design Goals](#design-goals)
- [License](#license)

## Features

- **Compile-time response typing** — `Endpoint` carries its response type as an associated type. No casts, no `Any`, no "type mismatch" at runtime.
- **`ResponseStrategy`** — declare *what* a response is: `JSON<Model>`, `Text`, `Raw`, or your own (e.g. envelope unwrapping).
- **Fully `Sendable`** — safe to hold in a `static let shared`, call from any actor, and fan out across tasks.
- **Interceptors** — adapt requests (auth, API keys) and observe completions (logging, metrics).
- **One place to configure conventions** — `bodyEncoder` / `responseDecoder` (snake_case, date formats) live on the client.
- **Honest errors** — encoding failures throw instead of silently sending an empty body; task cancellation surfaces as `CancellationError`, never wrapped as a network failure.

## Requirements

| | Minimum |
|---|---|
| iOS | 13.0 |
| macOS | 11.0 |
| Swift | 6.0 (SwiftPM tools 6.0) |

## Installation

### Xcode

1. **File → Add Package Dependencies…**
2. Paste the repository URL into the search field:
   ```
   https://github.com/konotori/RESTKit.git
   ```
3. Set the dependency rule to **Up to Next Major Version** from `1.0.0`, then click **Add Package**.

### Swift Package Manager

Add the dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/konotori/RESTKit.git", from: "1.0.0")
```

Then add `RESTKit` to your target:

```swift
.target(
    name: "MyApp",
    dependencies: ["RESTKit"]
)
```

## Quick Start

```swift
import RESTKit

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

// 1) Describe the call — only declare what differs from the defaults.
struct GetUser: Endpoint {
    typealias Response = JSON<User>          // ← what this endpoint returns

    let id: Int

    var baseURL: String { "https://api.example.com" }
    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }
}

// 2) Make the request — the result type flows from the endpoint.
let client = APIClient()
let user = try await client.request(GetUser(id: 1))   // user: User. No annotation needed.
```

And the safety net:

```swift
let post: Post = try await client.request(GetUser(id: 1))
// ❌ Compile error: cannot convert value of type 'User' to specified type 'Post'
```

## Core Concepts

RESTKit splits responsibilities along one rule:

| | Owns | Examples |
|---|---|---|
| **`Endpoint` = WHAT** | What the call is | path, method, body content, response type |
| **`APIClient` = HOW** | How calls are performed | JSON conventions, validation, interceptors, error contract |

### Endpoint

```swift
public protocol Endpoint<Response>: Sendable {
    associatedtype Response: ResponseStrategy

    var baseURL: String { get }
    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String]? { get }              // default: nil
    var queryParameters: [String: any Sendable]? { get } // default: nil
    var requestBody: RequestBody { get }                 // default: .none
    var needsAuthentication: Bool { get }                // default: false

    func asURLRequest(bodyEncoder: JSONEncoder) throws -> URLRequest
}
```

Endpoint parameters become stored properties — endpoints are plain values you can compare, log, and unit test in isolation.

Query parameter behavior:
- Sorted by key → deterministic URLs (stable cache keys, request signing, snapshot tests).
- Arrays expand to `key[]=a&key[]=b`.
- `NSNull` values are skipped.
- `+` is percent-encoded (`%2B`) so servers don't decode it as a space.

### ResponseStrategy

`Response` names a *strategy*, not just a model:

| Strategy | Result type | Use for |
|---|---|---|
| `JSON<Model>` | `Model` | JSON APIs (decoded with the client's `responseDecoder`) |
| `Text` | `String` | Plain-text responses |
| `Raw` | `Data` | Binary downloads, files |

Custom formats are a small conformance away — written once, reusable by any endpoint:

```swift
/// Unwraps the common { "data": ... } envelope.
enum Enveloped<Model: Decodable & Sendable>: ResponseStrategy {
    struct Envelope: Decodable { let data: Model }

    static func decode(_ data: Data, using decoder: JSONDecoder) throws -> Model {
        try decoder.decode(Envelope.self, from: data).data
    }
}

struct GetWrappedUser: Endpoint {
    typealias Response = Enveloped<User>   // reads exactly like what it does
    ...
}
```

Strategies throw their natural errors (`DecodingError`, your parser's error, ...); `APIClient` normalizes everything to `APIError.decodingFailed` in one place.

### RequestBody

```swift
var requestBody: RequestBody { .json(CreateUserRequest(name: "Alice")) }
```

| Case | Content-Type | Notes |
|---|---|---|
| `.json(any Encodable & Sendable)` | `application/json` | Encoded with the client's `bodyEncoder`. Encoding failures throw `APIError.encodingFailed` — never a silent empty body. |
| `.text(String)` | `text/plain` | UTF-8 |
| `.binary(Data)` | `application/octet-stream` | Sent as-is |
| `.form([String: any Sendable])` | `application/x-www-form-urlencoded` | Percent-encoded, space → `+`, arrays repeat the key, `NSNull` skipped, empty strings kept (`key=`) |
| `.none` | — | No body |

A `Content-Type` you set explicitly in `headers` always wins.

### APIClient

All conventions are configured once, at the client (parameters follow the data flow of a request):

```swift
let bodyEncoder = JSONEncoder()
bodyEncoder.keyEncodingStrategy = .convertToSnakeCase
bodyEncoder.dateEncodingStrategy = .iso8601

let responseDecoder = JSONDecoder()
responseDecoder.keyDecodingStrategy = .convertFromSnakeCase
responseDecoder.dateDecodingStrategy = .iso8601

let client = APIClient(
    client: URLSession.shared,                       // transport (HTTPClient)
    bodyEncoder: bodyEncoder,                        // request side
    responseDecoder: responseDecoder,                // response side
    responseValidator: DefaultResponseValidator(),   // status-code policy
    interceptors: [AuthInterceptor()]                // hooks
)
```

`APIClient` is `Sendable` — the shared-instance pattern just works under Swift 6:

```swift
enum API {
    static let shared = APIClient()
}
```

### Error handling

Every failure surfaces as `APIError`, except cancellation:

| Case | Meaning |
|---|---|
| `invalidURL` | `baseURL`/`path` could not form a URL |
| `encodingFailed(Error)` | Request body failed to encode |
| `requestFailed(Error)` | Transport-level failure (no connectivity, timeout, ...) |
| `invalidResponse` | Response was not HTTP |
| `redirectionError` / `clientError` / `serverError` / `unexpectedStatusCode` | Status-code buckets (4xx/5xx carry the response `Data?`) |
| `decodingFailed(Error)` | Response strategy failed to decode |
| `custom(String)` | For your own validators/interceptors |

**Cancellation contract:** if the surrounding `Task` is cancelled (e.g. a SwiftUI `.task` whose view disappeared), `request` throws `CancellationError` — not an `APIError`. Don't show error alerts for it:

```swift
do {
    user = try await client.request(GetUser(id: 1))
} catch is CancellationError {
    // user left the screen — do nothing
} catch let error as APIError {
    showAlert(error.localizedDescription)
}
```

## Organizing Endpoints

### Single backend (most apps) — one extension, zero per-endpoint cost

```swift
extension Endpoint {
    var baseURL: String { "https://api.myapp.com" }
}

struct GetProducts: Endpoint {
    typealias Response = JSON<[Product]>
    let category: String

    var path: String { "/v1/products" }
    var method: HTTPMethod { .get }
    var queryParameters: [String: any Sendable]? { ["category": category] }
}
```

### Multiple services — a 2-line marker protocol per service

The marker protocol is also the home for service-wide conventions (auth, headers):

```swift
protocol GitHubEndpoint: Endpoint {}
extension GitHubEndpoint {
    var baseURL: String { "https://api.github.com" }
    var needsAuthentication: Bool { true }
    var headers: [String: String]? { ["Accept": "application/vnd.github+json"] }
}

enum GitHub {   // namespace for discoverability
    struct SearchRepos: GitHubEndpoint {
        typealias Response = JSON<[Repo]>
        let query: String

        var path: String { "/search/repositories" }
        var method: HTTPMethod { .get }
        var queryParameters: [String: any Sendable]? { ["q": query] }
    }
}

let repos = try await client.request(GitHub.SearchRepos(query: "networking"))
```

### One-off calls — `APIEndpoint`, no custom type needed

```swift
let entries = try await client.request(
    APIEndpoint<JSON<[DictionaryEntry]>>(
        baseURL: "https://api.dictionaryapi.dev",
        path: "/api/v2/entries/en/swift",
        method: .get
    )
)
```

## Interceptors

```swift
public protocol RequestInterceptor: Sendable {
    /// Modify the request before it is sent.
    func adapt(_ request: URLRequest, for endpoint: any Endpoint) async throws -> URLRequest

    /// Observe the outcome (success, failure, or CancellationError).
    /// Not called if the request could not be built.
    func didComplete(_ request: URLRequest, result: Result<(Data, URLResponse), Error>, for endpoint: any Endpoint) async
}
```

Ordering (onion model): for `interceptors: [A, B]`, **B adapts first and A adapts last**, so the first registered interceptor sees the final request. `didComplete` runs in registration order.

### Bearer token auth

Endpoints opt in via `needsAuthentication` (default `false` — explicit is safer than implicit when credentials are involved):

```swift
actor TokenStore {
    private var token: String?

    func validToken() async throws -> String {
        if let token { return token }
        let refreshed = try await refresh()   // call your auth service
        token = refreshed
        return refreshed
    }
}

struct BearerAuthInterceptor: RequestInterceptor {
    let tokenStore: TokenStore

    func adapt(_ request: URLRequest, for endpoint: any Endpoint) async throws -> URLRequest {
        guard endpoint.needsAuthentication,
              request.url?.host == "api.myapp.com"   // second line of defense against token leaks
        else { return request }

        var request = request
        let token = try await tokenStore.validToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
```

### API key

```swift
struct APIKeyInterceptor: RequestInterceptor {
    let apiKey: String

    func adapt(_ request: URLRequest, for endpoint: any Endpoint) async throws -> URLRequest {
        var request = request
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        return request
    }
}
```

### Logging / metrics

```swift
struct LoggingInterceptor: RequestInterceptor {
    func didComplete(_ request: URLRequest, result: Result<(Data, URLResponse), Error>, for endpoint: any Endpoint) async {
        switch result {
        case .success: print("✅ \(endpoint.path)")
        case .failure(let error): print("❌ \(endpoint.path): \(error)")
        }
    }
}
```

## Production Patterns

RESTKit's core stays minimal; production concerns compose on top through **two seams**:

- **Interceptors** adapt every request (`adapt`) and observe every outcome (`didComplete`). Use them to *attach* something (auth header, API key) or *watch* (logging, metrics).
- **Decorators** wrap `APIClientProtocol` and control the *whole* request lifecycle — they can inspect the result, fail fast, gate, replay. Anything that reacts to the **outcome** (retry, refresh-on-401, circuit breaking, deduplication, prioritization) must be a decorator, because `adapt` can't see the response and `didComplete` can't change it or retry.

Every snippet below compiles against RESTKit as-is and was verified under concurrent load before publishing — single-flight refresh, in-flight coalescing, breaker transitions, and priority ordering each driven by a blocking-stub test that forces the requests to overlap. Copy them and adapt to your app.

> Decorators are `Sendable` value types wrapping `let base: any APIClientProtocol` — they nest freely (see [Composing them](#composing-them)) and the shared-instance pattern still works.

**In this section:** *Auth* — [token refresh](#token-refresh-single-flight), [pre-emptive refresh](#pre-emptive-token-refresh) · *Resilience* — [retry](#retry-with-backoff--jitter), [idempotency keys](#idempotency-keys), [circuit breaker](#circuit-breaker) · *Traffic shaping* — [rate limiting](#rate-limiting-token-bucket), [deduplication](#deduplication-in-flight-coalescing), [prioritization](#prioritization) · *Offline* — [offline queue](#offline-queue--replay-outbox) · then [composing them](#composing-them).

### Token refresh (single-flight)

**What** — When an access token expires mid-session, transparently refresh it and replay the failed request so callers never see the `401`. Concurrent `401`s must trigger **one** refresh, not a stampede.

**When** — OAuth2 / JWT: a short-lived access token paired with a long-lived refresh token.

**How it works**

1. An **interceptor** attaches the current access token to authenticated endpoints (`adapt`).
2. A **decorator** catches a `401` from an authenticated endpoint, asks the store to refresh, then retries once — the interceptor re-attaches the fresh token on the retry.
3. The store **coalesces** concurrent refreshes onto a single `Task`. A caller whose token was already rotated by someone else gets the new one without a second network round-trip.

```swift
/// Your app provides this — it mints a new access token (typically from a refresh token).
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
```

Wiring — the interceptor and the decorator share one store:

```swift
let store = AuthTokenStore(service: MyAuthService())
let client = AuthRefreshingClient(
    base: APIClient(interceptors: [BearerAuthInterceptor(store: store)]),
    store: store
)
```

#### Reactive vs. proactive refresh

The first line of `token()` is the *only* difference between two behaviors, and it matters for a request that **starts while a refresh is already in flight**:

| | Line present (**proactive**, shown above) | Line removed (**reactive**) |
|---|---|---|
| A latecomer request | Awaits the in-flight refresh, then fires **once** with the fresh token | Fires **once with the stale token**, takes its own `401`, *then* joins the refresh |
| Network calls for that latecomer | 1 (the real one) | 2 (a doomed `401` + the retry) |
| Refreshes triggered | 1 | 1 |

Both versions **coalesce to exactly one refresh** and resume every pending request once it lands — proactive simply skips the extra doomed call from a latecomer. Requests that *all* expire together (the common case) behave identically either way: they fire, all `401`, share one refresh, and retry. The distinction only appears for a request that arrives *after* a refresh has already begun. Start reactive if you prefer fewer moving parts; add the line when the wasted round-trip matters.

### Pre-emptive token refresh

**What** — Refresh the token *before* it expires (not after a `401`), so a burst of requests never sends a token that's about to be rejected.

**When** — The token carries an expiry you can read (JWT `exp`, OAuth `expires_in`). This is the only thing that prevents the "10 concurrent requests → 10 × `401`" stampede: reactive *and* proactive both still let a *simultaneous* batch fire stale, because the refresh only starts after the first `401` comes back. Pre-emptive refreshes ahead of time, so the batch goes out already-valid.

**How it works** — Give the token an `expiresAt`. `token()` returns the cached value only while it's comfortably valid (a `leeway` before expiry); otherwise it refreshes *first* — reusing the same single-flight `performRefresh()`, so a concurrent batch still collapses to one refresh and zero stale sends. Keep the `401`-catch decorator as a safety net for server-side revocation.

```swift
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
```

> Layer `AuthRefreshingClient` on top as a safety net for the rare `401` that still slips through (revocation, clock skew). If you use both the interceptor and that decorator, factor a small `TokenProvider` protocol (`token()` / `refresh(replacing:)`) so both accept either store.

### Retry with backoff & jitter

**What** — Automatically re-send a request that failed for a *transient* reason, backing off between attempts.

**When** — Flaky networks, load-balanced backends that occasionally 5xx, rate-limited APIs.

**How it works**

- Retry only **idempotent** methods (`HTTPMethod.idempotentMethods`) and **retryable** errors (5xx, `408`, `429`, transient `URLError`s). Never decoding/encoding/other-4xx errors, and never cancellation.
- Back off with **exponential delay + full jitter** so many clients don't synchronize into a thundering herd on recovery.
- Cap at `maxAttempts`.

```swift
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

let client = RetryingClient(base: APIClient(), maxAttempts: 3, baseDelay: 0.3)  // 0–0.3s, 0–0.6s
```

> **Limitation — `Retry-After`:** `APIError` carries the response body (`Data?`) but not headers, so a decorator can't read a server's `Retry-After`. To honor it, capture the header in a custom `ResponseValidator` or interceptor and surface the wait via `APIError.custom`.

### Idempotency keys

**What** — Attach a stable `Idempotency-Key` to mutating requests so a retried (or double-tapped) request is performed *once* by the server — no double charge, no duplicate order.

**When** — Any non-idempotent mutation you might retry (payments, order creation). It's what makes **retrying a `POST` safe** — without it, the retry recipe deliberately skips non-idempotent methods.

**How it works** — The endpoint carries the key, generated **once** when the endpoint value is created, so every retry of that value sends the *same* key (a fresh per-`adapt` UUID would defeat the point). An interceptor attaches it. With the key in place, widen the retry guard to also cover keyed endpoints.

```swift
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
```

A mutating endpoint mints its key once, at creation:

```swift
struct CreateCharge: IdempotentEndpoint {
    typealias Response = JSON<Charge>
    let idempotencyKey = UUID().uuidString   // generated ONCE → reused on every retry
    let amount: Int

    var path: String { "/charges" }
    var method: HTTPMethod { .post }
}
```

> The key must be stable across retries → it lives on the endpoint **value**, not generated in `adapt`. If you replay across app launches (see [offline queue](#offline-queue--replay-outbox)), persist the key alongside the request.

### Circuit breaker

**What** — Once a backend is failing consistently, stop sending requests for a cooldown ("open" the circuit) and fail fast — instead of piling more load onto a struggling server and making every user wait out a timeout.

**When** — Protecting a dependency that can be overwhelmed; improving perceived latency during an outage (an instant failure beats a 30-second timeout).

**How it works** — three states:

- **Closed** — requests flow; consecutive backend failures are counted.
- **Open** — after `failureThreshold` failures, reject immediately with `CircuitBreakerError.open` until `cooldown` elapses.
- **Half-open** — after the cooldown, allow a trial request: success → Closed, failure → Open again.

Only backend faults (5xx, transport, non-HTTP) count — a `4xx` means the server is healthy and answered.

```swift
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

let client = CircuitBreakingClient(
    base: APIClient(),
    breaker: CircuitBreaker(failureThreshold: 5, cooldown: 30)
)
```

> One breaker tracks one circuit — use a separate instance per host/service. This version admits whichever requests arrive first during the half-open window; a stricter variant would let through exactly one trial.

### Rate limiting (token bucket)

**What** — Pace *outgoing* requests to stay under an API's published rate limit, smoothing bursts instead of waiting to be `429`'d.

**When** — Rate-limited APIs. Distinct from the [circuit breaker](#circuit-breaker) (reacts to *failures*) and [prioritization](#prioritization) (caps *concurrency*): this caps *throughput over time*.

**How it works** — A token-bucket limiter: `burst` requests may go back-to-back after an idle period, then a steady `rate`. It's implemented with a single reserved `cursor` advanced *before* sleeping, so concurrent callers queue in order (fair, no starvation). The decorator awaits a slot before each request.

```swift
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

let client = RateLimitedClient(base: APIClient(), limiter: RateLimiter(rate: 10, burst: 5))
```

### Deduplication (in-flight coalescing)

**What** — When several callers ask for the *same* resource at the same time, fire **one** network call and share its result with all of them.

**When** — Multiple SwiftUI views appearing together, a prefetch racing an on-appear, rapid re-renders. Saves bandwidth and backend load.

**How it works** — Key each request by method + URL. The first caller for a key starts a `Task` and stores it; concurrent callers for the same key `await` that *same* task. The key is cleared when the task finishes — so it coalesces **in-flight** requests (it is not a cache). Restricted to `GET` (safe, idempotent reads).

```swift
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

let client = DeduplicatingClient(base: APIClient())
```

> Each endpoint's `Output` type differs, so the coalescer stores `Task<any Sendable, Error>` and the value is cast back to `E.Response.Output`. The key includes the full (deterministically-ordered) URL, so callers sharing a key share an `Output` type; the `as?` fallback to a direct call covers a theoretical cross-type key collision.

### Prioritization

Cap how many requests run at once — and, optionally, order the queue so important requests go first. **Two levels; pick what you actually need.**

**Level 1 — just cap concurrency.** The common case: "never more than N in flight" to protect the device and connection (prefetches shouldn't open 50 sockets). A plain semaphore is all you need:

```swift
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

let client = ConcurrencyLimitedClient(base: APIClient(), limiter: ConcurrencyLimiter(limit: 4))
```

> Trade-off: it's FIFO and doesn't special-case cancellation — a cancelled *queued* request still waits its turn before bailing (it won't deadlock, it just isn't prompt). Fine for most apps. Reach for Level 2 only if you need ordering or prompt cancellation.

**Level 2 — cap *and* prioritize.** Use a priority gate when queued requests must be **ordered** (user-initiated ahead of prefetch/analytics) **and** a cancelled queued request must bail **immediately** (never holding a slot hostage when a SwiftUI view disappears). This is more intricate — only adopt it when those two properties matter.

**How it works** — An async semaphore with `maxConcurrent` slots. When full, callers suspend on a continuation stored in a priority-ordered list; each `release()` hands the freed slot to the **highest-priority waiter** (FIFO within a level). Cancelling a queued request removes its waiter and throws `CancellationError`.

```swift
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

let client = PrioritizedClient(
    base: APIClient(),
    gate: PriorityGate(maxConcurrent: 4),
    priorityFor: { $0.needsAuthentication ? .high : .normal }
)
```

### Offline queue / replay (outbox)

**What** — Persist mutations made while offline and replay them, in order, when connectivity returns.

**When** — Offline-first apps; fire-and-forget mutations (analytics, "mark as read", outgoing messages) where the caller doesn't need the server's response immediately.

**How it works** — Unlike the others, this is **not** an `APIClientProtocol` decorator: an offline mutation has no response to return, so the caller gets an enqueue acknowledgement instead. `submit` queues a (type-erased) send; `drain` (call it when the network returns) replays FIFO. A connectivity error keeps the item and stops; any other failure is **permanent** → the item is dropped and reported via `onResult`, so a poison message can't block the queue forever.

```swift
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

// Submit while offline; drain when the path comes back (e.g. from NWPathMonitor):
let outbox = Outbox(client: APIClient()) { label, outcome in
    if case let .dropped(error) = outcome { log("dropped \(label): \(error)") }
}
await outbox.submit(MarkAsRead(id: 42), label: "read-42")
// ...later, on reconnect...
await outbox.drain()
```

> In-memory here. To survive app relaunches, persist an encodable representation of each request (URL / method / body / idempotency key) to disk instead of a closure, and rebuild the queue on launch. Because it's fire-and-forget, surface ultimate failures through `onResult` (a badge, a log, a re-prompt).

### Composing them

Each decorator wraps `any APIClientProtocol`, so they nest. The **outermost** decorator sees the call first. A sensible production stack:

```swift
let store = AuthTokenStore(service: MyAuthService())
let core = APIClient(interceptors: [BearerAuthInterceptor(store: store), LoggingInterceptor()])

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
```

Order encodes policy. In the stack above:

- **Prioritization** is outermost — a request waits for a slot *before* any work begins.
- **Deduplication** sits above retry — duplicate calls coalesce onto one retrying-and-breaking pipeline.
- **Circuit breaker** sits inside retry — each retry attempt is gated by the breaker, so retries don't hammer a circuit that's already open.
- **Auth refresh** is closest to the core, so a 401 is resolved before retry/breaker logic sees the outcome.

Reorder to match your own policy (e.g. breaker outside retry to count the *final* outcome rather than each attempt).

## Testing

Mock at the transport seam — `HTTPClient` is one method:

```swift
public protocol HTTPClient: Sendable {
    func perform(request: URLRequest) async throws -> (Data, URLResponse)
}
```

```swift
struct StubHTTPClient: HTTPClient {
    let data: Data
    let statusCode: Int

    func perform(request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil
        )!
        return (data, response)
    }
}

let client = APIClient(client: StubHTTPClient(data: userJSON, statusCode: 200))
let user = try await client.request(GetUser(id: 1))
```

Endpoints are testable without any networking at all:

```swift
let request = try GetUser(id: 1).asURLRequest()
#expect(request.url?.absoluteString == "https://api.example.com/users/1")
```

Run the package's own suite (90+ tests) with:

```bash
swift test
```

## Design Goals

- **Compile-time safety over runtime checks** — if it builds, the types line up.
- **Endpoint = WHAT, Client = HOW** — declarations stay tiny; conventions live in one place.
- **Minimal policy in core** — retry, caching, and auth flows compose on top via interceptors and decorators.
- **Swift 6 first** — `Sendable` end to end, no `@unchecked` in the library.
- Lightweight and dependency-free.

## License

[MIT](LICENSE)
