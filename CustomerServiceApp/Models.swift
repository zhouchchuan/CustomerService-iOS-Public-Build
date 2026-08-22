import Foundation

struct APIUser: Codable {
    let id: Int
    let username: String
    let role: String
    let display_name: String
    let slug: String?
}

struct LoginResponse: Codable {
    let token: String
    let user: APIUser
}

struct ChatSession: Codable, Identifiable, Hashable {
    let id: Int
    let token: String
    let agent_id: Int
    let agent_name: String
    let ip: String
    let user_agent: String
    let visitor_name: String
    let visitor_region: String?
    let visitor_city: String?
    let visitor_isp: String?
    let started_at: String
    let last_message_at: String
    let unread_agent: Int
    let unread_visitor: Int
    let last_message: ChatMessage?
    let is_closed: Bool?
    let closed_at: String?
    let source_url: String?

    var displayName: String {
        let area = Self.cleanLocation(visitor_city) ?? Self.cleanLocation(visitor_region)
        let carrier = Self.cleanCarrier(visitor_isp)
        let prefix = [area, carrier].compactMap { $0 }.joined()
        if !prefix.isEmpty {
            return "\(prefix) \(ip)"
        }

        let original = visitor_name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !original.isEmpty, original != "访客" {
            return "\(original) \(ip)"
        }
        return ip.isEmpty ? "访客" : "访客 \(ip)"
    }

    var avatarText: String {
        let source = Self.cleanLocation(visitor_city)
            ?? Self.cleanLocation(visitor_region)
            ?? visitor_name
        return String(source.prefix(1))
    }

    private static func cleanLocation(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text != "0",
              text.lowercased() != "null"
        else { return nil }

        for prefix in ["中国-", "中国 ", "中国"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        for suffix in ["特别行政区", "壮族自治区", "回族自治区", "维吾尔自治区", "自治区", "省", "市"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }
        return text.isEmpty ? nil : text
    }

    private static func cleanCarrier(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text != "0",
              text.lowercased() != "null"
        else { return nil }
        text = text
            .replacingOccurrences(of: "中国电信", with: "电信")
            .replacingOccurrences(of: "中国移动", with: "移动")
            .replacingOccurrences(of: "中国联通", with: "联通")
            .replacingOccurrences(of: "中国广电", with: "广电")
        return text
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    let id: Int
    let session_id: Int
    let sender_type: String
    let sender_id: Int?
    let kind: String
    let content: String
    let created_at: String
    var is_read: Bool?
    var read_at: String?

    var sentByAgent: Bool {
        sender_type == "agent" || sender_type == "system"
    }

    func markingRead(at readAt: String?) -> ChatMessage {
        var copy = self
        copy.is_read = true
        copy.read_at = readAt
        return copy
    }
}

struct ChatMessagesResponse: Codable {
    let session: ChatSession
    let messages: [ChatMessage]
}

struct SendMessageBody: Codable {
    let content: String
    let kind: String
}

struct DeviceTokenBody: Codable {
    let token: String
    let environment: String
}

struct CloseChatResponse: Codable {
    let ok: Bool
    let session: ChatSession
}

struct ReadChatResponse: Codable {
    let ok: Bool
    let through_message_id: Int
    let read_at: String?
}

enum ChatDateFormatter {
    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    static func messageTime(_ value: String) -> String {
        guard let date = date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "M月d日 HH:mm"
        } else {
            formatter.dateFormat = "yyyy年M月d日 HH:mm"
        }
        return formatter.string(from: date)
    }

    static func conversationTime(_ value: String) -> String {
        guard let date = date(from: value) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "M/d"
        }
        return formatter.string(from: date)
    }
}

