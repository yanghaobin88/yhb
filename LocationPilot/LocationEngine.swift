//
//  LocationEngine.swift
//  LocationPilot
//
//  注入引擎抽象层。
//  上层（AppState / 各个 View）只认 LocationEngine，不再关心定位到底
//  是本机注入还是走 Mac 桥接，两种实现返回同一套数据模型。
//

import Foundation

/// 注入引擎模式
enum EngineMode: String, CaseIterable, Identifiable {
    /// 本机注入：App 自己调 CLSimulationManager 改写 locationd，不需要 Mac
    case native
    /// Mac 桥接：沿用 locserver.py + pymobiledevice3 的老路子
    case remote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native: return "本机注入"
        case .remote: return "Mac 桥接"
        }
    }

    var detail: String {
        switch self {
        case .native: return "不连电脑，App 直接改写本机定位（需 TrollStore 安装才有权限）"
        case .remote: return "连 Mac 上的 locserver，由电脑下发给本机"
        }
    }

    var iconName: String {
        switch self {
        case .native: return "iphone.gen3"
        case .remote: return "desktopcomputer"
        }
    }
}

/// 统一的定位引擎接口。
/// 方法签名刻意与 LocServerClient 完全一致，这样 Mac 桥接实现可以直接复用。
protocol LocationEngine {

    // 服务与设备
    func health() async throws -> HealthData
    func status() async throws -> StatusData
    func devices() async throws -> DevicesData
    func selectDevice(udid: String) async throws -> SelectDeviceData
    func inspect() async throws -> InspectData
    func mountDeveloperImage() async throws -> MountData

    // 定位
    func setLocation(lat: Double, lng: Double, name: String?, udid: String?) async throws -> SetLocationData
    func clearLocation() async throws -> ClearData
    func session() async throws -> SessionState

    // 搜索与预设
    func search(query text: String, limit: Int) async throws -> SearchData
    func presets() async throws -> PresetsData

    // 路线
    func planRoute(start: GeoPoint,
                   end: GeoPoint,
                   mode: TravelMode,
                   pace: PlaybackPace,
                   alternatives: Int) async throws -> RoutePlanData
    func playRoute(points: [GeoPoint],
                   mode: TravelMode,
                   pace: PlaybackPace,
                   name: String?) async throws -> RoutePlayData
    func playRoute(start: GeoPoint,
                   end: GeoPoint,
                   mode: TravelMode,
                   pace: PlaybackPace) async throws -> RoutePlayData
    func stopRoute() async throws -> ClearData
}

// MARK: - 便捷调用

extension LocationEngine {
    /// 只要最优一条备选时的便捷调用
    func planRoute(start: GeoPoint,
                   end: GeoPoint,
                   mode: TravelMode,
                   pace: PlaybackPace) async throws -> RoutePlanData {
        try await planRoute(start: start, end: end, mode: mode, pace: pace, alternatives: 3)
    }
}

// MARK: - Mac 桥接实现

/// LocServerClient 本身就实现了全部签名，直接让它满足协议，
/// 老的 HTTP 通道一行代码都不用改。
extension LocServerClient: LocationEngine {}

// MARK: - 本机注入可用性判定

/// 判断本机注入在当前系统上是否可能生效。
///
/// 依据：本机注入要写进 locationd，必须带 `com.apple.locationd.simulation` 权限，
/// 而该权限只能靠 TrollStore 的 fake sign 注入；TrollStore 支持区间是
/// iOS 14.0b2–16.6.1 / 16.7 RC / 17.0，即主版本 14…17。
/// 超出区间时 objc 调用仍会「成功」（runtime 不校验权限），但写入被 locationd 静默丢弃，
/// 表现为：调用返回成功、定位毫无变化。此时唯一可行路径是 Mac 桥接。
enum InjectorCompat {

    /// TrollStore 支持的主版本区间
    static let supportedMajorRange: ClosedRange<Int> = 14...17

    static var majorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// 去掉 "Version " 前缀的系统版本串，用于文案
    static var versionText: String {
        var text = ProcessInfo.processInfo.operatingSystemVersionString
        if let range = text.range(of: "Version ") {
            text = String(text[range.upperBound...])
        }
        if let range = text.range(of: " (") {
            text = String(text[..<range.lowerBound])
        }
        return text
    }

    /// 当前系统能否尝试本机注入
    static var isNativeCapable: Bool {
        supportedMajorRange.contains(majorVersion)
    }

    /// 本机注入不可用时的原因；可用时为 nil
    static var blockReason: String? {
        guard !isNativeCapable else { return nil }
        if majorVersion > supportedMajorRange.upperBound {
            return "iOS \(versionText) 超出 TrollStore 支持区间（14.0–17.0）。"
                + "本机注入依赖的 com.apple.locationd.simulation 权限无法注入，locationd 会静默丢弃写入——"
                + "注入调用即使返回成功，定位也不会改变。已自动改用 Mac 桥接。"
        }
        return "iOS \(versionText) 低于 TrollStore 支持下限（14.0），本机注入不可用，已自动改用 Mac 桥接。"
    }

    /// 一句话结论，用于日志与自检首行
    static var statusLine: String {
        if isNativeCapable {
            return "iOS \(versionText)：在 TrollStore 支持区间内（14.0–17.0），本机注入可尝试。"
        }
        return "iOS \(versionText)：超出 TrollStore 支持区间（14.0–17.0），本机注入不可能生效。"
    }

    /// 本机注入被拒时给用户的下一步
    static var advice: String {
        "改用 Mac 桥接（iOS 17 及以上不需要 root、不需要 Xcode、不需要 TrollStore）："
            + "① Mac 上双击「启动 locserver.command」；② 数据线连上 iPhone 并点「信任此电脑」；"
            + "③ iPhone 设置 › 隐私与安全性 › 开发者模式 打开并重启；"
            + "④ 在本页「设置」里填 Mac 的局域网 IP 与端口。"
    }
}
