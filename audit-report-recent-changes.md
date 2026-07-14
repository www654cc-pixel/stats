# Stats 项目近期改动审计报告

**审计范围：** 最近 5 个提交（`5a5eace4` → `d7e9f508`）  
**审计时间：** 2026-07-14  
**分支：** `feature/single-icon-dashboard`  

---

## 1. 提交范围与总体印象

最近 5 个提交集中实现了"单图标仪表盘"（Single-icon dashboard）功能：将原先分散在菜单栏的多个模块图标折叠为一个图标，点击后展开一个综合 overview 弹窗。核心交付物包括：

- 统一的 `MetricTile` 磁贴骨架（`Stats/Views/MetricTiles.swift`）
- 顶部能量流桑基图（`Stats/Views/PowerFlowPortal.swift`）
- mihomo 代理面板（`Stats/Views/ProxyPortal.swift`）
- 快速启动面板（`Stats/Views/LauncherPortal.swift`）
- 各模块 portal 协议扩展，向 overview 暴露快照数据
- SMC 供电轨传感器补充，以适配 M5 / macOS 27 硬件

整体架构方向合理：通过协议化扩展减少模块间直接耦合，并用统一卡片样式提升视觉一致性。但部分实现存在硬编码、线程安全和硬件适配风险，需要后续补强。

---

## 2. 架构设计评估

### 2.1 单图标仪表盘架构

`CombinedView.swift` 作为 overview 面板的主控制器，结构清晰：

1. 顶部：`PowerFlowPortal`（电源/电池能量流）
2. 中部：`MetricTilesGrid`（CPU/GPU/RAM/Disk/Network/Sensors 六宫格）
3. 底部：fallback stock portals grid、单行世界时钟、可折叠 `ProxyPortal` 和 `LauncherPortal`

这种分层符合"先总览后细节"的信息架构，且保留了原有模块 portal 作为 fallback，降低了迁移风险。

### 2.2 Portal 协议扩展

`Kit/module/portal.swift` 新增 `Combined*Portal` 协议族：

- `CombinedCPUPortal`、`CombinedRAMPortal`、`CombinedSensorsPortal`
- `CombinedGPUPortal`、`CombinedDiskPortal`、`CombinedNetPortal`
- `CombinedClockPortal` 及 `ClockReading`、`PowerFlowReading`

该设计让 `Stats` app target 可以通过协议读取各模块最新快照，而不必直接链接模块内部类型，符合依赖倒置原则。

**建议：** 后续可考虑把快照读取统一为异步 `Publisher` 或 `AsyncStream`，避免当前基于 last-value 字段的轮询模式。

### 2.3 统一磁贴系统

`MetricTiles.swift` 将 CPU/GPU/RAM/Disk/Network/Sensors 的概览信息抽象为同一套 `MetricTile` 卡片，内置：

- 进度条可视化（`.bar`）
- 迷你折线（`.sparkline`）
- 共享卡片样式 `applyCardStyle()`

这显著减少了重复 UI 代码，便于后续新增模块。

---

## 3. 功能实现审计

### 3.1 PowerFlowPortal（能量流桑基图）

**实现要点：**
- 通过 IOKit 读取电池信息
- 通过 `CombinedSensorsPortal` 读取功耗数据
- 每 2 秒刷新，每 6 秒采样 `top -o power`
- 展示 Battery/DC-In → Mac → CPU/GPU/Display/Others 的能量流向

**风险点：**
1. **硬件依赖性强：** SMC 供电轨（`PP0b`、`PP1b`、`PBLR`、`PSTR`、`PDTR`）并非所有 Mac 都提供。M5 / macOS 27 上这些通道可能可用，但在旧机型或未来机型上可能缺失，导致桑基图显示为 0 或崩溃。
2. **`top -o power` 子进程开销：** 每 6 秒启动一次 `top` 进程，持续采样会累积进程创建开销。虽然单次不大，但对一个常驻菜单栏应用而言应谨慎。
3. **解析脆弱性：** `top` 输出格式可能随 macOS 版本变化，硬编码解析逻辑容易在未来系统升级后失效。

**建议：**
- 为 SMC 键值读取增加 fallback：若键不存在则隐藏对应能量流分支，或标注"不可用"。
- 考虑使用 `IOReport` 的能耗通道作为首选，SMC 作为 fallback（当前已因 M5 失效回退到 SMC，但需记录该决策）。
- 对 `top` 输出增加格式校验和错误日志，避免解析异常导致整个面板空白。

### 3.2 ProxyPortal（mihomo 代理面板）

**实现要点：**
- 读取 `127.0.0.1:9090` 的 `/configs`、`/proxies`、`/connections`
- 支持节点切换 `/proxies/{group}`
- 支持延迟测试
- 节点列表可折叠

**风险点：**
1. **硬编码地址与端口：** `127.0.0.1:9090` 是 mihomo 默认 REST API，但用户可能修改端口或启用认证。当前实现缺乏配置入口。
2. **缺乏认证：** mihomo 的 REST API 默认无认证，但若用户开启 `secret`，所有请求将失败，且 UI 不会明确提示原因。
3. **节点切换无二次确认：** 点击即可切换代理节点，可能误触导致网络中断。
4. **线程安全：** 代理数据和 UI 更新若在同一线程执行大量网络请求，可能阻塞主线程。

**建议：**
- 在设置中增加"代理控制器地址"和"Secret"配置项。
- 节点切换增加确认或撤销机制（例如短暂 toast + 撤销按钮）。
- 将网络请求移到后台线程，仅最终 UI 更新回主线程。

### 3.3 LauncherPortal（快速启动面板）

**实现要点：**
- 从 `Store.shared` 读取 `launcher_favorites`
- 横向排列应用图标
- 点击启动并关闭弹窗

**风险点：**
1. **任意应用启动：**  favorites 列表未校验目标路径是否为应用包，可能启动任意可执行文件。
2. **无沙箱声明：** 启动其他应用需要 `com.apple.security.automation.apple-events` 或 `LSUIElement` 相关权限，若 entitlements 未更新，在某些系统版本上会失败。

**建议：**
- 校验 favorites 项是否为 `.app`  bundle，并验证 bundle identifier。
- 检查 `Stats/Stats.entitlements` 是否包含必要的自动化权限。

### 3.4 世界时钟与 Clock 模块

`Modules/Clock/portal.swift` 和 `popup.swift` 新增了宽时钟 grid 布局、 intrinsicContentSize 修正以及单排时钟行 `ClockRow`。

**观察：**
- `ClockView` 的 `intrinsicContentSize` 修正有助于布局稳定性。
- 单排 `ClockRow` 在 overview 中占高更小，符合"紧凑总览"的目标。

---

## 4. 性能与资源占用

### 4.1 刷新频率

- `PowerFlowPortal` 每 2 秒刷新一次
- `MetricTilesGrid` 随模块数据更新刷新
- `ProxyPortal` 每次展开可能触发多次 REST 请求

**潜在问题：**
- 当 overview 未打开时，部分定时器仍在运行（需确认是否已做生命周期管理）。
- 高刷新率结合 Sankey 路径计算，可能增加 CPU 占用。

**建议：**
- 在 overview 关闭时暂停非必要刷新。
- 对 Sankey 路径计算结果做缓存，仅在底层数据变化时重算。

### 4.2 子进程开销

`top -o power` 每 6 秒启动一次。相比纯 IOKit/SMC 读取，子进程创建成本更高，且输出解析不可靠。

**建议：** 评估是否可用 `IOKit` 的进程能耗 API（如 `IOReport` 的 `ENERGY_MODEL` 相关通道）替代 `top`，或降低采样频率并提供设置项。

---

## 5. 安全与隐私

### 5.1 网络代理控制

`ProxyPortal` 能够切换用户网络代理节点。虽然目标是提升便利性，但也意味着：
- 恶意或误操作可导致网络流量路由变更
- 若未来支持远程 mihomo 地址，存在中间人攻击风险

**建议：** 所有代理 API 通信默认仅限 localhost，并明确提示用户该功能的影响。

### 5.2 应用启动

`LauncherPortal` 启动用户 favorites 中的应用，本身风险可控，但应确保 favorites 数据不被外部注入。

**建议：** 对 `Store.shared` 中的 `launcher_favorites` 做 schema 校验。

### 5.3 系统监控数据

读取 SMC、IOKit、电池信息属于系统监控应用的正常行为，符合用户预期。但应在隐私说明中提及数据仅用于本地展示，不上传。

---

## 6. 可维护性与上游兼容性

### 6.1 代码组织

- `CombinedView.swift` 体积明显增大，集成了多个子 portal 的创建、布局和刷新逻辑。
- 部分常量（如 `127.0.0.1:9090`、`launcher_favorites` key、刷新间隔）为硬编码。

**建议：**
- 将 `CombinedView` 拆分为更小的 coordinator，每个 portal 自包含。
- 将硬编码常量集中到 `Constants.swift` 或各 portal 的命名空间内。

### 6.2 测试覆盖

新增功能（尤其是 `ProxyPortal` 的 REST 交互和 `PowerFlowPortal` 的数据解析）目前没有对应的单元测试。

**建议：**
- 为 `PowerFlowPortal` 的 `top` 输出解析增加单元测试，使用固定输出样本。
- 为 `ProxyPortal` 的 JSON 解析增加测试用例。

### 6.3 本地化

新增 UI 文案已通过 `Localizable.strings` 进行中英文本地化，符合项目现有实践。

### 6.4 上游兼容性

- SMC 供电轨键值（`PP0b`、`PP1b` 等）是 Apple 未文档化的键，可能随硬件变化。
- `IOReport` 回退逻辑需要持续验证，尤其是新机型发布时。

**建议：** 在 `Modules/Sensors/values.swift` 中为这些键值添加注释，说明来源和已知适用机型。

---

## 7. 主要风险等级汇总

| 风险项 | 等级 | 说明 |
|--------|------|------|
| SMC 传感器键值缺失导致能量流显示异常 | 中 | 旧机型或未来机型可能无相关键值 |
| `top -o power` 解析随系统版本变化 | 中 | 输出格式非 API，可能失效 |
| ProxyPortal 硬编码 mihomo 地址/无认证 | 中 | 用户自定义配置时无法使用 |
| 代理节点切换无二次确认 | 低 | 可能误触 |
| CombinedView 体积过大 | 低 | 长期可维护性下降 |
| 刷新频率未根据面板生命周期调整 | 低 | 常驻后台可能浪费资源 |

---

## 8. 可执行建议

1. **短期（当前分支可完成）：**
   - 为 `PowerFlowPortal` 的 SMC 读取增加键值存在性校验和 fallback UI。
   - 将 `ProxyPortal` 的 `127.0.0.1:9090` 提取为可配置项，并支持 mihomo `secret`。
   - 节点切换增加简单确认或撤销提示。

2. **中期（合并前建议完成）：**
   - 为 `top` 输出解析和代理 JSON 解析补充单元测试。
   - 将 `CombinedView` 拆分为 coordinator，减少单文件职责。
   - 在 overview 隐藏时暂停非必要定时刷新。

3. **长期（持续跟踪）：**
   - 评估用 IOKit/IOReport 替代 `top` 采样。
   - 维护 SMC 键值与机型的对应关系文档。
   - 收集不同 Mac 机型上的能量流数据准确性反馈。

---

## 9. 结论

本次改动成功交付了单图标仪表盘的核心体验，架构方向（协议化快照 + 统一磁贴）是合理的，且保留了原有模块 portal 作为 fallback。主要风险集中在 **硬件相关的 SMC 键值适配**、**`top` 输出解析的脆弱性** 以及 **ProxyPortal 的硬编码配置**。建议在合并到主分支前完成上述短期和部分中期建议，以提升稳定性和可维护性。

该功能当前已编译为 Universal 二进制并安装到 `/Applications/Stats.app`，桌面安装包 `Stats-3.0.5-build3454-Universal.zip` 可用于同事分发。
