//
//  NativeInjector.swift
//  LocationPilot
//
//  直接用苹果私有 CLSimulationManager 接口把坐标注入本机 locationd，
//  彻底去掉「手机 App → Mac locserver.py」的桥接。
//
//  调用链（全部走 objc runtime，不依赖任何私有头文件）：
//  新通道（iOS 17+）：
//      CLSimulationManager
//        + defaultManager
//        - startSimulatingLocationWithCoordinate:accuracy:
//        - stopSimulatingLocation
//        - flush
//  旧通道（iOS 14–16，iOS 16.6 实测可用）：
//        - startLocationSimulation
//        - appendSimulatedLocation:   （参数是 CLLocation*）
//        - flush
//        - stopLocationSimulation
//        - clearSimulatedLocations
//
//  前提：App 必须持有 com.apple.locationd.simulation 权限。
//  用 TrollStore 安装（ldid -S 注入 entitlements）时该权限生效；
//  普通个人签名下 CLSimulationManager 会静默失效，不会报错。
//

import Foundation
import CoreLocation
import Darwin
import ObjectiveC

/// 一次注入调用的结果
struct InjectionOutcome {
    let ok: Bool
    /// 命中的私有方法名，便于排查不同 iOS 版本的差异
    let method: String
    let detail: String?
}

/// 旧通道的会话状态（闭包之间共享「是否已开始模拟」）
private final class LegacySession {
    var running = false
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
    /// 命中的停止方法名
    private(set) var resolvedStopSelector: String?

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

        // 不同系统版本的方法名与参数形态都不一致，必须按参数类型分组：
        // 坐标用两个 double（走浮点寄存器），对象参数走通用寄存器，混用会读到垃圾指针而崩溃。
        enum StartShape { case coordinateWithAccuracy, coordinate, object }
        let candidates: [(name: String, shape: StartShape)] = [
            ("startSimulatingLocationWithCoordinate:accuracy:", .coordinateWithAccuracy),
            ("startSimulatingLocationWithCoordinate:", .coordinate),
            ("simulateLocation:accuracy:", .coordinateWithAccuracy),
            ("simulateLocation:", .object),
            ("setSimulatedLocation:", .object)
        ]

        for candidate in candidates {
            let sel = NSSelectorFromString(candidate.name)
            guard instance.responds(to: sel) else { continue }
            guard let imp = class_getMethodImplementation(type(of: instance), sel) else { continue }

            let target = instance
            switch candidate.shape {
            case .coordinateWithAccuracy:
                typealias StartWithAccuracy = @convention(c) (AnyObject, Selector, Double, Double, Double) -> Void
                let fn = unsafeBitCast(imp, to: StartWithAccuracy.self)
                startCall = { coordinate, accuracy in
                    fn(target, sel, coordinate.latitude, coordinate.longitude, accuracy)
                }
            case .coordinate:
                typealias StartPlain = @convention(c) (AnyObject, Selector, Double, Double) -> Void
                let fn = unsafeBitCast(imp, to: StartPlain.self)
                startCall = { coordinate, _ in
                    fn(target, sel, coordinate.latitude, coordinate.longitude)
                }
            case .object:
                typealias StartObject = @convention(c) (AnyObject, Selector, AnyObject) -> Void
                let fn = unsafeBitCast(imp, to: StartObject.self)
                startCall = { coordinate, accuracy in
                    fn(target, sel, Self.makeLocation(coordinate, accuracy: accuracy))
                }
            }
            resolvedStartSelector = candidate.name
            break
        }

        // 新通道没有启动方法时，退回 iOS 14–16 的旧通道
        if startCall == nil {
            setupLegacyChannel(instance)
        }

        guard startCall != nil else {
            let names = candidateSelectors(of: instance)
            probeReport = "CLSimulationManager 实例在，但新/旧两套方法都不可用。已暴露方法：\(names)"
            return false
        }

        // 停止方法（旧通道已在 setupLegacyChannel 里配好）
        if stopCall == nil {
            for name in ["stopSimulatingLocation", "clearSimulatedLocation", "stopSimulation"] {
                let sel = NSSelectorFromString(name)
                guard instance.responds(to: sel) else { continue }
                guard let imp = class_getMethodImplementation(type(of: instance), sel) else { continue }
                typealias Stop = @convention(c) (AnyObject, Selector) -> Void
                let fn = unsafeBitCast(imp, to: Stop.self)
                let target = instance
                stopCall = { fn(target, sel) }
                resolvedStopSelector = name
                break
            }
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
                                    method: resolvedStopSelector ?? "stopSimulatingLocation",
                                    detail: stopCall == nil ? "系统没有提供停止方法，重启定位服务后恢复" : nil)
        }
        call()
        flushCall?()
        injected = false
        activePoint = nil
        activeName = nil
        return InjectionOutcome(ok: true, method: resolvedStopSelector ?? "stopSimulatingLocation", detail: nil)
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

    // MARK: - 自检（本机排障用）

    /// 端到端自检：接口可用性 → 权限 → 注入前基线 → 注入测试坐标 → 回读比对 → 还原原状态。
    /// 报告逐行可读，能区分「方法缺失 / 写入被忽略 / 权限不足 / 系统不回调」四类原因。
    func diagnose(testPoint: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 39.9042,
                                                                            longitude: 116.4074),
                  sampleTimeout: TimeInterval = 4) async -> (passed: Bool, report: String) {
        var lines: [String] = []
        var passed = false
        let probe = LocationProbe.shared

        lines.append("【注入自检】系统 \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let trollStoreRange = version.majorVersion >= 14 && version.majorVersion <= 17
        lines.append("0. 特权安装区间：\(trollStoreRange ? "在 TrollStore 支持范围内（14.0–17.0）" : "超出 TrollStore 支持范围（仅 14.0–17.0），本机注入基本不可能生效")")

        guard let cls = NSClassFromString("CLSimulationManager") else {
            classFound = false
            probeReport = "系统里没有 CLSimulationManager（iOS 版本不支持本机注入）"
            lines.append("1. 私有类：未找到，当前系统不支持本机注入")
            return (false, lines.joined(separator: "\n"))
        }
        classFound = true
        guard let instance = (manager ?? resolveManager(cls)) else {
            lines.append("1. 私有类：已找到，但取不到实例")
            return (false, lines.joined(separator: "\n"))
        }
        manager = instance
        lines.append("1. 私有类：已找到实例")

        let names = ["startLocationSimulation",
                     "appendSimulatedLocation:",
                     "flush",
                     "stopLocationSimulation",
                     "clearSimulatedLocations",
                     "setLocationDeliveryBehavior:",
                     "startSimulatingLocationWithCoordinate:accuracy:",
                     "startSimulatingLocationWithCoordinate:",
                     "stopSimulatingLocation"]
        var availableNames: [String] = []
        var missingNames: [String] = []
        for name in names {
            if instance.responds(to: NSSelectorFromString(name)) {
                availableNames.append(name)
            } else {
                missingNames.append(name)
            }
        }
        lines.append("2. 方法可用：\(availableNames.isEmpty ? "（无）" : availableNames.joined(separator: ", "))")
        if !missingNames.isEmpty {
            lines.append("   方法缺失：\(missingNames.joined(separator: ", "))")
        }

        let ready = available
        lines.append("3. 通道：\(ready ? "已就绪，" + (resolvedStartSelector ?? "?") : "不可用，" + probeReport)")
        lines.append("3.1 定位权限：\(probe.authorizationText)")

        guard ready else { return (false, lines.joined(separator: "\n")) }

        let entitlement = Self.simulationEntitlementState()
        switch entitlement {
        case .some(true):
            lines.append("3.2 注入权限：已具备 com.apple.locationd.simulation")
        case .some(false):
            lines.append("3.2 注入权限：缺失 → 当前安装方式没注入该权限，私有接口调用会被系统静默丢弃（需 TrollStore 安装）")
        case .none:
            lines.append("3.2 注入权限：读不到（SecTask 符号不可用），跳过此项")
        }

        // 注入前基线：先看系统此刻报什么位置，才能判断后面「没变」还是「变了」
        if let before = await probe.sample(timeout: 3, allowCached: true) {
            lines.append("3.3 注入前定位：\(Self.describe(before))")
        } else {
            lines.append("3.3 注入前定位：取不到（权限未开启或系统未回调）")
        }

        let baselinePoint = activePoint
        let baselineName = activeName
        let targetText = String(format: "%.5f, %.5f", testPoint.latitude, testPoint.longitude)
        let outcome = start(testPoint, accuracy: 25, name: "自检坐标")
        lines.append("4. 注入测试坐标 \(targetText)：\(outcome.ok ? "调用成功（\(outcome.method)）" : "调用失败（\(outcome.detail ?? "-")）")")
        guard outcome.ok else {
            restoreAfterDiagnose(baselinePoint, name: baselineName)
            return (false, lines.joined(separator: "\n"))
        }

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let after = await probe.sample(timeout: sampleTimeout)

        if let after {
            let target = CLLocation(latitude: testPoint.latitude, longitude: testPoint.longitude)
            let distance = after.distance(from: target)
            lines.append("5. 注入后定位：\(Self.describe(after))，与目标差 \(Int(distance)) 米")
            if distance <= 500 {
                passed = true
                lines.append("结论：注入生效，系统定位已改写。")
            } else {
                var tail: String
                if entitlement == false {
                    tail = "结论：注入被忽略，原因已定位 —— 本 App 二进制没有 com.apple.locationd.simulation 权限（当前不是 TrollStore 安装），私有接口调用被系统直接丢弃，改代码无用。"
                } else {
                    tail = "结论：注入被忽略，系统仍报原位置。常见原因：entry 权限被签名剥离、只有模糊位置权限、当前 iOS 版本已封堵该私有接口。"
                }
                if let baseline = await probe.sample(timeout: 2, allowCached: true),
                   after.distance(from: baseline) < 30 {
                    tail += "（注入前后坐标几乎相同，写入确实没生效）"
                }
                lines.append(tail)
            }
        } else {
            lines.append("5. 注入后定位：系统未回调，权限=\(probe.authorizationText)")
            lines.append(probe.isAuthorized
                         ? "结论：权限已开但系统不返回定位，无法回读验证。请打开系统「地图」App 看蓝点是否已落在测试坐标：已落则为生效，仍在本机则为写入被忽略。"
                         : "结论：定位权限不可用，先在 设置 > 隐私与安全性 > 定位服务 里给本 App「使用 App 期间」并打开精确位置后重测。")
        }

        restoreAfterDiagnose(baselinePoint, name: baselineName)
        return (passed, lines.joined(separator: "\n"))
    }

    /// 自检结束后把用户原本的坐标放回去，避免自检把模拟位置冲掉
    private func restoreAfterDiagnose(_ point: GeoPoint?, name: String?) {
        if let point {
            _ = start(point.coordinate, accuracy: 25, name: name)
        } else {
            _ = stop()
        }
    }

    /// 读本 App 二进制里的 com.apple.locationd.simulation 权限。
    /// 只有 TrollStore（或已越狱环境）安装才会带上它；普通签名缺失时私有接口调用成功但系统不采纳。
    /// 用 dlsym 取私有 SecTask 符号，取不到时返回 nil 表示无法判断。
    private static func simulationEntitlementState() -> Bool? {
        typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
        typealias CopyFn = @convention(c) (CFTypeRef, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFTypeRef>?

        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let createPtr = dlsym(handle, "SecTaskCreateFromSelf"),
              let copyPtr = dlsym(handle, "SecTaskCopyValueForEntitlement") else { return nil }
        let create = unsafeBitCast(createPtr, to: CreateFn.self)
        let copy = unsafeBitCast(copyPtr, to: CopyFn.self)
        guard let task = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        var error: Unmanaged<CFError>?
        guard let value = copy(task, "com.apple.locationd.simulation" as CFString, &error)?.takeRetainedValue() else {
            if let error { _ = error.takeRetainedValue() }
            return false
        }
        if let number = value as? NSNumber { return number.boolValue }
        return true
    }

    /// 采样结果的一行文字描述
    private static func describe(_ location: CLLocation) -> String {
        let accuracy = Int(max(0, location.horizontalAccuracy))
        return String(format: "%.5f, %.5f · 精度±%d 米", location.coordinate.latitude, location.coordinate.longitude, accuracy)
    }

    // MARK: - 旧通道（iOS 14–16）

    /// 配置 IOS 14–16 的旧注入通道：
    /// `startLocationSimulation` 开一次会话，`appendSimulatedLocation:` 逐个投递 CLLocation。
    private func setupLegacyChannel(_ instance: AnyObject) {
        let cls: AnyClass = type(of: instance)
        let beginSel = NSSelectorFromString("startLocationSimulation")
        let appendSel = NSSelectorFromString("appendSimulatedLocation:")
        guard instance.responds(to: beginSel),
              instance.responds(to: appendSel),
              let beginIMP = class_getMethodImplementation(cls, beginSel),
              let appendIMP = class_getMethodImplementation(cls, appendSel) else { return }

        typealias NoArgument = @convention(c) (AnyObject, Selector) -> Void
        typealias OneObject = @convention(c) (AnyObject, Selector, AnyObject) -> Void

        let beginFn = unsafeBitCast(beginIMP, to: NoArgument.self)
        let appendFn = unsafeBitCast(appendIMP, to: OneObject.self)
        let target = instance
        let session = LegacySession()

        var endCall: (() -> Void)?
        let endSel = NSSelectorFromString("stopLocationSimulation")
        if instance.responds(to: endSel), let imp = class_getMethodImplementation(cls, endSel) {
            let fn = unsafeBitCast(imp, to: NoArgument.self)
            endCall = { fn(target, endSel) }
        }

        var clearCall: (() -> Void)?
        let clearSel = NSSelectorFromString("clearSimulatedLocations")
        if instance.responds(to: clearSel), let imp = class_getMethodImplementation(cls, clearSel) {
            let fn = unsafeBitCast(imp, to: NoArgument.self)
            clearCall = { fn(target, clearSel) }
        }

        startCall = { coordinate, accuracy in
            if !session.running {
                beginFn(target, beginSel)
                session.running = true
            }
            let location = Self.makeLocation(coordinate, accuracy: accuracy)
            appendFn(target, appendSel, location)
        }

        stopCall = {
            if session.running {
                endCall?()
                session.running = false
            }
            clearCall?()
        }

        resolvedStartSelector = "startLocationSimulation + appendSimulatedLocation:"
        resolvedStopSelector = "stopLocationSimulation + clearSimulatedLocations"
    }

    // MARK: - 私有工具

    /// 统一的模拟位置构造：时间戳取当前时刻，无效字段按苹果约定置 -1
    nonisolated private static func makeLocation(_ coordinate: CLLocationCoordinate2D,
                                                accuracy: Double) -> CLLocation {
        CLLocation(coordinate: coordinate,
                   altitude: 100,
                   horizontalAccuracy: max(1, accuracy),
                   verticalAccuracy: -1,
                   course: -1,
                   speed: -1,
                   timestamp: Date())
    }

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
        // 不被系统自动挂起，否则回读采样会偶发收不到回调
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// 当前定位权限的文字描述，自检报告里用来排除权限因素
    var authorizationText: String {
        let statusText: String
        switch manager.authorizationStatus {
        case .notDetermined: statusText = "未询问"
        case .restricted: statusText = "受限"
        case .denied: statusText = "已拒绝"
        case .authorizedAlways: statusText = "始终允许"
        case .authorizedWhenInUse: statusText = "使用期间允许"
        @unknown default: statusText = "未知状态"
        }
        let accuracyText = (manager.accuracyAuthorization == .fullAccuracy) ? "精确位置" : "模糊位置"
        return "\(statusText) · \(accuracyText)"
    }

    /// 是否已获得定位授权
    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    /// 采一次系统当前定位，超时返回 nil
    /// - Parameter allowCached: 为 true 时优先用 5 分钟内的缓存值，避免为拿基线干等超时
    func sample(timeout: TimeInterval = 4, allowCached: Bool = false) async -> CLLocation? {
        if manager.authorizationStatus == .notDetermined {
            await MainActor.run { self.manager.requestWhenInUseAuthorization() }
            // 给用户一点时间点授权弹窗
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        if allowCached, let cached = manager.location,
           abs(cached.timestamp.timeIntervalSinceNow) < 300 {
            return cached
        }
        if !isAuthorized {
            // 没有权限时干等只会白等 4 秒，直接给缓存值（可能为 nil）
            return manager.location
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.latest = nil
                self.waiter = continuation
                self.manager.startUpdatingLocation()
                // 第一轮等待；没回调就重启一次定位再等，避开系统首帧偶发不投递
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    guard self.waiter != nil else { return }
                    self.manager.stopUpdatingLocation()
                    self.manager.startUpdatingLocation()
                    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                        self.finish(self.latest ?? self.manager.location)
                    }
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
