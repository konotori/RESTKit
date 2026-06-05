import Foundation

/// A strategy describing how an endpoint's raw response data becomes a typed value.
///
/// Built-in strategies: `JSON<Model>`, `Text`, and `Raw`. Add your own by
/// conforming a phantom type (caseless enum) to this protocol — e.g. an
/// `Enveloped<Model>` that unwraps a `{"data": ...}` wrapper, or a CSV parser.
///
/// Strategies throw their natural errors (`DecodingError`, parser errors, ...);
/// `APIClient` normalizes everything to `APIError.decodingFailed`.
public protocol ResponseStrategy<Output>: Sendable {
	associatedtype Output: Sendable

	static func decode(_ data: Data, using decoder: JSONDecoder) throws -> Output
}

/// Decodes the response as JSON into `Model` using the client's decoder.
public enum JSON<Model: Decodable & Sendable>: ResponseStrategy {
	public static func decode(_ data: Data, using decoder: JSONDecoder) throws -> Model {
		try decoder.decode(Model.self, from: data)
	}
}

/// Returns the response as a UTF-8 string.
public enum Text: ResponseStrategy {
	public static func decode(_ data: Data, using decoder: JSONDecoder) throws -> String {
		guard let text = String(data: data, encoding: .utf8) else {
			throw NSError(domain: "RESTKit", code: 1, userInfo: [
				NSLocalizedDescriptionKey: "Response is not valid UTF-8 text."
			])
		}
		return text
	}
}

/// Returns the raw response bytes untouched.
public enum Raw: ResponseStrategy {
	public static func decode(_ data: Data, using decoder: JSONDecoder) throws -> Data {
		data
	}
}
