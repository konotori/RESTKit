import Foundation
import Testing
@testable import RESTKit

@Suite("RequestBody Exhaustive Tests")
struct RequestBodyTests {
	
	// MARK: JSON
	@Test("JSON body encodes Codable correctly")
	func jsonBodyEncodes() throws {
		struct Payload: Codable {
			let name: String
			let age: Int
			let active: Bool
		}
		
		let payload = Payload(name: "Alice", age: 30, active: true)
		let body = RequestBody.json(payload)
		
		let data = try #require(try body.data())
		let decoded = try JSONDecoder().decode(Payload.self, from: data)
		
		#expect(decoded.name == "Alice")
		#expect(decoded.age == 30)
		#expect(decoded.active == true)
		#expect(body.contentType == "application/json")
	}
	
	@Test("JSON body handles nil optional")
	func jsonBodyWithNil() throws {
		struct Payload: Codable {
			let name: String
			let email: String?
		}
		
		let payload = Payload(name: "Bob", email: nil)
		let body = RequestBody.json(payload)
		
		let data = try #require(try body.data())
		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		
		#expect(json?["name"] as? String == "Bob")
		#expect(json?["email"] as? String == nil)
	}
	
	@Test("JSON body handles unicode & special chars")
	func jsonBodyUnicode() throws {
		struct Payload: Codable {
			let name: String
			let emoji: String
		}
		
		let payload = Payload(name: "José María", emoji: "🚀🎉")
		let body = RequestBody.json(payload)
		
		let data = try #require(try body.data())
		let decoded = try JSONDecoder().decode(Payload.self, from: data)
		
		#expect(decoded.name == "José María")
		#expect(decoded.emoji == "🚀🎉")
	}
	
	// MARK: Text
	@Test("Text body encodes UTF-8 string")
	func textBodyEncodes() throws {
		let text = "Hello, World!"
		let body = RequestBody.text(text)
		
		let data = try #require(try body.data())
		let decoded = String(data: data, encoding: .utf8)
		
		#expect(decoded == text)
		#expect(body.contentType == "text/plain")
	}
	
	@Test("Text body handles empty string")
	func textBodyEmpty() throws {
		let body = RequestBody.text("")
		let data = try #require(try body.data())
		
		#expect(String(data: data, encoding: .utf8) == "")
	}
	
	// MARK: Binary
	@Test("Binary body returns original data")
	func binaryBody() throws {
		let originalData = Data([0x01, 0x02, 0x03, 0xFF])
		let body = RequestBody.binary(originalData)
		
		let data = try #require(try body.data())
		#expect(data == originalData)
		#expect(body.contentType == "application/octet-stream")
	}
	
	// MARK: Form
	@Test("Form body encodes key-value pairs")
	func formBodyBasic() throws {
		let params: [String: any Sendable] = ["name": "Alice", "age": "30"]
		let body = RequestBody.form(params)
		
		let data = try #require(try body.data())
		let string = String(data: data, encoding: .utf8)!
		
		#expect(string.contains("name=Alice"))
		#expect(string.contains("age=30"))
		#expect(body.contentType == "application/x-www-form-urlencoded")
	}
	
	@Test("Form body percent-encodes special chars")
	func formBodyPercentEncoding() throws {
		let params: [String: any Sendable] = ["search": "hello world", "filter": "a&b=c"]
		let body = RequestBody.form(params)
		
		let data = try #require(try body.data())
		let string = String(data: data, encoding: .utf8)!
		
		#expect(string.contains("search=hello+world"))
		#expect(string.contains("filter=a%26b%3Dc"))
	}
	
	@Test("Form body keeps empty string values")
	func formBodyKeepsEmptyValues() throws {
		let params: [String: any Sendable] = ["name": "Alice", "empty": "", "age": "30"]
		let body = RequestBody.form(params)

		let data = try #require(try body.data())
		let string = String(data: data, encoding: .utf8)!

		#expect(string.contains("name=Alice"))
		#expect(string.contains("age=30"))
		// "empty=" is a legitimate form pair; backends distinguish missing key vs empty value.
		#expect(string.contains("empty="))
	}
	
	// MARK: None
	@Test("None body returns nil data")
	func noneBody() throws {
		let body = RequestBody.none
		#expect(try body.data() == nil)
		#expect(body.contentType == "")
	}

	@Test("Form body encodes arrays as duplicate keys")
	func formBodyArray() throws {
		let params: [String: any Sendable] = ["tags": ["networking", "url encode"]]
		let body = RequestBody.form(params)
		
		let data = try #require(try body.data())
		let string = String(data: data, encoding: .utf8)!
		
		#expect(string.contains("tags=networking"))
		#expect(string.contains("tags=url+encode"))
	}

	@Test("JSON body uses injected encoder")
	func jsonBodyCustomEncoder() throws {
		struct Payload: Codable {
			let firstName: String
		}

		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase

		let body = RequestBody.json(Payload(firstName: "Alice"))
		let data = try #require(try body.data(using: encoder))
		let string = try #require(String(data: data, encoding: .utf8))

		#expect(string.contains("first_name"))
	}

	@Test("JSON body throws encodingFailed when model fails to encode")
	func jsonBodyEncodeFailure() {
		struct FailingPayload: Encodable {
			func encode(to encoder: Encoder) throws {
				throw EncodingError.invalidValue(
					"value",
					EncodingError.Context(codingPath: [], debugDescription: "boom")
				)
			}
		}

		let body = RequestBody.json(FailingPayload())

		#expect {
			_ = try body.data()
		} throws: { error in
			guard let apiError = error as? APIError,
				  case .encodingFailed = apiError else {
				return false
			}
			return true
		}
	}

	@Test("Form body skips NSNull values")
	func formBodySkipsNull() throws {
		let params: [String: any Sendable] = ["name": "Alice", "empty": NSNull()]
		let body = RequestBody.form(params)
		
		let data = try #require(try body.data())
		let string = String(data: data, encoding: .utf8)!
		
		#expect(string.contains("name=Alice"))
		#expect(!string.contains("empty="))
	}
}
