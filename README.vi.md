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
- [Retry (decorator pattern)](#retry-decorator-pattern)
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

## Retry (decorator pattern)

RESTKit chủ ý để retry policy bên ngoài core. Bọc client bằng decorator và dùng `HTTPMethod.idempotentMethods` để chỉ retry các method an toàn:

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
                throw CancellationError()            // bị cancel thì không bao giờ retry
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
