//
//  NativeInjector.swift
//  LocationPilot
//
//  直接用苹果私有 CLSimulationManager 接口把坐标注入本机 locationd，
//  彻底去掉「手机 App → Mac locserver.py」的桥接。
//
//  调用链（全部走 objc runtime，不依赖任何私有头文件）：
//      CLSimulationManager
//        + defaultManager
//        - startSimulatingLocationWithCoordinate:accuracy:
//        - stopSimulatingLocation
//
//  前提：App 必须持有 com.apple.locationd.simulation 权限。
//  用 TrollStore 安装（ldid -S 注入 entitlements）时该权限生效；
//  普通个人签名下 CLSimulationManager 会静默失效，不会报错。
//

import Foundation
import CoreLocation
import ObjectiveC

/// 一次注入调用的结果
struct InjectionOutcome {
    let ok: Bool
    /// 命中的私有方法名，便于排查不同 iOS 版本的差异
    let method: String
    let detail: String?
}

/// 本机定位注入器
///
/// 线程约定：统一在主线程使用（AppState / RoutePlayer 都是 @MainActor）。
@MainActor
final class NativeInjector {

    static let shared = NativeInjector()

    // MARK: - 状态

    /// 最近一次注入的坐标
    private(set) var activePoint: GeoPoint?
    /// 最近一次注入带的地名
    private(set) var activeName: String?
    /// 是否已成功注入过（用于区分「在模拟」与「已清除」）
    private(set) var injected = false
    /// 探针结论（给设置页展示）
    private(set) var probeReport: String = "尚未探测"
    /// 是否找到了 CLSimulationManager 类
    private(set) var classFound = false
    /// 命中的启动方法名
    private(set) var resolvedStartSelector: String?

    // MARK: - 私有句柄

    private var manager: AnyObject?
    private var startCall: ((CLLocationCoordinate2D, Double) -> Void)?
    private var stopCall: (() -> Void)?
    /// 是否存在 flush（部分系统版本注入后需要显式落地）
    private var flushCall: (() -> Void)?

    private init() {}

    // MARK: - 对外接口

    /// 当前是否具备注入能力（未探测则先探测）
    var available: Bool {
        if startCall != nil { return true }
        return probe()
    }

    /// 一句话描述当前注入通道状态
    var statusText: String {
        if injected, let point = activePoint {
            let name = (activeName?.isEmpty == false) ? "\(activeName!) · " : ""
            return "模拟中：\(name)\(point.text)"
        }
        if startCall != nil { return "真实定位（注入接口已就绪）" }
        return "真实定位（注入接口不可用）"
    }

    /// 探测私有接口，成功返回 true
    @discardableResult
    func probe() -> Bool {
        if startCall != nil { return true }

        guard let cls = NSClassFromString("CLSimulationManager") else {
            classFound = false
            probeReport = "系统里没有 CLSimulationManager（iOS 版本不支持本机注入）"
            return false
        }
        classFound = true

        guard let instance = resolveManager(cls) else {
            manager = nil
            probeReport = "拿到了 CLSimulationManager 类，但取不到实例"
            return false
        }
        manager = instance

        // 不同系统版本的方法名不完全一致，按优先级逐个试
        let candidates: [(name: String, wantsAccuracy: Bool)] = [
            ("startSimulatingLocationWithCoordinate:accuracy:", true),
            ("startSimulatingLocationWithCoordinate:", false),
            ("simulateLocation:accuracy:", true),
            ("simulateLocation:", false),
            ("setSimulatedLocation:", false),
            ("setLocation:", false)
        ]

        for candidate in candidates {
            let sel = NSSelectorFromString(candidate.name)
            guard instance.responds(to: sel) else { continue }
            guard let imp = class_getMethodImplementation(type(of: instance), sel) else { continue }

            let target = instance
            if candidate.wantsAccuracy {
                typealias StartWithAccuracy = @convention(c) (AnyObject, Selector, Double, Double, Double) -> Void
                let fn = unsafeBitCast(imp, to: StartWithAccuracy.self)
                startCall = { coordinate, accuracy in
                    fn(target, sel, coordinate.latitude, coordinate.longitude, accuracy)
                }
            } else {
                typealias StartPlain = @convention(c) (AnyObject, Selector, Double, Double) -> Void
                let fn = unsafeBitCast(imp, to: StartPlain.self)
                startCall = { coordinate, _ in
                    fn(target, sel, coordinate.latitude, coordinate.longitude)
                }
            }
            resolvedStartSelector = candidate.name
            break
        }

        guard startCall != nil else {
            let names = candidateSelectors(of: instance)
            probeReport = "CLSimulationManager 实例在，但没有可用的启动方法。已暴露方法：\(names)"
            return false
        }

        // 停止方法
        for name in ["stopSimulatingLocation", "clearSimulatedLocation", "stopSimulation"] {
            let sel = NSSelectorFromString(name)
            guard instance.responds(to: sel) else { continue }
            guard let imp = class_getMethodImplementation(type(of: instance), sel) else { continue }
            typealias Stop = @convention(c) (AnyObject, Selector) -> Void
            let fn = unsafeBitCast(imp, to: Stop.self)
            let target = instance
            stopCall = { fn(target, sel) }
            break
        }

        // 落地方法
        for name in ["flush", "_flush"] {
            let sel = NSSelectorFromString(name)
            guard instance.responds(to: sel) else { continue }
            guard let imp = class_getMethodImplementation(type(of: instance), sel) else { continue }
            typealias Flush = @convention(c) (AnyObject, Selector) -> Void
            let fn = unsafeBitCast(imp, to: Flush.self)
            let target = instance
            flushCall = { fn(target, sel) }
            break
        }

        probeReport = "注入接口已就绪：\(resolvedStartSelector ?? "?")"
        return true
    }

    /// 注入一个坐标
    @discardableResult
    func start(_ coordinate: CLLocationCoordinate2D, accuracy: Double = 25, name: String? = nil) -> InjectionOutcome {
        guard (-90.0...90.0).contains(coordinate.latitude),
              (-180.0...180.0).contains(coordinate.longitude) else {
            return InjectionOutcome(ok: false, method: "none", detail: "坐标超出合法范围")
        }
        guard available, let call = startCall else {
            return InjectionOutcome(ok: false, method: "none", detail: probeReport)
        }

        call(coordinate, max(1, accuracy))
        flushCall?()

        injected = true
        activePoint = GeoPoint(coordinate)
        activeName = name

        let method = resolvedStartSelector ?? "?"
        return InjectionOutcome(ok: true, method: method,
                                detail: "已通过 \(method) 注入 \(activePoint?.text ?? "")")
    }

    /// 停止模拟，恢复真实定位
    @discardableResult
    func stop() -> InjectionOutcome {
        guard available, let call = stopCall else {
            // 没有 stop 方法时，退化为把坐标设回真实位置也无意义，直接标记状态
            injected = false
            activePoint = nil
            activeName = nil
            return InjectionOutcome(ok: stopCall != nil,
                                    method: "stopSimulatingLocation",
                                    detail: stopCall == nil ? "系统没有提供停止方法，重启定位服务后恢复" : nil)
        }
        call()
        flushCall?()
        injected = false
        activePoint = nil
        activeName = nil
        return InjectionOutcome(ok: true, method: "stopSimulatingLocation", detail: nil)
    }

    /// 生成一份会话状态，喂给界面上的「会话」区块
    func sessionState(deviceName: String) -> SessionState {
        let ready = startCall != nil
        let text: String
        if injected, let point = activePoint {
            let name = (activeName?.isEmpty == false) ? " · \(activeName!)" : ""
            text = "模拟中\(name)：\(point.text)"
        } else if ready {
            text = "真实定位（注入接口就绪）"
        } else {
            text = "真实定位（注入接口不可用）"
        }
        return SessionState(alive: true,
                            healthy: ready,
                            pid: nil,
                            stateText: text,
                            logPath: nil)
    }

    // MARK: - 私有工具

    /// 取 CLSimulationManager 实例：defaultManager / sharedManager / alloc+init
    private func resolveManager(_ cls: AnyClass) -> AnyObject? {
        let classGetters = ["defaultManager", "sharedManager", "sharedInstance"]
        for name in classGetters {
            let sel = NSSelectorFromString(name)
            guard let method = class_getClassMethod(cls, sel) else { continue }
            typealias Getter = @convention(c) (AnyClass, Selector) -> AnyObject?
            let fn = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            if let obj = fn(cls, sel) {
                return obj
            }
        }

        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(cls, allocSel) else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> AnyObject?
        let allocFn = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
        guard let raw = allocFn(cls, allocSel) else { return nil }

        let initSel = NSSelectorFromString("init")
        if let initMethod = class_getInstanceMethod(cls, initSel) {
            typealias InitFn = @convention(c) (AnyObject, Selector) -> AnyObject?
            let initFn = unsafeBitCast(method_getImplementation(initMethod), to: InitFn.self)
            if let obj = initFn(raw, initSel) {
                return obj
            }
        }
        return raw
    }

    /// 列出实例暴露的方法名，探针失败时贴给用户看
    private func candidateSelectors(of instance: AnyObject) -> String {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(type(of: instance), &count) else { return "（空）" }
        defer { free(list) }
        var names: [String] = []
        for index in 0..<Int(count) {
            let sel = method_getName(list[index])
            names.append(NSStringFromSelector(sel))
        }
        return names.sorted().joined(separator: ", ")
    }
}

// MARK: - 注入效果验证

/// 用一个真实 CLLocationManager 采样，确认系统定位是否真的被改写。
/// 这是判断「TrollStore 签名生效 / 普通签名静默失效」的唯一可靠办法。
final class LocationProbe: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    static let shared = LocationProbe()

    private let manager = CLLocationManager()
    private var latest: CLLocation?
    private var waiter: CheckedContinuation<CLLocation?, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
    }

    /// 采一次系统当前定位，超时返回 nil
    func sample(timeout: TimeInterval = 4) async -> CLLocation? {
        if manager.authorizationStatus == .notDetermined {
            await MainActor.run { self.manager.requestWhenInUseAuthorization() }
            // 给用户一点时间点授权弹窗
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.latest = nil
                self.waiter = continuation
                self.manager.startUpdatingLocation()
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    self.finish(self.latest ?? self.manager.location)
                }
            }
        }
    }

    /// 主线程串行结束，保证 continuation 只 resume 一次
    private func finish(_ location: CLLocation?) {
        guard let continuation = waiter else { return }
        waiter = nil
        manager.stopUpdatingLocation()
        continuation.resume(returning: location)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        DispatchQueue.main.async {
            self.latest = last
            self.finish(last)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.finish(nil) }
    }
}
