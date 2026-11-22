//
//  APIClient.swift
//  LocationPilot
//
//  与 Mac 端 locserver.py 通信的 HTTP 客户端。
//  只依赖 Foundation，不引入任何第三方库。
//

import Foundation

/// 本地桥接服务客户端
struct LocServerClient {

    /// 服务器根地址，形如 http://192.168.1.5:8765
    let baseURL: URL

    /// 默认超时。个别慢接口会在方法内部单独放宽。
    var defaultTimeout: TimeInterval = 45

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    // MARK: - 地址解析

    /// 把用户在设置页填写的地址拼成合法的 URL。
    /// 允许的输入：`192.168.1.5`、`192.168.1.5:8765`、`http://192.168.1.5:8765`。
    static func makeURL(host rawHost: String, port rawPort: String) -> URL? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }

        let lower = host.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            host = "http://" + host
        }

        guard var comps = URLComponents(string: host) else { return nil }
        guard let hostName = comps.host, !hostName.isEmpty else { return nil }

        let portText = rawPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if comps.port == nil, let p = Int(portText), p > 0, p < 65536 {
            comps.port = p
        }

        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }

    /// 供界面展示的地址文本
    static func displayAddress(host: String, port: String) -> String {
        if let url = makeURL(host: host, port: port) {
            return url.absoluteString
        }
        return "未配置"
    }

    // MARK: - 底层请求

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 1800
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private func send<T: Decodable>(path: String,
                                    method: String = "GET",
                                    payload: [String: Any]? = nil,
                                    query: [URLQueryItem] = [],
                                    timeout: TimeInterval? = nil) async throws -> T {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appendingPathComponent(relative)

        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        guard let finalURL = comps?.url else {
            throw LocServerError("服务器地址不合法，请在设置页重新填写。")
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? defaultTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let payload {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } else if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await LocServerClient.session.data(for: request)
        } catch {
            throw LocServerError(LocServerClient.friendlyMessage(for: error))
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoder = JSONDecoder()

        // 服务端任何状态码都会带统一外壳，先按外壳解一次
        if let envelope = try? decoder.decode(APIEnvelope<T>.self, from: data) {
            if envelope.ok, let value = envelope.data {
                return value
            }
            let message = envelope.error ?? "服务端返回失败（HTTP \(statusCode)）"
            throw LocServerError(message, detail: envelope.detail)
        }

        // 外壳都解不出来，说明对方不是 locserver
        let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
        throw LocServerError("服务返回了无法识别的内容（HTTP \(statusCode)），请确认地址指向 locserver。",
                             detail: snippet)
    }

    /// 把底层网络错误翻译成人话
    static func friendlyMessage(for error: Error) -> String {
        if let apiError = error as? LocServerError {
            return apiError.message
        }
        guard let urlError = error as? URLError else {
            return "网络请求失败：\(error.localizedDescription)"
        }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return "连不上 Mac 服务：请确认 locserver 已启动，且手机与 Mac 在同一 Wi-Fi。"
        case .timedOut:
            return "请求超时：Mac 可能正在挂载镜像或下载数据，请稍后重试。"
        case .notConnectedToInternet:
            return "手机没有网络连接，请先连上 Wi-Fi。"
        case .appTransportSecurityRequiresSecureConnection:
            return "系统拦截了 HTTP 明文请求，请检查 Info.plist 中的明文访问许可。"
        default:
            return "网络请求失败：\(urlError.localizedDescription)"
        }
    }

    // MARK: - 接口：服务与设备

    func health() async throws -> HealthData {
        try await send(path: "api/health", timeout: 20)
    }

    func status() async throws -> StatusData {
        try await send(path: "api/status", timeout: 50)
    }

    func devices() async throws -> DevicesData {
        try await send(path: "api/devices", timeout: 50)
    }

    func selectDevice(udid: String) async throws -> SelectDeviceData {
        try await send(path: "api/device/select",
                       method: "POST",
                       payload: ["udid": udid],
                       timeout: 60)
    }

    func inspect() async throws -> InspectData {
        try await send(path: "api/device/inspect", timeout: 180)
    }

    func mountDeveloperImage() async throws -> MountData {
        try await send(path: "api/device/mount", method: "POST", timeout: 1800)
    }

    // MARK: - 接口：定位

    func setLocation(lat: Double, lng: Double, name: String?, udid: String? = nil) async throws -> SetLocationData {
        var payload: [String: Any] = ["lat": lat, "lng": lng]
        if let name, !name.isEmpty { payload["name"] = name }
        if let udid, !udid.isEmpty { payload["udid"] = udid }
        return try await send(path: "api/location/set", method: "POST", payload: payload, timeout: 240)
    }

    func clearLocation() async throws -> ClearData {
        try await send(path: "api/location/clear", method: "POST", timeout: 150)
    }

    func session() async throws -> SessionState {
        try await send(path: "api/location/session", timeout: 50)
    }

    // MARK: - 接口：搜索与预设

    func search(query text: String, limit: Int = 8) async throws -> SearchData {
        try await send(path: "api/search",
                       query: [URLQueryItem(name: "q", value: text),
                               URLQueryItem(name: "limit", value: String(limit))],
                       timeout: 70)
    }

    func presets() async throws -> PresetsData {
        try await send(path: "api/presets", timeout: 30)
    }

    // MARK: - 接口：路线

    func planRoute(start: GeoPoint,
                   end: GeoPoint,
                   mode: TravelMode,
                   pace: PlaybackPace,
                   alternatives: Int = 3) async throws -> RoutePlanData {
        let payload: [String: Any] = [
            "startLat": start.lat,
            "startLng": start.lng,
            "endLat": end.lat,
            "endLng": end.lng,
            "mode": mode.rawValue,
            "smoothing": pace.rawValue,
            "alternatives": alternatives
        ]
        return try await send(path: "api/route/plan", method: "POST", payload: payload, timeout: 90)
    }

    func playRoute(points: [GeoPoint],
                   mode: TravelMode,
                   pace: PlaybackPace,
                   name: String?) async throws -> RoutePlayData {
        let rawPoints: [[String: Any]] = points.map { ["lat": $0.lat, "lng": $0.lng] }
        var payload: [String: Any] = [
            "points": rawPoints,
            "mode": mode.rawValue,
            "smoothing": pace.rawValue
        ]
        if let name, !name.isEmpty { payload["name"] = name }
        return try await send(path: "api/route/play", method: "POST", payload: payload, timeout: 300)
    }

    func playRoute(start: GeoPoint,
                   end: GeoPoint,
                   mode: TravelMode,
                   pace: PlaybackPace) async throws -> RoutePlayData {
        let payload: [String: Any] = [
            "startLat": start.lat,
            "startLng": start.lng,
            "endLat": end.lat,
            "endLng": end.lng,
            "mode": mode.rawValue,
            "smoothing": pace.rawValue
        ]
        return try await send(path: "api/route/play", method: "POST", payload: payload, timeout: 300)
    }

    func stopRoute() async throws -> ClearData {
        try await send(path: "api/route/stop", method: "POST", timeout: 150)
    }
}
