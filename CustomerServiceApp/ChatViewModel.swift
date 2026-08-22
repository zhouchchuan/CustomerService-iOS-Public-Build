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
    @Published private(set) var closingTokens: Set<String> = []

    private var socket: URLSessionWebSocketTask?
    private var socketSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
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
        do {
            server = normalizedServer(server)
            let body = LoginBody(username: username, password: password)
            let response: LoginResponse = try await APIClient.shared.request(
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
            UserDefaults.standard.set(server, forKey: "server")
            UserDefaults.standard.set(username, forKey: "username")
            UserDefaults.standard.set(authToken, forKey: "authToken")

            await refreshChats()
            startRealtime()
            requestPushPermission()
            await openPendingPushIfNeeded()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func logout() {
        stopRealtime()
        authToken = ""
        me = nil
        chats = []
        selected = nil
        messages = []
        closingTokens = []
        UserDefaults.standard.removeObject(forKey: "authToken")
    }

    func restore() async {
        guard loggedIn else { return }
        do {
            server = normalizedServer(server)
            let user: APIUser = try await APIClient.shared.request(
                "/api/auth/me",
                baseURL: server,
                token: authToken
            )
            me = user
            await refreshChats()
            startRealtime()
            requestPushPermission()
            await openPendingPushIfNeeded()
        } catch {
            logout()
        }
    }

    func becameActive() async {
        guard loggedIn else { return }
        connectSocket(force: socket == nil)
        await syncNow()
    }

    func refreshChats(silent: Bool = false) async {
        guard loggedIn else { return }
        do {
            let rows: [ChatSession] = try await APIClient.shared.request(
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
            UserDefaults.standard.removeObject(forKey: "pendingPushSessionToken")
            return
        }

        await refreshChats()
        if let session = chats.first(where: { $0.token == token }) {
            await open(session)
            UserDefaults.standard.removeObject(forKey: "pendingPushSessionToken")
        }
    }

    func open(_ session: ChatSession) async {
        selected = session
        do {
            let response: ChatMessagesResponse = try await APIClient.shared.request(
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
            let sent: ChatMessage = try await APIClient.shared.request(
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
            let sent = try await APIClient.shared.uploadImage(
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
            let _: CloseChatResponse = try await APIClient.shared.request(
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
            let _: OKResponse = try await APIClient.shared.request(
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
            let _: ReadChatResponse = try await APIClient.shared.request(
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
            let response: ChatMessagesResponse = try await APIClient.shared.request(
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
        guard loggedIn else { return }
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
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, self?.socket === task else { return }
                do {
                    try await task.send(.string("ping"))
                } catch {
                    return
                }
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled, socket === task {
            do {
                let received = try await task.receive()
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
            self.connectSocket()
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
        guard let token = UserDefaults.standard.string(forKey: "pendingPushSessionToken") else { return }
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

