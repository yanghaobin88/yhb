//
//  RouteView.swift
//  LocationPilot
//
//  「路线」页：设置起终点、规划备选路线、按节奏回放、停止回放。
//

import SwiftUI

struct RouteView: View {
    @EnvironmentObject private var app: AppState

    /// 搜索面板要写入哪一端
    private enum Endpoint {
        case start
        case end
    }

    @State private var mode: TravelMode = .walking
    @State private var pace: PlaybackPace = .standard
    @State private var searchTarget: Endpoint?
    @State private var showSearchSheet = false
    @State private var showStopConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let error = app.lastError {
                    ResultBannerView(text: error, isError: true) { app.clearBanners() }
                } else if let success = app.lastSuccess {
                    ResultBannerView(text: success, isError: false) { app.clearBanners() }
                }

                endpointCard
                optionCard
                routesCard
                controlCard
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showSearchSheet) {
            PlaceSearchSheet { result in
                switch searchTarget {
                case .start: app.routeStart = result.point
                case .end: app.routeEnd = result.point
                case nil: break
                }
                app.log("路线端点设为「\(result.name)」：\(result.point.text)", level: .info)
            }
            .presentationDetents([.medium, .large])
        }
        .alert("确定停止回放？", isPresented: $showStopConfirm) {
            Button("取消", role: .cancel) {}
            Button("停止", role: .destructive) {
                Task { await app.stopRoute() }
            }
        } message: {
            Text("停止后模拟位置会回到最后一次注入的点，需要恢复真实 GPS 请使用「清除定位」。")
        }
    }

    // MARK: - 起终点

    private var endpointCard: some View {
        Card(title: "路线起终点",
             subtitle: "可以在地图页点选后回填，也可以直接搜索地名。",
             systemImage: "arrow.triangle.turn.up.right.diamond") {

            endpointRow(title: "起点",
                        color: .green,
                        point: app.routeStart,
                        setFromPicked: { setStart() },
                        search: { searchTarget = .start; showSearchSheet = true })

            Divider()

            endpointRow(title: "终点",
                        color: .orange,
                        point: app.routeEnd,
                        setFromPicked: { setEnd() },
                        search: { searchTarget = .end; showSearchSheet = true })

            HStack(spacing: 10) {
                Button {
                    let start = app.routeStart
                    app.routeStart = app.routeEnd
                    app.routeEnd = start
                } label: {
                    Label("交换", systemImage: "arrow.up.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(app.routeStart == nil && app.routeEnd == nil)

                Button(role: .destructive) {
                    app.routeStart = nil
                    app.routeEnd = nil
                    app.log("已清空路线起终点。", level: .info)
                } label: {
                    Label("清空", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func endpointRow(title: String,
                             color: Color,
                             point: GeoPoint?,
                             setFromPicked: @escaping () -> Void,
                             search: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.footnote.weight(.medium))
                Spacer(minLength: 0)
                Text(point?.text ?? "未设置")
                    .font(.caption2.monospaced())
                    .foregroundStyle(point == nil ? .secondary : .primary)
            }
            HStack(spacing: 10) {
                Button("用当前选点") { setFromPicked() }
                    .font(.caption)
                    .buttonStyle(.borderless)
                Button("搜索地名") { search() }
                    .font(.caption)
                    .buttonStyle(.borderless)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 方式与节奏

    private var optionCard: some View {
        Card(title: "出行方式与回放节奏",
             subtitle: "方式影响路网规划与速度；节奏只影响模拟点的间隔时间。",
             systemImage: "figure.walk.motion") {

            Picker("出行方式", selection: $mode) {
                ForEach(TravelMode.allCases) { item in
                    Label(item.label, systemImage: item.iconName).tag(item)
                }
            }
            .pickerStyle(.segmented)

            Picker("回放节奏", selection: $pace) {
                ForEach(PlaybackPace.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(pace.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 备选路线

    private var routesCard: some View {
        Card(title: "备选路线",
             subtitle: "优先走真实路网；取不到路网时退化为直线插值，服务端会在结果里注明。",
             systemImage: "point.topleft.down.curvedto.point.bottomright.up") {

            if app.routes.isEmpty {
                EmptyHintView(text: "还没有规划结果，点下面的「规划路线」。", systemImage: "map")
            } else {
                VStack(spacing: 10) {
                    ForEach(app.routes) { route in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(route.label)
                                    .font(.footnote.weight(.semibold))
                                Spacer(minLength: 0)
                                Text(Format.distance(route.distance))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(Format.duration(route.duration))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(route.summary.isEmpty ? "无路名摘要" : route.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            HStack(spacing: 10) {
                                Text("\(route.pointsCount) 个点 · 每 \(String(format: "%.2f", route.interval)) 秒一个")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Button {
                                    Task { await app.playRoute(route, mode: mode, pace: pace) }
                                } label: {
                                    Label("回放", systemImage: "play.fill")
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.gray.opacity(0.10))
                        )
                    }
                }
            }
        }
    }

    // MARK: - 控制

    private var controlCard: some View {
        Card(title: "执行", subtitle: nil, systemImage: "paperplane.fill") {
            Button {
                Task { await app.planRoute(mode: mode, pace: pace) }
            } label: {
                Label("规划路线", systemImage: "arrow.triangle.branch")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.routeStart == nil || app.routeEnd == nil)

            Button {
                Task { await app.playRouteDirect(mode: mode, pace: pace) }
            } label: {
                Label("跳过规划直接回放", systemImage: "forward.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(app.routeStart == nil || app.routeEnd == nil)

            Button(role: .destructive) {
                showStopConfirm = true
            } label: {
                Label("停止回放", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("回放由 Mac 端后台进程按间隔逐个写入模拟位置，期间可以离开 App。回放结束位置停在终点，需要恢复真实 GPS 请在「注入」页点「清除定位」。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 辅助

    private func setStart() {
        if let point = app.pickedPoint {
            app.routeStart = point
            app.log("起点设为当前选点：\(point.text)", level: .info)
        } else {
            app.log("地图上还没有选点，请先到「地图」页点击地图。", level: .info)
        }
    }

    private func setEnd() {
        if let point = app.pickedPoint {
            app.routeEnd = point
            app.log("终点设为当前选点：\(point.text)", level: .info)
        } else {
            app.log("地图上还没有选点，请先到「地图」页点击地图。", level: .info)
        }
    }
}

#Preview {
    RouteView()
        .environmentObject(AppState())
}
