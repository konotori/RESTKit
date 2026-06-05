import Foundation

/// Describes a single API call: where it goes, what it sends, and what it returns.
///
/// Declare one small struct per endpoint and only override what differs from the
/// defaults (`headers`, `queryParameters`, `requestBody`, `needsAuthentication`):
///
/// ```swift
/// struct GetUser: Endpoint {
///     typealias Response = JSON<User>
///     let id: Int
///     var baseURL: String { "https://api.example.com" }
///     var path: String { "/users/\(id)" }
///     var method: HTTPMethod { .get }
/// }
/// let user = try await client.request(GetUser(id: 1))
/// ```
///
/// To share `baseURL` (and other conventions) across endpoints:
/// - Single backend: `extension Endpoint { var baseURL: String { "https://api.example.com" } }`
/// - Per service: `protocol GitHubEndpoint: Endpoint {}` +
///   `extension GitHubEndpoint { var baseURL: String { "https://api.github.com" } }`
public protocol Endpoint<Response>: Sendable {
	/// How this endpoint's response data becomes a typed value,
	/// e.g. `JSON<User>`, `Text`, `Raw`, or a custom `ResponseStrategy`.
	associatedtype Response: ResponseStrategy

    var baseURL: String { get }
    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String]? { get }
    var queryParameters: [String: any Sendable]? { get }
    var requestBody: RequestBody { get }
	/// Whether an auth interceptor should attach credentials to this endpoint.
	/// Defaults to `false`; endpoints that need authentication opt in explicitly.
	var needsAuthentication: Bool { get }

    func asURLRequest(bodyEncoder: JSONEncoder) throws -> URLRequest
}

public extension Endpoint {
	var headers: [String: String]? {
		nil
	}

	var queryParameters: [String: any Sendable]? {
		nil
	}

	var requestBody: RequestBody {
		.none
	}

	var needsAuthentication: Bool {
		false
	}

    /// Builds a complete, ready-to-send URLRequest.
    /// - Parameter bodyEncoder: The encoder used for `.json` request bodies.
    ///   `APIClient` always passes its own configured encoder. When calling this
    ///   directly (bypassing the client), pass the same encoder your client uses
    ///   so bodies stay consistent.
    func asURLRequest(bodyEncoder: JSONEncoder = JSONEncoder()) throws -> URLRequest {
        let url = try buildURL()
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        addHeaders(to: &request)
        try addBody(to: &request, using: bodyEncoder)

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
        // URLComponents leaves "+" unescaped in query values, but many servers
        // decode "+" as a space. Escape it explicitly so values round-trip intact.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

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

		// Sort by key so the resulting URL is deterministic (cache keys, request
		// signing, snapshot tests).
		return queryParameters.sorted { $0.key < $1.key }.flatMap { key, value -> [URLQueryItem] in
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

    private func addBody(to request: inout URLRequest, using bodyEncoder: JSONEncoder) throws {
        request.httpBody = try requestBody.data(using: bodyEncoder)
    }
}
