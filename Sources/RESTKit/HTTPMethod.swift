import Foundation

public enum HTTPMethod: String, CaseIterable {
	case get = "GET"
	case post = "POST"
	case put = "PUT"
	case delete = "DELETE"
	case patch = "PATCH"
	case head = "HEAD"
	case options = "OPTIONS"
	
	public static var idempotentMethods: [HTTPMethod] = [.get, .put, .delete, .head, .options]
}
