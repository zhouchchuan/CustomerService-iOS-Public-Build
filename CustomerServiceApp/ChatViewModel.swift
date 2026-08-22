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

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
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
            server = server.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
            connectSocket()
            requestPushPermission()
            await openPendingPushIfNeeded()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func logout() {
        stopSocket()
        authToken = ""
        me = nil
        chats = []
        selected = nil
        messages = []
        UserDefaults.standard.removeObject(forKey: "authToken")
    }

    func restore() async {
        guard loggedIn else { return }
        do {
            let user: APIUser = try await APIClient.shared.request(
                "/api/auth/me",
                baseURL: server,
                token: authToken
            )
            me = user
            await refreshChats()
            connectSocket()
            requestPushPermission()
            await openPendingPushIfNeeded()
        } catch {
            logout()
        }
    }

    func refreshChats() async {
        guard loggedIn else { return }
        do {
            let rows: [ChatSession] = try await APIClient.shared.request(
                "/api/staff/chats",
                baseURL: server,
                token: authToken
            )
            chats = rows
            if let selected, let newer = rows.first(where: { $0.token == selected.token }) {
                self.selected = newer
            }
        } catch {
            errorText = error.localizedDescription
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
            selected = response.session
            messages = response.messages
            await refreshChats()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func send(_ text: String) async {
        guard let session = selected else { return }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        do {
            let _: ChatMessage = try await APIClient.shared.request(
                "/api/staff/chats/\(session.token)/messages",
                baseURL: server,
                token: authToken,
                method: "POST",
                body: SendMessageBody(content: content, kind: "text")
            )
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

    func uploadImage(_ data: Data) async {
        guard let session = selected else { return }
        do {
            _ = try await APIClient.shared.uploadImage(
                "/api/staff/chats/\(session.token)/upload",
                baseURL: server,
                token: authToken,
                data: data
            )
        } catch {
            errorText = error.localizedDescription
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

    private func openPendingPushIfNeeded() async {
        guard let token = UserDefaults.standard.string(forKey: "pendingPushSessionToken") else { return }
        await open(token: token)
    }

    private func connectSocket() {
        stopSocket()
        guard
            let base = URL(string: server),
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return }

        components.scheme = base.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/staff"
        components.queryItems = [URLQueryItem(name: "token", value: authToken)]
        guard let url = components.url else { return }

        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        connected = true

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled, self?.socket === task else { return }
                try? await task.send(.string("ping"))
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled, socket === task {
            do {
                let message = try await task.receive()
                guard case let .string(text) = message,
                      let data = text.data(using: .utf8),
                      let event = try? JSONDecoder().decode(SocketEvent.self, from: data)
                else { continue }

                if event.type == "message" {
                    await refreshChats()
                    if event.session?.token == selected?.token,
                       let incoming = event.message,
                       !messages.contains(where: { $0.id == incoming.id }) {
                        messages.append(incoming)
                    }
                }
            } catch {
                guard socket === task else { return }
                connected = false
                scheduleReconnect()
                return
            }
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.loggedIn else { return }
            self.connectSocket()
        }
    }

    private func stopSocket() {
        reconnectTask?.cancel()
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask = nil
        receiveTask = nil
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
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
}
