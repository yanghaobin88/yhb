//
//  ContentView.swift
//  LocationPilot
//
//  主界面：五个标签页 + 顶部状态条 + 全局忙碌遮罩。
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState
    @State private var selection: Int = 0
    @State private var didBootstrap = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                StatusBannerView()

                TabView(selection: $selection) {
                    InjectView()
                        .tabItem { Label("注入", systemImage: "location.fill") }
                        .tag(0)

                    MapPickView()
                        .tabItem { Label("地图", systemImage: "map") }
                        .tag(1)

                    RouteView()
                        .tabItem { Label("路线", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
                        .tag(2)

                    FavoritesView()
                        .tabItem { Label("收藏", systemImage: "star.fill") }
                        .tag(3)

                    SettingsView()
                        .tabItem { Label("设置", systemImage: "gearshape.fill") }
                        .tag(4)
                }
                .tint(.accentColor)
            }

            if app.busy {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                BusyOverlay(text: app.busyText)
            }
        }
        .background(Color.pageBackground.ignoresSafeArea())
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            await app.bootstrap()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
