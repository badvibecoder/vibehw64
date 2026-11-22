# RELEASE.md — vibehw64 v1.0.0

Release notes for the **binary** distribution.

| | |
| --- | --- |
| Version | **1.0.0** |
| Release date | 2026-11-22 |
| Artifact | `vibehw64` (single executable) |
| Size | 2,017,296 bytes (~1.9 MiB) |
| SHA-256 | `efde927380872a172307c692fd8f02a272389932bcad5b8bb6d4534d4eac3381` |
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

### Verify the download

```sh
sha256sum vibehw64
# expect efde927380872a172307c692fd8f02a272389932bcad5b8bb6d4534d4eac3381
```

### Runtime requirements

| Requirement | Notes |
| --- | --- |
| glibc **≥ 2.44** | built against the current Arch/Garuda toolchain |
| `libGL` | Mesa / libglvnd |
| `libX11` + `libXrandr`, `libXinerama`, `libXcursor`, `libXi`, `libXfixes` | X11 or XWayland |
| `libwayland-client`, `libwayland-cursor`, `libwayland-egl`, `libxkbcommon` | native Wayland |
| `libm`, `libc` | standard |

**Not required:** raylib, Odin, GTK, Qt, Python, or any runtime data file. raylib is compiled
into the binary and the font is embedded.

The binary has **no `libraylib` dependency** — verified with `ldd`.

## First run

vibehw64 starts immediately. A banner may appear:

> Power and memory detail need one-time setup   **[ Set up ]**

Click it, authenticate through the normal polkit dialog, and the app fills in package/core
power and memory speed/voltage **without restarting**. This is a one-time action and survives
reboots.

If you prefer not to use the button, run `sudo scripts/install-permissions.sh` from a source
checkout.

## What this release includes

**CPU**
- Per-physical-core clocks with P-Core / E-Core grouping on Intel hybrid (8P + 16E verified)
  and CCD grouping on AMD, including `[3D]` tagging for stacked-cache dies
- Per-core utilisation, package utilisation
- Per-core temperatures, correctly attributed through package core IDs
- Package temperature, package power (RAPL), IA-core power

**Memory**
- Per-DIMM temperature from the SPD hub
- Configured speed, part number, configured voltage from SMBIOS
- `XMP/EXPO` indicator when the configured speed exceeds the JEDEC base bin

**GPU (AMD)**
- Edge / junction / memory temperatures, PPT power, fan RPM, sclk, mclk, vddgfx, usage %

**Storage** — one section per drive
- Model, type (NVMe / SSD / HDD), capacity
- NVMe sensor temperatures (composite + NAND sensors)
- Used %, free space

**Network** — one section per interface
- Ethernet: link speed, utilisation of the busier direction
- Wi-Fi: SSID in the section title, signal in dBm

**Interface**
- Collapsible sections and sub-groups
- Current / Minimum / Maximum / Average per sensor, with reset
- Editable poll interval (default 1500 ms)
- Drag-resizable columns, double-click to auto-fit
- Dedicated draggable scrollbar
- Per-class temperature colour thresholds

## Behaviour notes

- **Power shows `--` for the first interval** after launch or reset. RAPL power is a delta
  between two energy readings.
- **Averages are time-weighted**, so changing the interval mid-run does not skew them.
- **Column widths persist for the session only**; v1.0 deliberately saves no state.
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
| No CPU core voltage | requires MSR access or a bound Super I/O driver; not implemented in v1 |
| No board voltage section on some boards | needs `nct6775`/`it87`; some boards (e.g. Gigabyte Z890) expose temperatures only |
| SATA drive temperatures absent by default | requires the `drivetemp` kernel module |
| Wi-Fi SSID path unverified while associated | radio was down during development; degrades to `connected`/`disconnected` |
| NVIDIA GPUs unsupported | out of scope for v1 |
| No SMART attributes | would require the external `smartctl` |
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
