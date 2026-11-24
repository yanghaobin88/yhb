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
