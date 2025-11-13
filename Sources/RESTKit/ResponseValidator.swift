import Foundation

public protocol ResponseValidator {
    func validate(statusCode: Int, data: Data?) throws
}

public final class DefaultResponseValidator: ResponseValidator {
	public init() {}
	
    public func validate(statusCode: Int, data: Data?) throws {
        switch statusCode {
        case 200 ... 299:
            return
        case 300 ... 399:
            throw APIError.redirectionError(statusCode: statusCode)
        case 400 ... 499:
            throw APIError.clientError(statusCode: statusCode, data: data)
        case 500 ... 599:
            throw APIError.serverError(statusCode: statusCode, data: data)
        default:
            throw APIError.unexpectedStatusCode(statusCode: statusCode)
        }
    }
}
