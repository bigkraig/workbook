import Foundation

enum APIError: LocalizedError {
    /// The request was bounced to the Sign in with Apple gate.
    case notSignedIn
    /// Signed in, but this Apple ID isn't on the server's allowlist.
    case forbidden
    case server(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to continue."
        case .forbidden: return "This Apple ID isn't allowed to use Workbook."
        case .server(let code): return "The server returned an error (\(code))."
        case .decoding: return "The server sent something unexpected."
        }
    }
}

/// Client for the Workbook REST API (`/v1/…`).
struct API {
    let settings: AppSettings

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: settings.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    /// Fetch raw bytes. A response that isn't from our host (the gate
    /// redirected to Apple) or is HTML where data was expected means the
    /// session is missing or expired.
    func data(_ path: String, query: [URLQueryItem] = [], post body: Data? = nil) async throws -> (Data, String) {
        var request = URLRequest(url: url(path, query: query))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.decoding }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let bounced = http.url?.host() != settings.baseURL.host()
        if bounced || http.statusCode == 401 {
            await MainActor.run { settings.needsLogin = true }
            throw APIError.notSignedIn
        }
        if http.statusCode == 403 { throw APIError.forbidden }
        guard (200..<300).contains(http.statusCode) else { throw APIError.server(http.statusCode) }
        return (data, contentType)
    }

    private func json<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = [], post body: Data? = nil) async throws -> T {
        let (data, _) = try await data(path, query: query, post: body)
        do { return try JSONDecoder().decode(type, from: data) } catch { throw APIError.decoding }
    }

    // MARK: - Endpoints

    func vehicles() async throws -> [Vehicle] {
        try await json([Vehicle].self, "/v1/vehicles")
    }

    func vehicleImagePath(_ vehicle: Vehicle) -> String {
        "/v1/vehicles/\(vehicle.year)/\(vehicle.vehicle)/illustrations"
    }

    func rootNode(_ vehicle: Vehicle) async throws -> TreeNode {
        try await json(TreeNode.self, "/v1/vehicle_component_tree/\(vehicle.year)/\(vehicle.vehicle)")
    }

    func node(_ id: Int) async throws -> TreeNode {
        try await json(TreeNode.self, "/v1/vehicle_component_tree/nodes/\(id)")
    }

    func documents(node id: Int) async throws -> [DocumentSummary] {
        try await json([DocumentSummary].self, "/v1/vehicle_component_tree/nodes/\(id)/documents")
    }

    func search(_ vehicle: Vehicle, query: String) async throws -> [DocumentSummary] {
        try await json([DocumentSummary].self, "/v1/vehicles/\(vehicle.year)/\(vehicle.vehicle)/documents/search",
                       query: [URLQueryItem(name: "q", value: query)])
    }

    /// Documents a cross-reference points at (by labor-operation number).
    func resolve(_ ref: NestedRef, vehicle: Vehicle) async throws -> [DocumentSummary] {
        let body = try JSONSerialization.data(withJSONObject: [
            "year": vehicle.year, "vehicle": vehicle.vehicle,
            "aposNumber": ref.aposNumber, "documentType": "RL",
        ])
        return try await json([DocumentSummary].self, "/v1/workshop_literature/search", post: body)
    }

    func document(_ hkapId: String) async throws -> WorkshopDocument {
        let (data, _) = try await data("/v1/workshop_literature/\(hkapId)")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decoding
        }
        return WorkshopDocument(json: object)
    }

    func translations() async throws -> [String: String] {
        try await json([String: String].self, "/v1/content/translations")
    }

    func tool(_ number: String, vehicle: Vehicle) async throws -> ToolData {
        let id = Data(number.utf8).base64EncodedString()
        return try await json(ToolData.self, "/v1/content/tool_data/\(vehicle.year)/\(vehicle.vehicle)/\(id)")
    }

    func toolImagePath(_ number: String) -> String {
        "/v1/content/tool_image/\(Data(number.utf8).base64EncodedString())"
    }

    func figurePath(_ key: String) -> String {
        "/v1/content/workshop_image/\(key)/large"
    }

    func mediaPath(_ id: String) -> String {
        "/v1/content/media/\(id)"
    }
}

/// In-memory cache for illustrations, tool photos and PDFs, keyed by API path.
actor MediaStore {
    static let shared = MediaStore()
    private var cache: [String: (Data, String)] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<(Data, String), Error>] = [:]

    func load(_ path: String, api: API) async throws -> (data: Data, contentType: String) {
        if let hit = cache[path] { return hit }
        if let task = inFlight[path] { return try await task.value }
        let task = Task { try await api.data(path) }
        inFlight[path] = task
        defer { inFlight[path] = nil }
        let value = try await task.value
        cache[path] = value
        order.append(path)
        // Keep the most recent ~60 items; workshop SVGs run 200 KB+ each.
        if order.count > 60 { cache[order.removeFirst()] = nil }
        return value
    }

    func clear() {
        cache.removeAll()
        order.removeAll()
    }
}
