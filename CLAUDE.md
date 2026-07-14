# CLAUDE.md

Personal fork of [exelban/stats](https://github.com/exelban/stats) (macOS menu bar
system monitor). Custom work lives on branch `feature/single-icon-dashboard`,
rebased/re-applied on top of upstream releases (last base: v3.0.5). The user runs
this build daily on an Apple Silicon M5 MacBook, macOS 27, system language zh-Hans.

## Custom features (not in upstream)

All are part of the "Combined modules" single-icon dashboard: the menu bar collapses
to one icon (`CombinedModules_icon` store key) showing live system power; clicking it
opens a wide overview panel (`Popup` in `Stats/Views/CombinedView.swift`).

- **Overview panel** (`Stats/Views/CombinedView.swift`): summary tiles (power / CPU /
  memory pressure / temperature), module portals in a 2–3 column grid, wide cards below.
- **Power-flow sankey card** (`Stats/Views/PowerFlowPortal.swift`): adapter/battery →
  Mac → CPU/GPU/Display/Others energy-flow diagram with battery level bar, charge
  status + health chips, and top-3 CPU-consuming processes (via libproc
  `proc_pid_rusage`, not `top`). Three
  layouts: charging, on battery, battery-assist (adapter can't keep up). Custom
  drawing in `PowerSankeyView` (flipped coords, bezier ribbons).
- **Proxy panel** (`Stats/Views/ProxyPortal.swift`): mihomo REST API at
  `127.0.0.1:9090`, node switching, latency, live speed. Auto-hides when unreachable.
- **Launcher panel** (`Stats/Views/LauncherPortal.swift`): user-selected app shortcuts.
- **Cross-module snapshots**: modules expose latest values to the Stats app target via
  protocols in `Kit/module/portal.swift` (`CombinedCPUPortal`, `CombinedRAMPortal`,
  `CombinedSensorsPortal` + `PowerFlowReading`). The Stats app target does NOT link
  the SMC framework — SMC data must flow through the Sensors module portal.

## M5 / macOS 27 hardware quirks (measured on this machine)

- **IOReport "Energy Model" mJ channels are dead** (`CPU Energy`, `ECPU`, `PCPU`,
  `ANE`, `DRAM`, …): delta is 0 even under load. Only the nJ `GPU Energy` channel is
  live. Upstream's "CPU Power" sensor therefore reads 0 W on M5.
- **Workaround**: SMC supply rails, added as sensors in `Modules/Sensors/values.swift`:
  `PP0b` = CPU cluster rail ("CPU Rail"), `PP1b` = GPU rail ("GPU Rail"), `PBLR` =
  display backlight ("Display"). `PowerFlowPortal` falls back to the rail when the
  IOReport reading is < 0.05 W. `PHPC` ≈ whole compute complex (CPU+GPU+uncore) — too
  coarse for attribution. `PSTR` = system total, `PDTR` = DC-in (often reads 0).
- Battery: signed charge/discharge watts come from IOKit `Amperage` × `Voltage`
  (`PPBR`'s sign is unreliable). Health = `BatteryData.NominalChargeCapacity /
  DesignCapacity` (`AppleRawMaxCapacity` does not exist on M5). Charge-limit SMC keys
  (`CHWA`/`CH0B`/`CH0C`/`BCLM`) do not exist on M5 — charge control would need a
  privileged helper; deliberately not implemented.

## Build & install (no Apple Developer identity — ad-hoc signing)

```bash
xcodebuild build -project Stats.xcodeproj -scheme Stats -configuration Release \
  -derivedDataPath /tmp/StatsRelease \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES
osascript -e 'quit app "Stats"'
rm -rf /Applications/Stats.app
cp -R /tmp/StatsRelease/Build/Products/Release/Stats.app /Applications/Stats.app
# WidgetsExtension crashes under ad-hoc signing (Team-ID library validation) — remove it:
rm -rf /Applications/Stats.app/Contents/PlugIns/WidgetsExtension.appex
codesign --force --deep --sign - /Applications/Stats.app
open /Applications/Stats.app
```

Build-only check: same command with `-configuration Debug CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO`. The built-in updater is disabled on this machine
(`update-interval = Never`) because an official update would overwrite the fork.

## Conventions

- Commit style: conventional (`feat:`, `fix(Module):`), English.
- New source files must be registered in `Stats.xcodeproj/project.pbxproj` (follow the
  `ProxyPortal.swift` entries as a template for the four required sections).
- User-facing strings go through `localizedString()`; add keys to at least
  `en.lproj` and `zh-Hans.lproj` `Localizable.strings` (the user sees zh-Hans).
