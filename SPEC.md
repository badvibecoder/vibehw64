# SPEC.md — vibehw64

Specification of the **v1.0 build**: what it is, what it may and may not do, and the rules the
implementation follows. This document describes the shipped code, not a plan.

Version: `1.0.0` · Target: Linux x86-64 desktops

---

## 1. Objective

A HWiNFO64-style **sensors window** for Linux, distributed as a single executable that runs
from any directory with no installation, no configuration file and no background service.

It presents a collapsible tree of hardware readings with **Current / Minimum / Maximum /
Average** and a reset control, covering CPU, DDR5 memory, AMD GPU, storage and network.

## 2. Hard constraints

| Constraint | Rule |
| --- | --- |
| Language | **Pure Odin** |
| UI dependency | **`vendor:raylib` only** — no GTK, Qt, CMake, SDL, or hand-written C bindings |
| Distribution | **One executable**, `bin/vibehw64` |
| Assets | Font is **embedded at compile time** via `#load`; no runtime asset files |
| Config | **No config file** and no saved state; every launch starts fresh |
| Privilege | The app itself **never runs as root** and never requires `sudo` |
| Idle cost | Under 1% of one core at the default interval |
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

No other third-party libraries. `core:` and `vendor:` packages only.

## 4. Repository layout

```text
vibehw64/
├── README.md            user documentation
├── SPEC.md              this file
├── ARCHITECTURE.md      implementation deep-dive for future maintainers
├── RELEASE.md           release notes for the binary
├── build.sh             release build -> bin/vibehw64
├── .gitignore           bin/, ARCHIVE/, temp/, *.o
├── bin/                 build output (gitignored)
├── docs/screenshot.jpg
├── src/
│   ├── main.odin        entry point, argument parsing, probe output
│   ├── topology.odin    CPU topology: packages, groups, cores
│   ├── sensors_linux.odin  sensor model, discovery, registry, display helpers
│   ├── storage.odin     per-drive sections and memory identity rows
│   ├── net.odin         per-NIC sections, Wi-Fi SSID/signal
│   ├── usage.odin       CPU utilisation from /proc/stat
│   ├── names.odin       CPU short names, pci.ids lookup, SMBIOS, SPD decode
│   ├── perms.odin       in-app privilege setup (pkexec)
│   ├── sampler.odin     background sampling thread, snapshot, stats
│   ├── ui.odin          raylib window, tree, columns, scrollbar, banner
│   └── assets/          embedded font + licence
└── scripts/
    ├── build-raylib-static.sh   one-time static raylib build
    └── install-permissions.sh   manual equivalent of the in-app setup
```

`ARCHIVE/` is development scratch and is excluded from the repository.

## 5. Data model

Fixed-capacity, statically allocated. No dynamic containers anywhere.

```text
MAX_SECTIONS 24   MAX_GROUPS 16    MAX_SENSORS 512    MAX_SOURCES 512
MAX_CPUS     256  MAX_LABEL  40
```

- **Section** — a top-level collapsible row. Seven fixed sections are created first, in
  `Section_Id` order; drives and NICs append further sections dynamically.
- **Group** — a collapsible sub-area within a section (`P-Cores`, `E-Cores`, `CCD 0`, …).
  A section with exactly one group renders its rows directly with no redundant sub-header.
- **Sensor_Source** — one pre-opened file descriptor plus parse kind, scale, and RAPL
  baseline. `NO_SOURCE` marks computed metrics that have no file descriptor.
- **Sensor_Metric** — label, unit, class, group, source index, and the statistics.

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

## 7. Sensor sources

| Family | Source | Notes |
| --- | --- | --- |
| Core clocks | `cpuN/cpufreq/scaling_cur_freq` (kHz) | `cpuinfo_max_freq` read once for grouping |
| Package/core temps | `hwmon` `name == coretemp` | package found by `Package id N` label, not index |
| Power | `powercap` `intel-rapl` (preferred) | `intel-rapl-mmio` only if the MSR tree is absent — both mirror the same counters |
| DIMM temps | `hwmon` `spd5118` / `jc42` | labelled from the i2c address, e.g. `DIMM #0 (0x51)` |
| GPU | `hwmon` `amdgpu` + `drm/cardN/device/gpu_busy_percent` | `card0` is not assumed |
| CPU usage | `/proc/stat` | deltas; per core and aggregate |
| Drives | `/sys/class/nvme`, `/sys/class/block`, `hwmon nvme`, `statfs` | NVMe temps matched by hwmon device basename |
| NICs | `/proc/net/dev`, `/sys/class/net/*/speed` | non-physical interfaces skipped |
| Wi-Fi | `SIOCGIWESSID` ioctl, `/proc/net/wireless` | wext emulation via `CONFIG_CFG80211_WEXT` |
| Memory identity | SMBIOS type 17 | configured speed (`0x20`) preferred, else rated (`0x15`); configured voltage `0x26` |
| Names | `/proc/cpuinfo`, `pci.ids`, SMBIOS, SPD | see §8 |

**RAPL:** `Watts = Δenergy_uj / (Δt · 10⁶)`, with `max_energy_range_uj` added on wrap. First
sample yields no value — the row shows `--` until a second reading exists.

**Reading discipline:** descriptors are opened once at discovery. Polling is
`seek(fd, 0)` + `read` into fixed stack buffers. No directory walk and no allocation in the
loop.

## 8. Naming

- **CPU** — the brand string is the only source. A fixed list of literal vendor decorations
  is stripped (`Intel(R) `, `Core(TM) `, `(R)`, `(TM)`, `AMD `, ` CPU`, ` Processor`) plus any
  token ending in `-Core`. If stripping leaves nothing, the full brand string is used.
  No per-SKU table, no regex.
- **GPU** — `/usr/share/hwdata/pci.ids` keyed by PCI vendor:device; the bracketed marketing
  name is preferred. Streamed in 64 KB chunks. Absent file means no suffix.
- **Memory** — SMBIOS configured speed and part number; `XMP/EXPO` appended to the section
  title when configured speed exceeds the SPD JEDEC bin.
- Section titles read `CPU Core Clocks - Ultra 7 270K Plus`,
  `Memory (DDR5 SPD) - 6000MT  F5-6000J3636F16G  XMP/EXPO`.

## 9. UI

- Dark theme, resizable, default `760 × 820`, minimum `640 × 480`.
- **10 FPS** (`SetTargetFPS(10)`). When minimised the frame clock is kept alive but no
  formatting or drawing occurs.
- **Toolbar:** `Reset Min/Max` button and an `Interval [1500] ms` field. No summary readout —
  every value already appears in the tree.
- **Columns:** `Sensor | Current | Minimum | Maximum | Average | Unit`. Drag a divider to
  resize (7 px grab zone, resize cursor, highlighted line); **double-click a divider to
  auto-fit** the column to its widest rendered row (minimum 44 px). Widths persist for the
  session; growing the window widens the Sensor column by the delta.
- **Scrollbar:** dedicated 13 px strip on the right, outside the table. Proportional thumb,
  draggable, track click jumps. Table and hit-testing stop at the strip's left edge.
- **Colour thresholds** are per sensor class, gated on Celsius so clocks do not trip them:

  | Class | Amber | Red |
  | --- | --- | --- |
  | CPU package / core | ≥ 85 | ≥ 95 |
  | DIMM | ≥ 65 | ≥ 75 |
  | GPU edge | ≥ 80 | ≥ 90 |
  | GPU junction | ≥ 95 | ≥ 105 |
  | GPU memory | ≥ 85 | ≥ 95 |
  | Drive | ≥ 70 | ≥ 80 |

- **Input:** interval field accepts digits only, Enter commits, Esc reverts, clamped
  `100..10000`. `R` resets only when the field is unfocused.
- **Numbers** are right-aligned with per-unit precision (`MHz` 0, `°C` 1, `W` 2, `RPM` 0,
  `%` 0, `mV` 0, `V` 3, `MT/s` 0, `GB` 0, `TB` 1, `dBm` 0). Unseen or stale shows `--`.
  Odin's `fmt` zero-pads numeric widths, so padding is done manually.

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

## 11. Build

```sh
sudo scripts/build-raylib-static.sh   # once: builds + installs libraylib.a
./build.sh                            # -> bin/vibehw64
```

`build.sh` links statically against raylib and produces a binary with **no `libraylib`
dependency**.

## 12. Non-goals for v1.0

NVIDIA GPUs · SMART attributes and `smartctl` · fan speeds · motherboard/ambient sensors ·
XMP/EXPO timing decode · CPU core voltage (needs MSR or a bound Super I/O driver) · per-thread
rows · multi-socket UI · saved window/section state · graphs, history, logging, alerts ·
non-Linux platforms.

## 13. Verification matrix

| Area | Verified how |
| --- | --- |
| CPU topology (Intel hybrid) | live on Core Ultra 7 270K Plus, 8P + 16E |
| CPU topology (AMD CCD, `[3D]`) | synthetic sysfs fixture via `--sys-root` |
| CPU topology (frequency fallback) | synthetic 12600K-shaped fixture |
| `coretemp` ↔ core mapping | live, all 24 cores attributed |
| Power | live, 40.3 W package / 26.5 W IA under load |
| Memory speed/voltage | live, matches `dmidecode` (6000 MT/s, 1350 mV) |
| Drives | live, NVMe 3 sensors + capacity/usage; 16 TB HDD capacity |
| NICs | live, 1000 Mb/s link + utilisation |
| Wi-Fi SSID | **not verified while associated** — radio was down during development |
| Self-heal (pkexec) | verified end-to-end by the maintainer on the reference host |
| Steady-state CPU | 0.5% of one core at 10 Hz sampling, 4.6 MB RSS |
