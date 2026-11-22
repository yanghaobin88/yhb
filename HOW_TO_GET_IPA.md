---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: 219d94c26b60ac16cd844f8cbe62f421_e7fc52c3e64d11f18e5a525400de85a5
    ReservedCode1: +1I9k0wNj9TsmGE8ofjbEmHs9TQc+tnNp4NCcp4/QkZ/hjqsu+uYyCCkQvAMZLSsgO0lXuBKZIX/Q+F2aySkPlDBMrr4MoJAVfkbnQ4mgKyWXu1kIJZ2QcQw0u+46JQ6uthC6E2FnAdcd3GsbVxAI0ToUgoT6qI74HuM6XD2IU4MVjiPoaPBpUlHBZ4=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: 219d94c26b60ac16cd844f8cbe62f421_e7fc52c3e64d11f18e5a525400de85a5
    ReservedCode2: +1I9k0wNj9TsmGE8ofjbEmHs9TQc+tnNp4NCcp4/QkZ/hjqsu+uYyCCkQvAMZLSsgO0lXuBKZIX/Q+F2aySkPlDBMrr4MoJAVfkbnQ4mgKyWXu1kIJZ2QcQw0u+46JQ6uthC6E2FnAdcd3GsbVxAI0ToUgoT6qI74HuM6XD2IU4MVjiPoaPBpUlHBZ4=
---

# 如何拿到可自签的 ipa

## 为什么不能在本机直接生成

编译 iOS App 必须要有 iOS SDK（iPhoneOS.sdk），它只随 Xcode 提供。
本机当前状态：只装了 Command Line Tools，无 Xcode.app、无 iPhoneOS.sdk、无签名证书（0 valid identities）。
因此 `xcodebuild` 不可用，本地无法产出 ipa。Swift 语法解析（swiftc -parse）通过只能证明代码没语法错误，不能证明能编译成 App。

三条可行路径：

| 方案 | 需要什么 | 本地占用 | 出 ipa 时间 |
|---|---|---|---|
| A. GitHub Actions 云编译（本目录已配好） | GitHub 账号 | 0 | 约 5–10 分钟 |
| B. 本机装 Xcode 后本地编译 | App Store 下载 Xcode | 约 15–20 GB（当前剩 27 GB） | 1–3 小时 |
| C. 不做 App，用手机浏览器开 Mac 端页面 | 无 | 0 | 立即 |

本目录的 `.github/workflows/build-ipa.yml` 对应方案 A，已经把无签名编译和打 ipa 的流程写好。

## 方案 A 操作步骤（全程网页点选，不用命令行）

1. 打开 https://github.com/new ，Repository name 填 `LocationPilot`，选 **Private**，点 Create repository。
2. 在新仓库页面点 **uploading an existing file** 链接。
3. 把本目录里的 `LocationPilot`、`LocationPilot.xcodeproj`、`.github`、`.gitignore`、`README.md` 全部拖进上传框（`.github` 是隐藏目录，用 Finder 按 `Cmd+Shift+.` 显示后再拖）。
4. 点 **Commit changes**。提交后 Actions 会自动开始跑。
5. 点仓库顶部 **Actions** → 左侧 **Build Unsigned IPA** → 最新一次运行 → 等它变绿勾。
6. 页面底部 **Artifacts** 下载 `LocationPilot-ipa`（zip），解压得到 `LocationPilot.ipa`。

注意：仓库若是 Private，Actions 有免费额度（每月 2000 分钟）；Public 仓库完全免费。

## 拿到 ipa 之后怎么装（本机已有 i4Tools 9.11）

1. iPhone 用数据线连 Mac，i4Tools 识别到设备。
2. i4Tools 工具箱找到 **IPA 签名**（或「应用游戏 → 导入安装」时按提示签名）。
3. 用自己的 Apple ID（免费个人账号即可，无需 99 美元开发者账号）作为签名证书。
4. 若提示 Bundle ID `com.yhb.locationpilot` 已被占用，签名时改成 `com.yhb.locationpilot<你的任意后缀>`。
5. 签名完成后安装到手机。
6. 手机上：设置 → 隐私与安全性 → 开发者模式 → 打开并重启。
7. 首次打开 App 会提示「未受信任的开发者」，去 设置 → 通用 → VPN与设备管理 → 信任该 Apple ID。

## 免费证书的两个硬限制

- **7 天过期**：免费 Apple ID 签的 App 每 7 天必须重签一次，过期后图标点不开，重新签一次即可，数据保留。
- **最多 3 个 App**：同一免费账号同时最多签 3 个 App。

## 这套 App 装好后的实际用法

App 只是操作面板。真正改定位仍由 Mac 完成：Mac 必须开机、`启动 locserver.command` 在跑、iPhone 用 USB 连着 Mac。
App 里填 Mac 的局域网地址（形如 `http://192.168.x.x:8765`），点连通测试，通过后才能注入、搜索地名、路线回放。
*（内容由AI生成，仅供参考）*
