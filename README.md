# RESTKit

RESTKit is a lightweight, reusable Swift networking foundation designed to be embedded in many projects. It provides clean abstractions, testability, and extensibility without forcing app-specific policies.

## Features
- `Endpoint` protocol with base URL, path, method, headers, query, body, and response type.
- `APIClientProtocol` + `APIClient` for request execution, validation, and decoding.
- `HTTPClient` abstraction for easy mocking and testing.
- `RequestInterceptor` for request adaptation and lifecycle hooks.
- `ResponseValidator` and `ResponseDecoder` with sensible defaults.
- Strongly typed `RequestBody` and `ResponseType`.
- `APIError` for consistent error handling.

## Installation
Add as a Swift Package.

```swift
// Package.swift
.package(url: "https://github.com/your-org/RESTKit.git", from: "1.0.0")
```

## Quick Start

### 1) Define an Endpoint
```swift
import RESTKit

struct GetUserEndpoint: Endpoint {
    let userId: Int

    var baseURL: String { "https://api.example.com" }
    var path: String { "/users/\(userId)" }
    var method: HTTPMethod { .get }
    var headers: [String : String]? { nil }
    var queryParameters: [String : Any]? { nil }
    var requestBody: RequestBody { .none }
    var responseType: ResponseType { .json(User.self) }
}

struct User: Decodable {
    let id: Int
    let name: String
}
```

### 2) Create a client and make a request
```swift
let client = APIClient()
let endpoint = GetUserEndpoint(userId: 1)
let user: User = try await client.request(endpoint)
```

## Core Concepts

### Endpoint
`Endpoint` describes everything needed to build a `URLRequest`.

- `baseURL`: base host (e.g. `https://api.example.com`)
- `path`: resource path (e.g. `/users`)
- `method`: HTTP method
- `headers`: custom headers
- `queryParameters`: query dictionary
- `requestBody`: body data and content type
- `responseType`: how to decode the response

Defaults:
- `needsAuthentication` → `true`
- `allowRetry` → `true` for idempotent methods (a hint for higher layers)

### RequestBody
Supported body types:
- `.json(Encodable)`
- `.text(String)`
- `.binary(Data)`
- `.form([String: Any])`
- `.none`

`form` uses `application/x-www-form-urlencoded` rules, skips `NSNull` and empty strings, and supports arrays (duplicate keys).

### ResponseType
Supported response types:
- `.json(Decodable.Type)`
- `.text`
- `.data`
- `.custom((Data) throws -> Any)`

### ResponseDecoder / ResponseValidator
Default implementations:
- `DefaultResponseDecoder` handles JSON, text, data, and custom.
- `DefaultResponseValidator` maps HTTP codes into `APIError`.

```swift
let client = APIClient(
    responseValidator: DefaultResponseValidator(),
    responseDecoder: DefaultResponseDecoder()
)
```

### Per-API ResponseDecoder / ResponseValidator
Different APIs may use different status code rules or response formats. You can create multiple `APIClient` instances with different decoders/validators and choose per endpoint group.

```swift
// Example: API A uses normal JSON + standard status mapping
let apiAClient = APIClient(
    responseValidator: DefaultResponseValidator(),
    responseDecoder: DefaultResponseDecoder()
)

// Example: API B returns JSON even on errors (custom validator),
// and sometimes wraps data under a "payload" key (custom decoder).
struct APIBValidator: ResponseValidator {
    func validate(statusCode: Int, data: Data) throws {
        // Treat 200-299 as success, 400-499 as client error,
        // and map 500+ to server error (customize as needed).
        try DefaultResponseValidator().validate(statusCode: statusCode, data: data)
    }
}

struct APIBDecoder: ResponseDecoder {
    func decode(data: Data, as responseType: ResponseType) throws -> Any {
        // Example: unwrap { "payload": ... } for JSON responses.
        guard case let .json(type) = responseType else {
            return try DefaultResponseDecoder().decode(data: data, as: responseType)
        }
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let payload = raw?["payload"] {
            let payloadData = try JSONSerialization.data(withJSONObject: payload)
            return try JSONDecoder().decode(type, from: payloadData)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

let apiBClient = APIClient(
    responseValidator: APIBValidator(),
    responseDecoder: APIBDecoder()
)
```

### HTTPClient
`HTTPClient` abstracts the transport. `URLSession` already conforms.

```swift
public protocol HTTPClient {
    func perform(request: URLRequest) async throws -> (Data, URLResponse)
}
```

You can provide a custom client for testing:
```swift
final class MockHTTPClient: HTTPClient {
    func perform(request: URLRequest) async throws -> (Data, URLResponse) {
        // return mock data + response
    }
}
```

### RequestInterceptor
Interceptors allow you to adapt requests and observe completion.

```swift
struct AuthInterceptor: RequestInterceptor {
    func adapt(_ request: URLRequest, for endpoint: Endpoint) async throws -> URLRequest {
        var r = request
        r.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        return r
    }
}

let client = APIClient(interceptors: [AuthInterceptor()])
```

## Advanced Use Cases

### AuthInterceptor with Bearer Token (and refresh)
Use an actor-backed token store to safely read/update tokens, and only attach auth for endpoints that require it.

```swift
actor TokenStore {
    private var token: String?

    func currentToken() -> String? { token }
    func update(token: String) { self.token = token }

    func refreshTokenIfNeeded() async throws -> String {
        // Call your auth service here and update token.
        let newToken = "new-token"
        self.token = newToken
        return newToken
    }
}

struct BearerAuthInterceptor: RequestInterceptor {
    let tokenStore: TokenStore

    func adapt(_ request: URLRequest, for endpoint: Endpoint) async throws -> URLRequest {
        guard endpoint.needsAuthentication else { return request }
        var r = request
        let token = await tokenStore.currentToken() ?? (try await tokenStore.refreshTokenIfNeeded())
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }
}
```

### API Key (Header or Query)
Some APIs require a static key. You can add it in headers or query string.

```swift
struct ApiKeyHeaderInterceptor: RequestInterceptor {
    let apiKey: String

    func adapt(_ request: URLRequest, for endpoint: Endpoint) async throws -> URLRequest {
        var r = request
        r.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        return r
    }
}

struct ApiKeyQueryInterceptor: RequestInterceptor {
    let apiKey: String

    func adapt(_ request: URLRequest, for endpoint: Endpoint) async throws -> URLRequest {
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return request
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "api_key", value: apiKey))
        components.queryItems = items

        var r = request
        r.url = components.url
        return r
    }
}
```

### Retrying API Client (with backoff)
RESTKit keeps retry policy out of core. Wrap `APIClient` to add retry logic and honor `Endpoint.allowRetry`.

```swift
struct RetryPolicy {
    let maxAttempts: Int
    let baseDelay: UInt64 // nanoseconds

    func delay(for attempt: Int) -> UInt64 {
        // Exponential backoff: 0.3s, 0.6s, 1.2s, ...
        baseDelay * UInt64(1 << max(0, attempt - 1))
    }
}

final class RetryingAPIClient: APIClientProtocol {
    private let base: APIClientProtocol
    private let policy: RetryPolicy

    init(base: APIClientProtocol, policy: RetryPolicy) {
        self.base = base
        self.policy = policy
    }

    func request<T>(_ endpoint: Endpoint) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await base.request(endpoint)
            } catch {
                guard endpoint.allowRetry, attempt < policy.maxAttempts else { throw error }
                let delay = policy.delay(for: attempt)
                try await Task.sleep(nanoseconds: delay)
                attempt += 1
            }
        }
    }
}

let baseClient = APIClient(interceptors: [BearerAuthInterceptor(tokenStore: TokenStore())])
let retrying = RetryingAPIClient(
    base: baseClient,
    policy: RetryPolicy(maxAttempts: 3, baseDelay: 300_000_000)
)
```

### Using `didComplete` for logging/metrics
Observe every request to log errors or record metrics.

```swift
struct LoggingInterceptor: RequestInterceptor {
    func didComplete(_ request: URLRequest, result: Result<(Data, URLResponse), Error>, for endpoint: Endpoint) async {
        switch result {
        case .success((_, let response)):
            print("✅ \(endpoint.path) \(response)")
        case .failure(let error):
            print("❌ \(endpoint.path) \(error)")
        }
    }
}
```

### APIError
Standard error types:
- `invalidURL`
- `requestFailed(Error)`
- `invalidResponse`
- `decodingFailed(Error)`
- `typeMismatch`
- `clientError` / `serverError` / `redirectionError`
- `unexpectedStatusCode`
- `custom(String)`

## Extensibility
RESTKit is designed to be extended per app:
- Add new `RequestInterceptor` types (authentication, caching, analytics).
- Wrap `APIClient` with decorators (retry, circuit breaker, caching).
- Provide custom `ResponseDecoder` for XML or other formats.

## Testing
The package includes unit tests for:
- HTTP methods
- endpoint URL building
- request body encoding
- response decoding/validation
- interceptor behavior

You can run tests with:
```bash
swift test
```

## Design Goals
- Lightweight and dependency-free
- Easy to test
- Minimal policy in core
- Ready for reuse across projects

## License
MIT (or your preferred license)
