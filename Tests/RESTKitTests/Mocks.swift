import Foundation
import Testing
@testable import RESTKit

// MARK: - Test Doubles & Mocks

/// Thread-safe mutable box so test doubles can record state from Sendable contexts.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var _value: Value

	init(_ value: Value) {
		self._value = value
	}

	var value: Value {
		get {
			lock.lock()
			defer { lock.unlock() }
			return _value
		}
		set {
			lock.lock()
			defer { lock.unlock() }
			_value = newValue
		}
	}
}

// @unchecked Sendable: all mutable state is guarded by LockedBox.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
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

	private let _mockResponse = LockedBox<MockResponse?>(nil)
	private let _recordedRequest = LockedBox<URLRequest?>(nil)
	private let _shouldThrowError = LockedBox<(any Error)?>(nil)

	var mockResponse: MockResponse? {
		get { _mockResponse.value }
		set { _mockResponse.value = newValue }
	}

	var recordedRequest: URLRequest? {
		get { _recordedRequest.value }
		set { _recordedRequest.value = newValue }
	}

	var shouldThrowError: Error? {
		get { _shouldThrowError.value }
		set { _shouldThrowError.value = newValue }
	}

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

final class NonHTTPClient: HTTPClient, Sendable {
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

final class TestEndpoint: Endpoint, Sendable {
	let baseURL: String
	let path: String
	let method: HTTPMethod
	let headers: [String: String]?
	let queryParameters: [String: any Sendable]?
	let requestBody: RequestBody
	let responseType: ResponseType

	init(
		baseURL: String = "https://api.test.com",
		path: String,
		method: HTTPMethod,
		headers: [String: String]? = nil,
		queryParameters: [String: any Sendable]? = nil,
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
