# RESTKit

**Thư viện networking gọn nhẹ, thuần Swift 6 — type-safe tại compile-time, `Sendable` toàn bộ, zero dependency.**

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2013%2B%20%7C%20macOS%2011%2B-blue?logo=apple)](#yêu-cầu)
[![SPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](#cài-đặt)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey)](LICENSE)

> [English](README.md) | Tiếng Việt

Mỗi endpoint tự khai báo kiểu dữ liệu nó trả về, nên request sai kiểu là lỗi compile ngay — không phải bất ngờ lúc runtime. Không data race dưới strict concurrency, và mọi convention của API được cấu hình tại đúng một chỗ.

## Mục lục

- [Tính năng](#tính-năng)
- [Yêu cầu](#yêu-cầu)
- [Cài đặt](#cài-đặt)
- [Bắt đầu nhanh](#bắt-đầu-nhanh)
- [Khái niệm cốt lõi](#khái-niệm-cốt-lõi)
  - [Endpoint](#endpoint)
  - [ResponseStrategy](#responsestrategy)
  - [RequestBody](#requestbody)
  - [APIClient](#apiclient)
  - [Xử lý lỗi](#xử-lý-lỗi)
- [Tổ chức Endpoint](#tổ-chức-endpoint)
- [Interceptor](#interceptor)
- [Pattern cho production](#pattern-cho-production)
  - [Token refresh (single-flight)](#token-refresh-single-flight)
  - [Retry kèm backoff & jitter](#retry-kèm-backoff--jitter)
  - [Circuit breaker](#circuit-breaker)
  - [Deduplication (gộp request in-flight)](#deduplication-gộp-request-in-flight)
  - [Prioritization](#prioritization)
  - [Ghép các pattern lại với nhau](#ghép-các-pattern-lại-với-nhau)
- [Testing](#testing)
- [Mục tiêu thiết kế](#mục-tiêu-thiết-kế)
- [License](#license)

## Tính năng

- **Response typing tại compile-time** — `Endpoint` mang kiểu response dưới dạng associated type. Không cast, không `Any`, không dính "type mismatch" lúc runtime.
- **`ResponseStrategy`** — khai báo response *là gì*: `JSON<Model>`, `Text`, `Raw`, hoặc strategy của riêng bạn (ví dụ unwrap envelope).
- **`Sendable` toàn bộ** — yên tâm giữ trong `static let shared`, gọi từ bất kỳ actor nào, fan-out qua nhiều task.
- **Interceptor** — adapt request trước khi gửi (auth, API key) và observe kết quả trả về (logging, metrics).
- **Convention cấu hình một chỗ** — `bodyEncoder` / `responseDecoder` (snake_case, date format) nằm trên client.
- **Lỗi trung thực** — encode fail thì throw chứ không âm thầm gửi body rỗng; task bị cancel nổi lên thành `CancellationError`, không bị gói thành lỗi network.

## Yêu cầu

| | Tối thiểu |
|---|---|
| iOS | 13.0 |
| macOS | 11.0 |
| Swift | 6.0 (SwiftPM tools 6.0) |

## Cài đặt

### Xcode

1. **File → Add Package Dependencies…**
2. Dán URL của repo vào ô tìm kiếm:
   ```
   https://github.com/konotori/RESTKit.git
   ```
3. Chọn dependency rule **Up to Next Major Version** từ `1.0.0`, rồi bấm **Add Package**.

### Swift Package Manager

Thêm dependency vào `Package.swift`:

```swift
.package(url: "https://github.com/konotori/RESTKit.git", from: "1.0.0")
```

Rồi thêm `RESTKit` vào target:

```swift
.target(
    name: "MyApp",
    dependencies: ["RESTKit"]
)
```

## Bắt đầu nhanh

```swift
import RESTKit

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

// 1) Mô tả API call — chỉ khai báo những gì khác với mặc định.
struct GetUser: Endpoint {
    typealias Response = JSON<User>          // ← endpoint này trả về gì

    let id: Int

    var baseURL: String { "https://api.example.com" }
    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }
}

// 2) Gọi request — kiểu kết quả được suy ra từ endpoint.
let client = APIClient()
let user = try await client.request(GetUser(id: 1))   // user: User. Không cần ghi kiểu.
```

Còn nếu cố tình dùng sai kiểu:

```swift
let post: Post = try await client.request(GetUser(id: 1))
// ❌ Lỗi compile: cannot convert value of type 'User' to specified type 'Post'
```

## Khái niệm cốt lõi

RESTKit phân chia trách nhiệm theo một quy tắc duy nhất:

| | Chịu trách nhiệm | Ví dụ |
|---|---|---|
| **`Endpoint` = WHAT** | API call này là gì | path, method, nội dung body, kiểu response |
| **`APIClient` = HOW** | Thực hiện request như thế nào | convention JSON, validation, interceptor, quy ước lỗi |

### Endpoint

```swift
public protocol Endpoint<Response>: Sendable {
    associatedtype Response: ResponseStrategy

    var baseURL: String { get }
    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String]? { get }              // mặc định: nil
    var queryParameters: [String: any Sendable]? { get } // mặc định: nil
    var requestBody: RequestBody { get }                 // mặc định: .none
    var needsAuthentication: Bool { get }                // mặc định: false

    func asURLRequest(bodyEncoder: JSONEncoder) throws -> URLRequest
}
```

Tham số của endpoint chính là stored property — endpoint chỉ là value thuần, so sánh được, log được, unit test độc lập được.

Hành vi của query parameter:

- Sắp xếp theo key → URL ổn định (cache key không đổi, request signing, snapshot test).
- Mảng được expand thành `key[]=a&key[]=b`.
- Giá trị `NSNull` bị bỏ qua.
- `+` được percent-encode (`%2B`) để server không decode nhầm thành dấu cách.

### ResponseStrategy

`Response` là tên của một *strategy*, không đơn thuần là một model:

| Strategy | Kiểu kết quả | Dùng cho |
|---|---|---|
| `JSON<Model>` | `Model` | API JSON (decode bằng `responseDecoder` của client) |
| `Text` | `String` | Response dạng text thuần |
| `Raw` | `Data` | Download nhị phân, file |

Format tùy biến chỉ cần một conformance nhỏ — viết một lần, endpoint nào cũng dùng lại được:

```swift
/// Unwrap kiểu envelope phổ biến { "data": ... }.
enum Enveloped<Model: Decodable & Sendable>: ResponseStrategy {
    struct Envelope: Decodable { let data: Model }

    static func decode(_ data: Data, using decoder: JSONDecoder) throws -> Model {
        try decoder.decode(Envelope.self, from: data).data
    }
}

struct GetWrappedUser: Endpoint {
    typealias Response = Enveloped<User>   // đọc lên là hiểu ngay nó làm gì
    ...
}
```

Strategy cứ throw lỗi gốc của nó (`DecodingError`, lỗi của parser bạn dùng, ...); `APIClient` sẽ chuẩn hóa tất cả về `APIError.decodingFailed` tại một chỗ duy nhất.

### RequestBody

```swift
var requestBody: RequestBody { .json(CreateUserRequest(name: "Alice")) }
```

| Case | Content-Type | Ghi chú |
|---|---|---|
| `.json(any Encodable & Sendable)` | `application/json` | Encode bằng `bodyEncoder` của client. Encode fail sẽ throw `APIError.encodingFailed` — không bao giờ âm thầm gửi body rỗng. |
| `.text(String)` | `text/plain` | UTF-8 |
| `.binary(Data)` | `application/octet-stream` | Gửi nguyên trạng |
| `.form([String: any Sendable])` | `application/x-www-form-urlencoded` | Percent-encode, dấu cách → `+`, mảng lặp lại key, `NSNull` bỏ qua, chuỗi rỗng giữ lại (`key=`) |
| `.none` | — | Không có body |

Nếu bạn tự đặt `Content-Type` trong `headers` thì giá trị đó luôn được ưu tiên.

### APIClient

Mọi convention cấu hình một lần tại client (thứ tự tham số đi theo dòng chảy của request):

```swift
let bodyEncoder = JSONEncoder()
bodyEncoder.keyEncodingStrategy = .convertToSnakeCase
bodyEncoder.dateEncodingStrategy = .iso8601

let responseDecoder = JSONDecoder()
responseDecoder.keyDecodingStrategy = .convertFromSnakeCase
responseDecoder.dateDecodingStrategy = .iso8601

let client = APIClient(
    client: URLSession.shared,                       // transport (HTTPClient)
    bodyEncoder: bodyEncoder,                        // phía request
    responseDecoder: responseDecoder,                // phía response
    responseValidator: DefaultResponseValidator(),   // policy về status code
    interceptors: [AuthInterceptor()]                // các hook
)
```

`APIClient` là `Sendable` — pattern shared instance dùng thẳng được dưới Swift 6:

```swift
enum API {
    static let shared = APIClient()
}
```

### Xử lý lỗi

Mọi thất bại đều nổi lên dưới dạng `APIError`, trừ cancellation:

| Case | Ý nghĩa |
|---|---|
| `invalidURL` | `baseURL`/`path` không ghép thành URL hợp lệ |
| `encodingFailed(Error)` | Encode body của request thất bại |
| `requestFailed(Error)` | Lỗi tầng transport (mất mạng, timeout, ...) |
| `invalidResponse` | Response không phải HTTP |
| `redirectionError` / `clientError` / `serverError` / `unexpectedStatusCode` | Phân nhóm theo status code (4xx/5xx kèm `Data?` của response) |
| `decodingFailed(Error)` | Response strategy decode thất bại |
| `custom(String)` | Dành cho validator/interceptor của bạn |

**Quy ước cancellation:** nếu `Task` bao ngoài bị hủy (ví dụ `.task` của SwiftUI khi view biến mất), `request` sẽ throw `CancellationError` — không phải `APIError`. Đừng show alert lỗi cho trường hợp này:

```swift
do {
    user = try await client.request(GetUser(id: 1))
} catch is CancellationError {
    // người dùng đã rời màn hình — không cần làm gì
} catch let error as APIError {
    showAlert(error.localizedDescription)
}
```

## Tổ chức Endpoint

### Một backend duy nhất (đa số app) — một extension, từng endpoint không tốn thêm dòng nào

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

### Nhiều service — mỗi service một marker protocol 2 dòng

Marker protocol cũng là chỗ đặt convention chung của service đó (auth, headers):

```swift
protocol GitHubEndpoint: Endpoint {}
extension GitHubEndpoint {
    var baseURL: String { "https://api.github.com" }
    var needsAuthentication: Bool { true }
    var headers: [String: String]? { ["Accept": "application/vnd.github+json"] }
}

enum GitHub {   // namespace cho dễ tra cứu
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

### Gọi một lần — `APIEndpoint`, khỏi cần định nghĩa type mới

```swift
let entries = try await client.request(
    APIEndpoint<JSON<[DictionaryEntry]>>(
        baseURL: "https://api.dictionaryapi.dev",
        path: "/api/v2/entries/en/swift",
        method: .get
    )
)
```

## Interceptor

```swift
public protocol RequestInterceptor: Sendable {
    /// Chỉnh sửa request trước khi gửi đi.
    func adapt(_ request: URLRequest, for endpoint: any Endpoint) async throws -> URLRequest

    /// Quan sát kết quả (thành công, thất bại, hoặc CancellationError).
    /// Không được gọi nếu request build thất bại.
    func didComplete(_ request: URLRequest, result: Result<(Data, URLResponse), Error>, for endpoint: any Endpoint) async
}
```

Thứ tự chạy (onion model): với `interceptors: [A, B]`, **B adapt trước, A adapt sau cùng** — tức interceptor đăng ký đầu tiên sẽ thấy request ở trạng thái cuối cùng. `didComplete` chạy theo đúng thứ tự đăng ký.

### Bearer token auth

Endpoint chủ động opt-in qua `needsAuthentication` (mặc định `false` — đụng tới credentials thì tường minh vẫn an toàn hơn ngầm định):

```swift
actor TokenStore {
    private var token: String?

    func validToken() async throws -> String {
        if let token { return token }
        let refreshed = try await refresh()   // gọi auth service của bạn
        token = refreshed
        return refreshed
    }
}

struct BearerAuthInterceptor: RequestInterceptor {
    let tokenStore: TokenStore

    func adapt(_ request: URLRequest, for endpoint: any Endpoint) async throws -> URLRequest {
        guard endpoint.needsAuthentication,
              request.url?.host == "api.myapp.com"   // lớp chắn thứ hai chống lộ token
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

## Pattern cho production

Core của RESTKit cố ý giữ tối giản; các nhu cầu production ghép thêm bên trên qua **hai điểm mở rộng**:

- **Interceptor** adapt mọi request (`adapt`) và observe mọi kết quả (`didComplete`). Dùng để *gắn* thứ gì đó (header auth, API key) hoặc *quan sát* (logging, metrics).
- **Decorator** bọc `APIClientProtocol` và kiểm soát *toàn bộ* vòng đời request — đọc được kết quả, fail-fast, gate, replay. Bất cứ thứ gì phản ứng theo **kết quả** (retry, refresh-on-401, circuit breaking, deduplication, prioritization) đều phải là decorator, vì `adapt` không thấy response còn `didComplete` không đổi được kết quả hay retry.

Mọi đoạn code dưới đây compile thẳng với RESTKit và đã được kiểm chứng dưới tải đồng thời trước khi publish — single-flight refresh, gộp request in-flight, chuyển trạng thái breaker, và thứ tự ưu tiên, mỗi cái có một test dùng stub-chặn ép các request thật sự chồng lên nhau. Cứ copy về và chỉnh theo app của bạn.

> Decorator là value type `Sendable` bọc `let base: any APIClientProtocol` — chúng lồng nhau thoải mái (xem [Ghép các pattern lại với nhau](#ghép-các-pattern-lại-với-nhau)) và pattern shared-instance vẫn dùng được.

### Token refresh (single-flight)

**Là gì** — Khi access token hết hạn giữa session, refresh trong suốt rồi gửi lại request đã fail để caller không bao giờ thấy `401`. Nhiều `401` xảy ra đồng thời chỉ được kích hoạt **một** lần refresh, không tạo ra một đợt "stampede".

**Khi nào dùng** — OAuth2 / JWT: access token sống ngắn đi kèm refresh token sống dài.

**Hoạt động thế nào**

1. Một **interceptor** gắn access token hiện tại vào các endpoint cần auth (`adapt`).
2. Một **decorator** bắt `401` từ endpoint cần auth, yêu cầu store refresh, rồi retry một lần — interceptor gắn lại token mới ở lần retry.
3. Store **gộp (coalesce)** các lần refresh đồng thời về một `Task` duy nhất. Caller nào có token đã bị xoay vòng bởi người khác thì nhận token mới mà không tốn thêm một vòng network.

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

Lắp ráp — interceptor và decorator dùng chung một store:

```swift
let store = AuthTokenStore(service: MyAuthService())
let client = AuthRefreshingClient(
    base: APIClient(interceptors: [BearerAuthInterceptor(store: store)]),
    store: store
)
```

### Retry kèm backoff & jitter

**Là gì** — Tự động gửi lại request đã fail vì lý do *tạm thời*, có chờ (back off) giữa các lần thử.

**Khi nào dùng** — Mạng chập chờn, backend sau load-balancer thỉnh thoảng 5xx, API có rate limit.

**Hoạt động thế nào**

- Chỉ retry method **idempotent** (`HTTPMethod.idempotentMethods`) và lỗi **đáng retry** (5xx, `408`, `429`, các `URLError` tạm thời). Không bao giờ retry lỗi decode/encode/4xx khác, và không retry cancellation.
- Back off theo **cấp số nhân + full jitter** để nhiều client không đồng loạt dồn vào server đúng lúc nó vừa hồi phục.
- Giới hạn ở `maxAttempts`.

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

> **Giới hạn — `Retry-After`:** `APIError` mang theo body của response (`Data?`) nhưng không mang header, nên decorator không đọc được `Retry-After` của server. Muốn tôn trọng nó, hãy bắt header trong một `ResponseValidator` tùy biến hoặc interceptor rồi truyền thời gian chờ ra qua `APIError.custom`.

### Circuit breaker

**Là gì** — Một khi backend fail liên tục, ngừng gửi request trong một khoảng cooldown ("mở" mạch) và fail-fast — thay vì dồn thêm tải lên một server đang ngắc ngoải và bắt mọi người dùng ngồi chờ timeout.

**Khi nào dùng** — Bảo vệ một dependency dễ bị quá tải; cải thiện độ trễ cảm nhận khi sự cố (fail tức thì tốt hơn chờ timeout 30 giây).

**Hoạt động thế nào** — ba trạng thái:

- **Closed** — request đi bình thường; đếm số lần fail liên tiếp từ backend.
- **Open** — sau `failureThreshold` lần fail, từ chối ngay với `CircuitBreakerError.open` cho tới khi hết `cooldown`.
- **Half-open** — hết cooldown thì cho một request thử: thành công → Closed, fail → Open lại.

Chỉ lỗi từ backend (5xx, transport, non-HTTP) mới tính — `4xx` nghĩa là server vẫn khỏe và đã trả lời.

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

> Một breaker theo dõi một mạch — dùng một instance riêng cho mỗi host/service. Bản này cho qua bất kỳ request nào đến trước trong cửa sổ half-open; bản chặt hơn sẽ chỉ cho đúng một request thử.

### Deduplication (gộp request in-flight)

**Là gì** — Khi nhiều caller xin *cùng* một tài nguyên cùng lúc, chỉ bắn **một** request network và chia sẻ kết quả cho tất cả.

**Khi nào dùng** — Nhiều SwiftUI view xuất hiện cùng lúc, prefetch chạy đua với on-appear, re-render liên tục. Tiết kiệm băng thông và tải backend.

**Hoạt động thế nào** — Đặt key cho mỗi request theo method + URL. Caller đầu tiên cho một key sẽ tạo một `Task` và lưu lại; các caller đồng thời cùng key sẽ `await` đúng task đó. Key được xóa khi task xong — nên nó gộp các request **đang bay** (đây không phải cache). Giới hạn ở `GET` (đọc an toàn, idempotent).

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

> Mỗi endpoint có kiểu `Output` khác nhau, nên coalescer lưu `Task<any Sendable, Error>` và giá trị được cast về `E.Response.Output`. Key chứa URL đầy đủ (đã sắp xếp tất định), nên các caller dùng chung key thì dùng chung kiểu `Output`; nhánh `as?` gọi trực tiếp để dự phòng cho trường hợp lý thuyết key đụng nhau giữa hai kiểu.

### Prioritization

**Là gì** — Giới hạn số request chạy đồng thời, và khi có nhiều request xếp hàng, cho các request ưu tiên cao (do người dùng khởi tạo, nội dung đang hiển thị) chen lên trước các request ưu tiên thấp (prefetch, analytics).

**Khi nào dùng** — Băng thông/kết nối hạn chế; bạn không muốn một loạt prefetch làm trễ đúng cái request người dùng đang chờ.

**Hoạt động thế nào** — Một semaphore bất đồng bộ với `maxConcurrent` slot. Khi đầy, caller suspend trên một continuation được lưu trong danh sách sắp theo ưu tiên; mỗi lần `release()` trao slot vừa giải phóng cho **waiter ưu tiên cao nhất** (FIFO trong cùng một mức). Hủy một request đang xếp hàng sẽ gỡ waiter đó và throw `CancellationError`, nên một SwiftUI view đã biến mất không bao giờ giữ khư khư một slot.

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

### Ghép các pattern lại với nhau

Mỗi decorator bọc `any APIClientProtocol`, nên chúng lồng vào nhau được. Decorator **ngoài cùng** thấy request đầu tiên. Một stack production hợp lý:

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

Thứ tự lồng chính là policy. Trong stack trên:

- **Prioritization** ở ngoài cùng — request phải chờ tới lượt (có slot) *trước khi* bất kỳ việc gì bắt đầu.
- **Deduplication** nằm trên retry — các request trùng nhau gộp về cùng một pipeline retry-và-breaker.
- **Circuit breaker** nằm trong retry — mỗi lần retry đều bị breaker gate, nên retry không nện vào một mạch đang mở.
- **Auth refresh** gần core nhất, nên một 401 được giải quyết trước khi logic retry/breaker thấy kết quả.

Đổi thứ tự để khớp policy của bạn (ví dụ đặt breaker ngoài retry để đếm kết quả *cuối cùng* thay vì từng lần thử).

## Testing

Mock ngay tại transport — `HTTPClient` chỉ có đúng một method:

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

Endpoint test được hoàn toàn offline, không đụng gì tới networking:

```swift
let request = try GetUser(id: 1).asURLRequest()
#expect(request.url?.absoluteString == "https://api.example.com/users/1")
```

Chạy bộ test của package (90+ test):

```bash
swift test
```

## Mục tiêu thiết kế

- **Ưu tiên an toàn compile-time hơn check runtime** — build qua nghĩa là kiểu đã khớp.
- **Endpoint = WHAT, Client = HOW** — phần khai báo giữ thật gọn; convention dồn về một chỗ.
- **Core tối giản policy** — retry, caching, auth flow ghép thêm bên trên bằng interceptor và decorator.
- **Swift 6 trước tiên** — `Sendable` từ đầu tới cuối, không có `@unchecked` trong thư viện.
- Gọn nhẹ, zero dependency.

## License

[MIT](LICENSE)
