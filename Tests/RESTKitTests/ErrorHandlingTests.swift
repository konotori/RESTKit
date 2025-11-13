import Foundation
import Testing
@testable import RESTKit


@Suite("Error Handling Tests")
struct ErrorHandlingTests {
	let mockClient = MockHTTPClient()
	
	init() {
		mockClient.recordedRequest = nil
	}
	
	// MARK: Type Mismatch
	@Test("Type mismatch throws correct error")
	func typeMismatchError() async {
		let userData = try! JSONEncoder().encode(
			User(id: 1, name: "Test", email: "email")
		)
		mockClient.mockResponse = .init(data: userData, statusCode: 200)
		
		let apiClient = APIClient(client: mockClient)
		let endpoint = TestEndpoint(
			path: "/users/1",
			method: .get,
			requestBody: .none,
			responseType: .json(User.self)
		)
		
		await #expect {
			let _: Int = try await apiClient.request(endpoint)
		} throws: { error in
			guard let apiError = error as? APIError,
				  case .typeMismatch = apiError else {
				return false
			}
			
			return true
		}
	}
	
	// MARK: Network Errors
	@Test("Network error throws requestFailed")
	func networkError() async {
		mockClient.shouldThrowError = URLError(.notConnectedToInternet)
		
		let apiClient = APIClient(client: mockClient)
		let endpoint = TestEndpoint(
			path: "/users",
			method: .get,
			requestBody: .none,
			responseType: .text
		)
		
		await #expect {
			let _: String = try await apiClient.request(endpoint)
		} throws: { error in
			guard let apiError = error as? APIError,
				  case .requestFailed = apiError else {
				return false
			}
			
			return true
		}
	}
	
	// MARK: Status Code Errors
	@Test("400 error throws clientError with data")
	func clientErrorWithData() async {
		let errorData = #"{"error": "Bad Request"}"#.data(using: .utf8)!
		mockClient.mockResponse = .init(data: errorData, statusCode: 400)
		
		let apiClient = APIClient(client: mockClient)
		let endpoint = TestEndpoint(
			path: "/users",
			method: .post,
			requestBody: .none,
			responseType: .text
		)
		
		await #expect {
			let _: String = try await apiClient.request(endpoint)
		} throws: { error in
			guard let apiError = error as? APIError,
				 case .clientError(let code, let data) = apiError else {
				return false
			}
			
			return code == 400 && data == errorData
		}
	}
	
	@Test("500 error throws serverError")
	func serverError() async {
		mockClient.mockResponse = .init(data: Data(), statusCode: 500)
		
		let apiClient = APIClient(client: mockClient)
		let endpoint = TestEndpoint(
			path: "/users",
			method: .get,
			requestBody: .none,
			responseType: .text
		)
		
		await #expect {
			let _: String = try await apiClient.request(endpoint)
		} throws: { error in
			guard let apiError = error as? APIError,
				  case .serverError(let code, _) = apiError else {
				return false
			}
			
			return code == 500
		}
	}
	
	// MARK: Invalid Response
	@Test("Non-HTTP response throws invalidResponse")
	func invalidResponse() async {
		let client = APIClient(client: NonHTTPClient())
		let endpoint = TestEndpoint(
			path: "/users",
			method: .get,
			requestBody: .none,
			responseType: .text
		)
		
		await #expect {
			let _: String = try await client.request(endpoint)
		} throws: { error in
			guard let apiError = error as? APIError,
				  case .invalidResponse = apiError else {
				return false
			}
			return true
		}
	}
	
	// MARK: Decode Error
	@Test("Invalid JSON throws decodingFailed")
	func decodeError() async {
		let invalidJSON = #"{"invalid": json}"#.data(using: .utf8)!
		mockClient.mockResponse = .init(data: invalidJSON, statusCode: 200)
		
		let apiClient = APIClient(client: mockClient)
		let endpoint = TestEndpoint(
			path: "/users",
			method: .get,
			requestBody: .none,
			responseType: .json(User.self)
		)
		
		await #expect {
			let _: User = try await apiClient.request(endpoint)
		} throws: { error in
			guard let apiError = error as? APIError,
				  case .decodingFailed = apiError else {
				return false
			}
			
			return true
		}
	}
}
