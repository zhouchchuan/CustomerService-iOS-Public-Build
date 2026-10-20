import XCTest
@testable import CustomerServiceApp

final class LoginURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class PersistentLoginTests: XCTestCase {
    private var store: UserDefaults!
    private var suite: String!
    private var model: ChatViewModel!

    override func setUp() async throws {
        suite = "login-tests-" + UUID().uuidString
        store = UserDefaults(suiteName: suite)!
        store.set("https://login.example.test", forKey: "server")
        store.set("old-session", forKey: "authToken")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoginURLProtocol.self]
        model = ChatViewModel(api: APIClient(session: URLSession(configuration: configuration)), defaults: store)
        // Exercise authentication without launching live sockets or permission UI.
        model.enteredBackground()
    }

    override func tearDown() async throws {
        model.logout(revoke: false)
        store.removePersistentDomain(forName: suite)
        LoginURLProtocol.handler = nil
    }

    func testOfflineStartupKeepsLogin() async {
        LoginURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await model.restore()
        XCTAssertTrue(model.loggedIn)
        XCTAssertEqual(store.string(forKey: "authToken"), "old-session")
        XCTAssertFalse(model.connected)
    }

    func testServerUnavailableKeepsLogin() async {
        LoginURLProtocol.handler = { _ in (503, Data(#"{"detail":"maintenance"}"#.utf8)) }
        await model.restore()
        XCTAssertTrue(model.loggedIn)
        XCTAssertEqual(store.string(forKey: "authToken"), "old-session")
    }

    func testUnauthorizedClearsRejectedLogin() async {
        LoginURLProtocol.handler = { _ in (401, Data(#"{"detail":"账号不可用"}"#.utf8)) }
        await model.restore()
        XCTAssertFalse(model.loggedIn)
        XCTAssertNil(store.string(forKey: "authToken"))
    }

    func testRecoveryMigratesTokenAndReloadKeepsIt() async {
        LoginURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await model.restore()
        LoginURLProtocol.handler = { request in
            if request.url!.path == "/api/auth/session" {
                return (200, Data(#"{"token":"permanent-session","user":{"id":1,"username":"agent","role":"agent","display_name":"客服"}}"#.utf8))
            }
            return (200, Data("[]".utf8))
        }
        await model.restore()
        XCTAssertEqual(model.authToken, "permanent-session")
        XCTAssertEqual(store.string(forKey: "authToken"), "permanent-session")
        let reloaded = ChatViewModel(defaults: store)
        XCTAssertTrue(reloaded.loggedIn)
        XCTAssertEqual(reloaded.authToken, "permanent-session")
        reloaded.logout(revoke: false)
    }

    func testExplicitLogoutClearsLocalLogin() {
        model.logout(revoke: false)
        XCTAssertFalse(model.loggedIn)
        XCTAssertNil(store.string(forKey: "authToken"))
        XCTAssertTrue(model.chats.isEmpty)
    }
}
