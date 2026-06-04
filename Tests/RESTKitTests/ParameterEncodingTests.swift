import Foundation
import Testing
@testable import RESTKit

@Suite("Parameter Encoding Edge Cases")
struct ParameterEncodingTests {
	
	// MARK: Query Parameters
	
	@Test("Query array encodes with brackets")
	func queryArray() throws {
		let endpoint = TestEndpoint(
			baseURL: "https://api.test.com",
			path: "/items",
			method: .get,
			headers: nil,
			queryParameters: ["tags": ["swift", "ios", "mobile"]],
			requestBody: .none,
			responseType: .text
		)
		
		let request = try endpoint.asURLRequest()
		let urlString = try #require(request.url?.absoluteString)
		
		#expect(urlString.contains("tags%5B%5D=swift&tags%5B%5D=ios&tags%5B%5D=mobile"))
	}
	
	@Test("Query items are sorted by key for deterministic URLs")
	func queryDeterministicOrder() throws {
		let endpoint = TestEndpoint(
			baseURL: "https://api.test.com",
			path: "/items",
			method: .get,
			headers: nil,
			queryParameters: ["zebra": "1", "apple": "2", "mango": "3"],
			requestBody: .none,
			responseType: .text
		)

		let request = try endpoint.asURLRequest()
		let urlString = try #require(request.url?.absoluteString)

		#expect(urlString.contains("apple=2&mango=3&zebra=1"))
	}

	@Test("Plus sign in query value is percent-encoded")
	func queryPlusSignEncoded() throws {
		let endpoint = TestEndpoint(
			baseURL: "https://api.test.com",
			path: "/search",
			method: .get,
			headers: nil,
			queryParameters: ["q": "c++ language", "tz": "+07:00"],
			requestBody: .none,
			responseType: .text
		)

		let request = try endpoint.asURLRequest()
		let urlString = try #require(request.url?.absoluteString)

		// "+" must be escaped, otherwise servers decode it as a space.
		#expect(urlString.contains("q=c%2B%2B%20language"))
		#expect(urlString.contains("tz=%2B07:00"))
	}

	@Test("Query nil values are ignored")
	func queryNilValues() throws {
		let endpoint = TestEndpoint(
			baseURL: "https://api.test.com",
			path: "/search",
			method: .get,
			headers: nil,
			queryParameters: ["q": "test", "filter": NSNull()],
			requestBody: .none,
			responseType: .text
		)
		
		let request = try endpoint.asURLRequest()
		let urlString = try #require(request.url?.absoluteString)
		
		#expect(urlString.contains("q=test"))
		#expect(!urlString.contains("filter"))
	}
	
	@Test("Query special characters are percent-encoded")
	func querySpecialChars() throws {
		let endpoint = TestEndpoint(
			baseURL: "https://api.test.com",
			path: "/search",
			method: .get,
			headers: nil,
			queryParameters: ["q": "hello world & more = test", "emoji": "🚀"],
			requestBody: .none,
			responseType: .text
		)
		
		let request = try endpoint.asURLRequest()
		let urlString = try #require(request.url?.absoluteString)
	
		#expect(urlString.contains("q=hello%20world%20%26%20more%20%3D%20test"))
		#expect(urlString.contains("emoji=%F0%9F%9A%80"))
	}
	
	@Test("Query empty string values are included")
	func queryEmptyString() throws {
		let endpoint = TestEndpoint(
			baseURL: "https://api.test.com",
			path: "/search",
			method: .get,
			headers: nil,
			queryParameters: ["q": ""],
			requestBody: .none,
			responseType: .text
		)
		
		let request = try endpoint.asURLRequest()
		let urlString = try #require(request.url?.absoluteString)
		
		#expect(urlString.contains("q="))
	}
	
	@Test("Query nested dictionary is flattened to string")
	func queryNestedDictionary() throws {
		let nested = ["nested": ["key": "value"]] as [String: any Sendable]
		let endpoint = TestEndpoint(
			baseURL: "https://api.test.com",
			path: "/test",
			method: .get,
			headers: nil,
			queryParameters: ["data": nested],
			requestBody: .none,
			responseType: .text
		)
		
		let request = try endpoint.asURLRequest()
		let urlString = try #require(request.url?.absoluteString)
		
		#expect(urlString.contains("data="))  // Flattened to string representation
	}
	
	@Test("Query with no parameters returns clean URL")
	func queryEmpty() throws {
		let endpoint = TestEndpoint(
			baseURL: "https://api.test.com",
			path: "/items",
			method: .get,
			headers: nil,
			queryParameters: nil,
			requestBody: .none,
			responseType: .text
		)
		
		let request = try endpoint.asURLRequest()
		let urlString = request.url?.absoluteString
		
		#expect(urlString == "https://api.test.com/items")
	}
}
