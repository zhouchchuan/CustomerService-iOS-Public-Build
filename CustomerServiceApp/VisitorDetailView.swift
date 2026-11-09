import SwiftUI

struct VisitorDetailView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let initialSession: ChatSession
    @State private var details: VisitorDetails?
    @State private var errorText = ""
    @State private var loading = true

    private var session: ChatSession { details?.session ?? initialSession }

    var body: some View {
        List {
            Section("访客信息") {
                LabeledContent("IP 地址", value: session.ip.isEmpty ? "未知" : session.ip)
                    .textSelection(.enabled)
                LabeledContent("地域", value: session.visitor_region ?? session.visitor_city ?? "未知")
                LabeledContent("运营商", value: session.visitor_isp ?? "未知")
            }
            Section("最近一次进入客服的来源") {
                SourceAddress(value: session.source_url, kind: nil)
            }
            if loading { ProgressView("正在读取来源记录…") }
            if !errorText.isEmpty {
                Section {
                    Text(errorText).foregroundStyle(.secondary)
                    Button("重新加载") { Task { await load() } }
                }
            }
            if let details, !details.visits.isEmpty {
                Section {
                    ForEach(details.visits) { visit in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ChatDateFormatter.messageTime(visit.visited_at))
                                .font(.subheadline.bold())
                            Text("IP：\(visit.ip)").font(.caption).foregroundStyle(.secondary)
                            SourceAddress(value: visit.source_url, kind: visit.source_kind)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("访问记录 · 最近 50 次")
                } footer: {
                    Text("记录进入客服时收到的来源。浏览器未提供具体页面时，无法还原商品或播放页地址。")
                }
            }
        }
        .navigationTitle("访客详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            details = try await viewModel.visitorDetails(token: initialSession.token)
            errorText = ""
        } catch {
            errorText = "来源记录暂时无法读取，请稍后重试。"
        }
    }
}

private struct SourceAddress: View {
    let value: String?
    let kind: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = SourceLink.url(value) {
                Text(value ?? "")
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if SourceLink.quality(value) == "site" {
                    Text("仅取得站点地址，未提供具体页面")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 20) {
                    Link("打开来源", destination: url)
                    Button("复制网址") { UIPasteboard.general.string = value }
                        .buttonStyle(.borderless)
                }
                .font(.subheadline)
                if let kind {
                    Text(kind == "referrer" ? "浏览器提供" : "入口链接提供")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("未提供来源地址")
                Text("可能为直接访问，或浏览器未发送来源信息。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
