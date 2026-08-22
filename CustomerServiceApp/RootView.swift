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
        .animation(.easeInOut(duration: 0.2), value: viewModel.loggedIn)
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
                    List {
                        ForEach(viewModel.chats) { chat in
                            Button {
                                Task {
                                    await viewModel.open(chat)
                                    showChat = viewModel.selected != nil
                                }
                            } label: {
                                ChatRow(chat: chat)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task {
                                        await viewModel.close(chat)
                                    }
                                } label: {
                                    Label("结束服务", systemImage: "xmark.circle.fill")
                                }
                                .disabled(viewModel.closingTokens.contains(chat.token))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
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
                showChat = token != nil
            }
        }
    }
}

private struct ChatRow: View {
    let chat: ChatSession

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.blue.gradient)
                .frame(width: 48, height: 48)
                .overlay {
                    Text(chat.avatarText)
                        .foregroundStyle(.white)
                        .bold()
                }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(chat.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(ChatDateFormatter.conversationTime(chat.last_message_at))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if chat.unread_agent > 0 {
                        Text("\(chat.unread_agent)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .frame(minWidth: 20, minHeight: 20)
                            .padding(.horizontal, 2)
                            .background(.red, in: Capsule())
                    }
                }
                Text(previewText)
                    .lineLimit(1)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private var previewText: String {
        guard let message = chat.last_message else { return "新会话" }
        switch message.kind {
        case "image": return "[图片]"
        case "video": return "[视频]"
        case "attachment_deleted": return "[附件已删除]"
        default: return message.content
        }
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
                .onAppear {
                    guard let id = viewModel.messages.last?.id else { return }
                    DispatchQueue.main.async {
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
        .background(Color(.systemGroupedBackground))
        .navigationTitle(viewModel.selected?.displayName ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let server: String

    private var isAgent: Bool { message.sentByAgent }
    private var isSystem: Bool { message.sender_type == "system" }

    private var attachmentURL: URL? {
        if let absolute = URL(string: message.content), absolute.scheme != nil {
            return absolute
        }
        guard let base = URL(string: server) else { return nil }
        return URL(string: message.content, relativeTo: base)?.absoluteURL
    }

    var body: some View {
        Group {
            if isSystem {
                VStack(spacing: 4) {
                    Text(message.content)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    Text(ChatDateFormatter.messageTime(message.created_at))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    if isAgent { Spacer(minLength: 42) }

                    if !isAgent {
                        Circle()
                            .fill(Color.orange.gradient)
                            .frame(width: 30, height: 30)
                            .overlay {
                                Text("访")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            }
                    }

                    VStack(alignment: isAgent ? .trailing : .leading, spacing: 4) {
                        bubbleBody

                        HStack(spacing: 7) {
                            Text(ChatDateFormatter.messageTime(message.created_at))
                            if isAgent {
                                Text(message.is_read == true ? "已读" : "未读")
                                    .foregroundStyle(message.is_read == true ? Color.green : Color.secondary)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }

                    if !isAgent { Spacer(minLength: 42) }
                }
            }
        }
    }

    @ViewBuilder
    private var bubbleBody: some View {
        if message.kind == "image", let url = attachmentURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView()
                    .frame(width: 100, height: 100)
            }
            .frame(maxWidth: 240, maxHeight: 260)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if message.kind == "video", let url = attachmentURL {
            Link(destination: url) {
                Label("查看视频", systemImage: "play.rectangle.fill")
                    .padding(12)
                    .frame(maxWidth: 240)
            }
            .background(isAgent ? Color.blue : Color(.secondarySystemBackground))
            .foregroundStyle(isAgent ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        } else {
            Text(message.content)
                .textSelection(.enabled)
                .padding(11)
                .background(isAgent ? Color.blue : Color(.secondarySystemBackground))
                .foregroundStyle(isAgent ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }
}

