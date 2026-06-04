import Foundation

public protocol ResponseDecoder: Sendable {
    func decode(_ data: Data, as responseType: ResponseType) throws -> Any
}

public final class DefaultResponseDecoder: ResponseDecoder, Sendable {
	private let jsonDecoder: JSONDecoder
	
	public init(jsonDecoder: JSONDecoder = JSONDecoder()) {
		self.jsonDecoder = jsonDecoder
	}
	
    public func decode(_ data: Data, as responseType: ResponseType) throws -> Any {
        do {
            switch responseType {
            case let .json(modelType):
                return try jsonDecoder.decode(modelType, from: data)
            case .text:
				if let text = String(data: data, encoding: .utf8) {
					return text
				}
				let error = NSError(domain: "RESTKit", code: 1, userInfo: [
					NSLocalizedDescriptionKey: "Response is not valid UTF-8 text."
				])
				throw APIError.decodingFailed(error)
            case .data:
                return data
            case let .custom(decodeFunction):
                return try decodeFunction(data)
            }
        } catch {
            throw APIError.decodingFailed(error)
        }
    }
}
