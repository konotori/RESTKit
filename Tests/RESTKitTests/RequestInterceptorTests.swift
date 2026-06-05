import Foundation
import Testing
@testable import RESTKit

@Suite("RequestInterceptor Tests")
struct RequestInterceptorTests {

    @Test("Default adapt returns request unchanged")
    func defaultAdaptReturnsRequest() async throws {
        let url = URL(string: "https://api.test.com/users")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let endpoint = TestEndpoint(
            path: "/users",
            method: .get,
            requestBody: .none,
            responseType: Text.self
        )

        struct DefaultInterceptor: RequestInterceptor {}
        let interceptor = DefaultInterceptor()
        let adapted = try await interceptor.adapt(request, for: endpoint)

        #expect(adapted.url == request.url)
        #expect(adapted.httpMethod == request.httpMethod)
    }

    @Test("Default didComplete does not throw")
    func defaultDidCompleteNoThrow() async {
        let url = URL(string: "https://api.test.com/users")!
        let request = URLRequest(url: url)
        let endpoint = TestEndpoint(
            path: "/users",
            method: .get,
            requestBody: .none,
            responseType: Text.self
        )

        struct DefaultInterceptor: RequestInterceptor {}
        let interceptor = DefaultInterceptor()
        await interceptor.didComplete(request, result: .failure(APIError.invalidURL), for: endpoint)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        await interceptor.didComplete(request, result: .success((Data(), response)), for: endpoint)
    }

    @Test("Custom interceptor modifies request")
    func customInterceptorModifiesRequest() async throws {
        let url = URL(string: "https://api.test.com/users")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let endpoint = TestEndpoint(
            path: "/users",
            method: .get,
            requestBody: .none,
            responseType: Text.self
        )

        struct AuthInterceptor: RequestInterceptor {
            func adapt(_ request: URLRequest, for endpoint: any Endpoint) async throws -> URLRequest {
                var r = request
                r.setValue("Bearer token123", forHTTPHeaderField: "Authorization")
                return r
            }
        }
        let interceptor = AuthInterceptor()
        let adapted = try await interceptor.adapt(request, for: endpoint)

        #expect(adapted.value(forHTTPHeaderField: "Authorization") == "Bearer token123")
    }
}
