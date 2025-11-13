import Foundation

public protocol APIClientProtocol {
    func request<T>(_ endpoint: Endpoint) async throws -> T
}

public final class APIClient: APIClientProtocol {
    private let client: HTTPClient
    private let responseValidator: ResponseValidator
    private let responseDecoder: ResponseDecoder
	private let interceptors: [any RequestInterceptor]

    public init(
        client: HTTPClient = URLSession.shared,
        responseValidator: ResponseValidator = DefaultResponseValidator(),
		responseDecoder: ResponseDecoder = DefaultResponseDecoder(),
		interceptors: [any RequestInterceptor] = []
    ) {
        self.client = client
        self.responseValidator = responseValidator
        self.responseDecoder = responseDecoder
		self.interceptors = interceptors
    }

    public func request<T>(_ endpoint: Endpoint) async throws -> T {
		var request = try endpoint.asURLRequest()
		
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
			let apiError = mapToAPIError(error)
			await notifyCompletion(request, result: .failure(apiError), for: endpoint)
			throw apiError
		}
    }
	
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
	
	private func mapToAPIError(_ error: Error) -> APIError {
		if let apiError = error as? APIError {
			return apiError
		}
		return APIError.requestFailed(error)
	}
}
