import Foundation
import Testing
@testable import RESTKit

@Suite("APIClient Integration Tests")
struct APIClientTests {

    // MARK: - Success Paths

    @Test("Successful request returns decoded JSON")
    func successReturnsDecodedJSON() async throws {
        let userData = try JSONEncoder().encode(User(id: 1, name: "Alice", email: "alice@test.com"))
        let mock = MockHTTPClient()
        mock.mockResponse = .init(data: userData, statusCode: 200)

        let client = APIClient(client: mock)
        let endpoint = TestEndpoint(
            path: "/users/1",
            method: .get,
            requestBody: .none,
            responseType: .json(User.self)
        )

        let result: User = try await client.request(endpoint)
        #expect(result.id == 1)
        #expect(result.name == "Alice")
        #expect(result.email == "alice@test.com")
        #expect(mock.recordedRequest?.url?.absoluteString.contains("/users/1") == true)
    }

    @Test("Successful request returns text response")
    func successReturnsText() async throws {
        let textData = "Hello, World!".data(using: .utf8)!
        let mock = MockHTTPClient()
        mock.mockResponse = .init(data: textData, statusCode: 200)

        let client = APIClient(client: mock)
        let endpoint = TestEndpoint(
            path: "/greet",
            method: .get,
            requestBody: .none,
            responseType: .text
        )

        let result: String = try await client.request(endpoint)
        #expect(result == "Hello, World!")
    }

    @Test("Successful request returns raw data")
    func successReturnsData() async throws {
        let rawData = Data([0x01, 0x02, 0x03])
        let mock = MockHTTPClient()
        mock.mockResponse = .init(data: rawData, statusCode: 200)

        let client = APIClient(client: mock)
        let endpoint = TestEndpoint(
            path: "/binary",
            method: .get,
            requestBody: .none,
            responseType: .data
        )

        let result: Data = try await client.request(endpoint)
        #expect(result == rawData)
    }

    // MARK: - Interceptors

    @Test("Interceptors adapt request in reverse order")
    func interceptorsAdaptInReverseOrder() async throws {
        let mock = MockHTTPClient()
        mock.mockResponse = .init(data: "OK".data(using: .utf8)!, statusCode: 200)

        let adaptOrder = LockedBox<[String]>([])
        let interceptor1 = RecordingInterceptor(name: "A") { adaptOrder.value.append("A") }
        let interceptor2 = RecordingInterceptor(name: "B") { adaptOrder.value.append("B") }

        let client = APIClient(client: mock, interceptors: [interceptor1, interceptor2])
        let endpoint = TestEndpoint(
            path: "/test",
            method: .get,
            requestBody: .none,
            responseType: .text
        )

        let _: String = try await client.request(endpoint)
        // Last registered runs first during adapt (reversed), so B then A
        #expect(adaptOrder.value == ["B", "A"])
    }

    @Test("didComplete is called on failure")
    func didCompleteCalledOnFailure() async {
        let mock = MockHTTPClient()
        mock.shouldThrowError = URLError(.notConnectedToInternet)

        let didCompleteCalled = LockedBox(false)
        let interceptor = CompletionRecordingInterceptor { didCompleteCalled.value = true }

        let client = APIClient(client: mock, interceptors: [interceptor])
        let endpoint = TestEndpoint(
            path: "/users",
            method: .get,
            requestBody: .none,
            responseType: .text
        )

        do {
            let _: String = try await client.request(endpoint)
        } catch {}
        #expect(didCompleteCalled.value == true)
    }

    @Test("didComplete is called on success")
    func didCompleteCalledOnSuccess() async throws {
        let mock = MockHTTPClient()
        mock.mockResponse = .init(data: "OK".data(using: .utf8)!, statusCode: 200)

        let didCompleteCalled = LockedBox(false)
        let interceptor = CompletionRecordingInterceptor { didCompleteCalled.value = true }

        let client = APIClient(client: mock, interceptors: [interceptor])
        let endpoint = TestEndpoint(
            path: "/test",
            method: .get,
            requestBody: .none,
            responseType: .text
        )

        let _: String = try await client.request(endpoint)
        #expect(didCompleteCalled.value == true)
    }

    // MARK: - Body Encoder

    @Test("Client's bodyEncoder is applied to JSON request bodies")
    func clientBodyEncoderIsApplied() async throws {
        struct Payload: Codable {
            let firstName: String
        }

        let mock = MockHTTPClient()
        mock.mockResponse = .init(data: "OK".data(using: .utf8)!, statusCode: 200)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let client = APIClient(client: mock, bodyEncoder: encoder)
        let endpoint = TestEndpoint(
            path: "/users",
            method: .post,
            requestBody: .json(Payload(firstName: "Alice")),
            responseType: .text
        )

        let _: String = try await client.request(endpoint)

        let bodyData = try #require(mock.recordedRequest?.httpBody)
        let string = try #require(String(data: bodyData, encoding: .utf8))
        #expect(string.contains("first_name"))
    }

    // MARK: - Sendable / Concurrency

    @Test("APIClient and core types are Sendable")
    func coreTypesAreSendable() {
        // Compile-time guarantees: these calls only compile if the types are Sendable.
        func requiresSendable<T: Sendable>(_: T.Type) {}
        requiresSendable(APIClient.self)
        requiresSendable(APIError.self)
        requiresSendable(RequestBody.self)
        requiresSendable(ResponseType.self)
        requiresSendable(HTTPMethod.self)

        // The canonical consumer pattern: a shared client in a static let.
        _ = SharedClientHolder.shared
    }

    @Test("APIClient handles concurrent requests from multiple tasks")
    func concurrentRequests() async throws {
        let mock = MockHTTPClient()
        mock.mockResponse = .init(data: "OK".data(using: .utf8)!, statusCode: 200)

        let client = APIClient(client: mock)
        let endpoint = TestEndpoint(
            path: "/concurrent",
            method: .get,
            requestBody: .none,
            responseType: .text
        )

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    try await client.request(endpoint)
                }
            }
            for try await result in group {
                #expect(result == "OK")
            }
        }
    }
}

// Compiles only because APIClient is Sendable (static let requires it in Swift 6).
private enum SharedClientHolder {
    static let shared = APIClient()
}

// MARK: - Test Interceptors

private final class RecordingInterceptor: RequestInterceptor, Sendable {
    let name: String
    let onAdapt: @Sendable () -> Void

    init(name: String, onAdapt: @escaping @Sendable () -> Void) {
        self.name = name
        self.onAdapt = onAdapt
    }

    func adapt(_ request: URLRequest, for endpoint: Endpoint) async throws -> URLRequest {
        onAdapt()
        return request
    }
}

private final class CompletionRecordingInterceptor: RequestInterceptor, Sendable {
    let onComplete: @Sendable () -> Void

    init(onComplete: @escaping @Sendable () -> Void) {
        self.onComplete = onComplete
    }

    func didComplete(_ request: URLRequest, result: Result<(Data, URLResponse), Error>, for endpoint: Endpoint) async {
        onComplete()
    }
}
