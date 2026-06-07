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
- [Retry (decorator pattern)](#retry-decorator-pattern)
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

## Retry (decorator pattern)

RESTKit keeps retry policy out of the core. Wrap the client and use `HTTPMethod.idempotentMethods` to retry only safe methods:

```swift
struct RetryingAPIClient: APIClientProtocol {
    let base: any APIClientProtocol
    let maxAttempts: Int

    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response.Output {
        var attempt = 1
        while true {
            do {
                return try await base.request(endpoint)
            } catch is CancellationError {
                throw CancellationError()            // never retry cancellation
            } catch {
                guard HTTPMethod.idempotentMethods.contains(endpoint.method),
                      attempt < maxAttempts
                else { throw error }

                try await Task.sleep(nanoseconds: 300_000_000 << (attempt - 1))  // 0.3s, 0.6s, ...
                attempt += 1
            }
        }
    }
}

let client = RetryingAPIClient(base: APIClient(), maxAttempts: 3)
```

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
