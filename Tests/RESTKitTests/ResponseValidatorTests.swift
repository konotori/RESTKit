import Foundation
import Testing
@testable import RESTKit

@Suite("ResponseValidator Tests")
struct ResponseValidatorTests {

    let validator = DefaultResponseValidator()

    @Test("2xx status codes succeed")
    func successRange() throws {
        try validator.validate(statusCode: 200, data: nil)
        try validator.validate(statusCode: 201, data: nil)
        try validator.validate(statusCode: 204, data: nil)
        try validator.validate(statusCode: 299, data: nil)
    }

    @Test("3xx throws redirectionError")
    func redirectionRange() {
        #expect(throws: APIError.redirectionError(statusCode: 301)) {
            try validator.validate(statusCode: 301, data: nil)
        }
        #expect(throws: APIError.redirectionError(statusCode: 302)) {
            try validator.validate(statusCode: 302, data: nil)
        }
        #expect(throws: APIError.redirectionError(statusCode: 399)) {
            try validator.validate(statusCode: 399, data: nil)
        }
    }

    @Test("4xx throws clientError with data")
    func clientErrorRange() {
        let data = Data([1, 2, 3])
        #expect(throws: APIError.clientError(statusCode: 400, data: data)) {
            try validator.validate(statusCode: 400, data: data)
        }
        #expect(throws: APIError.clientError(statusCode: 404, data: nil)) {
            try validator.validate(statusCode: 404, data: nil)
        }
        #expect(throws: APIError.clientError(statusCode: 499, data: nil)) {
            try validator.validate(statusCode: 499, data: nil)
        }
    }

    @Test("5xx throws serverError with data")
    func serverErrorRange() {
        let data = "error body".data(using: .utf8)
        #expect(throws: APIError.serverError(statusCode: 500, data: data)) {
            try validator.validate(statusCode: 500, data: data)
        }
        #expect(throws: APIError.serverError(statusCode: 502, data: nil)) {
            try validator.validate(statusCode: 502, data: nil)
        }
        #expect(throws: APIError.serverError(statusCode: 599, data: nil)) {
            try validator.validate(statusCode: 599, data: nil)
        }
    }

    @Test("Unexpected status codes throw unexpectedStatusCode")
    func unexpectedStatusCode() {
        #expect(throws: APIError.unexpectedStatusCode(statusCode: 199)) {
            try validator.validate(statusCode: 199, data: nil)
        }
        #expect(throws: APIError.unexpectedStatusCode(statusCode: 600)) {
            try validator.validate(statusCode: 600, data: nil)
        }
        #expect(throws: APIError.unexpectedStatusCode(statusCode: 0)) {
            try validator.validate(statusCode: 0, data: nil)
        }
    }
}
