import Foundation

public protocol HTTPClient: Sendable {
    func perform(request: URLRequest) async throws -> (Data, URLResponse)
}
