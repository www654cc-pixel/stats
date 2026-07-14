# Stats 二开全面审计报告

**审计范围：** `feature/single-icon-dashboard` 分支全部 8 个自定义提交（`9bc8ba01` → `5a5eace4`）  
**对比基线：** 上游 `v3.0.5`（`2fff0dfb`）  
**审计时间：** 2026-07-14  
**改动规模：** 26 文件，+2678 / −122 行，新增 4 个 Swift 文件（~1740 行）

---

## 一、改动全景

### 1.1 新增功能模块

| 文件 | 行数 | 功能 |
|------|------|------|
| `PowerFlowPortal.swift` | 765 | 能量流桑基图：电池/适配器 → CPU/GPU/Display/Others，含高耗能进程 |
| `ProxyPortal.swift` | 395 | mihomo 代理面板：节点状态、延迟测试、节点切换、实时流量 |
| `MetricTiles.swift` | 402 | 统一磁贴系统：CPU/GPU/RAM/Disk/Network/Sensors 六宫格 |
| `LauncherPortal.swift` | 175 | 快速启动面板：用户收藏应用图标横排 |

### 1.2 改动的上游文件

| 文件 | 改动 | 说明 |
|------|------|------|
| `CombinedView.swift` | +365 | 重构为单图标仪表盘 + overview popup 控制器 |
| `Kit/module/portal.swift` | +94 | 新增 `Combined*Portal` 协议族 + `PowerFlowReading`/`ClockReading` |
| `Modules/Clock/portal.swift` | ±169 | 宽 portal + NSGridView 多时区平铺 |
| `Modules/Sensors/portal.swift` | +50 | 暴露 `lastPowerFlow` 供电轨读数 |
| `Stats/Views/AppSettings.swift` | +76 | 单图标开关 + 启动器收藏管理 |
| 其余 5 个模块 portal | 各 +10~14 | 实现 `Combined*Portal` 协议暴露快照 |

### 1.3 架构方向评估

**合理之处：**
- 通过 `Combined*Portal` 协议族实现依赖倒置，overview 面板不直接链接模块内部类型。
- 统一 `MetricTile` 骨架消除了六套重复 UI 代码，扩展新模块成本低。
- 保留了原有 stock portal 作为 fallback，迁移风险低。
- `appear()/disappear()` 生命周期管理已接入（`Popup` 类 L393-409），popup 关闭时停止 power/proxy 定时器。

**结构性隐患：**
- `CombinedView.Popup` 承担了所有子 portal 的创建、布局、刷新协调，职责过重（接近 250 行）。
- 定时器分散在各子 portal 中，缺少统一的刷新调度器，难以做全局自适应频率。

---

## 二、性能审计（核心）

### 2.1 定时器全景

当 overview popup 打开时，同时运行 **4 个独立定时器**：

| 来源 | 间隔 | 触发内容 | 关闭时停止 |
|------|------|----------|-----------|
| `Popup.refreshTimer` | 1s | 6 个磁贴刷新 + 时钟行 | ✅ |
| `PowerFlowPortal.refreshTimer` | 2s | 电池读取 + SMC 读数 + 桑基图重绘 | ✅ |
| `ProxyPortal.speedTimer` | 2s | `/connections` HTTP 请求 | ✅ |
| `ProxyPortal.testTimer` | 30s | `/configs` + `/proxies` + N 个延迟测试 | ✅ |
| `CombinedView.powerTimer` | 2s | 菜单栏图标刷新 | ❌ **常驻运行** |

**问题 1：菜单栏图标定时器常驻不停止**

`CombinedView.setupSingleIconView()`（L150-153）启动的 `powerTimer` 在 `enable()` 时创建，**无论 popup 是否打开都每 2 秒运行**。当 popup 打开时，它与 `PowerFlowPortal` 的 2 秒定时器重复读取相同的电池/SMC 数据。

**问题 2：`top -o power` 子进程是最大 CPU 消耗源**

`PowerFlowPortal.readTopProcesses()`（L306-344）：
```
/usr/bin/top -o power -l 2 -n 3 -stats pid,command,power
```
- `-l 2` 让 top 运行两个采样周期。第一个是开机累计值（无用），第二个才是瞬时值。
- top 在采样期间**自身消耗 CPU** 遍历所有进程的 power 信息，在进程数多的系统上可达 3-8% CPU 持续 1-2 秒。
- `readDataToEndOfFile()` 阻塞直到 top 完成（可能 2-5 秒）。
- 虽然在后台线程执行（L290 `DispatchQueue.global(qos: .utility)`），但 top 进程本身的 CPU 开销无法避免。
- 频率：每 6 秒一次（`topTicker % 3 == 0`，2 秒定时器的第 3 个 tick）。

**这是整个二开改动中 CPU 占用最高的单项。** 对一个常驻菜单栏应用来说，持续每 6 秒 fork 一次 top 进程是不可接受的。

**问题 3：代理延迟测试并发爆炸**

`ProxyPortal.refreshState()`（L218）：
```swift
all.forEach { name in self.testDelay(name) }
```
每 30 秒对所有节点发起并发 HTTP 请求。如果用户有 50 个代理节点，就是 50 个并发 `URLSessionDataTask`，每个通过代理隧道请求 `gstatic.com/generate_204`。这不仅消耗 CPU（TLS 握手 + 代理隧道），还会短暂占用大量网络带宽。

**问题 4：桑基图每 2 秒完整重绘**

`PowerSankeyView.draw()`（L456-629）每次刷新执行：
- 4-6 条 `NSBezierPath` 曲线路径构建 + 渐变填充
- 3-5 个节点圆角矩形 + SF Symbol 渲染
- 多段 `NSAttributedString.draw()`

即使所有功率值与上次完全相同，仍会触发 `needsDisplay = true`（L190）导致完整重绘。

**问题 5：磁贴每秒全量刷新无 diff**

`MetricTilesGrid.refresh()`（L115-211）每秒读取 6 个 portal 的快照，执行字符串格式化（`Units.getReadableSpeed`、`DiskSize.getReadableMemory` 等），然后无条件写入 `NSTextField.stringValue`。AppKit 内部会做字符串比较，但格式化计算和颜色判断仍每秒执行 6 次。

### 2.2 性能优化建议

#### P0 — 必须修复（影响日常 CPU 占用）

**1. 移除 `top -o power`，改用原生 API**

方案 A（推荐）：使用 `libproc` 的 `proc_pidinfo` + `proc_pid_rusage` 获取每个进程的 CPU 时间，自行计算瞬时 CPU%，替代 power 排序：
```swift
// 用 proc_listallpids 获取进程列表
// 用 proc_pidinfo + PROC_PIDTASKINFO 获取 CPU 时间
// 两次采样差值 / 时间间隔 = 瞬时 CPU%
// 按 CPU% 排序取 top 3
```
- 优点：无子进程，纯 C API，开销极低（<0.1% CPU）
- 缺点：是 power 排序而非 CPU 排序，但对用户来说 "高 CPU 进程" 比 "高 power 进程" 更直观

方案 B：保留 top 但大幅降频 + 缓存：
- 频率从 6 秒改为 30 秒
- 在 popup 关闭时不运行
- 缓存上一次结果，popup 刚打开时先显示缓存值

**2. 菜单栏图标定时器接入 popup 生命周期**

当 popup 打开时暂停 `powerTimer`（PowerFlowPortal 已在刷新相同数据）；popup 关闭时恢复。或者让 `powerTimer` 直接复用 PowerFlowPortal 的 `lastPowerValue`（已有协议暴露），避免重复读取。

#### P1 — 建议修复

**3. 代理延迟测试改为惰性 + 增量**

- 每 30 秒只测试**当前节点**的延迟
- 其他节点在用户**展开列表时**才测试
- 测试结果缓存 5 分钟，避免重复请求
- 限制并发数（如最多 5 个同时）

**4. 桑基图增量重绘**

在 `PowerSankeyView` 中缓存上一次的 model 值，仅当任一功率值变化超过 0.2W 时才触发 `needsDisplay`：
```swift
set model(value) {
    if significantChange(oldValue, value) {
        _model = value
        needsDisplay = true
    }
}
```

**5. 磁贴刷新加 diff 短路**

在 `MetricTile.set()` 中缓存上一次的格式化字符串，仅当变化时才写入 `stringValue`：
```swift
func set(value: String, ...) {
    guard value != self.lastValue else { return }
    self.lastValue = value
    self.valueField.stringValue = value
    ...
}
```

#### P2 — 锦上添花

**6. 自适应刷新频率**

根据系统状态动态调整：
- 电池供电 + popup 打开：磁贴 2s，桑基图 3s
- 适配器供电 + 高负载：保持 1s/2s
- 系统空闲（CPU < 5%）：磁贴 3s，桑基图 5s
- popup 关闭：菜单栏图标 3s（而非 2s）

**7. 电池状态用通知替代轮询**

用 `IOPSNotificationCreateRunLoopSource` 注册电池变化回调，替代每 2 秒的 `IOPSCopyPowerSourcesInfo` 轮询。仅在状态变化时才读取详情。

**8. `recomputeHeight` 防抖**

多个 `onResize` 回调可能在同一周期内连续触发。用 `DispatchQueue.main.async` 合并：
```swift
private var recomputeScheduled = false
private func recomputeHeight() {
    guard !self.recomputeScheduled else { return }
    self.recomputeScheduled = true
    DispatchQueue.main.async {
        self.recomputeScheduled = false
        self.applySize(width: self.frame.width)
    }
}
```

---

## 三、代码质量审计

### 3.1 硬编码问题

| 位置 | 硬编码值 | 风险 |
|------|----------|------|
| `ProxyPortal` L16 | `127.0.0.1:9090` | 已改为 Store 可配置 ✅ |
| `ProxyPortal` L263 | `gstatic.com/generate_204` | 测试 URL 不可配置 |
| `PowerFlowPortal` L145 | `2` 秒刷新间隔 | 不可配置 |
| `PowerFlowPortal` L309 | `top -l 2` | 采样次数硬编码 |
| `MetricTiles.swift` L37 | 6 个模块 spec | 新增模块需改代码 |
| `MetricTile.swift` L109-113 | 阈值 60/85/75/92/80/95 | 不可配置 |

### 3.2 线程安全

**良好实践：**
- 所有 UI 更新通过 `DispatchQueue.main.async` 回主线程 ✅
- `top` 采样在后台线程执行 ✅
- `URLSession` 用 ephemeral 配置 ✅

**隐患：**
- `ProxyPortal.nodeRows` 字典在主线程读写，但 `testDelay` 的 completion 在后台线程准备数据后回主线程——正确。但 `detectGroup` 中的 `proxies.values.compactMap` 在 completion handler 线程执行，如果 proxies 很大会有短暂阻塞。
- `PowerFlowPortal.topIsRunning` 标志位跨线程访问无同步（L287-288 写，L294 回主线程后写）——实际可接受因为读写都在主线程或回主线程后。

### 3.3 错误处理

- `ProxyPortal` 网络请求失败时静默返回 nil，UI 不显示错误原因 ❌
  - 建议：区分"控制器不可达"和"节点不存在"，在 header 显示状态图标
- `PowerFlowPortal.readTopProcesses` 中 `task.run()` 失败返回空数组 ✅
- `LauncherPortal.appInfo` 校验文件存在性 ✅，但未校验是否为 .app bundle ❌

### 3.4 可维护性

- `CombinedView.Popup` 类内聚了 5 个子 portal 的生命周期管理，建议拆出 `OverviewCoordinator`。
- `PowerFlowPortal` 765 行偏长，`PowerSankeyView.draw()` 单方法 173 行，建议拆分为 `drawSources` / `drawConsumers` / `drawMacNode` 等子方法。
- 无单元测试覆盖新增功能 ❌

---

## 四、功能增强建议

### 4.1 与现有架构契合的高价值功能

**1. 汇率/多币种磁贴**

鉴于使用者覆盖俄罗斯、哈萨克斯坦、墨西哥、英国市场，在磁贴网格中新增一个 "FX" 磁贴，展示关键货币对（CNY/RUB、CNY/KZT、CNY/MXN、CNY/GBP）的实时汇率。数据源可用免费的公开 API（如 `exchangerate.host`），每小时刷新一次，CPU 开销可忽略。

实现成本：1 个新 `FxTile` + 1 个 `CombinedFxPortal` 协议（或直接在 overview 层内联），约 200 行。

**2. 日程/下一会议行**

在 ClockRow 下方增加一行 "下一个会议" 预览（通过 EventKit 读取日历，显示标题 + 距离开始时间）。对跨时区办公尤其有用。

**3. 剪贴板速查**

在 LauncherPortal 旁增加一个剪贴板历史按钮，点击展开最近 5 条文本/链接。纯本地存储，无隐私风险。

**4. 热节流状态指示**

在 CPU/GPU 磁贴上叠加一个小的火焰图标，当检测到热节流时点亮。数据可通过 `sysctl` 或 `IOReport` 的 thermal 通道获取。

**5. 网络延迟质量指示**

在 Network 磁贴中增加一个到可配置目标（默认 `8.8.8.8`）的 ping 延迟值，用颜色区分（绿<50ms / 橙<150ms / 红>150ms）。对通过代理上网的场景尤其有用——可以一眼看出代理是否影响延迟。

### 4.2 交互优化

**6. 磁贴长按快速操作**

- CPU 磁贴长按 → 弹出"结束高耗能进程"菜单
- RAM 磁贴长按 → "清理内存"（触发 purge 命令）
- Disk 磁贴长按 → "打开存储管理"

**7. 代理面板增强**

- 节点搜索框（节点多时快速过滤）
- 节点分组折叠（按地区/类型）
- 一键测速所有节点（手动触发，非自动）

**8. 能量流增强**

- 点击桑基图某条流 → 展开该组件的历史功耗折线
- 长按 → 截图分享当前能量流

### 4.3 性能监控自身

**9. Stats 自身资源占用磁贴**

在设置中开启一个开发模式磁贴，显示 Stats 进程自身的 CPU%、内存占用。方便用户验证优化效果。

---

## 五、优先级矩阵

| 建议 | 类型 | 影响 | 工作量 | 优先级 |
|------|------|------|--------|--------|
| 移除 `top`，改用 `libproc` | 性能 P0 | ⭐⭐⭐ | 中 | 🔴 立即 |
| 菜单栏定时器接入 popup 生命周期 | 性能 P0 | ⭐⭐ | 小 | 🔴 立即 |
| 代理延迟测试改惰性 | 性能 P1 | ⭐⭐ | 小 | 🟡 近期 |
| 桑基图增量重绘 | 性能 P1 | ⭐ | 小 | 🟡 近期 |
| 磁贴 diff 短路 | 性能 P1 | ⭐ | 小 | 🟡 近期 |
| 自适应刷新频率 | 性能 P2 | ⭐⭐ | 中 | 🟢 后续 |
| 电池通知替代轮询 | 性能 P2 | ⭐ | 中 | 🟢 后续 |
| 汇率磁贴 | 功能 | ⭐⭐⭐ | 中 | 🟡 近期 |
| 日程预览行 | 功能 | ⭐⭐ | 中 | 🟢 后续 |
| 网络延迟指示 | 功能 | ⭐⭐ | 小 | 🟡 近期 |
| 热节流指示 | 功能 | ⭐ | 小 | 🟢 后续 |
| 磁贴长按操作 | 交互 | ⭐⭐ | 中 | 🟢 后续 |
| 代理面板增强 | 交互 | ⭐⭐ | 中 | 🟢 后续 |

---

## 六、结论

本次二开成功交付了一个信息密度高、视觉统一的菜单栏仪表盘，架构方向（协议化快照 + 统一磁贴）是合理的。主要改进空间集中在**性能层面**：`top -o power` 子进程是 CPU 占用的首要来源，应优先用原生 `libproc` API 替代；其次应将菜单栏图标定时器接入 popup 生命周期，避免重复读取。功能层面，鉴于使用者的国际化金融背景，汇率磁贴和网络延迟指示是性价比最高的两个增强方向。

完成 P0 两项优化后，预计可将 popup 打开时的额外 CPU 占用从约 3-5% 降至 0.5% 以下，popup 关闭时常驻开销从约 1-2% 降至接近 0%。
