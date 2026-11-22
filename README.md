# vibehw64

A lightweight, HWiNFO64-style **hardware sensor monitor for Linux** — one self-contained
binary, no installer, no config files, no background service.

![vibehw64](docs/screenshot.jpg)

---

## What it is

vibehw64 is the "Sensors window" half of HWiNFO64, rebuilt for Linux. It shows live readings
from your CPU, memory, GPU, drives and network interfaces in a collapsible tree, with
**Current / Minimum / Maximum / Average** for every sensor and a one-key reset.

It is deliberately small: ~2 MB, a single executable, and a handful of `sysfs` reads every
1.5 seconds. At the default interval it costs well under 1% of one CPU core and about 5 MB
of RAM.

## Requirements

- **Linux x86-64**
- **glibc ≥ 2.44** — this binary is built against a current Arch/Garuda toolchain
- The usual desktop graphics libraries:
  `libGL`, `libX11`, `libXrandr`, `libXinerama`, `libXcursor`, `libXi`, `libXfixes`,
  `libwayland-client`, `libwayland-cursor`, `libwayland-egl`, `libxkbcommon`
- Kernel support for `hwmon`, `powercap`, `nvme` (all standard)

You do **not** need raylib, Odin, or any runtime config. raylib is compiled into the binary,
and the UI font is embedded in it.

## Running it

```sh
chmod +x vibehw64
./vibehw64
```

The window is resizable; `760 × 820` is the default size.

### First run — the setup banner

Two kernel interfaces are root-only by default:

| Interface | Why it is locked down |
| --- | --- |
| `/sys/class/powercap/*/energy_uj` | RAPL energy counters, mode `0400 root` |
| `/sys/firmware/dmi/tables/DMI` | SMBIOS table, mode `0400 root` |

Without them, package/core **power** reads `[Root Required]` and **memory speed/voltage**
show `--`. Everything else works fine.

On first launch a banner appears:

> Power and memory detail need one-time setup   **[ Set up ]**

Click **Set up**. Your desktop's standard authentication dialog (polkit) asks for your
password. vibehw64 never sees or handles it — the password goes to polkit, not to the app.

After authenticating, the app installs a udev rule and a small oneshot systemd unit,
reloads both, and **repopulates itself in place — no restart**. The changes persist across
reboots.

If you would rather not use the in-app button, the same setup is available as a script:

```sh
sudo scripts/install-permissions.sh
```

and can be removed again with:

```sh
sudo scripts/install-permissions.sh --uninstall
```

## What the sections show

| Section | Contents |
| --- | --- |
| **CPU Package & Power** | package temperature, total CPU usage %, package power, IA-core power |
| **CPU Core Clocks** | per-physical-core MHz, split into P-Cores / E-Cores (Intel hybrid) or CCD 0…N (AMD) |
| **CPU Core Usage** | per-core utilisation %, same grouping as clocks |
| **CPU Core Temperatures** | per-core °C from `coretemp`, attributed to the right core |
| **Memory (DDR5 SPD)** | per-DIMM temperature, configured speed, configured voltage |
| **GPU (AMD)** | edge/junction/memory temperature, PPT power, fan, sclk, mclk, vddgfx, GPU usage % |
| **CPU & Board Voltages** | every `hwmon` voltage input that exists (empty if no Super I/O driver) |
| **one per drive** | model + type, NVMe temperatures, capacity, used %, free |
| **one per NIC** | Ethernet: link speed + utilisation; Wi-Fi: SSID in the title, signal in dBm |

Sections with nothing to show are hidden rather than shown empty — for example, the voltage
section simply does not appear on a board where no Super I/O driver is bound.

## Where the numbers come from

Nothing is scraped from other tools, and nothing is estimated. Every value is read from the
kernel or from a firmware table:

| Reading | Source |
| --- | --- |
| CPU core clocks | `cpuinfo_max_freq` once, then `cpufreq/scaling_cur_freq` |
| CPU core / package temperatures | `hwmon` `coretemp` — `tempN_input` + `tempN_label` |
| CPU usage (per core and package) | `/proc/stat` counter deltas |
| Package / IA-core power | `powercap` `energy_uj` deltas over elapsed time |
| CPU core count, P/E or CCD grouping | `cpu_core`/`cpu_atom` cpumasks (Intel), `cache/index3/shared_cpu_list` (AMD) |
| Memory speed, part number, voltage | SMBIOS type 17 (configured speed preferred over rated) |
| DIMM temperatures | `hwmon` `spd5118` (or `jc42`) |
| GPU temperatures / power / clocks / fan | `hwmon` `amdgpu` |
| GPU utilisation | `drm/cardN/device/gpu_busy_percent` |
| Drive model, size, type | `/sys/class/block`, `/sys/class/nvme` |
| Drive temperatures | `hwmon` `nvme`; SATA only if the `drivetemp` module is loaded |
| Drive used / free | `statfs` on the first filesystem mounted from that drive |
| NIC link speed | `/sys/class/net/<if>/speed` |
| NIC utilisation | `/proc/net/dev` byte deltas over the interval |
| Wi-Fi SSID | `SIOCGIWESSID` ioctl |
| Wi-Fi signal | `/proc/net/wireless` |
| Short CPU name | `/proc/cpuinfo` brand string, vendor decoration stripped |
| GPU marketing name | `/usr/share/hwdata/pci.ids` keyed by PCI ID |

## Controls

| Action | How |
| --- | --- |
| Scroll the list | mouse wheel, drag the scrollbar, or click the scrollbar track |
| Collapse / expand | click a section or group header |
| Resize a column | drag the divider between two column headers |
| Auto-fit a column | double-click its divider |
| Change poll interval | click the interval field, type a value in ms, press Enter (Esc reverts) |
| Reset Min/Max/Average | `Reset Min/Max` button, or press `R` |

The interval accepts **whole milliseconds only**, default `1500`. Lower values give sharper
peaks; higher values are gentler on the machine.

Column widths persist for the session. Growing the window widens the sensor column so the
table keeps filling it.

## Permissions and privacy

The setup step writes exactly two files:

```
/etc/udev/rules.d/99-vibehw64-power.rules            # chmod 0444 on powercap energy_uj
/etc/systemd/system/vibehw64-dmi-perms.service       # chmod 0444 on the DMI table at boot
```

Both are narrow: they change the mode of two specific files and nothing else. Neither grants
vibehw64 itself any privilege — the app always runs as your user.

**Privacy note:** the SMBIOS table includes your system UUID and hardware serial numbers.
Making it readable means any local user can read those. That is the same information
`dmidecode` shows, and it is what enables the memory speed readout. If you would rather not
expose it, run with the DMI rule absent — memory speed degrades to the SPD JEDEC value and
the app works normally otherwise.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Power shows `[Root Required]` | Setup not done. Click **Set up**, or run `sudo scripts/install-permissions.sh`. |
| Power shows `--` for ~3 s after start | Expected — RAPL power needs two energy readings. |
| Memory Speed/Voltage show `--` | DMI table unreadable — same setup step. |
| Memory shows a `(JEDEC)` suffix | Only the SPD fallback is available; SMBIOS was unreadable. |
| No **CPU & Board Voltages** section | No Super I/O (`nct6775`/`it87`) driver bound. This is a board limitation. |
| SATA drive has no temperature | Load the `drivetemp` module: `sudo modprobe drivetemp`. |
| Wi-Fi title says `disconnected` | Radio is down. When connected it shows the SSID. |
| Window looks blurry / scaled oddly | HiDPI scaling under Wayland. Report it — it is a known weak spot. |
| `no display available` on launch | No usable `DISPLAY`/`WAYLAND_DISPLAY`. Use `vibehw64 --probe` for headless output. |

## Headless / scripting

```sh
./vibehw64 --probe                       # 3 samples, prints, exits
./vibehw64 --probe --ticks 10 --interval 500
```

The probe prints the discovered topology, every section and every sensor's
current/minimum/maximum/average, then exits non-zero if nothing was discovered. It is the
quickest way to check whether setup is needed:

```sh
./vibehw64 --probe --ticks 1 | grep perms
```

## Building from source

Requirements: **Odin** (`dev-2026-10` was used), `gcc`, `make`, `git`, and the X11/GL/Wayland
development headers.

```sh
# 1. Build and install the static raylib archive that Odin's vendor bindings expect.
#    Needed because the bindings target raylib 6.0 while distros ship 6.2, and the
#    Odin vendor tree contains no x86-64 static archive.
sudo scripts/build-raylib-static.sh

# 2. Build the binary.
./build.sh          # -> bin/vibehw64

# 3. Optional: the probe build used for development.
odin build src -debug -out:bin/vibehw64-debug
```

`build.sh` links raylib statically, so the resulting binary has no `libraylib` dependency:

```
libc, libm, libGL, libX11 + X extensions, libwayland-*, libxkbcommon
```

`ARCHIVE/` holds development scratch (raylib source clone, synthetic `sysfs` fixtures, probe
logs) and is excluded from the repository.

## Credits

- **raylib** — zlib licence — compiled into the binary
- **DejaVu Sans Mono** — Bitstream Vera licence — embedded; see
  `src/assets/LICENSE-DejaVu.txt`
- **Odin** — the language and `vendor:raylib` bindings
- GPU names come from the distro's `pci.ids` (`hwdata`), when present
