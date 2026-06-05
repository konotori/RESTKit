import Foundation

/// A ready-made generic endpoint for quick, one-off calls — no custom type needed:
///
/// ```swift
/// let endpoint = APIEndpoint<JSON<[Entry]>>(
///     baseURL: "https://api.dictionaryapi.dev",
///     path: "/api/v2/entries/en/swift",
///     method: .get
/// )
/// let entries = try await client.request(endpoint)
/// ```
///
/// For endpoints used in more than one place, prefer declaring a small
/// `Endpoint`-conforming struct instead (see `Endpoint` documentation).
public struct APIEndpoint<Response: ResponseStrategy>: Endpoint {
	public var baseURL: String
	public var path: String
	public var method: HTTPMethod
	public var headers: [String: String]?
	public var queryParameters: [String: any Sendable]?
	public var requestBody: RequestBody
	public var needsAuthentication: Bool

	public init(
		baseURL: String,
		path: String,
		method: HTTPMethod,
		headers: [String: String]? = nil,
		queryParameters: [String: any Sendable]? = nil,
		requestBody: RequestBody = .none,
		needsAuthentication: Bool = false
	) {
		self.baseURL = baseURL
		self.path = path
		self.method = method
		self.headers = headers
		self.queryParameters = queryParameters
		self.requestBody = requestBody
		self.needsAuthentication = needsAuthentication
	}
}
