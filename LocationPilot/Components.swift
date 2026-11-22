//
//  Components.swift
//  LocationPilot
//
//  可复用的界面组件：卡片容器、状态横幅、键值行、日志列表、输入框样式。
//

import SwiftUI

// MARK: - 卡片容器

/// 统一的白底圆角卡片，标题可选
struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cardBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - 键值行

/// 左侧标题、右侧内容的一行信息
struct KeyValueRow: View {
    let title: String
    let value: String
    var valueColor: Color = .primary
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(monospaced ? .footnote.monospaced() : .footnote)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 顶部状态横幅

/// 常驻在页面上方的状态条：服务器连接 + 设备 + 会话
struct StatusBannerView: View {
    @EnvironmentObject private var app: AppState

    private var dotColor: Color {
        switch app.connection {
        case .online: return app.selectedDevice == nil ? .orange : .green
        case .offline: return .red
        case .unknown: return .gray
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.statusSummary)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                Text("会话：\(app.sessionText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if app.busy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await app.refreshStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.bannerBackground)
    }
}

// MARK: - 结果提示

/// 展示最近一次成功或失败的结果
struct ResultBannerView: View {
    let text: String
    let isError: Bool
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.green)
                .font(.footnote)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isError ? Color.red.opacity(0.10) : Color.green.opacity(0.10))
        )
    }
}

// MARK: - 忙碌遮罩

/// 全屏忙碌提示，带正在执行的动作说明
struct BusyOverlay: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text.isEmpty ? "正在处理…" : text)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cardBackground)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        )
    }
}

// MARK: - 日志列表

struct LogListView: View {
    let entries: [LogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty {
                Text("暂无运行记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: entry.level.symbol)
                            .font(.caption2)
                            .foregroundStyle(color(for: entry.level))
                            .padding(.top, 2)
                        Text(entry.timeText)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.text)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .failure: return .red
        }
    }
}

// MARK: - 空态提示

struct EmptyHintView: View {
    let text: String
    var systemImage: String = "info.circle"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 主题色

extension Color {
    /// 卡片底色：深色模式下自动变深
    static var cardBackground: Color {
        Color(uiColorNamed: "CardBackground") ?? Color.gray.opacity(0.10)
    }

    static var cardBorder: Color {
        Color.gray.opacity(0.25)
    }

    static var bannerBackground: Color {
        Color(uiColorNamed: "BannerBackground") ?? Color.gray.opacity(0.08)
    }

    static var pageBackground: Color {
        Color(uiColorNamed: "PageBackground") ?? Color.gray.opacity(0.06)
    }

    /// 按名字取自适应色；取不到就返回 nil，由调用方给兜底色
    init?(uiColorNamed name: String) {
        #if os(iOS)
        guard let color = UIColor(named: name) else { return nil }
        self.init(uiColor: color)
        #else
        guard let color = NSColor(named: name) else { return nil }
        self.init(nsColor: color)
        #endif
    }
}

// MARK: - 输入框装饰

extension View {
    /// 数字键盘（仅 iOS 有意义，其它平台原样返回）
    @ViewBuilder
    func numberPadKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }

    /// 卡片内的输入框统一样式
    func cardFieldStyle() -> some View {
        self
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
}

// MARK: - 格式化工具

enum Format {
    /// 米 → 人类可读距离
    static func distance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f 公里", meters / 1000.0)
        }
        return String(format: "%.0f 米", meters)
    }

    /// 秒 → 人类可读时长
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return "\(total / 3600) 小时 \((total % 3600) / 60) 分"
        }
        if total >= 60 {
            return "\(total / 60) 分 \(total % 60) 秒"
        }
        return "\(total) 秒"
    }

    /// 把用户输入的文本解析成坐标，容忍中英文逗号与空格分隔
    static func parseCoordinate(lat: String, lng: String) -> GeoPoint? {
        func normalize(_ text: String) -> String {
            text.replacingOccurrences(of: "，", with: ".")
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let la = Double(normalize(lat)), let ln = Double(normalize(lng)) else {
            return nil
        }
        let point = GeoPoint(lat: la, lng: ln)
        return point.isValid ? point : nil
    }

    /// 坐标 → 两段文本，便于填进输入框
    static func split(_ point: GeoPoint) -> (lat: String, lng: String) {
        (String(format: "%.6f", point.lat), String(format: "%.6f", point.lng))
    }
}
