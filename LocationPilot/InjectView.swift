//
//  InjectView.swift
//  LocationPilot
//
//  「注入」页：手动坐标、预设与收藏一键注入、清除定位、设备状态回显。
//

import SwiftUI

struct InjectView: View {
    @EnvironmentObject private var app: AppState

    @State private var latText: String = ""
    @State private var lngText: String = ""
    @State private var nameText: String = ""
    @State private var showClearConfirm = false
    @State private var lastResult: SetLocationData?

    private var coordinatePreview: String {
        if let point = Format.parseCoordinate(lat: latText, lng: lngText) {
            return point.text
        }
        return "坐标格式不正确"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let error = app.lastError {
                    ResultBannerView(text: error, isError: true) { app.clearBanners() }
                } else if let success = app.lastSuccess {
                    ResultBannerView(text: success, isError: false) { app.clearBanners() }
                }

                coordinateCard
                presetCard
                favoriteQuickCard
                statusCard
                logCard
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if latText.isEmpty, lngText.isEmpty, let point = app.pickedPoint {
                applyText(point)
            }
            if app.presets.isEmpty, app.hasServerConfigured {
                Task { await app.loadPresets() }
            }
        }
        .onChange(of: app.pickedPoint) { _, newValue in
            if let point = newValue {
                applyText(point)
            }
        }
        .alert("确定清除模拟定位？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task { await app.clearLocation() }
            }
        } message: {
            Text("清除后设备会恢复真实 GPS 位置，之前注入的坐标将失效。")
        }
    }

    // MARK: - 坐标输入卡

    private var coordinateCard: some View {
        Card(title: "手动注入坐标",
             subtitle: "纬度范围 ±90，经度范围 ±180，支持 6 位小数。点「地图」页可直接在图上选点并回填到这里。",
             systemImage: "scope") {

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("纬度")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("39.908722", text: $latText)
                        .cardFieldStyle()
                        .numberPadKeyboard()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("经度")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("116.397499", text: $lngText)
                        .cardFieldStyle()
                        .numberPadKeyboard()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("备注名称（可选）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("例如：公司 / 家 / 客户现场", text: $nameText)
                    .cardFieldStyle()
            }

            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(coordinatePreview)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("读取当前选点") {
                    if let point = app.pickedPoint {
                        applyText(point)
                    } else {
                        app.log("地图上还没有选点，请先到「地图」页点击地图。", level: .info)
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }

            HStack(spacing: 10) {
                Button {
                    guard let point = Format.parseCoordinate(lat: latText, lng: lngText) else {
                        app.log("坐标格式不正确，请检查纬度与经度。", level: .failure)
                        return
                    }
                    let title = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        lastResult = await app.inject(point: point, name: title.isEmpty ? nil : title)
                    }
                } label: {
                    Label("立即注入", systemImage: "location.north.line.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("清除定位", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if let result = lastResult {
                VStack(alignment: .leading, spacing: 4) {
                    KeyValueRow(title: "注入结果", value: result.message, valueColor: .green)
                    KeyValueRow(title: "设备", value: result.deviceName ?? "未知")
                    KeyValueRow(title: "通道", value: result.channel ?? "未知")
                    KeyValueRow(title: "进程", value: result.pid ?? "无", monospaced: true)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - 预设卡

    private var presetCard: some View {
        Card(title: "内置预设地点",
             subtitle: app.engineMode == .native
                ? "打包在 App 里的常用地点，离线可用，点一下即注入。"
                : "来自 Mac 端 iosloc.py 的 PRESETS 常量，点一下即注入。",
             systemImage: "mappin.circle.fill") {
            if app.presets.isEmpty {
                EmptyHintView(text: app.hasServerConfigured
                              ? "还没有读取到预设，点右上角刷新按钮重试。"
                              : "请先在「设置」页配置 Mac 服务器地址。")
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)],
                          spacing: 8) {
                    ForEach(app.presets) { preset in
                        Button {
                            applyText(preset.point)
                            nameText = preset.name
                            Task { await app.inject(point: preset.point, name: preset.name) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(preset.point.text)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.gray.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 收藏快捷卡

    private var favoriteQuickCard: some View {
        Card(title: "收藏快捷注入",
             subtitle: "收藏保存在本机，换网络也不丢。",
             systemImage: "star.circle.fill") {
            if app.favorites.isEmpty {
                EmptyHintView(text: "还没有收藏。可在「收藏」页把常用坐标存下来。", systemImage: "star")
            } else {
                VStack(spacing: 8) {
                    ForEach(app.favorites.prefix(5)) { favorite in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(favorite.name)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                                Text(favorite.point.text)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("注入") {
                                applyText(favorite.point)
                                nameText = favorite.name
                                Task { await app.inject(point: favorite.point, name: favorite.name) }
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 设备状态卡

    private var statusCard: some View {
        Card(title: "设备与前置条件",
             subtitle: "注入失败时，先在这里检查通道、开发者模式与镜像状态。",
             systemImage: "iphone.gen3") {
            if let device = app.selectedDevice {
                KeyValueRow(title: "设备", value: device.displayName)
                KeyValueRow(title: "型号", value: device.model ?? "未知")
                KeyValueRow(title: "系统", value: "iOS \(device.ios ?? "?") （\(device.build ?? "版本未知")）")
                KeyValueRow(title: "连接", value: device.connection ?? "未知")
                KeyValueRow(title: "通道", value: device.channelText)
                KeyValueRow(title: "UDID", value: device.udid, monospaced: true)
            } else {
                EmptyHintView(text: "尚未检测到设备，请确认数据线已连接并点了「信任此电脑」。",
                              systemImage: "cable.connector")
            }

            Divider()

            KeyValueRow(title: "会话", value: app.sessionText,
                        valueColor: (app.session?.alive == true) ? .green : .secondary)

            if let inspect = app.inspect {
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

            if let health = app.health {
                KeyValueRow(title: "服务版本",
                            value: "locserver \(health.version) · Python \(health.python)")
                KeyValueRow(title: "依赖",
                            value: health.dependenciesReady ? "就绪（pymobiledevice3 + geosearch）" : "缺失，注入会失败",
                            valueColor: health.dependenciesReady ? .green : .red)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await app.loadDevices() }
                } label: {
                    Label("检测设备", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await app.runInspect() }
                } label: {
                    Label("诊断", systemImage: "stethoscope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if app.selectedDevice?.needDeveloperImage == true {
                    Button {
                        Task { await app.mountDeveloperImage() }
                    } label: {
                        Label("挂载镜像", systemImage: "externaldrive.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - 日志卡

    private var logCard: some View {
        Card(title: "最近操作记录",
             subtitle: "只保留本机最近 200 条，不会上传。",
             systemImage: "list.bullet.rectangle") {
            LogListView(entries: Array(app.logs.prefix(10)))
            if !app.logs.isEmpty {
                Button("清空记录") { app.clearLogs() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - 辅助

    private func applyText(_ point: GeoPoint) {
        let parts = Format.split(point)
        latText = parts.lat
        lngText = parts.lng
    }
}

#Preview {
    InjectView()
        .environmentObject(AppState())
}
