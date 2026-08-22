import PhotosUI
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        Group {
            if viewModel.loggedIn {
                MainView()
            } else {
                LoginView()
            }
        }
        .animation(.2, value: viewModel.loggedIn)
    }
}

private struct LoginView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Spacer(minLength: 50)
                    Image(systemName: "message.badge.filled.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(.blue.gradient)
                    Text("客服工作台")
                        .font(.largeTitle.bold())
                    Text("实时接收网页客户消息")
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        TextField("服务器，例如 https://kefu.example.com", text: $viewModel.server)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textFieldStyle(.roundedBorder)
                        TextField("客服账号", text: $viewModel.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .textFieldStyle(.roundedBorder)
                        SecureField("密码", text: $viewModel.password)
                            .textContentType(.password)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.top, 12)

                    if !viewModel.errorText.isEmpty {
                        Text(viewModel.errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await viewModel.login() }
                    } label: {
                        Text("登录")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.server.isEmpty || viewModel.username.isEmpty || viewModel.password.isEmpty)

                    Text("登录成功后 App 会申请系统通知权限。前台消息由 WebSocket 实时接收，后台与锁屏通知由 APNs 接收。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding(24)
            }
        }
    }
}

private struct MainView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var showChat = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.chats.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("暂无会话")
                            .font(.headline)
                        Text("收到客户消息后会显示在这里")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.chats) { chat in
                        Button {
                            Task {
                                await viewModel.open(chat)
                                showChat = true
                            }
                        } label: {
                            ChatRow(chat: chat)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await viewModel.refreshChats()
                    }
                }
            }
            .navigationTitle(viewModel.me?.display_name ?? "客服")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(viewModel.connected ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(viewModel.connected ? "实时在线" : "正在重连")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("开启通知") {
                            viewModel.requestPushPermission()
                        }
                        Button("退出登录", role: .destructive) {
                            viewModel.logout()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(isPresented: $showChat) {
                ChatView()
            }
            .onChange(of: viewModel.selected?.token) { token in
                if token != nil {
                    showChat = true
                }
            }
        }
    }
}

private struct ChatRow: View {
    let chat: ChatSession

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.blue.gradient)
                .frame(width: 44, height: 44)
                .overlay {
                    Text(String(chat.visitor_name.prefix(1)))
                        .foregroundStyle(.white)
                        .bold()
                }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(chat.visitor_name)
                        .font(.headline)
                    Spacer()
                    if chat.unread_agent > 0 {
                        Text("\(chat.unread_agent)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.red, in: Circle())
                    }
                }
                Text(chat.last_message?.content ?? chat.ip)
                    .lineLimit(1)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("IP \(chat.ip)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct ChatView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message, server: viewModel.server)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _ in
                    guard let id = viewModel.messages.last?.id else { return }
                    withAnimation {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.title3)
                }
                .onChange(of: photoItem) { item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            await viewModel.uploadImage(data)
                        }
                        photoItem = nil
                    }
                }

                TextField("回复客户…", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)

                Button {
                    let value = text
                    text = ""
                    Task { await viewModel.send(value) }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(viewModel.selected?.visitor_name ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let server: String

    private var isAgent: Bool { message.sender_type == "agent" }

    private var attachmentURL: URL? {
        if let absolute = URL(string: message.content), absolute.scheme != nil {
            return absolute
        }
        guard let base = URL(string: server) else { return nil }
        return URL(string: message.content, relativeTo: base)?.absoluteURL
    }

    var body: some View {
        HStack {
            if isAgent { Spacer() }
            Group {
                if message.kind == "image", let url = attachmentURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView()
                            .frame(width: 100, height: 100)
                    }
                    .frame(maxWidth: 240, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    Text(message.content)
                        .padding(11)
                        .background(isAgent ? Color.blue : Color(.secondarySystemBackground))
                        .foregroundStyle(isAgent ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                }
            }
            .frame(maxWidth: 280, alignment: isAgent ? .trailing : .leading)
            if !isAgent { Spacer() }
        }
    }
}
