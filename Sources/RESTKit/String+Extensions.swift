import Foundation

internal extension String {
	func urlQueryEncoded() -> String {
		var allowed = CharacterSet.urlQueryAllowed
		allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
		return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
	}
	
	func formURLEncoded() -> String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._*")
		let encoded = addingPercentEncoding(withAllowedCharacters: allowed) ?? self
		return encoded.replacingOccurrences(of: "%20", with: "+")
	}
}
