import Foundation

internal extension String {
	func formURLEncoded() -> String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._*")
		let encoded = addingPercentEncoding(withAllowedCharacters: allowed) ?? self
		return encoded.replacingOccurrences(of: "%20", with: "+")
	}
}
