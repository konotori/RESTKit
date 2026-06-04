import Foundation

public enum ResponseType: Sendable {
    case json(any (Decodable & Sendable).Type)
    case text
    case data
    case custom(@Sendable (Data) throws -> any Sendable)
}
