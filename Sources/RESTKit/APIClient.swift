import Foundation

public protocol APIClientProtocol: Sendable {
    func request<T>(_ endpoint: Endpoint) async throws -> T
}

public final class APIClient: APIClientProtocol, Sendable {
    private let client: HTTPClient
	private let bodyEncoder: JSONEncoder
    private let responseDecoder: ResponseDecoder
    private let responseValidator: ResponseValidator
	private let interceptors: [any RequestInterceptor]

    public init(
        client: HTTPClient = URLSession.shared,
		bodyEncoder: JSONEncoder = JSONEncoder(),
		responseDecoder: ResponseDecoder = DefaultResponseDecoder(),
        responseValidator: ResponseValidator = DefaultResponseValidator(),
		interceptors: [any RequestInterceptor] = []
    ) {
        self.client = client
		self.bodyEncoder = bodyEncoder
        self.responseDecoder = responseDecoder
        self.responseValidator = responseValidator
		self.interceptors = interceptors
    }

    public func request<T>(_ endpoint: Endpoint) async throws -> T {
		var request = try endpoint.asURLRequest(bodyEncoder: bodyEncoder)
		
		do {
			request = try await adapt(request, for: endpoint)
			
			let (data, response) = try await client.perform(request: request)
			
			guard let httpResponse = response as? HTTPURLResponse else {
				throw APIError.invalidResponse
			}
			
			try responseValidator.validate(statusCode: httpResponse.statusCode, data: data)
			
			let decodedObject = try responseDecoder.decode(data, as: endpoint.responseType)
			
			guard let result = decodedObject as? T else {
				throw APIError.typeMismatch(
					expected: String(describing: T.self),
					actual: String(describing: type(of: decodedObject))
				)
			}
			
			await notifyCompletion(request, result: .success((data, httpResponse)), for: endpoint)
			return result
		} catch {
			let mappedError = mapError(error)
			await notifyCompletion(request, result: .failure(mappedError), for: endpoint)
			throw mappedError
		}
    }
	
	/// Applies interceptors in reverse registration order (onion model): for
	/// `interceptors: [A, B]`, B adapts first and A adapts last, so the first
	/// registered interceptor sees the final request. `didComplete` is notified
	/// in registration order.
	private func adapt(_ request: URLRequest, for endpoint: Endpoint) async throws -> URLRequest {
		var currentRequest = request
		
		for interceptor in interceptors.reversed() {
			currentRequest = try await interceptor.adapt(currentRequest, for: endpoint)
		}
		
		return currentRequest
	}
	
	private func notifyCompletion(_ request: URLRequest, result: Result<(Data, URLResponse), Error>, for endpoint: Endpoint) async {
		for interceptor in interceptors {
			await interceptor.didComplete(request, result: result, for: endpoint)
		}
	}
	
	/// Maps raw errors to the public error contract: cancellation surfaces as
	/// CancellationError so callers can distinguish "task was cancelled" from real
	/// failures; everything else surfaces as APIError.
	private func mapError(_ error: Error) -> Error {
		// URLSession reports Task cancellation as URLError(.cancelled).
		if error is CancellationError || (error as? URLError)?.code == .cancelled {
			return CancellationError()
		}
		if let apiError = error as? APIError {
			return apiError
		}
		return APIError.requestFailed(error)
	}
}
