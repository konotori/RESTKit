import Foundation
import Testing
@testable import RESTKit

@Suite("HTTPMethod Tests")
struct HTTPMethodTests {

    @Test("Raw values match HTTP spec")
    func rawValues() {
        #expect(HTTPMethod.get.rawValue == "GET")
        #expect(HTTPMethod.post.rawValue == "POST")
        #expect(HTTPMethod.put.rawValue == "PUT")
        #expect(HTTPMethod.delete.rawValue == "DELETE")
        #expect(HTTPMethod.patch.rawValue == "PATCH")
        #expect(HTTPMethod.head.rawValue == "HEAD")
        #expect(HTTPMethod.options.rawValue == "OPTIONS")
    }

    @Test("CaseIterable includes all methods")
    func caseIterable() {
        let all = HTTPMethod.allCases
        #expect(all.contains(.get))
        #expect(all.contains(.post))
        #expect(all.contains(.put))
        #expect(all.contains(.delete))
        #expect(all.contains(.patch))
        #expect(all.contains(.head))
        #expect(all.contains(.options))
        #expect(all.count == 7)
    }

    @Test("Idempotent methods contain get put delete head options")
    func idempotentMethods() {
        let idempotent = HTTPMethod.idempotentMethods
        #expect(idempotent.contains(.get))
        #expect(idempotent.contains(.put))
        #expect(idempotent.contains(.delete))
        #expect(idempotent.contains(.head))
        #expect(idempotent.contains(.options))
        #expect(idempotent.contains(.post) == false)
        #expect(idempotent.contains(.patch) == false)
    }
}
