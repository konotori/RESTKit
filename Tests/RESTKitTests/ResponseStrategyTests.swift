import Foundation
import Testing
@testable import RESTKit

@Suite("ResponseStrategy Tests")
struct ResponseStrategyTests {
	let mockData = #"{"id": 1, "name": "Test", "email": "Test@gmail.com"}"#.data(using: .utf8)!
	let decoder = JSONDecoder()

	// MARK: JSON
	@Test("JSON strategy decodes to the model type")
	func jsonStrategy() throws {
		let user = try JSON<User>.decode(mockData, using: decoder)

		#expect(user.id == 1)
		#expect(user.name == "Test")
		#expect(user.email == "Test@gmail.com")
	}

	@Test("JSON strategy respects the injected decoder configuration")
	func jsonStrategyUsesInjectedDecoder() throws {
		struct Payload: Decodable {
			let firstName: String
		}

		let snakeCaseDecoder = JSONDecoder()
		snakeCaseDecoder.keyDecodingStrategy = .convertFromSnakeCase

		let data = #"{"first_name": "Alice"}"#.data(using: .utf8)!
		let payload = try JSON<Payload>.decode(data, using: snakeCaseDecoder)

		#expect(payload.firstName == "Alice")
	}

	// MARK: Text
	@Test("Text strategy returns UTF-8 string")
	func textStrategy() throws {
		let textData = "Hello, World!".data(using: .utf8)!
		let text = try Text.decode(textData, using: decoder)

		#expect(text == "Hello, World!")
	}

	@Test("Text strategy throws for invalid UTF-8")
	func textStrategyInvalidUTF8() {
		let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])

		// Strategies throw their raw error; APIClient owns APIError normalization.
		#expect(throws: (any Error).self) {
			try Text.decode(invalidUTF8, using: decoder)
		}
	}

	@Test("Invalid UTF-8 text surfaces as decodingFailed through APIClient")
	func invalidUTF8MapsToDecodingFailedThroughClient() async {
		let mock = MockHTTPClient()
		mock.mockResponse = .init(data: Data([0xFF, 0xFE, 0xFD]), statusCode: 200)

		let client = APIClient(client: mock)
		let endpoint = TestEndpoint(
			path: "/text",
			method: .get,
			responseType: Text.self
		)

		await #expect {
			_ = try await client.request(endpoint)
		} throws: { error in
			guard let apiError = error as? APIError,
				  case .decodingFailed = apiError else {
				return false
			}
			return true
		}
	}

	// MARK: Raw
	@Test("Raw strategy returns bytes untouched")
	func rawStrategy() throws {
		let rawData = Data([0x01, 0x02, 0x03])
		let data = try Raw.decode(rawData, using: decoder)

		#expect(data == rawData)
	}

	// MARK: Custom strategies

	/// A custom strategy unwrapping a {"data": ...} envelope — written once,
	/// reusable by any endpoint.
	enum Enveloped<Model: Decodable & Sendable>: ResponseStrategy {
		struct Envelope: Decodable {
			let data: Model
		}

		static func decode(_ data: Data, using decoder: JSONDecoder) throws -> Model {
			try decoder.decode(Envelope.self, from: data).data
		}
	}

	@Test("Custom strategy unwraps an envelope")
	func customEnvelopedStrategy() throws {
		let wrapped = #"{"data": {"id": 7, "name": "Wrapped", "email": null}}"#.data(using: .utf8)!
		let user = try Enveloped<User>.decode(wrapped, using: decoder)

		#expect(user.id == 7)
		#expect(user.name == "Wrapped")
	}

	@Test("Custom strategy works end-to-end through APIClient")
	func customStrategyThroughClient() async throws {
		let wrapped = #"{"data": {"id": 7, "name": "Wrapped", "email": null}}"#.data(using: .utf8)!
		let mock = MockHTTPClient()
		mock.mockResponse = .init(data: wrapped, statusCode: 200)

		let client = APIClient(client: mock)
		let endpoint = TestEndpoint(
			path: "/users/7",
			method: .get,
			requestBody: .none,
			responseType: Enveloped<User>.self
		)

		let user = try await client.request(endpoint)
		#expect(user.id == 7)
	}

	@Test("Custom strategy errors surface as decodingFailed through APIClient")
	func customStrategyErrorMapsToDecodingFailed() async {
		struct CSVParseError: Error {}

		enum FailingStrategy: ResponseStrategy {
			static func decode(_ data: Data, using decoder: JSONDecoder) throws -> String {
				throw CSVParseError()
			}
		}

		let mock = MockHTTPClient()
		mock.mockResponse = .init(data: Data("x".utf8), statusCode: 200)

		let client = APIClient(client: mock)
		let endpoint = TestEndpoint(
			path: "/report",
			method: .get,
			requestBody: .none,
			responseType: FailingStrategy.self
		)

		await #expect {
			_ = try await client.request(endpoint)
		} throws: { error in
			guard let apiError = error as? APIError,
				  case .decodingFailed = apiError else {
				return false
			}
			return true
		}
	}
}
