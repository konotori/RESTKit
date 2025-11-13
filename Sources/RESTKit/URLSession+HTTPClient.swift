import Foundation

extension URLSession: HTTPClient {
	public func perform(request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
			throw APIError.invalidResponse
        }

        return (data, httpResponse)
    }
}
