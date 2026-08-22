import Foundation

enum APIError: LocalizedError {
    case invalidServer
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            return "服务器地址不正确"
        case let .http(_, message):
            return message
        }
    }
}

actor APIClient {
    static let shared = APIClient()

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func request<T: Decodable>(
        _ path: String,
        baseURL: String,
        token: String? = nil,
        method: String = "GET",
        body: Encodable? = nil
    ) async throws -> T {
        guard let url = URL(string: normalized(baseURL) + path) else {
            throw APIError.invalidServer
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    func uploadImage(_ path: String, baseURL: String, token: String, data: Data) async throws -> ChatMessage {
        guard let url = URL(string: normalized(baseURL) + path) else {
            throw APIError.invalidServer
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: responseData)
        return try decoder.decode(ChatMessage.self, from: responseData)
    }

    private func normalized(_ baseURL: String) -> String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(-1, "服务器没有返回有效响应")
        }
        guard 200..<300 ~= http.statusCode else {
            let object = try? JSONSerialization.jsonObject(with: data)
            let detail = (object as? [String: Any])?["detail"]
            let message = detail as? String ?? "请求失败（HTTP \(http.statusCode)）"
            throw APIError.http(http.statusCode, message)
        }
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeValue = wrapped.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}
