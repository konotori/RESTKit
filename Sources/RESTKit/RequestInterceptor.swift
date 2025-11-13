import Foundation

public protocol RequestInterceptor {
    /// Modify request before sending
    func adapt(_ request: URLRequest, for endpoint: Endpoint) async throws -> URLRequest
    
    /// Callback after request completes (success or failure).
    /// - Parameters:
    ///   - request: The request that was sent.
    ///   - result: Success with (Data, URLResponse) or failure with Error. Failure if request was never sent.
    ///   - endpoint: The original endpoint.
    func didComplete(_ request: URLRequest, result: Result<(Data, URLResponse), Error>, for endpoint: Endpoint) async
}

public extension RequestInterceptor {
	func adapt(_ request: URLRequest, for endpoint: Endpoint) async throws -> URLRequest {
        request
    }
    
	func didComplete(_ request: URLRequest, result: Result<(Data, URLResponse), Error>, for endpoint: Endpoint) async {
        // Default: Do nothing
    }
}
