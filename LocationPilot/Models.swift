//
//  Models.swift
//  LocationPilot
//
//  与服务端 locserver.py 一一对应的数据模型。
//  所有经纬度均为 WGS84（与 GPS、Apple 地图一致）。
//

import Foundation
import CoreLocation

// MARK: - 统一响应外壳

/// locserver 所有接口的统一外层结构：{"ok":true,"time":"...","data":{...}}
/// 失败时为：{"ok":false,"time":"...","error":"...","detail":"..."}
struct APIEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let time: String?
    let data: T?
    let error: String?
    let detail: String?
}

/// 接口调用失败时抛出的错误，message 可以直接展示给用户
struct LocServerError: LocalizedError {
    let message: String
    let detail: String?

    init(_ message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }

    var errorDescription: String? { message }
}

// MARK: - 坐标

/// 一个经纬度点（WGS84）
struct GeoPoint: Codable, Hashable, Identifiable {
    let lat: Double
    let lng: Double

    var id: String { String(format: "%.6f,%.6f", lat, lng) }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
    var text: String { String(format: "%.6f, %.6f", lat, lng) }

    init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.lat = coordinate.latitude
        self.lng = coordinate.longitude
    }

    /// 坐标是否落在合法范围内
    var isValid: Bool {
        (-90.0...90.0).contains(lat) && (-180.0...180.0).contains(lng)
    }
}

// MARK: - 健康检查

struct HealthData: Decodable {
    let service: String
    let version: String
    let port: Int
    let host: String
    let startedAt: String
    let uptime: Double
    let python: String
    let dependencies: Dependencies

    struct Dependencies: Decodable {
        let pymobiledevice3: Bool
        let geosearch: Bool
    }

    /// 依赖是否全部就绪（未就绪时注入一定失败）
    var dependenciesReady: Bool {
        dependencies.pymobiledevice3 && dependencies.geosearch
    }
}

// MARK: - 设备

struct DeviceInfo: Decodable, Hashable, Identifiable {
    let udid: String
    let name: String?
    let model: String?
    let ios: String?
    let build: String?
    let connection: String?
    let channel: String?
    let channelLabel: String?
    let selected: Bool?
    let label: String?

    var id: String { udid }
    var displayName: String { (name?.isEmpty == false) ? name! : "iPhone" }
    var channelText: String {
        if let label = channelLabel, !label.isEmpty { return label }
        switch channel {
        case "dvt": return "DVT 通道（iOS 17 及以上）"
        case "classic": return "经典通道（iOS 11-16，需挂载镜像）"
        case "unsupported": return "不支持注入（iOS 11 以下）"
        default: return "未知通道"
        }
    }
    /// 只有经典通道必须挂载开发者镜像
    var needDeveloperImage: Bool { channel == "classic" }
}

/// /api/devices 的返回体
struct DevicesData: Decodable {
    let device: DeviceInfo?
    let devices: [DeviceInfo]?
}

/// /api/device/select 的返回体
struct SelectDeviceData: Decodable {
    let device: DeviceInfo?
    let message: String?
}

// MARK: - 会话状态

struct SessionState: Decodable {
    let alive: Bool
    let healthy: Bool
    let pid: String?
    let stateText: String
    let logPath: String?
}

// MARK: - 整体状态

struct StatusData: Decodable {
    let service: String?
    let version: String?
    let port: Int?
    let host: String?
    let lan: [String]?
    let device: DeviceInfo?
    let devices: [DeviceInfo]?
    let session: SessionState?
    let hints: [String]?
}

// MARK: - 前置条件诊断

struct InspectData: Decodable {
    let device: DeviceInfo?
    let channel: String?
    let channelLabel: String?
    let devModeSupported: Bool?
    let devMode: String?
    let ddiMounted: Bool?
    let ddiState: String?
    let hints: [String]?
}

// MARK: - 镜像挂载

struct MountData: Decodable {
    let mounted: Bool
    let message: String?
    let output: String?
}

// MARK: - 注入 / 清除

struct SetLocationData: Decodable {
    let lat: Double
    let lng: Double
    let name: String?
    let udid: String?
    let deviceName: String?
    let channel: String?
    let pid: String?
    let message: String
}

struct ClearData: Decodable {
    let cleared: Bool
    let udid: String?
    let message: String
}

// MARK: - 地名搜索

struct PlaceResult: Decodable, Identifiable {
    let name: String
    let addr: String?
    let lat: Double
    let lng: Double
    let source: String?
    let precise: Bool?

    var id: String { "\(name)-\(lat)-\(lng)" }
    var point: GeoPoint { GeoPoint(lat: lat, lng: lng) }
    var sourceText: String { source ?? "未知来源" }
}

struct SearchData: Decodable {
    let query: String?
    let count: Int?
    let results: [PlaceResult]?
}

// MARK: - 预设地点

struct PresetPlace: Decodable, Identifiable, Hashable {
    let name: String
    let lat: Double
    let lng: Double

    var id: String { "\(name)-\(lat)-\(lng)" }
    var point: GeoPoint { GeoPoint(lat: lat, lng: lng) }
}

struct PresetsData: Decodable {
    let presets: [PresetPlace]
}

// MARK: - 本地收藏（存在 iPhone 本机，不上传）

struct FavoritePlace: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var lat: Double
    var lng: Double
    var createdAt: Date

    init(id: UUID = UUID(), name: String, point: GeoPoint, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.lat = point.lat
        self.lng = point.lng
        self.createdAt = createdAt
    }

    var point: GeoPoint { GeoPoint(lat: lat, lng: lng) }
}

// MARK: - 路线

/// 出行方式，rawValue 与服务端 mode 字段一致
enum TravelMode: String, CaseIterable, Identifiable {
    case walking
    case cycling
    case driving

    var id: String { rawValue }

    var label: String {
        switch self {
        case .walking: return "步行"
        case .cycling: return "骑行"
        case .driving: return "驾车"
        }
    }

    var iconName: String {
        switch self {
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        }
    }
}

/// 回放节奏，rawValue 与服务端 smoothing 字段一致
enum PlaybackPace: String, CaseIterable, Identifiable {
    case smooth
    case standard
    case fast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smooth: return "顺滑"
        case .standard: return "标准"
        case .fast: return "快速验证"
        }
    }

    var detail: String {
        switch self {
        case .smooth: return "最接近真实速度，蓝点连续移动，耗时较长"
        case .standard: return "约 5 分钟走完，基本看不出跳跃"
        case .fast: return "1 分钟走完，只看功能是否生效"
        }
    }
}

struct RouteOption: Decodable, Identifiable {
    let index: Int
    let label: String
    let distance: Double
    let duration: Double
    let summary: String
    let points: [GeoPoint]
    let pointsCount: Int
    let interval: Double
    let totalSeconds: Double

    var id: Int { index }
}

struct RoutePlanData: Decodable {
    let mode: String
    let modeLabel: String
    let smoothing: String
    let smoothingLabel: String
    let source: String
    let note: String?
    let routes: [RouteOption]
}

struct RoutePlayData: Decodable {
    let gpx: String
    let pointsCount: Int
    let interval: Double
    let totalSeconds: Double
    let distance: Double
    let smoothing: String
    let smoothingLabel: String
    let pid: String?
    let message: String
}

// MARK: - 日志

/// 界面底部「运行日志」里的一条记录
struct LogEntry: Identifiable, Hashable {
    enum Level: String {
        case info
        case success
        case failure

        var symbol: String {
            switch self {
            case .info: return "info.circle"
            case .success: return "checkmark.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            }
        }
    }

    let id = UUID()
    let level: Level
    let time: Date
    let text: String

    var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: time)
    }
}
