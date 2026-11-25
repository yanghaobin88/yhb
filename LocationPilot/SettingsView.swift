//
//  SettingsView.swift
//  LocationPilot
//
//  「设置」页：Mac 服务器地址、连通性测试、设备选择、前置条件诊断、使用说明。
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState

    @State private var hostDraft: String = ""
    @State private var portDraft: String = "8765"
    @State private var loaded = false

    private var draftURL: URL? {
        LocServerClient.makeURL(host: hostDraft, port: portDraft)
    }

    private var draftDirty: Bool {
        hostDraft.trimmingCharacters(in: .whitespacesAndNewlines) != app.host ||
        portDraft.trimmingCharacters(in: .whitespacesAndNewlines) != app.port
    }

    var body: some View {
        Form {
            engineSection
            if app.engineMode == .remote {
                serverSection
            }
            healthSection
            deviceSection
            diagnoseSection
            logSection
            aboutSection
        }
        .onChange(of: app.engineMode) { _ in
            Task { await app.bootstrap() }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            hostDraft = app.host
            portDraft = app.port
        }
    }

    // MARK: - 注入方式

    private var engineSection: some View {
        Section {
            Picker("注入方式", selection: $app.engineMode) {
                ForEach(EngineMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: app.engineMode.iconName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                Text(app.engineMode.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let session = app.session {
                KeyValueRow(title: "会话", value: session.stateText,
                            valueColor: session.healthy ? .green : .orange)
            }
        } header: {
            Text("注入方式")
        } footer: {
            Text("「本机注入」不连电脑：App 直接调用系统私有 CLSimulationManager 改写 locationd。该接口需要 com.apple.locationd.simulation 权限，只有 TrollStore 安装（ldid -S 注入 entitlements）才生效；普通签名下会静默失效。")
        }
    }

    // MARK: - 服务器地址

    private var serverSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("IP / 主机")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                TextField("192.168.1.5", text: $hostDraft)
                    .cardFieldStyle()
                    .numberPadKeyboard()
            }

            HStack(spacing: 8) {
                Text("端口")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                TextField("8765", text: $portDraft)
                    .cardFieldStyle()
                    .numberPadKeyboard()
            }

            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(draftURL?.absoluteString ?? "地址不合法")
                    .font(.caption2.monospaced())
                    .foregroundStyle(draftURL == nil ? .red : .secondary)
                    .textSelection(.enabled)
            }

            Button {
                save()
                Task { await app.testConnection() }
            } label: {
                Label(draftDirty ? "保存并测试连接" : "测试连接", systemImage: "bolt.horizontal.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(draftURL == nil)

            if draftDirty {
                Button("撤销修改") {
                    hostDraft = app.host
                    portDraft = app.port
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Mac 服务器")
        } footer: {
            Text("在 Mac 上执行 locserver（双击「启动 locserver.command」），终端会打印本机局域网地址，形如 http://192.168.x.x:8765。iPhone 必须和 Mac 连同一个 Wi-Fi。")
        }
    }

    // MARK: - 连通性

    private var healthSection: some View {
        Section {
            HStack(spacing: 8) {
                Circle()
                    .fill(app.connection.isOnline ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(app.connection.text)
                    .font(.footnote)
                Spacer(minLength: 0)
                if app.busy {
                    ProgressView().controlSize(.mini)
                }
            }

            if let health = app.health {
                KeyValueRow(title: "服务", value: "\(health.service) \(health.version)")
                KeyValueRow(title: "监听", value: "\(health.host):\(health.port)")
                KeyValueRow(title: "Python", value: health.python)
                KeyValueRow(title: "启动时间", value: health.startedAt)
                KeyValueRow(title: "已运行", value: Format.duration(health.uptime))
                KeyValueRow(title: "依赖",
                            value: health.dependenciesReady ? "就绪" : "缺失（pymobiledevice3 / geosearch）",
                            valueColor: health.dependenciesReady ? .green : .red)
            }

            if let lan = app.status?.lan, !lan.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac 检测到的局域网地址")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(lan, id: \.self) { address in
                        Button {
                            applyLAN(address)
                        } label: {
                            HStack(spacing: 6) {
                                Text(address)
                                    .font(.caption2.monospaced())
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.down.left.circle")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if let hints = app.status?.hints, !hints.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(hints, id: \.self) { hint in
                        Text("· \(hint)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("连接状态")
        }
    }

    // MARK: - 设备

    private var deviceSection: some View {
        Section {
            if app.devices.isEmpty {
                Text("尚未检测到设备")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.devices) { device in
                    Button {
                        Task { await app.selectDevice(device) }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: (app.selectedDevice?.udid == device.udid)
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle((app.selectedDevice?.udid == device.udid) ? Color.accentColor : Color.secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.displayName)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("iOS \(device.ios ?? "?") · \(device.connection ?? "未知连接") · \(device.channelText)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(device.udid)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                Task { await app.loadDevices() }
            } label: {
                Label("重新检测设备", systemImage: "arrow.clockwise")
            }
            .font(.footnote)
        } header: {
            Text("目标设备")
        } footer: {
            Text("多台设备同时连接时，注入与回放都只会作用于选中的这一台。iOS 11-16 需要先挂载开发者镜像。")
        }
    }

    // MARK: - 诊断

    private var diagnoseSection: some View {
        Section {
            Button {
                Task { await app.runInspect() }
            } label: {
                Label("诊断前置条件", systemImage: "stethoscope")
            }
            .font(.footnote)

            if let inspect = app.inspect {
                KeyValueRow(title: "通道", value: inspect.channelLabel ?? "未知")
                KeyValueRow(title: "开发者模式", value: inspect.devMode ?? "未查询")
                KeyValueRow(title: "镜像", value: inspect.ddiState ?? (inspect.ddiMounted == true ? "已挂载" : "未挂载"))

                if let hints = inspect.hints, !hints.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(hints, id: \.self) { hint in
                            Text("· \(hint)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if app.engineMode == .remote {
                Button {
                    Task { await app.mountDeveloperImage() }
                } label: {
                    Label("挂载开发者镜像", systemImage: "externaldrive.badge.plus")
                }
                .font(.footnote)
            }
        } header: {
            Text("前置条件")
        } footer: {
            Text("iOS 17 及以上走 DVT 通道，需要先在「设置 - 隐私与安全性 - 开发者模式」打开开发者模式并重启；iOS 11-16 走经典通道，需要挂载与系统版本匹配的开发者镜像。")
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section {
            LogListView(entries: Array(app.logs.prefix(30)))
            if !app.logs.isEmpty {
                Button("清空运行记录", role: .destructive) {
                    app.clearLogs()
                }
                .font(.footnote)
            }
        } header: {
            Text("运行记录")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("使用步骤 · \(app.engineMode.label)")
                    .font(.footnote.weight(.semibold))
                if app.engineMode == .native {
                    Text("1. 用 TrollStore 安装 ipa（保留 App 内置 entitlements）。")
                        .font(.caption)
                    Text("2. 打开 App，本页点「测试连接」，看到「注入接口已就绪」即为正常。")
                        .font(.caption)
                    Text("3. 在「注入」页输入坐标或点预设；「地图」页可以直接点图选点。")
                        .font(.caption)
                    Text("4. 点「诊断前置条件」会真采样验证一次，确认蓝点是否被改写。")
                        .font(.caption)
                    Text("5. 需要恢复真实位置时，点「清除定位」。")
                        .font(.caption)
                } else {
                    Text("1. Mac 上双击「启动 locserver.command」，等待终端打印地址。")
                        .font(.caption)
                    Text("2. 用数据线连接 iPhone，手机上点「信任此电脑」。")
                        .font(.caption)
                    Text("3. 在本页填写 Mac 的 IP 与端口，点「保存并测试连接」。")
                        .font(.caption)
                    Text("4. 回到「注入」页输入坐标或点预设；「地图」页可以直接点图选点。")
                        .font(.caption)
                    Text("5. 需要恢复真实位置时，点「清除定位」或直接拔掉数据线重启定位服务。")
                        .font(.caption)
                }
            }
            .foregroundStyle(.primary)

            KeyValueRow(title: "App", value: "LocationPilot 1.0")
            KeyValueRow(title: "Bundle ID", value: "com.yhb.locationpilot", monospaced: true)
            KeyValueRow(title: "最低系统", value: "iOS 17.0")
        } header: {
            Text("关于")
        } footer: {
            Text("本机注入模式下所有坐标都只在你手机上处理，不经过任何服务器；Mac 桥接模式下也只走局域网，不上传云端。")
        }
    }

    // MARK: - 辅助

    private func save() {
        let trimmedHost = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = portDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        app.host = trimmedHost
        app.port = trimmedPort.isEmpty ? "8765" : trimmedPort
        app.log("已保存服务器地址：\(app.baseAddressText)", level: .info)
    }

    /// 点局域网地址时自动回填（形如 http://192.168.1.5:8765）
    private func applyLAN(_ address: String) {
        var text = address
        if text.lowercased().hasPrefix("http://") {
            text = String(text.dropFirst("http://".count))
        } else if text.lowercased().hasPrefix("https://") {
            text = String(text.dropFirst("https://".count))
        }
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        hostDraft = parts.first ?? text
        if parts.count > 1 {
            portDraft = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        app.log("已填入局域网地址 \(address)，请点「保存并测试连接」。", level: .info)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
