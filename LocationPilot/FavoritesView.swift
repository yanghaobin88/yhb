//
//  FavoritesView.swift
//  LocationPilot
//
//  「收藏」页：把常用坐标存到本机，一键注入；也能把 Mac 端预设转成收藏。
//

import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var app: AppState

    @State private var newName: String = ""
    @State private var manualLat: String = ""
    @State private var manualLng: String = ""

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("名称，例如：公司", text: $newName)
                        .cardFieldStyle()

                    HStack(spacing: 8) {
                        TextField("纬度", text: $manualLat)
                            .cardFieldStyle()
                            .numberPadKeyboard()
                        TextField("经度", text: $manualLng)
                            .cardFieldStyle()
                            .numberPadKeyboard()
                    }

                    HStack(spacing: 10) {
                        Button {
                            if let point = app.pickedPoint {
                                manualLat = Format.split(point).lat
                                manualLng = Format.split(point).lng
                                app.log("已填入地图当前选点：\(point.text)", level: .info)
                            } else {
                                app.log("地图上还没有选点。", level: .info)
                            }
                        } label: {
                            Label("填入当前选点", systemImage: "mappin.and.ellipse")
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)

                        Spacer(minLength: 0)

                        Button {
                            addFromManualInput()
                        } label: {
                            Label("添加收藏", systemImage: "plus.circle.fill")
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("新增收藏")
            } footer: {
                Text("收藏只保存在这台 iPhone 上，不会上传到任何服务器。")
            }

            if !app.favorites.isEmpty {
                Section("我的收藏（\(app.favorites.count)）") {
                    ForEach(app.favorites) { favorite in
                        favoriteRow(favorite)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            if app.favorites.indices.contains(index) {
                                app.removeFavorite(app.favorites[index])
                            }
                        }
                    }
                }
            }

            if !app.presets.isEmpty {
                Section {
                    ForEach(app.presets) { preset in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.footnote.weight(.medium))
                                Text(preset.point.text)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                app.addFavorite(name: preset.name, point: preset.point)
                            } label: {
                                Image(systemName: "star.badge.plus")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Mac 端内置预设")
                } footer: {
                    Text("这些是 iosloc.py 里的 PRESETS，点右侧加星即可存为本地收藏。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear {
            if app.presets.isEmpty, app.hasServerConfigured {
                Task { await app.loadPresets() }
            }
        }
    }

    // MARK: - 单条收藏

    private func favoriteRow(_ favorite: FavoritePlace) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(favorite.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Text(favorite.point.text)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                Task { await app.inject(point: favorite.point, name: favorite.name) }
            } label: {
                Label("注入", systemImage: "location.north.line.fill")
                    .labelStyle(.titleAndIcon)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - 新增

    private func addFromManualInput() {
        guard let point = Format.parseCoordinate(lat: manualLat, lng: manualLng) else {
            app.log("坐标格式不正确，纬度需在 ±90 内、经度需在 ±180 内。", level: .failure)
            return
        }
        app.addFavorite(name: newName, point: point)
        newName = ""
        manualLat = ""
        manualLng = ""
    }
}

#Preview {
    FavoritesView()
        .environmentObject(AppState())
}
