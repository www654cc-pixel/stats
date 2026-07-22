# Combined Dashboard

This fork collapses Stats into one menu bar icon and presents the enabled modules
as a single, glanceable macOS dashboard. It is tuned for an Apple Silicon M5 Mac
running macOS 27 in Simplified Chinese.

## Information architecture

The popup is approximately 972 points wide and follows a three-column rhythm:

- The top metric strip summarizes live system power, CPU load, memory pressure,
  and temperature.
- The hero power-flow card explains where energy comes from and where it goes.
  Activity Monitor and Settings actions are integrated into this card so the
  upper-left region is useful rather than decorative whitespace.
- Calendar always renders a complete six-week month and keeps Today visible.
- Quota and world clocks are grouped as compact utility portals.
- Proxy and launcher share the bottom row at a 62:38 ratio.

## Liquid Glass language

The root popup is a transparent, borderless window. It deliberately has no outer
glass sheet, stroke, or white frame. This lets the individual surfaces read as
independent pieces of native glass instead of cards nested inside a large card.

Primary data surfaces use the system `.regular` glass material for legibility and
depth. Lightweight interaction surfaces such as proxy controls and launcher items
use `.clear` glass. System-provided glass is preferred to hand-painted gradients:
it participates in the compositor's current Liquid Glass treatment and responds
to the desktop behind the panel. Fixed radii establish hierarchy:

- 22 pt for metric and compact utility cards.
- 28 pt for the hero power-flow and calendar cards.
- 20 pt for embedded toolbars and controls.

Typography uses semantic system fonts, restrained weights, tabular digits for
telemetry, and secondary-label colors for metadata. Avoid stacking translucent
containers; a portal should normally have one glass boundary.

## Data flow

Cross-module readings enter the Stats application target through protocols in
`Kit/module/portal.swift`:

- `CombinedCPUPortal`
- `CombinedRAMPortal`
- `CombinedSensorsPortal`
- `PowerFlowReading`

The app target does not link the SMC framework. Sensor and power values must flow
through the Sensors module portal rather than reading SMC directly from a view.

On the M5 machine, IOReport Energy Model millijoule channels are inactive. The
power-flow view therefore falls back to measured SMC rails when an IOReport value
is below 0.05 W: `PP0b` for CPU, `PP1b` for GPU, and `PBLR` for the display. Battery
power is derived from signed IOKit amperage multiplied by voltage. The panel also
supports three source layouts: charging, battery-only, and battery assist when the
adapter cannot cover the current load.

## Portals

- Calendar: full six-week grid with locale-aware labels and stable Today state.
- Quota: account usage snapshots exposed by the Quota module.
- Proxy: mihomo API at `127.0.0.1:9090`, including node switch, latency, and live
  throughput; hidden when the service is unreachable.
- Launcher: user-selected application shortcuts.

All user-facing strings must pass through `localizedString()` and be added to at
least the English and Simplified Chinese localization files.

## Build and install

This machine uses ad-hoc signing because no Apple Developer identity is available:

```bash
xcodebuild build -project Stats.xcodeproj -scheme Stats -configuration Release \
  -derivedDataPath /tmp/StatsRelease \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES
osascript -e 'quit app "Stats"'
rm -rf /Applications/Stats.app
cp -R /tmp/StatsRelease/Build/Products/Release/Stats.app /Applications/Stats.app
rm -rf /Applications/Stats.app/Contents/PlugIns/WidgetsExtension.appex
codesign --force --deep --sign - /Applications/Stats.app
open /Applications/Stats.app
```

The Widgets extension is removed because Team-ID library validation crashes under
ad-hoc signing. The built-in updater should remain set to Never so an official
release does not overwrite the fork.

For a build-only check, use Debug with `CODE_SIGNING_ALLOWED=NO` and
`CODE_SIGNING_REQUIRED=NO`.

## Launch at login

The Settings toggle and command-line maintenance switch both use
`SMAppService.mainApp`; changing defaults alone does not register a login item.
After installing the signed app, enable it from the app's own bundle context:

```bash
osascript -e 'quit app "Stats"'
/Applications/Stats.app/Contents/MacOS/Stats --enable-launch-at-login \
  >/tmp/stats-launch.log 2>&1 &
```

Disable with `--disable-launch-at-login`. Confirm the actual system registration:

```bash
sfltool dumpbtm | rg -A12 -B4 'eu\.exelban\.Stats|/Applications/Stats\.app'
```

## Verification checklist

1. Run `git diff --check`.
2. Complete a Debug build with signing disabled.
3. Complete the Release build, remove the widget extension, and ad-hoc sign.
4. Run `codesign --verify --deep --strict /Applications/Stats.app`.
5. Open the combined popup and visually check the borderless root, six-week
   calendar, portal spacing, typography, and both light and dark desktop areas.
6. Verify launch-at-login registration with `sfltool dumpbtm`.
