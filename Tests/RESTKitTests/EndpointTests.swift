import Foundation
import Testing
@testable import RESTKit

@Suite("Endpoint Core Functionality Tests")
struct EndpointTests {
    
    // MARK: - URL Building
    
    @Test("Builds correct URL with path")
    func buildsCorrectURL() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/users",
            method: .get,
            requestBody: .none,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        
        #expect(request.url?.absoluteString == "https://api.test.com/users")
        #expect(request.httpMethod == "GET")
    }
    
    @Test("Handles baseURL with trailing slash")
    func baseURLWithTrailingSlash() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com/",
            path: "users",
            method: .get,
            requestBody: .none,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        
        #expect(request.url?.absoluteString == "https://api.test.com/users")
    }
    
    @Test("Handles baseURL without trailing slash")
    func baseURLWithoutTrailingSlash() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/users",
            method: .get,
            requestBody: .none,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        
        #expect(request.url?.absoluteString == "https://api.test.com/users")
    }
    
    @Test("Handles path without leading slash")
    func pathWithoutLeadingSlash() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "users",
            method: .get,
            requestBody: .none,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        
        #expect(request.url?.absoluteString == "https://api.test.com/users")
    }
    
    @Test("Handles nested path")
    func nestedPath() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com/api/v1",
            path: "/users/profile/123",
            method: .get,
            requestBody: .none,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        
        #expect(request.url?.absoluteString == "https://api.test.com/api/v1/users/profile/123")
    }
    
    @Test("Throws invalidURL for malformed baseURL")
    func invalidBaseURL() {
        let endpoint = TestEndpoint(
            baseURL: "not a url",
            path: "/users",
            method: .get,
            requestBody: .none,
            responseType: .text
        )
        
        #expect(throws: APIError.invalidURL) {
            try endpoint.asURLRequest()
        }
    }
    
    // MARK: - Query Parameters
    
    @Test("Adds query parameters to URL")
    func queryParameters() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/search",
            method: .get,
            queryParameters: ["q": "test", "limit": "10"],
            requestBody: .none,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        let urlString = try #require(request.url?.absoluteString)
        
        #expect(urlString.contains("q=test"))
        #expect(urlString.contains("limit=10"))
    }
    
    @Test("Percent-encodes query parameter values")
    func queryPercentEncoding() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/search",
            method: .get,
            queryParameters: ["q": "hello world & more"],
            requestBody: .none,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        let urlString = try #require(request.url?.absoluteString)
        
        #expect(urlString.contains("q=hello%20world%20%26%20more"))
    }
    
    @Test("Query array adds brackets")
    func queryArray() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/items",
            method: .get,
            queryParameters: ["tags": ["swift", "ios"]],
            requestBody: .none,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        let urlString = try #require(request.url?.absoluteString)
		
        #expect(urlString.contains("tags%5B%5D=swift&tags%5B%5D=ios"))
    }
    
    @Test("Nil query parameters are ignored")
    func nilQueryParameters() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/items",
            method: .get,
            queryParameters: nil,
            requestBody: .none,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        
        #expect(request.url?.query == nil)
    }
    
    // MARK: - Headers
    
    @Test("Adds custom headers")
    func customHeaders() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/users",
            method: .get,
            headers: ["Authorization": "Bearer token", "X-Custom": "value"],
            requestBody: .none,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "X-Custom") == "value")
    }
    
    @Test("Does not override Content-Type if already set")
    func doesNotOverrideContentType() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/users",
            method: .post,
            headers: ["Content-Type": "application/xml"], // Explicitly set by user
            requestBody: .json(["name": "Alice"]), // Body là JSON
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/xml")
    }
    
    @Test("Sets Content-Type from body if not provided")
    func setsContentTypeFromBody() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/users",
            method: .post,
            headers: nil, // Not set
            requestBody: .json(["name": "Alice"]),
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }
    
    // MARK: - Request Body
    
    @Test("Adds JSON body to request")
    func jsonBody() throws {
		struct JsonPayload: Codable {
            let name: String
            let age: Int
        }
        let payload = JsonPayload(name: "Alice", age: 30)
        let body = RequestBody.json(payload)
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/users",
            method: .post,
            headers: nil,
            requestBody: body,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        let bodyData = try #require(request.httpBody)
        
        let decoded = try JSONDecoder().decode(JsonPayload.self, from: bodyData)
        #expect(decoded.name == "Alice")
        #expect(decoded.age == 30)
    }
    
    @Test("Adds text body to request")
    func textBody() throws {
        let body = RequestBody.text("Plain text payload")
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/text",
            method: .post,
            headers: nil,
            requestBody: body,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        let bodyData = try #require(request.httpBody)
        let text = try #require(String(data: bodyData, encoding: .utf8))
        
        #expect(text == "Plain text payload")
    }
    
    @Test("Adds binary body to request")
    func binaryBody() throws {
        let binaryData = Data([0x01, 0x02, 0x03, 0xFF])
        let body = RequestBody.binary(binaryData)
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/binary",
            method: .post,
            headers: nil,
            requestBody: body,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        let bodyData = try #require(request.httpBody)
        
        #expect(bodyData == binaryData)
    }
    
    @Test("Adds form body to request")
    func formBody() throws {
        let body = RequestBody.form(["name": "Alice", "age": "30"])
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/form",
            method: .post,
            headers: nil,
            requestBody: body,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        let bodyData = try #require(request.httpBody)
        let string = try #require(String(data: bodyData, encoding: .utf8))
        
        #expect(string.contains("name=Alice"))
        #expect(string.contains("age=30"))
    }
    
    @Test("Does not set body for .none")
    func noneBody() throws {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/get",
            method: .get,
            headers: nil,
            requestBody: .none,
            responseType: .text
        )
        
        let request = try endpoint.asURLRequest()
        
        #expect(request.httpBody == nil)
    }
    
    // MARK: - Endpoint Defaults (allowRetry, needsAuthentication)

    @Test("GET endpoint allowRetry is true")
    func allowRetryForGet() {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/users",
            method: .get,
            requestBody: .none,
            responseType: .text
        )
        #expect(endpoint.allowRetry == true)
    }

    @Test("POST endpoint allowRetry is false")
    func allowRetryForPost() {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/users",
            method: .post,
            requestBody: .none,
            responseType: .text
        )
        #expect(endpoint.allowRetry == false)
    }

    @Test("Default needsAuthentication is true")
    func defaultNeedsAuthentication() {
        let endpoint = TestEndpoint(
            baseURL: "https://api.test.com",
            path: "/users",
            method: .get,
            requestBody: .none,
            responseType: .text
        )
        #expect(endpoint.needsAuthentication == true)
    }

    // MARK: - HTTP Method

    @Test("Sets correct HTTP method")
    func httpMethod() throws {
        let methods: [(HTTPMethod, String)] = [
            (.get, "GET"),
            (.post, "POST"),
            (.put, "PUT"),
            (.delete, "DELETE"),
            (.patch, "PATCH")
        ]
        
        for (method, expected) in methods {
            let endpoint = TestEndpoint(
                baseURL: "https://api.test.com",
                path: "/test",
                method: method,
                requestBody: .none,
                responseType: .text
            )
            
            let request = try endpoint.asURLRequest()
            #expect(request.httpMethod == expected)
        }
    }
}
