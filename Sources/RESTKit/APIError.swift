import Foundation

public enum APIError: Error, LocalizedError, Equatable {
    case invalidURL
    case requestFailed(Error)
    case invalidResponse
    case decodingFailed(Error)
    case typeMismatch(expected: String, actual: String)
    case clientError(statusCode: Int, data: Data?) // 400-499
    case serverError(statusCode: Int, data: Data?) // 500-599
    case redirectionError(statusCode: Int) // 300-399
    case unexpectedStatusCode(statusCode: Int)
    case custom(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid URL."
        case let .requestFailed(error):
            "Request failed with error: \(error.localizedDescription)"
        case .invalidResponse:
            "Received invalid response from the server."
        case let .decodingFailed(error):
            "Failed to decode response: \(error.localizedDescription)"
        case let .typeMismatch(expected, actual):
            "Type mismatch. Expected \(expected), got \(actual)."
        case let .clientError(code, _):
            "Client error (HTTP \(code))."
        case let .serverError(code, _):
            "Server error (HTTP \(code))."
        case let .redirectionError(code):
            "Unexpected redirection (HTTP \(code))."
        case let .unexpectedStatusCode(code):
            "Unexpected HTTP status code: \(code)."
        case let .custom(message):
            message
        }
    }

    public static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL),
             (.invalidResponse, .invalidResponse):
            return true
        case let (.requestFailed(e1), .requestFailed(e2)):
            return (e1 as NSError).isEqual(e2 as NSError)
        case let (.decodingFailed(e1), .decodingFailed(e2)):
            return (e1 as NSError).isEqual(e2 as NSError)
        case let (.typeMismatch(a1, b1), .typeMismatch(a2, b2)):
            return a1 == a2 && b1 == b2
        case let (.clientError(c1, d1), .clientError(c2, d2)):
            return c1 == c2 && d1 == d2
        case let (.serverError(c1, d1), .serverError(c2, d2)):
            return c1 == c2 && d1 == d2
        case let (.redirectionError(c1), .redirectionError(c2)):
            return c1 == c2
        case let (.unexpectedStatusCode(c1), .unexpectedStatusCode(c2)):
            return c1 == c2
        case let (.custom(m1), .custom(m2)):
            return m1 == m2
        default:
            return false
        }
    }
}
