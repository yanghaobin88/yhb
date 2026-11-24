//
//  AppState.swift
//  LocationPilot
//
//  全局状态：服务器配置、设备与会话状态、地图选点、收藏、日志。
//  所有网络调用都集中在这里，界面只负责展示和触发。
//

import Foundation
import SwiftUI
import CoreLocation

@MainActor
final class AppState: ObservableObject {

    /// 与 Mac 服务的连接状态
    enum Connection: Equatable {
        case unknown
        case online
        case offline(String)

        var text: String {
            switch self {
            case .unknown: return "未连接"
            case .online: return "已连接"
            case .offline(let reason): return reason
            }
        }

        var isOnline: Bool {
            if case .online = self { return true }
            return false
        }
    }

    // MARK: - 持久化键

    private enum Keys {
        static let host = "lp.server.host"
        static let port = "lp.server.port"
        static let favorites = "lp.favorites"
        static let engineMode = "lp.engine.mode"
    }

    // MARK: - 注入引擎

    /// 定位注入走哪条路：本机注入（默认，不需要电脑）或 Mac 桥接
    @Published var engineMode: EngineMode {
        didSet {
            UserDefaults.standard.set(engineMode.rawValue, forKey: Keys.engineMode)
            log("注入模式已切换为：\(engineMode.label)", level: .info)
        }
    }

    // MARK: - 服务器配置

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Keys.host) }
    }

    @Published var port: String {
        didSet { UserDefaults.standard.set(port, forKey: Keys.port) }
    }

    // MARK: - 服务端状态

    @Published private(set) var connection: Connection = .unknown
    @Published private(set) var health: HealthData?
    @Published private(set) var status: StatusData?
    @Published private(set) var session: SessionState?
    @Published private(set) var inspect: InspectData?
    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var selectedDevice: DeviceInfo?
    @Published private(set) var presets: [PresetPlace] = []

    // MARK: - 本地收藏

    @Published private(set) var favorites: [FavoritePlace] = []

    // MARK: - 地图与路线

    /// 地图当前选中的点（点地图或搜地名都会更新它）
    @Published var pickedPoint: GeoPoint?
    /// 路线起点
    @Published var routeStart: GeoPoint?
    /// 路线终点
    @Published var routeEnd: GeoPoint?
    /// 规划出的路线
    @Published private(set) var routes: [RouteOption] = []

    // MARK: - 交互状态

    @Published private(set) var busy = false
    @Published private(set) var busyText = ""
    @Published private(set) var lastError: String?
    @Published private(set) var lastSuccess: String?
    @Published private(set) var logs: [LogEntry] = []

    // MARK: - 初始化

    init() {
        let defaults = UserDefaults.standard
        let savedHost = defaults.string(forKey: Keys.host) ?? ""
        let savedPort = defaults.string(forKey: Keys.port) ?? "8765"
        self.host = savedHost
        self.port = savedPort
        self.engineMode = EngineMode(rawValue: defaults.string(forKey: Keys.engineMode) ?? "") ?? .native
        loadFavorites()
        log("App 已启动，服务器地址：\(baseAddressText)", level: .info)
    }

    // MARK: - 派生属性

    /// 传给客户端的 BaseURL；地址不合法时为 nil
    var baseURL: URL? {
        LocServerClient.makeURL(host: host, port: port)
    }

    var baseAddressText: String {
        switch engineMode {
        case .native: return "本机注入（无需 Mac）"
        case .remote: return LocServerClient.displayAddress(host: host, port: port)
        }
    }

    var hasServerConfigured: Bool {
        switch engineMode {
        case .native: return true
        case .remote: return baseURL != nil
        }
    }

    /// 当前设备是否就绪（有设备、通道支持、开发者模式没被明确关掉）
    var deviceReady: Bool {
        guard let device = selectedDevice else { return false }
        if device.channel == "unsupported" { return false }
        if let mode = inspect?.devMode, mode.contains("未开启") { return false }
        return true
    }

    /// 顶部状态条的一句话摘要
    var statusSummary: String {
        if let device = selectedDevice {
            let version = device.ios ?? "未知版本"
            let channel = device.channelLabel ?? device.connection ?? "未知连接"
            return "\(device.displayName) · iOS \(version) · \(channel)"
        }
        if engineMode == .native {
            return "本机注入已就绪（不需要电脑）"
        }
        switch connection {
        case .online: return "服务已连接，但未检测到 iPhone"
        case .offline(let reason): return reason
        case .unknown: return "请先在设置中填写 Mac 服务器地址"
        }
    }

    var sessionText: String {
        session?.stateText ?? "暂无会话信息"
    }

    // MARK: - 客户端

    private func makeEngine() throws -> any LocationEngine {
        switch engineMode {
        case .native:
            return NativeEngine()
        case .remote:
            guard let url = baseURL else {
                throw LocServerError("服务器地址不合法，请到「设置」填写 Mac 的局域网 IP 与端口，或切回「本机注入」。")
            }
            return LocServerClient(baseURL: url)
        }
    }

    // MARK: - 日志

    func log(_ text: String, level: LogEntry.Level = .info) {
        let entry = LogEntry(level: level, time: Date(), text: text)
        logs.insert(entry, at: 0)
        if logs.count > 200 {
            logs.removeLast(logs.count - 200)
        }
    }

    func clearLogs() {
        logs.removeAll()
        lastError = nil
        lastSuccess = nil
    }

    func clearBanners() {
        lastError = nil
        lastSuccess = nil
    }

    private func markError(_ error: Error) {
        let message = (error as? LocServerError)?.message ?? error.localizedDescription
        lastError = message
        lastSuccess = nil
        log(message, level: .failure)
    }

    private func markSuccess(_ message: String) {
        lastSuccess = message
        lastError = nil
        log(message, level: .success)
    }

    // MARK: - 服务连通性

    /// 测试连接：先查健康状态，再拉一次整体状态
    @discardableResult
    func testConnection() async -> Bool {
        busy = true
        busyText = engineMode == .native ? "正在检查本机注入接口…" : "正在连接 Mac 服务…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let result = try await engine.health()
            health = result
            connection = .online
            log("\(result.service) \(result.version)：\(result.python)", level: .success)
            if !result.dependenciesReady {
                if engineMode == .native {
                    log("注入接口不可用：\(result.python)。请确认本 App 是用 TrollStore 安装，且保留了 com.apple.locationd.simulation 权限。",
                        level: .failure)
                } else {
                    log("注意：服务端依赖未就绪，注入会失败。请在 Mac 上双击「启动.command」完成安装。",
                        level: .failure)
                }
            }
            await loadStatus(using: engine, silently: true)
            return true
        } catch {
            health = nil
            connection = .offline((error as? LocServerError)?.message ?? error.localizedDescription)
            markError(error)
            return false
        }
    }

    /// 刷新整体状态（设备、会话、提示）
    @discardableResult
    func refreshStatus() async -> Bool {
        do {
            let engine = try makeEngine()
            return await loadStatus(using: engine, silently: false)
        } catch {
            markError(error)
            return false
        }
    }

    private func loadStatus(using engine: any LocationEngine, silently: Bool) async -> Bool {
        do {
            let data = try await engine.status()
            status = data
            session = data.session
            devices = data.devices ?? []
            selectedDevice = data.device
            connection = .online
            if !silently {
                if let device = data.device {
                    log("设备状态：\(device.displayName) iOS \(device.ios ?? "?")，\(data.session?.stateText ?? "无会话")",
                        level: .info)
                } else {
                    log("服务在线，但没有检测到 iPhone。请检查数据线与「信任此电脑」。", level: .failure)
                }
            }
            return true
        } catch {
            if !silently { markError(error) }
            connection = .offline((error as? LocServerError)?.message ?? error.localizedDescription)
            return false
        }
    }

    /// 只刷新会话状态（轻量，用于注入后回显）
    func refreshSession() async {
        do {
            let engine = try makeEngine()
            session = try await engine.session()
        } catch {
            // 会话查询失败不打扰用户，只记日志
            log("查询会话状态失败：\((error as? LocServerError)?.message ?? error.localizedDescription)",
                level: .info)
        }
    }

    // MARK: - 设备

    func loadDevices() async {
        busy = true
        busyText = "正在读取设备列表…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let data = try await engine.devices()
            devices = data.devices ?? []
            selectedDevice = data.device
            connection = .online
            if let device = data.device {
                markSuccess("检测到设备：\(device.displayName)")
            } else {
                log("没有检测到设备。", level: .failure)
            }
        } catch {
            markError(error)
        }
    }

    func selectDevice(_ device: DeviceInfo) async {
        busy = true
        busyText = "正在切换设备…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let data = try await engine.selectDevice(udid: device.udid)
            selectedDevice = data.device ?? device
            markSuccess(data.message ?? "已切换目标设备")
            await refreshStatus()
        } catch {
            markError(error)
        }
    }

    // MARK: - 前置条件

    func runInspect() async {
        busy = true
        busyText = "正在诊断前置条件（首次较慢）…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let data = try await engine.inspect()
            inspect = data
            markSuccess("诊断完成：\(data.channelLabel ?? "通道未知")")
        } catch {
            markError(error)
        }
    }

    func mountDeveloperImage() async {
        busy = true
        busyText = "正在挂载开发者镜像（首次需下载，可能数分钟）…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let data = try await engine.mountDeveloperImage()
            markSuccess(data.message ?? "开发者镜像已就绪")
            await runInspect()
        } catch {
            markError(error)
        }
    }

    // MARK: - 预设地点

    func loadPresets() async {
        do {
            let engine = try makeEngine()
            presets = try await engine.presets().presets
        } catch {
            log("读取内置预设失败：\((error as? LocServerError)?.message ?? error.localizedDescription)",
                level: .info)
        }
    }

    // MARK: - 注入定位

    /// 注入坐标；成功返回结果，失败返回 nil 并把原因写进 lastError
    @discardableResult
    func inject(point: GeoPoint, name: String? = nil) async -> SetLocationData? {
        guard point.isValid else {
            markError(LocServerError("坐标超出合法范围：纬度 ±90，经度 ±180。"))
            return nil
        }
        busy = true
        busyText = "正在注入定位（\(point.text)）…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let data = try await engine.setLocation(lat: point.lat,
                                                    lng: point.lng,
                                                    name: name,
                                                    udid: selectedDevice?.udid)
            markSuccess(data.message)
            pickedPoint = point
            await refreshSession()
            return data
        } catch {
            markError(error)
            return nil
        }
    }

    /// 清除定位，恢复真实 GPS
    @discardableResult
    func clearLocation() async -> Bool {
        busy = true
        busyText = "正在清除模拟定位…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let data = try await engine.clearLocation()
            markSuccess(data.message)
            await refreshSession()
            return data.cleared
        } catch {
            markError(error)
            return false
        }
    }

    // MARK: - 地名搜索

    func search(_ text: String, limit: Int = 8) async -> [PlaceResult] {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        busy = true
        busyText = "正在搜索「\(keyword)」…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let data = try await engine.search(query: keyword, limit: limit)
            let results = data.results ?? []
            if results.isEmpty {
                log("「\(keyword)」没有搜到结果，换个说法或加上城市名试试。", level: .info)
            } else {
                log("「\(keyword)」搜到 \(results.count) 个地点。", level: .info)
            }
            return results
        } catch {
            markError(error)
            return []
        }
    }

    // MARK: - 路线

    func planRoute(mode: TravelMode, pace: PlaybackPace) async {
        guard let start = routeStart, let end = routeEnd else {
            markError(LocServerError("请先设置起点和终点（可在地图页点选，或手动输入坐标）。"))
            return
        }
        busy = true
        busyText = "正在规划路线…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let data = try await engine.planRoute(start: start, end: end, mode: mode, pace: pace)
            routes = data.routes
            if routes.isEmpty {
                markError(LocServerError("没有规划出可用路线，请调整起终点后重试。"))
            } else {
                let note = (data.note?.isEmpty == false) ? "（\(data.note!)）" : ""
                markSuccess("规划完成：\(data.source)\(note)，共 \(routes.count) 条备选路线。")
            }
        } catch {
            markError(error)
        }
    }

    func playRoute(_ option: RouteOption, mode: TravelMode, pace: PlaybackPace) async {
        busy = true
        busyText = "正在启动路线回放…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let data = try await engine.playRoute(points: option.points,
                                                  mode: mode,
                                                  pace: pace,
                                                  name: option.summary.isEmpty ? "路线回放" : option.summary)
            markSuccess(data.message)
            await refreshSession()
        } catch {
            markError(error)
        }
    }

    /// 不规划直接按起终点回放（服务端会自己走一遍路网规划）
    func playRouteDirect(mode: TravelMode, pace: PlaybackPace) async {
        guard let start = routeStart, let end = routeEnd else {
            markError(LocServerError("请先设置起点和终点。"))
            return
        }
        busy = true
        busyText = "正在启动路线回放…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let data = try await engine.playRoute(start: start, end: end, mode: mode, pace: pace)
            markSuccess(data.message)
            await refreshSession()
        } catch {
            markError(error)
        }
    }

    func stopRoute() async {
        busy = true
        busyText = "正在停止回放…"
        defer {
            busy = false
            busyText = ""
        }
        do {
            let engine = try makeEngine()
            let data = try await engine.stopRoute()
            markSuccess(data.message)
            await refreshSession()
        } catch {
            markError(error)
        }
    }

    // MARK: - 收藏

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: Keys.favorites) else {
            favorites = []
            return
        }
        do {
            favorites = try JSONDecoder().decode([FavoritePlace].self, from: data)
        } catch {
            favorites = []
        }
    }

    private func saveFavorites() {
        do {
            let data = try JSONEncoder().encode(favorites)
            UserDefaults.standard.set(data, forKey: Keys.favorites)
        } catch {
            log("保存收藏失败：\(error.localizedDescription)", level: .failure)
        }
    }

    @discardableResult
    func addFavorite(name: String, point: GeoPoint) -> FavoritePlace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? point.text : trimmed
        let favorite = FavoritePlace(name: title, point: point)
        favorites.insert(favorite, at: 0)
        saveFavorites()
        markSuccess("已收藏「\(title)」")
        return favorite
    }

    func removeFavorite(_ favorite: FavoritePlace) {
        favorites.removeAll { $0.id == favorite.id }
        saveFavorites()
        log("已删除收藏「\(favorite.name)」", level: .info)
    }

    // MARK: - 启动引导

    /// 首屏自动跑一次：有地址就连接，没地址就提示去设置页
    func bootstrap() async {
        if engineMode == .native {
            let device = NativeEngine.localDevice()
            selectedDevice = device
            devices = [device]
            log("本机注入模式启动：不连电脑，直接改写本机定位。", level: .info)
            await testConnection()
            await loadPresets()
        } else if hasServerConfigured {
            await testConnection()
            await loadPresets()
        } else {
            log("还没有配置服务器地址。请在「设置」页填写 Mac 的局域网 IP，例如 192.168.1.5:8765。",
                level: .info)
        }
    }
}
