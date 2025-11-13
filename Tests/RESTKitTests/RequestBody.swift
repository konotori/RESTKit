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
		
		let data = try #require(body.data)
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
		
		let data = try #require(body.data)
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
		
		let data = try #require(body.data)
		let decoded = try JSONDecoder().decode(Payload.self, from: data)
		
		#expect(decoded.name == "José María")
		#expect(decoded.emoji == "🚀🎉")
	}
	
	// MARK: Text
	@Test("Text body encodes UTF-8 string")
	func textBodyEncodes() throws {
		let text = "Hello, World!"
		let body = RequestBody.text(text)
		
		let data = try #require(body.data)
		let decoded = String(data: data, encoding: .utf8)
		
		#expect(decoded == text)
		#expect(body.contentType == "text/plain")
	}
	
	@Test("Text body handles empty string")
	func textBodyEmpty() throws {
		let body = RequestBody.text("")
		let data = try #require(body.data)
		
		#expect(String(data: data, encoding: .utf8) == "")
	}
	
	// MARK: Binary
	@Test("Binary body returns original data")
	func binaryBody() throws {
		let originalData = Data([0x01, 0x02, 0x03, 0xFF])
		let body = RequestBody.binary(originalData)
		
		let data = try #require(body.data)
		#expect(data == originalData)
		#expect(body.contentType == "application/octet-stream")
	}
	
	// MARK: Form
	@Test("Form body encodes key-value pairs")
	func formBodyBasic() throws {
		let params: [String: Any] = ["name": "Alice", "age": "30"]
		let body = RequestBody.form(params)
		
		let data = try #require(body.data)
		let string = String(data: data, encoding: .utf8)!
		
		#expect(string.contains("name=Alice"))
		#expect(string.contains("age=30"))
		#expect(body.contentType == "application/x-www-form-urlencoded")
	}
	
	@Test("Form body percent-encodes special chars")
	func formBodyPercentEncoding() throws {
		let params: [String: Any] = ["search": "hello world", "filter": "a&b=c"]
		let body = RequestBody.form(params)
		
		let data = try #require(body.data)
		let string = String(data: data, encoding: .utf8)!
		
		#expect(string.contains("search=hello+world"))
		#expect(string.contains("filter=a%26b%3Dc"))
	}
	
	@Test("Form body filters empty values")
	func formBodyFiltersEmpty() throws {
		let params: [String: Any] = ["name": "Alice", "empty": "", "age": "30"]
		let body = RequestBody.form(params)
		
		let data = try #require(body.data)
		let string = String(data: data, encoding: .utf8)!
		
		#expect(string.contains("name=Alice"))
		#expect(string.contains("age=30"))
		#expect(!string.contains("empty="))
	}
	
	// MARK: None
	@Test("None body returns nil data")
	func noneBody() {
		let body = RequestBody.none
		#expect(body.data == nil)
		#expect(body.contentType == "")
	}

	@Test("Form body encodes arrays as duplicate keys")
	func formBodyArray() throws {
		let params: [String: Any] = ["tags": ["networking", "url encode"]]
		let body = RequestBody.form(params)
		
		let data = try #require(body.data)
		let string = String(data: data, encoding: .utf8)!
		
		#expect(string.contains("tags=networking"))
		#expect(string.contains("tags=url+encode"))
	}

	@Test("Form body skips NSNull values")
	func formBodySkipsNull() throws {
		let params: [String: Any] = ["name": "Alice", "empty": NSNull()]
		let body = RequestBody.form(params)
		
		let data = try #require(body.data)
		let string = String(data: data, encoding: .utf8)!
		
		#expect(string.contains("name=Alice"))
		#expect(!string.contains("empty="))
	}
}
