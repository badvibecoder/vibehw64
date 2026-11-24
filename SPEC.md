# SPEC.md — vibehw64

Specification of the **v1.1 build**: what it is, what it may and may not do, and the rules the
implementation follows. This document describes the shipped code, not a plan.

Version: `1.1.0` · 2026-11-24 · Target: Linux x86-64 desktops

---

## 1. Objective

A HWiNFO64-style **sensors window** for Linux, distributed as a single executable that runs
from any directory with no installation, no configuration file and no background service.

It presents a collapsible tree of hardware readings with **Current / Minimum / Maximum /
Average** and a reset control, covering CPU, DDR5/DDR4 memory, AMD GPU, storage, network and
the remaining board/peripheral `hwmon` sensors. It can also copy the current snapshot as
aligned text.

## 2. Hard constraints

| Constraint | Rule |
| --- | --- |
| Language | **Pure Odin** |
| UI dependency | **`vendor:raylib` only** — no GTK, Qt, CMake, SDL, or hand-written C bindings |
| Distribution | **One executable**, `bin/vibehw64` |
| Assets | Font **and icon** are embedded at compile time via `#load`; no runtime asset files |
| Config | **No config file** and no saved state; every launch starts fresh |
| Privilege | The app itself **never runs as root** and never requires `sudo` |
| Idle cost | Under 1% of one core at the default interval (design target) |
| Steady-state allocation | **Zero** heap allocation in the polling or drawing loop |

The binary still links the system graphics stack dynamically (`libGL`, `libX11`,
`libwayland-*`, `libxkbcommon`, `libc`). "Self-contained" means **no raylib, no Odin, no
assets, no config** — not "no shared libraries".

## 3. Language, toolchain, dependencies

- **Odin** `dev-2026-10` (any recent dev build should work).
- **raylib 6.0**, built **statically** by `scripts/build-raylib-static.sh` and installed into
  Odin's vendor tree.
  - Reason: the Odin bindings declare raylib `6.0.0` and link either `libraylib.so.600` or
    `libraylib.a`. Distros ship **6.2** (`libraylib.so.620`) and the vendor tree carries no
    x86-64 static archive, so a default build fails at link time.
  - Built from the `6.0` git tag with **both** `GLFW_LINUX_ENABLE_X11=TRUE` and
    `GLFW_LINUX_ENABLE_WAYLAND=TRUE`, so GLFW picks native Wayland when `WAYLAND_DISPLAY` is
    set and falls back to X11/XWayland otherwise.
- **Link flags** (see `build.sh`):
  `-define:RAYLIB_SHARED=false -extra-linker-flags:"-lGL -lm -lrt -lX11 -lXrandr -lXinerama
  -lXcursor -lXi -lXfixes -lwayland-client -lwayland-cursor -lwayland-egl -lxkbcommon"`.
- **Font**: DejaVu Sans Mono, vendored in `src/assets/` with its licence, embedded with
  `#load("assets/DejaVuSansMono.ttf")`.
- **Icon**: PNGs (16–256 px) plus the SVG source in `src/assets/`, embedded at compile time
  and passed to the window manager with `SetWindowIcons`. Native Wayland ignores runtime
  window icons; X11/XWayland shows them.

No other third-party libraries. `core:` and `vendor:` packages only.

## 4. Repository layout

```text
vibehw64/
├── README.md            user documentation
├── SPEC.md              this file
├── ARCHITECTURE.md      implementation deep-dive for future maintainers
├── RELEASE.md           release notes for the binary
├── build.sh             release build -> bin/vibehw64
├── bin/                 build output
├── docs/screenshot.jpg
├── src/
│   ├── main.odin        entry point, argument parsing, probe/snapshot output
│   ├── topology.odin    CPU topology: packages, groups, cores
│   ├── sensors_linux.odin  sensor model, discovery, registry, display helpers
│   ├── storage.odin     per-drive sections and memory identity/usage rows
│   ├── meminfo.odin     /proc/meminfo-backed memory usage metrics
│   ├── net.odin         per-NIC sections, Wi-Fi SSID/signal
│   ├── usage.odin       CPU utilisation from /proc/stat
│   ├── names.odin       CPU short names, pci.ids (incl. subsystem), SMBIOS, SPD decode
│   ├── perms.odin       in-app privilege setup (pkexec)
│   ├── sampler.odin     background sampling thread, snapshot, stats
│   ├── ui.odin          raylib window, tree, columns, scrollbar, banner, Copy, bands
│   └── assets/          embedded font, icon PNG/SVG, licences
├── tests/
│   └── run-fixtures.py  synthesized AMD/Intel/SMBIOS regression trees
└── scripts/
    ├── build-raylib-static.sh   one-time static raylib build (uses temp/)
    └── install-permissions.sh   manual equivalent of the in-app setup
```

`bin/` and `temp/` are build output/scratch, not source. `tests/run-fixtures.py` creates its
fixtures in a temporary directory and removes them after the run.

## 5. Data model

Fixed-capacity, statically allocated. No dynamic containers anywhere.

```text
MAX_SECTIONS 64   MAX_GROUPS 128   MAX_SENSORS 512   MAX_SOURCES 512
MAX_CPUS     256  MAX_CLASSES 8    MAX_LABEL   48    MAX_DIMMS   16
MAX_NET      8
```

- **Section** — a top-level collapsible row. **Four fixed sections** are created first, in
  `Section_Id` order: CPU, Memory, GPU, Voltages. Drives, NICs and the final
  **Other Sensors** section append dynamically. Other is deliberately last.
- **Group** — a collapsible subsection within a section. The structure is one group level:
  - CPU: `Package & Power`, `Thermal Headroom - Package`, `CPU Core Clocks - <class>`,
    `CPU Core Usage - <class>`, `CPU Core Temperatures - <class>`,
    `<class> - Distance from TjMax (<limit> C)`, `<class> - Distance from Tcontrol (<limit> C)`.
  - Memory: `Usage`, `Modules`, `Temperatures`.
  - GPU: `GPU`; Voltages: `Voltages`; Other: `Temperatures`, `Fans`.
  - Drives: `Drive`; NICs: `Link`.
  - A section with exactly one non-empty group renders its rows directly; empty groups are
    skipped.
- **Sensor_Source** — one pre-opened file descriptor plus parse kind, scale, and RAPL
  baseline. `NO_SOURCE` marks computed metrics that have no file descriptor.
- **Sensor_Metric** — label, unit, class, group, source index, and statistics. Derived rows
  also carry `derived_from` (the source metric) and `limit` (the TjMax/Tcontrol value).
- Long labels are capped at **48** bytes. CPU/GPU/memory identity strings live in `App`.

**Statistics rule:** average is **time-weighted** (`Σ value·dt / Σ dt`), not a plain mean.
The interval is user-editable, so a plain mean would be silently skewed by a rate change.
Reset sets `min = max = cur`, zeroes the accumulators, and drops RAPL baselines so power
min/max cannot span the reset boundary.

## 6. CPU topology

Groups are discovered, never hard-coded. No assumption about core counts, 6/8-core CCDs, or
any specific SKU.

**Model:** Package → Group → Physical core.

1. **Intel hybrid** — `/sys/devices/cpu_core/cpus` and `/sys/devices/cpu_atom/cpus` are used
   as authoritative P/E masks (hybrid PMU cpumasks, kernel ≥ 5.16).
2. **Fallback** — cluster cores by `cpufreq/cpuinfo_max_freq`. Two or more distinct tiers are
   required; the lowest tier becomes `E`, the rest `P`. A single tier produces one
   `All Cores` group. Absolute frequency thresholds MUST NOT be used.
3. **AMD CCD** — group by `cache/index3/shared_cpu_list`; every core in a CCD shares that L3
   domain. A group whose `index3/size` exceeds its siblings' is tagged `[3D]`.
   `topology/core_id` restarts per CCD and MUST NOT be used as a global key.
4. **SMT** — collapse `topology/thread_siblings_list`; one row per physical core.
5. **Core identity** — `coretemp` labels are package core IDs, not Linux CPU indices, and are
   non-contiguous. Temperature rows are joined to CPUs through `topology/core_id`.
   The mapping MUST be validated at init (the multiset of `Core N` suffixes must equal the
   multiset of discovered `core_id`s); on mismatch, raw labels are shown untagged rather than
   guessed.

All CPU sensor groups live under the single CPU section; the old top-level clocks/usage/
temperatures/thermal sections were folded into it.

## 7. Sensor sources

| Family | Source | Notes |
| --- | --- | --- |
| Core clocks | `cpuN/cpufreq/scaling_cur_freq` (kHz) | `cpuinfo_max_freq` read once for grouping |
| Package/core temps | `hwmon` `name == coretemp` | package found by `Package id N` label, not index |
| TjMax/Tcontrol | `coretemp` `tempN_crit` / `tempN_max` | package + per-core; distances derived from the live temp |
| Power | `powercap` `intel-rapl` (preferred) | `intel-rapl-mmio` only if the MSR tree is absent — both mirror the same counters |
| PL1/PL2 + windows | `powercap` `constraint_N_name/power_limit_uw/time_window_us` | matched by `long_term`/`short_term`, not index |
| Memory usage | `/proc/meminfo` | `MemTotal/MemAvailable`, commit, swap; read once per sample |
| Memory identity | SMBIOS type 17 | configured speed preferred, size/locator for per-DIMM, configured voltage |
| DIMM temps | `hwmon` `spd5118` / `jc42` | labelled from the i2c address, e.g. `DIMM #0 (0x51)` |
| GPU | `hwmon` `amdgpu` + `drm/cardN/device/*` | `card0` is not assumed; VRAM used/total from the DRM node |
| CPU usage | `/proc/stat` | deltas; per core and aggregate |
| Drives | `/sys/class/nvme`, `/sys/class/block`, `hwmon nvme`, `statfs` | NVMe temps matched by hwmon device basename |
| NICs | `/proc/net/dev`, `/sys/class/net/*/speed` | non-physical interfaces skipped |
| Wi-Fi | `SIOCGIWESSID` ioctl, `/proc/net/wireless` | wext emulation via `CONFIG_CFG80211_WEXT` |
| Other sensors | unclaimed `hwmon` `temp*_input` / `fan*_input` | ACPI zones, NIC/Wi-Fi/board temps and fans |
| Names | `/proc/cpuinfo`, `pci.ids`, SMBIOS, SPD | see §8 |

**RAPL:** `Watts = Δenergy_uj / (Δt · 10⁶)`, with `max_energy_range_uj` added on wrap. First
sample yields no value — the row shows `--` until a second reading exists.

**PL1/PL2 and TAU:** limits are read once and published as static rows; time windows are
auto-scaled to seconds or milliseconds. They are BIOS/EC policy, not measured power.

**Derived rows:** TjMax/Tcontrol distance metrics are computed from an already-sampled
temperature metric (`derived_from`) and a static `limit`; no extra file descriptor per core.

**Reading discipline:** descriptors are opened once at discovery. Polling is
`seek(fd, 0)` + `read` into fixed stack buffers. No directory walk and no allocation in the
loop. `/proc/meminfo` is one fd read per tick, like `/proc/stat`.

## 8. Naming

- **CPU** — the brand string is the only source. A fixed list of literal vendor decorations
  is stripped (`Intel(R) `, `Core(TM) `, `(R)`, `(TM)`, `AMD `, ` CPU`, ` Processor`) plus any
  token ending in `-Core`. If stripping leaves nothing, the full brand string is used.
  No per-SKU table, no regex.
- **GPU** — `/usr/share/hwdata/pci.ids` keyed by PCI vendor:device; the subsystem
  vendor:device is preferred when present, so an AIB entry such as
  `Nitro+ Radeon RX 570/580/590` replaces the generic family list. Falls back to
  vendor:device, then to no suffix.
- **Memory** — SMBIOS configured speed and part number; `XMP/EXPO` appended when configured
  speed exceeds the SPD JEDEC bin. The section is `Memory`, or `Memory (DDR5 SPD)` only when
  an SPD5 EEPROM was actually decoded.
- **SMBIOS nominal voltage** — the type 17 configured-voltage field is firmware nominal data,
  not a live VDIMM measurement. The row is labelled `SMBIOS Nominal Voltage`.
- Section titles read `CPU - Ultra 7 270K Plus`,
  `Memory - 6000MT  F5-6000J3636F16G  XMP/EXPO`,
  `GPU (AMD) - Nitro+ Radeon RX 570/580/590`.

## 9. UI

- Dark theme, resizable, default `760 × 820`, minimum `640 × 480`.
- **10 FPS** (`SetTargetFPS(10)`). When minimised the frame clock is kept alive but no
  formatting or drawing occurs.
- **Toolbar:** `Reset Min/Max`, an `Interval [1500] ms` field, and a right-aligned **Copy**
  button. No summary readout — every value already appears in the tree.
- **Copy:** builds an aligned plain-text snapshot from the UI snapshot (all sections, groups
  and rows regardless of collapse state), places it on the clipboard via
  `SetClipboardText`, and flashes `Copied`. The same formatter backs `--snapshot`.
- **Columns:** `Sensor | Current | Minimum | Maximum | Average | Unit`. Drag a divider to
  resize (7 px grab zone, resize cursor, highlighted line); **double-click a divider to
  auto-fit** the column to its widest rendered row (minimum 44 px). Widths persist for the
  session; growing the window widens the Sensor column by the delta.
- **Scrollbar:** dedicated 13 px strip on the right, outside the table. Proportional thumb,
  draggable, track click jumps. Table and hit-testing stop at the strip's left edge.
- **Temperature bands:** measured Celsius cells are evaluated independently. Below 60 C the
  normal row colours apply. 60.0–69.9 C is a green box with white text; 70.0–79.9 C orange;
  80.0 C+ red. Distance rows, `TjMax`/`Tcontrol` limit rows and non-Celsius values are
  excluded.
- **Distance colours:** the TjMax distance text uses the equivalent 85/95 C thresholds; the
  Tcontrol distance goes amber within 5 C of Tcontrol and red at/above it. The static limit
  rows are uncoloured.
- **Input:** interval field accepts digits only, Enter commits, Esc reverts, clamped
  `100..10000`. `R` resets only when the field is unfocused.
- **Numbers** are right-aligned with per-unit precision (`MHz` 0, `C` 1, `W` 2, `RPM` 0,
  `%` 0, `mV` 0, `V` 3, `MT/s` 0, drive `GB` 0, `TB` 1, RAM `GB` 2, seconds/ms 2, `dBm` 0).
  Unseen or stale shows `--`. Odin's `fmt` zero-pads numeric widths, so padding is manual.

## 10. Permissions

Two kernel interfaces are root-only and must be opened for full function:

| Interface | Mechanism | Why not the obvious one |
| --- | --- | --- |
| `powercap/*/energy_uj` | udev rule with `RUN+=/bin/chmod 0444` | it is a sysfs *attribute*; `MODE=` cannot reach it |
| `/sys/firmware/dmi/tables/DMI` | oneshot systemd unit at boot | nothing under `/sys/firmware/dmi` has a uevent or subsystem, so udev cannot match it |

Files written:

```
/etc/udev/rules.d/99-vibehw64-power.rules
/etc/systemd/system/vibehw64-dmi-perms.service
```

**In-app setup (`perms.odin`):** the app spawns

```
pkexec /bin/sh -c "<fixed script>"
```

- The user's password is handled by **polkit**, never by the application.
- The rule and unit contents are compiled into the binary and **base64-encoded** in the
  script, so no escaping is needed and no user input reaches a shell.
- Runs on a **worker thread** so the window stays responsive.
- On success the **sampler thread** reopens the power descriptors and re-reads SMBIOS, then
  the UI rebuilds section titles. No restart.
- Failure (cancelled, declined, no polkit agent, missing `pkexec`) leaves the banner in a
  retry state and changes nothing.

`scripts/install-permissions.sh` performs the identical operation for headless or scripted
use, and supports `--uninstall`. It also removes rule/unit files from before the app rename.

## 11. Build and tests

```sh
sudo scripts/build-raylib-static.sh   # once: builds + installs libraylib.a; clones into temp/
./build.sh                            # -> bin/vibehw64
python3 tests/run-fixtures.py         # AMD CCD/[3D], Intel fallback, synthetic SMBIOS
```

`build.sh` links statically against raylib and produces a binary with **no `libraylib`
dependency**. The fixture script synthesizes sysfs trees and a small DMI table, runs
`--probe --sys-root` against them, and exits non-zero on a missing expected group/row.

## 12. Non-goals for v1.1

NVIDIA GPUs · SMART attributes and `smartctl` · **fan control** (monitoring is implemented
where `hwmon` exposes it) · board sensors not exposed by a bound `hwmon` driver · XMP/EXPO timing decode · CPU core voltage (needs MSR or a bound Super I/O driver) ·
per-thread rows · multi-socket UI · saved window/section state · graphs, history, logging,
alerts · non-Linux platforms.

## 13. Verification matrix

| Area | Verified how |
| --- | --- |
| CPU topology (Intel non-hybrid) | live, i9-10850K, 10C/20T, one `All Cores` group |
| CPU topology (AMD CCD, `[3D]`) | `tests/run-fixtures.py` (16C/32T, two CCDs, 96 MB vs 32 MB L3) |
| CPU topology (Intel frequency fallback) | `tests/run-fixtures.py` (6 P + 4 E, no PMU masks) |
| SMBIOS walker / per-DIMM | synthetic DMI blob in `tests/run-fixtures.py` (2 × 16 GB, 6000 MT/s) |
| `coretemp` ↔ core mapping | live, all 10 physical cores attributed |
| PL1/PL2 + TAU | live, 75 W / 115 W, 47.97 s / 2.44 ms |
| TjMax/Tcontrol distances | live, package and all cores sum correctly to 100.0 / 84.0 C |
| Memory usage | live, installed 64.00 / usable 62.66 GB, sums reconcile |
| Per-DIMM capacity/speed | live, 2 × 32.00 GB, 4000 MT/s |
| VRAM used/total | live, matches DRM sysfs bytes |
| Copy / `--snapshot` | output generated and inspected; same formatter as the button |
| Temperature band thresholds | boundary check 59.9/60/69.9/70/79.9/80/100 C |
| Drives | live, NVMe + 16 TB HDD capacity/usage |
| NICs | live, 1000 Mb/s link + utilisation |
| Wi-Fi SSID | **not verified while associated** — radio was down/absent during development |
| Wi-Fi temperature | may show `--` until the driver reports a value |
| Self-heal (pkexec) | verified previously on the reference host; not re-run here |
| Steady-state cost | v1.0 measured 0.5% of one core / 4.6 MB; **not re-profiled for v1.1** |
