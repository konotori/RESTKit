import Foundation

public protocol HTTPClient {
    func perform(request: URLRequest) async throws -> (Data, URLResponse)
}
