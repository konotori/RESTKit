import Foundation

public protocol Endpoint {
    var baseURL: String { get }
    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String]? { get }
    var queryParameters: [String: Any]? { get }
    var requestBody: RequestBody { get }
    var responseType: ResponseType { get }
	var needsAuthentication: Bool { get }
	var allowRetry: Bool { get }

    func asURLRequest() throws -> URLRequest
}

public extension Endpoint {
	var needsAuthentication: Bool {
		true
	}
	
	var allowRetry: Bool {
		HTTPMethod.idempotentMethods.contains(method)
	}
	
    func asURLRequest() throws -> URLRequest {
        let url = try buildURL()
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        addHeaders(to: &request)
        addBody(to: &request)
        
        return request
    }
	
	private func buildURL() throws -> URL {
		guard let baseURL = URL(string: baseURL),
			  let _ = baseURL.scheme,
			  let _ = baseURL.host,
			  var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
		else {
			throw APIError.invalidURL
		}
		
        components.path = normalizedPath(for: components)
        components.queryItems = makeQueryItems()
        
        guard let url = components.url else {
            throw APIError.invalidURL
        }
        return url
    }

    private func normalizedPath(for components: URLComponents) -> String {
		let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
		let endpointPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
		
		return basePath + "/" + endpointPath
    }
    
	private func makeQueryItems() -> [URLQueryItem]? {
		guard let queryParameters,
			  !queryParameters.isEmpty else {
			return nil
		}
		
		return queryParameters.flatMap { key, value -> [URLQueryItem] in
			// Handle array (e.g. tags[]=swift&tags[]=ios)
			if let array = value as? [Any] {
				return array.map { item in
					URLQueryItem(
						name: key + "[]",
						value: "\(item)"
					)
				}
			}
			// Skip nil values
			guard !(value is NSNull) else {
				return []
			}
			// Single value
			return [URLQueryItem(name: key, value: "\(value)")]
		}
	}
	
	private func addHeaders(to request: inout URLRequest) {
		headers?.forEach { key, value in
			request.setValue(value, forHTTPHeaderField: key)
		}
		if request.value(forHTTPHeaderField: "Content-Type") == nil,
		   !requestBody.contentType.isEmpty {
			request.setValue(requestBody.contentType, forHTTPHeaderField: "Content-Type")
		}
	}

    private func addBody(to request: inout URLRequest) {
        request.httpBody = requestBody.data
    }
}
