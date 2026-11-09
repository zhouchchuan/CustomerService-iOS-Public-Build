import XCTest
@testable import CustomerServiceApp

@MainActor
final class VisitorSourceTests: XCTestCase {
    private let sessionJSON = #"{"id":1,"token":"visitor-token","agent_id":1,"agent_name":"客服","ip":"119.135.163.149","user_agent":"Safari","visitor_name":"访客","started_at":"2026-11-09T00:00:00Z","last_message_at":"2026-11-09T00:00:00Z","unread_agent":3,"unread_visitor":0}"#

    func testOlderSessionWithoutSourceStillDecodes() throws {
        let session = try JSONDecoder().decode(ChatSession.self, from: Data(sessionJSON.utf8))
        XCTAssertNil(session.source_url)
        XCTAssertNil(session.source_quality)
        XCTAssertEqual(session.unread_agent, 3)
    }

    func testFullAddressAndUnsafeSchemes() {
        let source = "https://shop.example:9443/goods/123?sku=4&from=video#buy"
        XCTAssertEqual(SourceLink.url(source)?.absoluteString, source)
        XCTAssertEqual(SourceLink.quality(source), "page")
        XCTAssertEqual(SourceLink.quality("https://shop.example/"), "site")
        for bad in ["javascript:alert(1)", "file:///private/file", "//example.com/a", "https://user:pass@example.com/a", "https://example.com/\n"] {
            XCTAssertNil(SourceLink.url(bad))
        }
    }

    func testVisitorLookupDoesNotOpenOrMarkChatRead() async throws {
        let suite = "visitor-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://support.example", forKey: "server")
        defaults.set("staff-token", forKey: "authToken")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoginURLProtocol.self]
        let model = ChatViewModel(api: APIClient(session: URLSession(configuration: config)), defaults: defaults)
        model.enteredBackground()
        defer {
            model.logout(revoke: false)
            defaults.removePersistentDomain(forName: suite)
            LoginURLProtocol.handler = nil
        }
        var calls = 0
        let response = "{\"session\":" + sessionJSON + ",\"visits\":[]}"
        LoginURLProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.url?.path, "/api/staff/chats/visitor-token/visitor")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer staff-token")
            return (200, Data(response.utf8))
        }
        let details = try await model.visitorDetails(token: "visitor-token")
        XCTAssertEqual(details.session.unread_agent, 3)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.messages.isEmpty)
    }
}
