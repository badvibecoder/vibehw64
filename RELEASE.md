# RELEASE.md — vibehw64 v1.1.0

Release notes for the **binary** distribution.

| | |
| --- | --- |
| Version | **1.1.0** |
| Release date | 2026-11-24 |
| Artifact | `vibehw64` (single executable) |
| Size | 2,068,264 bytes (~1.97 MiB) |
| Platform | Linux x86-64 |
| Built with | Odin `dev-2026-10`, raylib 6.0 (static) |

---

## Install

No package, no installer, no service.

```sh
chmod +x vibehw64
./vibehw64
```

Put it anywhere — `~/.local/bin`, `/opt`, a USB stick. It needs no asset or config files next
to it.

### Runtime requirements

| Requirement | Notes |
| --- | --- |
| glibc **≥ 2.44** | built against the current Arch/Garuda toolchain |
| `libGL` | Mesa / libglvnd |
| `libX11` + `libXrandr`, `libXinerama`, `libXcursor`, `libXi`, `libXfixes` | X11 or XWayland |
| `libwayland-client`, `libwayland-cursor`, `libwayland-egl`, `libxkbcommon` | native Wayland |
| `libm`, `libc` | standard |

**Not required:** raylib, Odin, GTK, Qt, Python, or any runtime data file. raylib is compiled
into the binary; the font and window icon are embedded.

The binary has **no `libraylib` dependency** — verified with `ldd`.

## First run

vibehw64 starts immediately. A banner may appear:

> Power and memory detail need one-time setup   **[ Set up ]**

Click it, authenticate through the normal polkit dialog, and the app fills in package/core
power and memory speed/nominal voltage **without restarting**. This is a one-time action and survives
reboots. The per-DIMM capacity and `Installed Capacity` rows are created at launch, so after
the in-app setup they appear on the next start.

If you prefer not to use the button, run `sudo scripts/install-permissions.sh` from a source
checkout.

## What this release includes

**CPU**
- One **CPU** section with clearly labeled subsections:
  *Package & Power*, *Thermal Headroom - Package*, *CPU Core Clocks/Usage/Temperatures*,
  and per-core *Distance from TjMax/Tcontrol*
- Per-physical-core clocks with P-Core / E-Core grouping on Intel hybrid and CCD grouping on
  AMD, including `[3D]` tagging for stacked-cache dies
- Per-core utilisation, package utilisation, per-core and package temperatures
- Package and IA-core power (RAPL)
- **PL1 / PL2 limits** and their **time windows (TAU)** as static rows
- **Thermal headroom**: package and per-core distance from TjMax (`tempN_crit`) and Tcontrol
  (`tempN_max`), with the actual limits in the subsection headers
- **Per-cell temperature bands**: Current / Minimum / Maximum / Average cells turn green
  (60–69.9 °C), orange (70–79.9 °C) or red (80 °C+) with white text

**Memory**
- **Installed capacity**, usable total, physical used/available/load
- **Virtual memory used/available/load** based on commit charge, plus **Swap used/total/load**
- Per-DIMM **capacity**, configured speed and SMBIOS locator
- Configured speed, part number, `XMP/EXPO` indicator, DIMM temperatures where exposed
- `SMBIOS Nominal Voltage` (firmware data, not a live VDIMM measurement)

**GPU (AMD)**
- Edge / junction / memory temperatures, PPT power, fan RPM, sclk, mclk, vddgfx, usage %
- **VRAM used / total**
- Subsystem-aware marketing name from `pci.ids` (e.g. `Nitro+ Radeon RX 570/580/590`)

**Storage** — one section per drive
- Model, type (NVMe / SSD / HDD), capacity
- NVMe sensor temperatures (composite + NAND sensors)
- Used %, free space

**Network** — one section per interface
- Ethernet: link speed, utilisation of the busier direction
- Wi-Fi: SSID in the section title, signal in dBm

**Other Sensors** — the remaining `hwmon` long tail
- ACPI thermal zones, NIC PHY/MAC temperatures, Wi-Fi temperature, board Super I/O
  temperatures, and fan RPMs where exposed

**Interface**
- Collapsible sections and subsections
- Current / Minimum / Maximum / Average per sensor, with reset
- **Copy** button: aligned text snapshot of every section/row on the clipboard
- Headless **`--snapshot`** mode using the same formatter
- Editable poll interval (default 1500 ms)
- Drag-resizable columns, double-click to auto-fit
- Dedicated draggable scrollbar
- Per-cell temperature highlighting
- Embedded window icon (X11/XWayland; native Wayland uses its own app-icon mechanism)

## Behaviour notes

- **Power shows `--` for the first interval** after launch or reset. RAPL power is a delta
  between two energy readings.
- **Averages are time-weighted**, so changing the interval mid-run does not skew them.
- **Column widths persist for the session only**; v1.1 deliberately saves no state.
- **Copy** includes all sections and rows regardless of collapse state. **`--snapshot`** prints
  the same text without a display.
- **Temperature bands are per cell** and driven independently by each value; a cool Current
  does not hide a hot Maximum. Distance and static-limit rows are excluded.
- **Virtual Memory rows use commit charge** (`Committed_AS` / `CommitLimit`), not physical
  RAM; Swap is reported separately.
- **SMBIOS Nominal Voltage is firmware data**, not the board's live VDIMM. It commonly reads
  1.2 V even when the BIOS is set higher.
- **Per-DIMM / Installed Capacity need readable DMI at launch**; if setup runs in-app, restart
  once to see them.
- **The app runs unprivileged at all times.** Only the one-time setup writes privileged files.

## System changes

Installing permissions creates exactly two files:

```
/etc/udev/rules.d/99-vibehw64-power.rules
/etc/systemd/system/vibehw64-dmi-perms.service
```

Both only set mode `0444` on specific files. To remove them:

```sh
sudo scripts/install-permissions.sh --uninstall
```

and reboot to restore the original modes.

## Known limitations

| Limitation | Reason |
| --- | --- |
| Memory CAS latency / tREFI not shown | the SPD `eeprom` attribute exposes only page 0, so the XMP/EXPO block cannot be read |
| No CPU core voltage | requires MSR access or a bound Super I/O driver; not implemented |
| No board voltage section on some boards | needs `nct6775`/`it87`; some boards expose temperatures only |
| `SMBIOS Nominal Voltage` may not match BIOS VDIMM | the SMBIOS configured-voltage field is nominal firmware data, not a live sensor |
| Per-DIMM / Installed Capacity absent until restart | created at discovery; DMI must be readable then |
| TjMax/Tcontrol sections absent | require `coretemp` `crit`/`max`; typically Intel only |
| SATA drive temperatures absent by default | requires the `drivetemp` kernel module |
| Wi-Fi SSID unverified while associated | radio was down/absent during development; degrades to `connected`/`disconnected` |
| Wi-Fi temperature may show `--` | the driver reports no value while idle/disassociated |
| No fan control | monitoring only; no PWM interface |
| NVIDIA GPUs unsupported | out of scope |
| No SMART attributes | would require the external `smartctl` or ioctl work |
| No graphs, history, logging or alerts | deliberately absent |
| Older glibc unsupported | binary is built against glibc 2.44 |

## Upgrading and uninstalling

- **Upgrade:** replace the binary. No state to migrate.
- **Uninstall:** delete the binary; optionally run `install-permissions.sh --uninstall` to
  remove the udev rule and systemd unit.

## Licence and attribution

- **raylib** — zlib licence — statically linked
- **DejaVu Sans Mono** — Bitstream Vera licence — embedded; full text in
  `src/assets/LICENSE-DejaVu.txt`
- **Odin** — language and `vendor:raylib` bindings
- GPU marketing names are read at runtime from the distribution's `pci.ids` (`hwdata`)
- The embedded icon is described in the README Credits section
