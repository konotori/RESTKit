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

        var adaptOrder: [String] = []
        let interceptor1 = RecordingInterceptor(name: "A") { adaptOrder.append("A") }
        let interceptor2 = RecordingInterceptor(name: "B") { adaptOrder.append("B") }

        let client = APIClient(client: mock, interceptors: [interceptor1, interceptor2])
        let endpoint = TestEndpoint(
            path: "/test",
            method: .get,
            requestBody: .none,
            responseType: .text
        )

        let _: String = try await client.request(endpoint)
        // Last registered runs first during adapt (reversed), so B then A
        #expect(adaptOrder == ["B", "A"])
    }

    @Test("didComplete is called on failure")
    func didCompleteCalledOnFailure() async {
        let mock = MockHTTPClient()
        mock.shouldThrowError = URLError(.notConnectedToInternet)

        var didCompleteCalled = false
        let interceptor = CompletionRecordingInterceptor { didCompleteCalled = true }

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
        #expect(didCompleteCalled == true)
    }

    @Test("didComplete is called on success")
    func didCompleteCalledOnSuccess() async throws {
        let mock = MockHTTPClient()
        mock.mockResponse = .init(data: "OK".data(using: .utf8)!, statusCode: 200)

        var didCompleteCalled = false
        let interceptor = CompletionRecordingInterceptor { didCompleteCalled = true }

        let client = APIClient(client: mock, interceptors: [interceptor])
        let endpoint = TestEndpoint(
            path: "/test",
            method: .get,
            requestBody: .none,
            responseType: .text
        )

        let _: String = try await client.request(endpoint)
        #expect(didCompleteCalled == true)
    }
}

// MARK: - Test Interceptors

private final class RecordingInterceptor: RequestInterceptor {
    let name: String
    let onAdapt: () -> Void

    init(name: String, onAdapt: @escaping () -> Void) {
        self.name = name
        self.onAdapt = onAdapt
    }

    func adapt(_ request: URLRequest, for endpoint: Endpoint) async throws -> URLRequest {
        onAdapt()
        return request
    }
}

private final class CompletionRecordingInterceptor: RequestInterceptor {
    let onComplete: () -> Void

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    func didComplete(_ request: URLRequest, result: Result<(Data, URLResponse), Error>, for endpoint: Endpoint) async {
        onComplete()
    }
}
