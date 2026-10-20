import Combine
import Foundation
import UIKit
import UserNotifications

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var server = UserDefaults.standard.string(forKey: "server") ?? "https://your-domain.example"
    @Published var username = UserDefaults.standard.string(forKey: "username") ?? "xiaomei"
    @Published var password = ""
    @Published var authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""
    @Published var me: APIUser?
    @Published var chats: [ChatSession] = []
    @Published var selected: ChatSession?
    @Published var messages: [ChatMessage] = []
    @Published var errorText = ""
    @Published var connected = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var closingTokens: Set<String> = []

    private let api: APIClient
    private let defaults: UserDefaults
    private var restoring = false
    private var restoreTask: Task<Void, Never>?
    private var lastSocketActivity = Date()
    private var isForeground = true
    private var socket: URLSessionWebSocketTask?
    private var socketSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(api: APIClient = .shared, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        self.server = defaults.string(forKey: "server") ?? "https://your-domain.example"
        self.username = defaults.string(forKey: "username") ?? "xiaomei"
        self.authToken = defaults.string(forKey: "authToken") ?? ""
        NotificationCenter.default.publisher(for: .apnsToken)
            .compactMap { $0.object as? String }
            .sink { [weak self] token in
                Task { await self?.registerDevice(token) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openChat)
            .compactMap { $0.object as? String }
            .sink { [weak self] token in
                Task { await self?.open(token: token) }
            }
            .store(in: &cancellables)
    }

    var loggedIn: Bool { !authToken.isEmpty }

    func login() async {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            server = normalizedServer(server)
            let body = LoginBody(username: username, password: password)
            let response: LoginResponse = try await request(
                "/api/auth/login",
                baseURL: server,
                method: "POST",
                body: body
            )
            guard response.user.role == "agent" || response.user.role == "admin" else {
                throw APIError.http(403, "该账号不是客服账号")
            }

            authToken = response.token
            me = response.user
            password = ""
            errorText = ""
            defaults.set(server, forKey: "server")
            defaults.set(username, forKey: "username")
            defaults.set(authToken, forKey: "authToken")

            await refreshChats()
            startRealtime()
            requestPushPermission()
            await openPendingPushIfNeeded()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func logout(revoke: Bool = true) {
        let oldToken = authToken
        let oldServer = server
        stopRealtime()
        restoreTask?.cancel()
        restoreTask = nil
        authToken = ""
        me = nil
        chats = []
        selected = nil
        messages = []
        closingTokens = []
        defaults.removeObject(forKey: "authToken")
        defaults.removeObject(forKey: "pendingPushSessionToken")
        if revoke && !oldToken.isEmpty {
            Task {
                let _: OKResponse? = try? await api.request(
                    "/api/auth/logout", baseURL: oldServer, token: oldToken, method: "POST"
                )
            }
        }
    }

    func restore() async {
        guard loggedIn, !restoring else { return }
        restoring = true
        let initialToken = authToken
        defer { restoring = false }
        do {
            server = normalizedServer(server)
            let response: LoginResponse
            do {
                response = try await request(
                    "/api/auth/session", baseURL: server, token: initialToken, method: "POST"
                )
            } catch APIError.http(404, _) {
                // Allow the app to be installed before the server upgrade.
                let user: APIUser = try await request(
                    "/api/auth/me", baseURL: server, token: initialToken
                )
                response = LoginResponse(token: initialToken, user: user)
            }
            guard authToken == initialToken else { return }
            guard ["agent", "admin"].contains(response.user.role) else {
                logout(revoke: false)
                errorText = "该账号不是客服账号"
                return
            }
            authToken = response.token
            defaults.set(authToken, forKey: "authToken")
            me = response.user
            errorText = ""
            restoreTask?.cancel()
            restoreTask = nil
            await refreshChats()
            guard loggedIn else { return }
            startRealtime()
            if isForeground {
                requestPushPermission()
                await openPendingPushIfNeeded()
            }
        } catch {
            guard authToken == initialToken else { return }
            if let error = error as? APIError, error.requiresLogin {
                logout(revoke: false)
                errorText = error.localizedDescription
            } else {
                connected = false
                errorText = "网络暂不可用，登录已保留，正在自动重连"
                scheduleRestore()
            }
        }
    }

    private func scheduleRestore() {
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.loggedIn, self.isForeground else { return }
            self.restoreTask = nil
            await self.restore()
        }
    }

    func becameActive() async {
        isForeground = true
        guard loggedIn else { return }
        // A socket may still look open after iOS suspended the application.
        cancelSocket()
        await restore()
    }

    func enteredBackground() {
        isForeground = false
        stopRealtime()
        restoreTask?.cancel()
        restoreTask = nil
    }

    private func request<T: Decodable>(
        _ path: String, baseURL: String, token: String? = nil,
        method: String = "GET", body: Encodable? = nil
    ) async throws -> T {
        do {
            let response: T = try await api.request(path, baseURL: baseURL, token: token, method: method, body: body)
            if let token, token != authToken { throw CancellationError() }
            return response
        } catch {
            if let token, token == authToken,
               let apiError = error as? APIError, apiError.requiresLogin {
                logout(revoke: false)
                errorText = apiError.localizedDescription
            }
            throw error
        }
    }

    func refreshChats(silent: Bool = false) async {
        guard loggedIn else { return }
        do {
            let rows: [ChatSession] = try await request(
                "/api/staff/chats",
                baseURL: server,
                token: authToken
            )
            chats = sortedChats(rows.filter { $0.is_closed != true })
            if let selected {
                self.selected = chats.first(where: { $0.token == selected.token }) ?? self.selected
            }
        } catch {
            if !silent {
                errorText = error.localizedDescription
            }
        }
    }

    func open(token: String) async {
        if let session = chats.first(where: { $0.token == token }) {
            await open(session)
            defaults.removeObject(forKey: "pendingPushSessionToken")
            return
        }

        await refreshChats()
        if let session = chats.first(where: { $0.token == token }) {
            await open(session)
            defaults.removeObject(forKey: "pendingPushSessionToken")
        }
    }

    func open(_ session: ChatSession) async {
        selected = session
        do {
            let response: ChatMessagesResponse = try await request(
                "/api/staff/chats/\(session.token)/messages",
                baseURL: server,
                token: authToken
            )
            guard selected?.token == session.token else { return }
            selected = response.session
            messages = response.messages.sorted { $0.id < $1.id }
            upsertSession(response.session)
            await markRead(session.token, refreshList: true)
        } catch {
            errorText = error.localizedDescription
        }
    }

    func send(_ text: String) async {
        guard let session = selected else { return }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        do {
            let sent: ChatMessage = try await request(
                "/api/staff/chats/\(session.token)/messages",
                baseURL: server,
                token: authToken,
                method: "POST",
                body: SendMessageBody(content: content, kind: "text")
            )
            appendOrReplace(sent)
            Task { [weak self] in
                await self?.refreshChats(silent: true)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func uploadImage(_ data: Data) async {
        guard let session = selected else { return }
        do {
            let sent = try await api.uploadImage(
                "/api/staff/chats/\(session.token)/upload",
                baseURL: server,
                token: authToken,
                data: data
            )
            appendOrReplace(sent)
            Task { [weak self] in
                await self?.refreshChats(silent: true)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func close(_ session: ChatSession) async {
        guard !closingTokens.contains(session.token) else { return }
        closingTokens.insert(session.token)
        defer { closingTokens.remove(session.token) }

        do {
            let _: CloseChatResponse = try await request(
                "/api/staff/chats/\(session.token)/close",
                baseURL: server,
                token: authToken,
                method: "POST"
            )
            removeSession(token: session.token)
        } catch {
            errorText = error.localizedDescription
        }
    }

    func registerDevice(_ deviceToken: String) async {
        guard loggedIn, me?.role == "agent" else { return }
        do {
            let _: OKResponse = try await request(
                "/api/staff/device-token",
                baseURL: server,
                token: authToken,
                method: "POST",
                body: DeviceTokenBody(token: deviceToken, environment: "production")
            )
        } catch {
            print("Device token registration failed: \(error.localizedDescription)")
        }
    }

    func requestPushPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private func markRead(_ token: String, refreshList: Bool) async {
        guard loggedIn else { return }
        do {
            let _: ReadChatResponse = try await request(
                "/api/staff/chats/\(token)/read",
                baseURL: server,
                token: authToken,
                method: "POST"
            )
            if refreshList {
                await refreshChats(silent: true)
            }
        } catch {
            // 下次实时事件或轮询会再次补偿已读状态。
        }
    }

    private func refreshSelectedMessages(silent: Bool = true) async {
        guard let token = selected?.token, loggedIn else { return }
        do {
            let response: ChatMessagesResponse = try await request(
                "/api/staff/chats/\(token)/messages",
                baseURL: server,
                token: authToken
            )
            guard selected?.token == token else { return }
            selected = response.session
            messages = response.messages.sorted { $0.id < $1.id }
            upsertSession(response.session)
        } catch {
            if !silent {
                errorText = error.localizedDescription
            }
        }
    }

    private func syncNow() async {
        await refreshChats(silent: true)
        if selected != nil {
            await refreshSelectedMessages()
        }
    }

    private func startRealtime() {
        guard loggedIn, isForeground else { return }
        stopRealtime()
        connectSocket()
        startSyncLoop()
    }

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self, self.loggedIn else { return }
                tick += 1

                if self.selected != nil {
                    await self.refreshSelectedMessages()
                }
                if self.selected == nil || tick.isMultiple(of: 2) {
                    await self.refreshChats(silent: true)
                }
                if self.socket == nil {
                    self.connectSocket()
                }
            }
        }
    }

    private func connectSocket(force: Bool = false) {
        guard loggedIn, isForeground, me != nil else { return }
        if socket != nil, !force { return }
        if force {
            cancelSocket()
        }
        guard
            let base = URL(string: server),
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return }

        components.scheme = base.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/staff"
        components.queryItems = [URLQueryItem(name: "token", value: authToken)]
        guard let url = components.url else { return }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        socketSession = session
        socket = task
        connected = false
        lastSocketActivity = Date()
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, self?.socket === task else { return }
                guard let self else { return }
                if Date().timeIntervalSince(self.lastSocketActivity) > 60 {
                    self.cancelSocket()
                    self.scheduleReconnect()
                    return
                }
                do {
                    try await task.send(.string("ping"))
                } catch {
                    self.cancelSocket()
                    self.scheduleReconnect()
                    return
                }
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled, socket === task {
            do {
                let received = try await task.receive()
                guard socket === task else { return }
                lastSocketActivity = Date()
                let text: String
                switch received {
                case let .string(value):
                    text = value
                case let .data(data):
                    guard let value = String(data: data, encoding: .utf8) else { continue }
                    text = value
                @unknown default:
                    continue
                }

                guard let data = text.data(using: .utf8),
                      let event = try? JSONDecoder().decode(SocketEvent.self, from: data)
                else { continue }
                handle(event)
            } catch {
                guard socket === task else { return }
                socket = nil
                socketSession?.invalidateAndCancel()
                socketSession = nil
                heartbeatTask?.cancel()
                heartbeatTask = nil
                connected = false
                scheduleReconnect()
                return
            }
        }
    }

    private func handle(_ event: SocketEvent) {
        switch event.type {
        case "connected", "pong":
            connected = true

        case "message":
            connected = true
            if let session = event.session {
                upsertSession(session)
            }
            let token = event.session?.token ?? event.session_token
            if token == selected?.token, let incoming = event.message {
                appendOrReplace(incoming)
                if incoming.sender_type == "visitor", let token {
                    Task { [weak self] in
                        await self?.markRead(token, refreshList: true)
                    }
                }
            }

        case "messages_read":
            guard event.reader == "visitor" else { return }
            let throughID = event.through_message_id ?? 0
            messages = messages.map { message in
                guard message.sentByAgent, message.id <= throughID else { return message }
                return message.markingRead(at: event.read_at)
            }

        case "session_reopened":
            if let session = event.session {
                upsertSession(session)
            }

        case "session_closed":
            let token = event.session?.token ?? event.session_token
            if let token {
                removeSession(token: token)
            }

        case "attachment_deleted":
            let token = event.session?.token ?? event.session_token
            if token == selected?.token {
                Task { [weak self] in
                    await self?.refreshSelectedMessages(silent: true)
                }
            }

        default:
            break
        }
    }

    private func appendOrReplace(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
            messages.sort { $0.id < $1.id }
        }
    }

    private func upsertSession(_ session: ChatSession) {
        if session.is_closed == true {
            removeSession(token: session.token)
            return
        }
        if let index = chats.firstIndex(where: { $0.token == session.token }) {
            chats[index] = session
        } else {
            chats.append(session)
        }
        chats = sortedChats(chats)
        if selected?.token == session.token {
            selected = session
        }
    }

    private func removeSession(token: String) {
        chats.removeAll { $0.token == token }
        if selected?.token == token {
            selected = nil
            messages = []
        }
    }

    private func sortedChats(_ rows: [ChatSession]) -> [ChatSession] {
        rows.sorted { lhs, rhs in
            let left = ChatDateFormatter.date(from: lhs.last_message_at) ?? .distantPast
            let right = ChatDateFormatter.date(from: rhs.last_message_at) ?? .distantPast
            if left == right { return lhs.id > rhs.id }
            return left > right
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, let self, self.loggedIn, self.socket == nil else { return }
            self.reconnectTask = nil
            await self.restore()
        }
    }

    private func cancelSocket() {
        reconnectTask?.cancel()
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask = nil
        receiveTask = nil
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketSession?.invalidateAndCancel()
        socketSession = nil
        connected = false
    }

    private func stopRealtime() {
        syncTask?.cancel()
        syncTask = nil
        cancelSocket()
    }

    private func openPendingPushIfNeeded() async {
        guard let token = defaults.string(forKey: "pendingPushSessionToken") else { return }
        await open(token: token)
    }

    private func normalizedServer(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private struct LoginBody: Codable {
    let username: String
    let password: String
}

private struct OKResponse: Codable {
    let ok: Bool
}

private struct SocketEvent: Codable {
    let type: String
    let message: ChatMessage?
    let session: ChatSession?
    let session_token: String?
    let reader: String?
    let through_message_id: Int?
    let read_at: String?
    let by: String?
}

