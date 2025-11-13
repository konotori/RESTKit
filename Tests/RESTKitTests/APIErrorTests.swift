import Foundation
import Testing
@testable import RESTKit

@Suite("APIError Tests")
struct APIErrorTests {

    @Test("invalidURL has correct description")
    func invalidURLDescription() {
        let error = APIError.invalidURL
        #expect(error.errorDescription == "Invalid URL.")
    }

    @Test("requestFailed wraps error description")
    func requestFailedDescription() {
        let underlying = URLError(.notConnectedToInternet)
        let error = APIError.requestFailed(underlying)
        #expect(error.errorDescription?.contains("Request failed") == true)
        #expect(error.errorDescription?.contains(underlying.localizedDescription) == true)
    }

    @Test("invalidResponse has correct description")
    func invalidResponseDescription() {
        let error = APIError.invalidResponse
        #expect(error.errorDescription == "Received invalid response from the server.")
    }

    @Test("decodingFailed wraps error description")
    func decodingFailedDescription() {
        struct CustomError: Error {}
        let error = APIError.decodingFailed(CustomError())
        #expect(error.errorDescription?.contains("Failed to decode") == true)
    }

    @Test("typeMismatch has expected and actual in description")
    func typeMismatchDescription() {
        let error = APIError.typeMismatch(expected: "String", actual: "Int")
        #expect(error.errorDescription == "Type mismatch. Expected String, got Int.")
    }

    @Test("clientError includes status code")
    func clientErrorDescription() {
        let error = APIError.clientError(statusCode: 404, data: nil)
        #expect(error.errorDescription == "Client error (HTTP 404).")
    }

    @Test("serverError includes status code")
    func serverErrorDescription() {
        let error = APIError.serverError(statusCode: 500, data: nil)
        #expect(error.errorDescription == "Server error (HTTP 500).")
    }

    @Test("redirectionError includes status code")
    func redirectionErrorDescription() {
        let error = APIError.redirectionError(statusCode: 302)
        #expect(error.errorDescription == "Unexpected redirection (HTTP 302).")
    }

    @Test("unexpectedStatusCode includes status code")
    func unexpectedStatusCodeDescription() {
        let error = APIError.unexpectedStatusCode(statusCode: 999)
        #expect(error.errorDescription == "Unexpected HTTP status code: 999.")
    }

    @Test("custom returns message")
    func customDescription() {
        let error = APIError.custom("Something went wrong")
        #expect(error.errorDescription == "Something went wrong")
    }
}
