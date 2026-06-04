import Foundation

extension URLSession: HTTPClient {
	public func perform(request: URLRequest) async throws -> (Data, URLResponse) {
		try await data(for: request)
	}
}
