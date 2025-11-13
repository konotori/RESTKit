import Foundation

public enum ResponseType {
    case json(Decodable.Type)
    case text
    case data
    case custom((Data) throws -> Any)
}
