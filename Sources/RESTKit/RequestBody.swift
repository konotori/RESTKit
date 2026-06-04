import Foundation

public enum RequestBody: Sendable {
    case json(any Encodable & Sendable)
    case text(String)
    case binary(Data)
    case form([String: any Sendable])
    case none

    /// - Parameter encoder: The encoder used for `.json` bodies. Pass a configured
    ///   instance to customize encoding (e.g. date or key strategies).
    public func data(using encoder: JSONEncoder = JSONEncoder()) throws -> Data? {
        switch self {
        case let .json(encodable):
            do {
                return try encoder.encode(encodable)
            } catch {
                throw APIError.encodingFailed(error)
            }

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
