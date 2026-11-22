---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: 219d94c26b60ac16cd844f8cbe62f421_54a609ede64d11f19f9d525400cd780f
    ReservedCode1: T5QRWmrJON17BE+h8waVv6k/hEDEEtM69RRYkU789Vra7aYsw6oKhU1aYRxegb+057kX6j79pePF3Pk5qfZ7Q9n0M0IT8gQ5Emg5v0EA5WWu0banAlSnRiq6Jn4cjWACxYMOwwGTW3w+E4Cxrdu7gIR8HNZ+d1QgURXNa7NLPsi0AUo8gFijf+MYcO4=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: 219d94c26b60ac16cd844f8cbe62f421_54a609ede64d11f19f9d525400cd780f
    ReservedCode2: T5QRWmrJON17BE+h8waVv6k/hEDEEtM69RRYkU789Vra7aYsw6oKhU1aYRxegb+057kX6j79pePF3Pk5qfZ7Q9n0M0IT8gQ5Emg5v0EA5WWu0banAlSnRiq6Jn4cjWACxYMOwwGTW3w+E4Cxrdu7gIR8HNZ+d1QgURXNa7NLPsi0AUo8gFijf+MYcO4=
---

# LocationPilot 使用说明

LocationPilot 是一个纯 SwiftUI 的 iOS 客户端，用来遥控 Mac 上运行的 `locserver.py`，
从而给 iPhone 注入模拟定位、回放路线、清除定位。手机端不碰任何私有接口，全部能力
都由 Mac 端服务代理。

- Bundle ID：`com.yhb.locationpilot`
- 最低系统：iOS 17.0
- 语言：Swift / SwiftUI，无 Storyboard、无第三方依赖
- 工程文件：`LocationPilot.xcodeproj`

## 一、编译前必须知道的两件事

1. **必须用 Xcode 打开，不能用命令行 `xcodebuild` 走 CommandLineTools。**
   本机若只装了 Xcode Command Line Tools，`xcodebuild` 会报
   `requires Xcode, but active developer directory is a command line tools instance`。
   请先安装 Xcode（App Store，约 10 GB），然后：

   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```

2. **首次运行需要在手机上开启「开发者模式」**（iOS 16 起强制）。
   路径：设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启手机 → 确认。

## 二、编译与安装步骤

1. 双击 `LocationPilot.xcodeproj` 打开工程。
2. Xcode 菜单 → Settings → Accounts，用你自己的 Apple ID 登录（免费账号即可）。
3. 选中左侧工程 `LocationPilot` → TARGETS `LocationPilot` → Signing & Capabilities：
   - 勾选 `Automatically manage signing`
   - Team 选择你的个人团队（形如 `张三 (ABCDE12345)`）
   - 如果提示 Bundle ID 冲突，把 `com.yhb.locationpilot` 改成一个唯一的，
     例如 `com.yourname.locationpilot`
4. 手机用数据线连到 Mac，在 Xcode 顶部设备下拉框里选中这台 iPhone。
5. 按 `⌘R` 运行。首次运行手机会提示「不受信任的开发者」：
   设置 → 通用 → VPN与设备管理 → 开发者 App → 选择你的 Apple ID → 信任。
6. 如提示「无法验证 App」，拔线重插、或在 Xcode 里 `Product → Clean Build Folder` 后重跑。

> 免费证书签名的 App **每 7 天过期一次**，到期后双击图标会闪退，
> 用 Xcode 重新 `⌘R` 跑一次即可续期（不需要改任何代码）。
> 想长期使用需加入 Apple Developer Program（99 美元/年）后改用正式描述文件。

## 三、Mac 端准备

1. 在 Mac 的 `iOS定位工具` 目录下双击 `启动 locserver.command`，
   服务默认监听 `0.0.0.0:8765`，日志在 `~/.iosloc/locserver.log`。
2. 查询 Mac 的局域网 IP：

   ```bash
   ipconfig getifaddr en0
   ```

3. 手机和 Mac 必须连同一个 Wi-Fi（或手机开热点给 Mac 也行）。

## 四、App 内配置

1. 打开 App → 底部「设置」标签页。
2. 在「Mac 服务器地址」里填 Mac 的局域网 IP，端口保持 `8765`，
   点击「保存并测试连接」。看到绿色「已连接」即通。
3. 同一页面点击「刷新设备」，从设备列表里选中要注入的那台 iPhone。
4. iOS 11~16 的机型还需点「挂载开发者镜像」（只需一次，拔线后可能要重做）。
5. 首页顶部的状态条会显示服务、设备和会话状态，点右侧刷新按钮可随时重新拉取。

## 五、五个标签页怎么用

| 标签页 | 用途 |
| --- | --- |
| 注入 | 手动输入经纬度、或点「用地图选点」带入坐标，一键注入；也可清除定位恢复真实 GPS |
| 地图 | Apple 地图上点一下取坐标，可设为注入点、路线起点或终点，也支持地名搜索 |
| 路线 | 选起点终点、出行方式（步行/骑行/驾车）与回放节奏，先规划再回放，可随时停止 |
| 收藏 | 常用地点收藏，点一下即注入；同时展示服务端内置的 6 个预设地点 |
| 设置 | 服务器地址、连通性测试、设备选择、镜像挂载、诊断信息、运行日志 |

## 六、常见问题

| 现象 | 处理 |
| --- | --- |
| 设置页提示「未连接」 | 确认 Mac 上 `locserver` 在跑（浏览器打开 `http://<MacIP>:8765/api/health` 应返回 JSON）；确认同一 Wi-Fi；检查 Mac 防火墙是否拦了 8765 |
| 提示「会话失效/隧道断开」 | 多为数据线松动。重新插紧线，再点一次注入；`/api/status` 的 hints 里会写明原因 |
| 注入成功但地图上蓝点没动 | 手机需保持解锁、屏幕常亮；部分机型的「查找我的 iPhone」关闭后才生效；确认选中的设备是当前这台 |
| 路线回放中途断开 | 回到「路线」页点「停止回放」，再重新开始；长时间回放建议关掉手机自动锁屏 |
| 地名搜索报错 503 | Mac 端 `geosearch.py` 缺失或被删除，恢复该文件后重启 locserver |
| 编译报 `Signing for "LocationPilot" requires a development team` | 回到第二节第 3 步选择 Team |

## 七、代码结构

| 文件 | 职责 |
| --- | --- |
| `LocationPilotApp.swift` | App 入口，注入全局 `AppState` |
| `ContentView.swift` | 五标签主界面 + 顶部状态条 + 忙碌遮罩 |
| `Models.swift` | 与服务端 JSON 一一对应的数据模型、出行方式与回放节奏枚举、日志条目 |
| `APIClient.swift` | 全部 HTTP 请求封装，统一错误映射，接口清单与服务端 `LOCSERVER_API.md` 一致 |
| `AppState.swift` | 全局状态、持久化（地址/收藏）、业务流程编排 |
| `InjectView.swift` | 注入页 |
| `MapPickView.swift` | 地图选点页（含地名搜索面板） |
| `RouteView.swift` | 路线规划与回放页 |
| `FavoritesView.swift` | 收藏与预设页 |
| `SettingsView.swift` | 服务器配置、设备管理、诊断与日志页 |
| `Components.swift` | 卡片、横幅、日志列表等复用组件与格式化工具 |

接口字段细节见上一级目录的 `LOCSERVER_API.md`。
*（内容由AI生成，仅供参考）*
