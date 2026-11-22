//
//  MapPickView.swift
//  LocationPilot
//
//  「地图」页：Apple 地图上点选坐标、地名搜索、设为注入点或路线起终点。
//

import SwiftUI
import MapKit
import CoreLocation

struct MapPickView: View {
    @EnvironmentObject private var app: AppState

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.908722, longitude: 116.397499),
                           span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))
    )
    @State private var showSearchSheet = false
    @State private var showFavoriteSheet = false
    @State private var favoriteName = ""

    private var currentPoint: GeoPoint? { app.pickedPoint }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            bottomBar
        }
        .sheet(isPresented: $showSearchSheet) {
            PlaceSearchSheet { result in
                select(result.point, zoom: 0.01)
                app.log("从搜索结果选择「\(result.name)」：\(result.point.text)", level: .info)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showFavoriteSheet) {
            favoriteSheet
                .presentationDetents([.height(240)])
        }
        .onAppear {
            if let point = app.pickedPoint {
                focus(on: point, zoom: 0.02)
            }
        }
    }

    // MARK: - 地图

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                if let point = currentPoint {
                    Annotation("当前选点", coordinate: point.coordinate) {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.20))
                                .frame(width: 34, height: 34)
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        }
                    }
                }

                if let start = app.routeStart {
                    Marker("起点", systemImage: "flag.fill", coordinate: start.coordinate)
                        .tint(.green)
                }

                if let end = app.routeEnd {
                    Marker("终点", systemImage: "flag.checkered", coordinate: end.coordinate)
                        .tint(.orange)
                }

                if let route = app.routes.first, route.points.count >= 2 {
                    MapPolyline(coordinates: route.points.map { $0.coordinate })
                        .stroke(Color.accentColor.opacity(0.75), lineWidth: 4)
                } else if let start = app.routeStart, let end = app.routeEnd {
                    MapPolyline(coordinates: [start.coordinate, end.coordinate])
                        .stroke(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.cafe, .restaurant, .park, .subwayStation])))
            .onTapGesture { screenPoint in
                if let coordinate = proxy.convert(screenPoint, from: .local) {
                    app.pickedPoint = GeoPoint(coordinate)
                    app.log("地图选点：\(GeoPoint(coordinate).text)", level: .info)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - 底部操作条

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    showSearchSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text("搜索地名")
                            .font(.footnote)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.bordered)

                Button {
                    focusOnSelected()
                } label: {
                    Image(systemName: "scope")
                }
                .buttonStyle(.bordered)
            }

            if let point = currentPoint {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前选点")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(point.text)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await app.inject(point: point, name: "地图选点") }
                    } label: {
                        Label("注入此处", systemImage: "location.north.line.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        app.routeStart = point
                        app.log("已设为路线起点：\(point.text)", level: .info)
                    } label: {
                        Text("设为起点")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        app.routeEnd = point
                        app.log("已设为路线终点：\(point.text)", level: .info)
                    } label: {
                        Text("设为终点")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        favoriteName = ""
                        showFavoriteSheet = true
                    } label: {
                        Image(systemName: "star")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Text("在地图上轻点即可选点")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.10), radius: 10, y: 2)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: - 收藏命名

    private var favoriteSheet: some View {
        NavigationStack {
            Form {
                Section("给这个坐标起个名字") {
                    TextField("例如：客户现场 / 家", text: $favoriteName)
                }
                Section {
                    Text(currentPoint?.text ?? "请先在图上选点")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("收藏坐标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showFavoriteSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let point = currentPoint else { return }
                        app.addFavorite(name: favoriteName, point: point)
                        showFavoriteSheet = false
                    }
                    .disabled(currentPoint == nil)
                }
            }
        }
    }

    // MARK: - 辅助

    private func select(_ point: GeoPoint, zoom: Double) {
        app.pickedPoint = point
        focus(on: point, zoom: zoom)
    }

    private func focusOnSelected() {
        if let point = currentPoint {
            focus(on: point, zoom: 0.01)
        } else if let device = app.selectedDevice, let preset = app.presets.first {
            // 没有选点时退回到第一个预设，避免点了没反应
            app.log("还没有选点，已定位到预设「\(preset.name)」，设备：\(device.displayName)", level: .info)
            select(preset.point, zoom: 0.05)
        }
    }

    private func focus(on point: GeoPoint, zoom: Double) {
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(
                MKCoordinateRegion(center: point.coordinate,
                                   span: MKCoordinateSpan(latitudeDelta: zoom, longitudeDelta: zoom))
            )
        }
    }
}

// MARK: - 地名搜索面板

/// 地名搜索面板：调用 Mac 端 geosearch.py 的在线搜索
struct PlaceSearchSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// 选中某条结果后的回调
    var onSelect: (PlaceResult) -> Void

    @State private var keyword: String = ""
    @State private var results: [PlaceResult] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("输入地名，例如：杭州西湖", text: $keyword)
                        .cardFieldStyle()
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                    Button("搜索") { runSearch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching)
                }
                .padding(14)

                if searching {
                    ProgressView("正在搜索…")
                        .padding(.top, 30)
                } else if results.isEmpty {
                    EmptyHintView(text: "还没有搜索结果。搜索由 Mac 端 geosearch.py 完成，需要 Mac 能上网。",
                                  systemImage: "magnifyingglass")
                        .padding(14)
                } else {
                    List(results) { item in
                        Button {
                            onSelect(item)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.primary)
                                if let addr = item.addr, !addr.isEmpty {
                                    Text(addr)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                HStack(spacing: 8) {
                                    Text(item.point.text)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(item.sourceText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("地名搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func runSearch() {
        let text = keyword
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searching = true
        Task {
            let list = await app.search(text, limit: 10)
            results = list
            searching = false
        }
    }
}

#Preview {
    MapPickView()
        .environmentObject(AppState())
}
