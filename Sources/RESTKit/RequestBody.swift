import Foundation

public enum RequestBody {
    case json(Encodable)
    case text(String)
    case binary(Data)
    case form([String: Any])
    case none

    public var data: Data? {
        switch self {
        case let .json(encodable):
            return try? JSONEncoder().encode(encodable)

        case let .text(string):
            return string.data(using: .utf8)

        case let .binary(data):
            return data

        case let .form(parameters):
            let pairs = parameters.flatMap { key, value -> [String] in
                if let array = value as? [Any] {
                    return array.map { item in
                        let encodedKey = key.formURLEncoded()
                        let encodedValue = "\(item)".formURLEncoded()
                        return "\(encodedKey)=\(encodedValue)"
                    }
                }

                if value is NSNull {
                    return []
                }
				
				if let stringValue = value as? String, stringValue.isEmpty {
					return []
				}

                let encodedKey = key.formURLEncoded()
                let encodedValue = "\(value)".formURLEncoded()
                return ["\(encodedKey)=\(encodedValue)"]
            }

            let formString = pairs.joined(separator: "&")
            return formString.data(using: .utf8)

        case .none:
            return nil
        }
    }

    public var contentType: String {
        switch self {
        case .json: "application/json"
        case .text: "text/plain"
        case .binary: "application/octet-stream"
        case .form: "application/x-www-form-urlencoded"
        case .none: ""
        }
    }
}
