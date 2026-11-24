//
//  NativeEngine.swift
//  LocationPilot
//
//  本机注入引擎：完全替代 Mac 端 locserver.py。
//  定位注入走 NativeInjector（私有 CLSimulationManager），
//  地名搜索走 MKLocalSearch，路线规划走 MKDirections，
//  路线回放由 App 自己的定时器逐点注入，不再需要电脑。
//
//  返回的数据模型与 locserver 完全一致，所以界面层零改动。
//

import Foundation
import MapKit
import CoreLocation
import UIKit

// MARK: - 本机注入引擎

struct NativeEngine: LocationEngine {

    // MARK: 服务与设备

    func health() async throws -> HealthData {
        let injector = await NativeInjector.shared
        let ready = await injector.available
        let report = await injector.probeReport
        return HealthData(service: "LocationPilot Native",
                          version: "1.0",
                          port: 0,
                          host: "本机",
                          startedAt: Self.startTimeText,
                          uptime: Date().timeIntervalSince(Self.launchedAt),
                          python: report,
                          dependencies: HealthData.Dependencies(pymobiledevice3: ready,
                                                                geosearch: true))
    }

    func status() async throws -> StatusData {
        let device = Self.localDevice()
        return StatusData(service: "LocationPilot Native",
                          version: "1.0",
                          port: nil,
                          host: "本机",
                          lan: nil,
                          device: device,
                          devices: [device],
                          session: await currentSession(),
                          hints: await hints())
    }

    func devices() async throws -> DevicesData {
        let device = Self.localDevice()
        return DevicesData(device: device, devices: [device])
    }

    func selectDevice(udid: String) async throws -> SelectDeviceData {
        SelectDeviceData(device: Self.localDevice(),
                         message: "本机注入模式只作用于当前这台 iPhone")
    }

    func inspect() async throws -> InspectData {
        let injector = await NativeInjector.shared
        let ready = await injector.available
        let report = await injector.probeReport
        let activeName = await injector.activeName
        let activePoint = await injector.activePoint

        var hints: [String] = []

        if ready {
            hints.append("注入接口：\(report)")
            hints.append("已持有 com.apple.locationd.simulation 权限（TrollStore 安装时注入的 entitlements 生效）")
        } else {
            hints.append("注入接口不可用：\(report)")
            hints.append("确认是用 TrollStore 安装的 ipa；用爱思 / AltStore 等普通签名安装时该接口会静默失效。")
        }

        // 真采样验证：只有系统真的吐出新坐标，才算注入成功
        if ready {
            if let sampled = await LocationProbe.shared.sample(timeout: 3) {
                let actual = GeoPoint(sampled.coordinate)
                if let activePoint {
                    let distance = Self.distance(from: activePoint, to: actual)
                    if distance < 2000 {
                        hints.append(String(format: "注入验证通过：系统回报 %@，与注入点相差 %.0f 米。",
                                            actual.text, distance))
                    } else {
                        hints.append(String(format: "注入未生效：系统回报 %@，注入点是 %@（相差 %.0f 米）。权限缺失时就会这样。",
                                            actual.text, activePoint.text, distance))
                    }
                } else {
                    hints.append("当前是真实定位：\(actual.text)（还没有注入过坐标）")
                }
            } else {
                hints.append("定位采样失败：请检查「设置 - 隐私与安全性 - 定位服务」里本 App 是否已授权。")
            }
        }

        return InspectData(device: Self.localDevice(),
                           channel: "native",
                           channelLabel: "本机注入（CLSimulationManager）",
                           devModeSupported: true,
                           devMode: "无需（不依赖开发者模式）",
                           ddiMounted: true,
                           ddiState: "无需（不依赖开发者镜像）",
                           hints: hints)
    }

    func mountDeveloperImage() async throws -> MountData {
        MountData(mounted: true,
                  message: "本机注入不需要开发者镜像",
                  output: nil)
    }

    // MARK: 定位

    func setLocation(lat: Double, lng: Double, name: String?, udid: String?) async throws -> SetLocationData {
        _ = udid   // 本机注入只作用于这台 iPhone，忽略设备号
        let injector = await NativeInjector.shared
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let outcome = await injector.start(coordinate, accuracy: 25, name: name)

        guard outcome.ok else {
            throw LocServerError("本机注入失败：\(outcome.detail ?? "未知原因")")
        }

        let device = Self.localDevice()
        let title = (name?.isEmpty == false) ? name! : String(format: "%.6f, %.6f", lat, lng)
        return SetLocationData(lat: lat,
                               lng: lng,
                               name: name,
                               udid: device.udid,
                               deviceName: device.name,
                               channel: "native",
                               pid: nil,
                               message: "已注入本机定位：\(title)")
    }

    func clearLocation() async throws -> ClearData {
        let injector = await NativeInjector.shared
        let outcome = await injector.stop()
        let device = Self.localDevice()
        return ClearData(cleared: outcome.ok,
                         udid: device.udid,
                         message: outcome.ok
                            ? "已停止模拟，定位恢复为真实位置"
                            : "已清除注入记录（\(outcome.detail ?? "需重启定位服务才彻底恢复")）")
    }

    func session() async throws -> SessionState {
        await currentSession()
    }

    // MARK: 搜索与预设

    func search(query text: String, limit: Int = 8) async throws -> SearchData {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            return SearchData(query: text, count: 0, results: [])
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = keyword
        request.resultTypes = [.address, .pointOfInterest]

        do {
            let response = try await MKLocalSearch(request: request).start()
            let results: [PlaceResult] = response.mapItems.prefix(max(1, limit)).compactMap { item in
                let coordinate = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                let title = item.name ?? item.placemark.name ?? keyword
                let address = item.placemark.title ?? ""
                return PlaceResult(name: title,
                                   addr: address,
                                   lat: coordinate.latitude,
                                   lng: coordinate.longitude,
                                   source: "Apple 地图",
                                   precise: true)
            }
            return SearchData(query: keyword, count: results.count, results: results)
        } catch {
            throw LocServerError("地名搜索失败：\(error.localizedDescription)")
        }
    }

    func presets() async throws -> PresetsData {
        PresetsData(presets: Self.builtinPresets)
    }

    // MARK: 路线

    func planRoute(start: GeoPoint,
                   end: GeoPoint,
                   mode: TravelMode,
                   pace: PlaybackPace,
                   alternatives: Int) async throws -> RoutePlanData {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.coordinate))
        request.transportType = Self.transportType(for: mode)
        request.requestsAlternateRoutes = alternatives > 1

        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch {
            throw LocServerError("Apple 地图没有规划出路线：请把起终点换到有道路的地方再试。")
        }

        let picked = response.routes.prefix(max(1, alternatives))
        var options: [RouteOption] = []
        for (index, route) in picked.enumerated() {
            let points = Self.sample(points: route.polyline)
            guard points.count > 1 else { continue }
            let distance = route.distance
            let totalSeconds = Self.totalSeconds(pace: pace, distance: distance, nativeDuration: route.expectedTravelTime)
            let interval = totalSeconds / Double(points.count - 1)
            options.append(RouteOption(index: index,
                                       label: "路线 \(index + 1)",
                                       distance: distance,
                                       duration: route.expectedTravelTime,
                                       summary: route.name.isEmpty ? "\(Int(distance)) 米" : route.name,
                                       points: points,
                                       pointsCount: points.count,
                                       interval: interval,
                                       totalSeconds: totalSeconds))
        }

        guard !options.isEmpty else {
            throw LocServerError("路线数据为空，请调整起终点。")
        }

        return RoutePlanData(mode: mode.rawValue,
                             modeLabel: mode.label,
                             smoothing: pace.rawValue,
                             smoothingLabel: pace.label,
                             source: "Apple 地图",
                             note: "本机规划（不经过 Mac）",
                             routes: options)
    }

    func playRoute(points: [GeoPoint],
                   mode: TravelMode,
                   pace: PlaybackPace,
                   name: String?) async throws -> RoutePlayData {
        guard points.count > 1 else {
            throw LocServerError("路线点太少，无法回放。")
        }
        guard await NativeInjector.shared.available else {
            throw LocServerError("本机注入接口不可用，请用 TrollStore 重新安装后再试。")
        }

        let distance = Self.distance(of: points)
        let totalSeconds = Self.totalSeconds(pace: pace, distance: distance, nativeDuration: nil)
        let interval = max(0.05, totalSeconds / Double(points.count - 1))

        await RoutePlayer.shared.start(points: points, interval: interval, name: name ?? "路线回放")

        return RoutePlayData(gpx: "",
                             pointsCount: points.count,
                             interval: interval,
                             totalSeconds: interval * Double(points.count - 1),
                             distance: distance,
                             smoothing: pace.rawValue,
                             smoothingLabel: pace.label,
                             pid: nil,
                             message: "已开始回放（\(points.count) 个点，约 \(Format.duration(interval * Double(points.count - 1))) 走完）")
    }

    func playRoute(start: GeoPoint,
                   end: GeoPoint,
                   mode: TravelMode,
                   pace: PlaybackPace) async throws -> RoutePlayData {
        let plan = try await planRoute(start: start, end: end, mode: mode, pace: pace, alternatives: 1)
        guard let first = plan.routes.first else {
            throw LocServerError("路线数据为空，请调整起终点。")
        }
        return try await playRoute(points: first.points, mode: mode, pace: pace, name: first.summary)
    }

    func stopRoute() async throws -> ClearData {
        await RoutePlayer.shared.stop()
        _ = await NativeInjector.shared.stop()
        return ClearData(cleared: true,
                         udid: Self.localDevice().udid,
                         message: "已停止回放，定位恢复为真实位置")
    }

    // MARK: - 内部工具

    /// 启动时刻，用于健康页展示
    private static let launchedAt = Date()
    private static let startTimeText: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: Date())
    }()

    /// 当前这台 iPhone
    static func localDevice() -> DeviceInfo {
        let device = UIDevice.current
        let udid = device.identifierForVendor?.uuidString ?? "local-device"
        return DeviceInfo(udid: udid,
                          name: device.name,
                          model: device.model,
                          ios: device.systemVersion,
                          build: nil,
                          connection: "本机",
                          channel: "native",
                          channelLabel: "本机注入",
                          selected: true,
                          label: "本机")
    }

    private func currentSession() async -> SessionState {
        let injector = await NativeInjector.shared
        return await injector.sessionState(deviceName: Self.localDevice().displayName)
    }

    private func hints() async -> [String] {
        let injector = await NativeInjector.shared
        var list = [await injector.probeReport]
        if await injector.available {
            list.append("本机注入模式：不需要电脑，不需要数据线，不需要开发者模式。")
        } else {
            list.append("注入接口不可用：请确认用 TrollStore 安装，并保留 com.apple.locationd.simulation 权限。")
        }
        return list
    }

    /// 出行方式到 MapKit 的映射
    static func transportType(for mode: TravelMode) -> MKDirectionsTransportType {
        switch mode {
        case .walking: return .walking
        case .cycling: return .cycling
        case .driving: return .automobile
        }
    }

    /// 回放总时长：顺滑按真实速度，标准固定 5 分钟，快速固定 1 分钟
    static func totalSeconds(pace: PlaybackPace, distance: Double, nativeDuration: TimeInterval?) -> Double {
        switch pace {
        case .smooth:
            if let nativeDuration, nativeDuration > 0 {
                return min(max(nativeDuration, 30), 7200)
            }
            // 没有真实时长就按 6 km/h 步行速度粗算
            return min(max(distance / 1.7, 30), 7200)
        case .standard:
            return 300
        case .fast:
            return 60
        }
    }

    /// 把路线折线抽稀成回放点
    static func sample(points polyline: MKPolyline, limit: Int = 400) -> [GeoPoint] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        let buffer = polyline.coordinates
        let step = max(1, count / max(1, limit))
        var result: [GeoPoint] = []
        var index = 0
        while index < count {
            result.append(GeoPoint(buffer[index]))
            index += step
        }
        let last = GeoPoint(buffer[count - 1])
        if result.last != last {
            result.append(last)
        }
        return result
    }

    /// 折线总长（米）
    static func distance(of points: [GeoPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total: Double = 0
        for index in 1..<points.count {
            let a = CLLocation(latitude: points[index - 1].lat, longitude: points[index - 1].lng)
            let b = CLLocation(latitude: points[index].lat, longitude: points[index].lng)
            total += a.distance(from: b)
        }
        return total
    }

    /// 两点距离（米）
    static func distance(from a: GeoPoint, to b: GeoPoint) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lng)
            .distance(from: CLLocation(latitude: b.lat, longitude: b.lng))
    }

    /// 内置常用地点（原来由 locserver 提供，现在打包进 App，离线可用）
    static let builtinPresets: [PresetPlace] = [
        PresetPlace(name: "北京 · 天安门广场", lat: 39.908700, lng: 116.397500),
        PresetPlace(name: "北京 · 三里屯太古里", lat: 39.936000, lng: 116.455000),
        PresetPlace(name: "上海 · 外滩", lat: 31.239700, lng: 121.490400),
        PresetPlace(name: "上海 · 陆家嘴", lat: 31.239000, lng: 121.505700),
        PresetPlace(name: "广州 · 广州塔", lat: 23.106600, lng: 113.324500),
        PresetPlace(name: "深圳 · 市民中心", lat: 22.545600, lng: 114.058700),
        PresetPlace(name: "杭州 · 西湖断桥", lat: 30.259000, lng: 120.149000),
        PresetPlace(name: "成都 · 天府广场", lat: 30.657700, lng: 104.065700),
        PresetPlace(name: "西安 · 钟楼", lat: 34.261700, lng: 108.942300),
        PresetPlace(name: "武汉 · 江汉关", lat: 30.578200, lng: 114.293800),
        PresetPlace(name: "南京 · 新街口", lat: 32.040800, lng: 118.780900),
        PresetPlace(name: "重庆 · 解放碑", lat: 29.557800, lng: 106.577000),
        PresetPlace(name: "青岛 · 五四广场", lat: 36.062700, lng: 120.384700),
        PresetPlace(name: "香港 · 中环", lat: 22.283100, lng: 114.158200),
        PresetPlace(name: "台北 · 101", lat: 25.033900, lng: 121.564500),
        PresetPlace(name: "东京 · 东京塔", lat: 35.658600, lng: 139.745400),
        PresetPlace(name: "首尔 · 光化门", lat: 37.575900, lng: 126.976900),
        PresetPlace(name: "新加坡 · 滨海湾", lat: 1.283400, lng: 103.860700),
        PresetPlace(name: "纽约 · 时代广场", lat: 40.758000, lng: -73.985500),
        PresetPlace(name: "伦敦 · 大本钟", lat: 51.500700, lng: -0.124600)
    ]
}

// MARK: - 本机路线回放器

/// 用定时器逐点调用注入接口，让蓝点沿路线连续移动。
/// 全程在本机完成，不再依赖 locserver 的 /api/route/play。
@MainActor
final class RoutePlayer {

    static let shared = RoutePlayer()

    private(set) var playing = false
    private(set) var progress = 0
    private(set) var total = 0

    private var task: Task<Void, Never>?

    private init() {}

    func start(points: [GeoPoint], interval: TimeInterval, name: String?) {
        stop()
        guard !points.isEmpty else { return }

        let injector = NativeInjector.shared
        playing = true
        total = points.count
        progress = 0

        let step = max(0.05, interval)
        task = Task { @MainActor in
            for (index, point) in points.enumerated() {
                if Task.isCancelled { return }
                _ = injector.start(point.coordinate, accuracy: 25, name: name)
                self.progress = index + 1
                if index < points.count - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                }
            }
            self.playing = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        playing = false
        progress = 0
        total = 0
    }
}
