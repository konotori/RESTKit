import Foundation

public protocol RequestInterceptor: Sendable {
    /// Modify request before sending
    func adapt(_ request: URLRequest, for endpoint: any Endpoint) async throws -> URLRequest
    
    /// Callback after request completes (success or failure).
    /// Not called when the request could not be built (e.g. invalid URL or body encoding failure).
    /// - Parameters:
    ///   - request: The request that was sent.
    ///   - result: Success with (Data, URLResponse) or failure with Error (including CancellationError if the task was cancelled).
    ///   - endpoint: The original endpoint.
    func didComplete(_ request: URLRequest, result: Result<(Data, URLResponse), Error>, for endpoint: any Endpoint) async
}

public extension RequestInterceptor {
	func adapt(_ request: URLRequest, for endpoint: any Endpoint) async throws -> URLRequest {
        request
    }
    
	func didComplete(_ request: URLRequest, result: Result<(Data, URLResponse), Error>, for endpoint: any Endpoint) async {
        // Default: Do nothing
    }
}
