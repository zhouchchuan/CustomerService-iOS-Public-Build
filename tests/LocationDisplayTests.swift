import Foundation

@main
struct LocationDisplayTests {
    static func chat(city: Any = "清远市", region: Any = "广东省", isp: Any = "电信", name: String = "访客") throws -> ChatSession {
        let value: [String: Any] = [
            "id": 1, "token": "test", "agent_id": 1, "agent_name": "客服",
            "ip": "203.0.113.10", "user_agent": "", "visitor_name": name,
            "visitor_region": region, "visitor_city": city, "visitor_isp": isp,
            "started_at": "2026-10-05T00:00:00Z", "last_message_at": "2026-10-05T00:00:00Z",
            "unread_agent": 0, "unread_visitor": 0
        ]
        return try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: value))
    }

    static func main() throws {
        let cases: [(Any, String)] = [
            ("电信", "清远电信 203.0.113.10"),
            ("中国移动", "清远移动 203.0.113.10"),
            ("中国联通", "清远联通 203.0.113.10"),
            ("中国广电", "清远广电 203.0.113.10"),
            ("CN", "清远 203.0.113.10"),
            (" cn ", "清远 203.0.113.10"),
            (NSNull(), "清远 203.0.113.10"),
            ("0", "清远 203.0.113.10"),
            ("BT", "清远BT 203.0.113.10")
        ]
        for (isp, expected) in cases {
            let session = try chat(isp: isp)
            precondition(session.displayName == expected, session.displayName)
            precondition(session.avatarText == "清")
        }
        let noCity = try chat(city: NSNull(), isp: "联通")
        precondition(noCity.displayName == "广东联通 203.0.113.10")
        let unknown = try chat(city: NSNull(), region: NSNull(), isp: NSNull())
        precondition(unknown.displayName == "访客 203.0.113.10")
        let custom = try chat(city: NSNull(), region: NSNull(), isp: NSNull(), name: "老客户")
        precondition(custom.displayName == "老客户 203.0.113.10")
        print("Location display: 12 cases passed")
    }
}
