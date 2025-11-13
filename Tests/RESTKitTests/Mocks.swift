import Foundation
import Testing
@testable import RESTKit

// MARK: - Test Doubles & Mocks

final class MockHTTPClient: HTTPClient {
	struct MockResponse {
		let data: Data
		var httpResponse: HTTPURLResponse
		
		init(data: Data, statusCode: Int) {
			self.data = data
			self.httpResponse = HTTPURLResponse(
				url: URL(string: "https://api.test.com")!,
				statusCode: statusCode,
				httpVersion: nil,
				headerFields: nil
			)!
		}
	}
	
	var mockResponse: MockResponse?
	var recordedRequest: URLRequest?
	var shouldThrowError: Error?
	
	func perform(request: URLRequest) async throws -> (Data, URLResponse) {
		recordedRequest = request
		
		if let error = shouldThrowError {
			throw error
		}
		
		guard let response = mockResponse else {
			throw URLError(.badServerResponse)
		}
		
		return (response.data, response.httpResponse)
	}
}

final class NonHTTPClient: HTTPClient {
	func perform(request: URLRequest) async throws -> (Data, URLResponse) {
		let response = URLResponse(
			url: request.url!,
			mimeType: nil,
			expectedContentLength: 0,
			textEncodingName: nil
		)
		return (Data(), response)
	}
}

// MARK: - Test Models
struct User: Codable, Equatable {
	let id: Int
	let name: String
	let email: String?
}

struct ErrorResponse: Codable {
	let message: String
	let code: Int
}

enum TestEnum: String, Codable {
	case optionA, optionB
}

// MARK: - Test Helper

final class TestEndpoint: Endpoint {
	let baseURL: String
	let path: String
	let method: HTTPMethod
	let headers: [String: String]?
	let queryParameters: [String: Any]?
	let requestBody: RequestBody
	let responseType: ResponseType
	
	init(
		baseURL: String = "https://api.test.com",
		path: String,
		method: HTTPMethod,
		headers: [String: String]? = nil,
		queryParameters: [String: Any]? = nil,
		requestBody: RequestBody,
		responseType: ResponseType
	) {
		self.baseURL = baseURL
		self.path = path
		self.method = method
		self.headers = headers
		self.queryParameters = queryParameters
		self.requestBody = requestBody
		self.responseType = responseType
	}
}
