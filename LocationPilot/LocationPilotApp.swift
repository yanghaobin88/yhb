//
//  LocationPilotApp.swift
//  LocationPilot
//
//  App 入口：注入全局状态并挂载主界面。
//

import SwiftUI

@main
struct LocationPilotApp: App {
    /// 全局状态对象，整个 App 共享一份
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
        }
    }
}
