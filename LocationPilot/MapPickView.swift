//
//  MapPickView.swift
//  LocationPilot
//
//  「地图」页：Apple 地图上点选坐标、地名搜索、设为注入点或路线起终点。
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

struct MapPickView: View {
    @EnvironmentObject private var app: AppState

    /// 地图聚焦请求：token 变化时才移动视野
    fileprivate struct MapFocus: Equatable {
        let center: CLLocationCoordinate2D
        let span: Double
        let token: UUID
        static func == (lhs: MapFocus, rhs: MapFocus) -> Bool { lhs.token == rhs.token }
    }

    @State private var focusRequest: MapFocus?
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
        MapCanvas(point: currentPoint,
                  start: app.routeStart,
                  end: app.routeEnd,
                  route: routeCoordinates,
                  routeDashed: routeIsPreview,
                  focus: focusRequest) { coordinate in
            app.pickedPoint = GeoPoint(coordinate)
            app.log("地图选点：\(GeoPoint(coordinate).text)", level: .info)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    /// 已规划路线的坐标；没有路线时退回起终点直线
    private var routeCoordinates: [CLLocationCoordinate2D] {
        if let route = app.routes.first, route.points.count >= 2 {
            return route.points.map { $0.coordinate }
        }
        if let start = app.routeStart, let end = app.routeEnd {
            return [start.coordinate, end.coordinate]
        }
        return []
    }

    /// 没有真实规划结果时用虚线示意
    private var routeIsPreview: Bool {
        return (app.routes.first?.points.count ?? 0) < 2
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
        focusRequest = MapFocus(center: point.coordinate, span: zoom, token: UUID())
    }
}

// MARK: - 地图画布（MKMapView 包装，兼容 iOS 16）

/// 单个标注：用颜色和图标区分选点 / 起点 / 终点
private final class PilotAnnotation: NSObject, MKAnnotation {
    let title: String?
    let tint: UIColor
    let glyph: String
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(title: String, coordinate: CLLocationCoordinate2D, tint: UIColor, glyph: String) {
        self.title = title
        self.coordinate = coordinate
        self.tint = tint
        self.glyph = glyph
    }
}

private struct MapCanvas: UIViewRepresentable {
    var point: GeoPoint?
    var start: GeoPoint?
    var end: GeoPoint?
    var route: [CLLocationCoordinate2D]
    var routeDashed: Bool
    var focus: MapPickView.MapFocus?
    var onTap: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.pointOfInterestFilter = .includingAll
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.908722, longitude: 116.397499),
                                         span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)),
                      animated: false)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        map.addGestureRecognizer(tap)
        context.coordinator.mapView = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // 标注
        var desired: [(String, CLLocationCoordinate2D, UIColor, String)] = []
        if let point = point {
            desired.append(("当前选点", point.coordinate, .systemRed, "mappin"))
        }
        if let start = start {
            desired.append(("起点", start.coordinate, .systemGreen, "flag.fill"))
        }
        if let end = end {
            desired.append(("终点", end.coordinate, .systemOrange, "flag.checkered"))
        }
        let annoSignature = desired
            .map { "\($0.0)@\($0.1.latitude),\($0.1.longitude)" }
            .joined(separator: ";")
        if coordinator.lastAnnotationSignature != annoSignature {
            coordinator.lastAnnotationSignature = annoSignature
            map.removeAnnotations(map.annotations.compactMap { $0 as? PilotAnnotation })
            for item in desired {
                map.addAnnotation(PilotAnnotation(title: item.0, coordinate: item.1, tint: item.2, glyph: item.3))
            }
        }

        // 路线
        let routeSignature = "\(route.count)|\(route.first?.latitude ?? 0),\(route.first?.longitude ?? 0)|\(route.last?.latitude ?? 0),\(route.last?.longitude ?? 0)|\(routeDashed)"
        if coordinator.lastRouteSignature != routeSignature {
            coordinator.lastRouteSignature = routeSignature
            map.removeOverlays(map.overlays)
            if route.count >= 2 {
                let line = MKPolyline(coordinates: route, count: route.count)
                map.addOverlay(line, level: .aboveRoads)
            }
        }

        // 视野
        if let focus = focus, coordinator.lastFocusToken != focus.token {
            coordinator.lastFocusToken = focus.token
            map.setRegion(MKCoordinateRegion(center: focus.center,
                                             span: MKCoordinateSpan(latitudeDelta: focus.span, longitudeDelta: focus.span)),
                          animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapCanvas
        weak var mapView: MKMapView?
        var lastAnnotationSignature = ""
        var lastRouteSignature = ""
        var lastFocusToken: UUID?

        init(_ parent: MapCanvas) { self.parent = parent }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map = mapView else { return }
            let screen = gesture.location(in: map)
            let coordinate = map.convert(screen, toCoordinateFrom: map)
            parent.onTap(coordinate)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pilot = annotation as? PilotAnnotation else { return nil }
            let identifier = "pilot"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            if view == nil {
                view = MKMarkerAnnotationView(annotation: pilot, reuseIdentifier: identifier)
            }
            view?.annotation = pilot
            view?.markerTintColor = pilot.tint
            view?.glyphImage = UIImage(systemName: pilot.glyph)
            view?.displayPriority = .required
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: line)
            if parent.routeDashed {
                renderer.strokeColor = UIColor.systemGray.withAlphaComponent(0.85)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [6, 5]
            } else {
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.80)
                renderer.lineWidth = 4
            }
            return renderer
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
