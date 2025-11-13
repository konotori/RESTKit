import Foundation
import Testing
@testable import RESTKit

@Suite("ResponseType Exhaustive Tests")
struct ResponseTypeTests {
	let mockData = #"{"id": 1, "name": "Test", "email": "Test@gmail.com"}"#.data(using: .utf8)!
	
	// MARK: JSON
	@Test("JSON response decodes to correct type")
	func jsonResponse() throws {
		let decoder = DefaultResponseDecoder()
		let responseType = ResponseType.json(User.self)
		
		let result = try decoder.decode(mockData, as: responseType)
		let user = try #require(result as? User)
		
		#expect(user.id == 1)
		#expect(user.name == "Test")
		#expect(user.email == "Test@gmail.com")
	}
	
	@Test("JSON response fails with decode error")
	func jsonDecodeError() throws {
		let invalidData = #"{"invalid": json}"#.data(using: .utf8)!
		let decoder = DefaultResponseDecoder()
		let responseType = ResponseType.json(User.self)
		
		#expect {
			try decoder.decode(invalidData, as: responseType)
		} throws: { error in
			guard let apiError = error as? APIError,
				  case .decodingFailed = apiError else {
				return false
			}
			
			return true
		}
	}
	
	// MARK: Text
	@Test("Text response returns string")
	func textResponse() throws {
		let textData = "Hello, World!".data(using: .utf8)!
		let decoder = DefaultResponseDecoder()
		let responseType = ResponseType.text
		
		let result = try decoder.decode(textData, as: responseType)
		let text = try #require(result as? String)
		
		#expect(text == "Hello, World!")
	}
	
	// MARK: Data
	@Test("Data response returns raw data")
	func dataResponse() throws {
		let rawData = Data([0x01, 0x02, 0x03])
		let decoder = DefaultResponseDecoder()
		let responseType = ResponseType.data
		
		let result = try decoder.decode(rawData, as: responseType)
		let data = try #require(result as? Data)
		
		#expect(data == rawData)
	}
	
	// MARK: Custom
	@Test("Custom response decodes using provided function")
	func customResponse() async throws {
		let xmlData = "<user><id>1</id><name>XML</name></user>".data(using: .utf8)!
		let decoder = DefaultResponseDecoder()
		
		let responseType = ResponseType.custom { data in
			let string = String(data: data, encoding: .utf8)!
			let id = Int(string.components(separatedBy: "<id>").dropFirst().first?.components(separatedBy: "</id>").first ?? "0")!
			let name = string.components(separatedBy: "<name>").dropFirst().first?.components(separatedBy: "</name>").first ?? ""
			return User(id: id, name: name, email: nil)
		}
		
		let result = try decoder.decode(xmlData, as: responseType)
		let user = try #require(result as? User)
		
		#expect(user.id == 1)
		#expect(user.name == "XML")
	}
}
