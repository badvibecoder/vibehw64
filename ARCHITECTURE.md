# ARCHITECTURE.md — vibehw64

Deep-dive for whoever picks this up next **without the development history**. It explains what
each piece does, how data flows, why the non-obvious decisions were made, and which landmines
are already marked.

Read this before changing anything. `SPEC.md` is the normative "what"; this is the "how and why".

---

## 1. Mental model

One process, one global `App`, three kinds of state:

```
     ┌─────────────── discovery (main thread, once) ────────────────┐
     │  topology → sensor files → metrics + groups + sections       │
     └──────────────────────────────┬───────────────────────────────┘
                                    │
   ┌──────────── sampler thread ────┴────┐        ┌──── UI thread (raylib, 10 FPS) ────┐
   │ read fds / proc / statfs → stats   │        │ copy snapshot → draw → input       │
   │ /proc/meminfo → memory stats       │───────▶│ owns section/group expanded state, │
   │ periodically copy into snapshot    │        │ column widths, scroll, Copy buffer │
   │ (mutex-guarded)                    │        └────────────────────────────────────┘
   └────────────────────────────────────┘
                                    ▲
                     perms worker thread (on demand): pkexec → result flag
```

Everything is **statically allocated**. There are no dynamic containers, no per-frame
allocations, and no per-sample allocations. Discovery may build paths on the stack but never
on the heap.

The binary is a single executable with the font **and icon** compiled in. raylib is linked
statically.

## 2. Module map

| File | Responsibility | Key types |
| --- | --- | --- |
| `main.odin` | entry point, arg parsing, `--probe`, `--snapshot` | — |
| `topology.odin` | CPU packages/groups/cores, `core_id` join, path helpers | `Topology`, `Core`, `Core_Class` |
| `sensors_linux.odin` | sensor model, registry, discovery, display helpers, thermal labels | `App`, `Sensor_Source`, `Sensor_Metric`, `Group`, `Section` |
| `storage.odin` | per-drive sections, memory identity/per-DIMM rows | `fs_usage`, `block_bytes`, `discover_storage`, `discover_memory_info` |
| `meminfo.odin` | memory usage/commit/swap rows from `/proc/meminfo` | `Mem_State`, `Mem_Metrics`, `meminfo_init`, `meminfo_update` |
| `net.odin` | per-NIC sections, Wi-Fi SSID/signal | `Net_Iface`, `discover_net`, `net_update` |
| `usage.odin` | CPU utilisation from `/proc/stat` | `usage_init`, `usage_update`, `usage_parse` |
| `names.odin` | CPU short name, `pci.ids` (incl. subsystem), SMBIOS, SPD decode | `SMB_Memory`, `cpu_short_name`, `pci_ids_lookup`, `spd_summary` |
| `perms.odin` | in-app privilege setup via pkexec | `Perms`, `Perms_State`, `perms_*` |
| `sampler.odin` | sampling thread, snapshot, reset, interval | `Sampler` |
| `ui.odin` | raylib window, tree, columns, scrollbar, banner, Copy, temp bands | `ui_*` globals + helpers |
| `assets/` | embedded font, icon PNG/SVG, licences | `FONT_BYTES`, `ICON_*` |
| `tests/run-fixtures.py` | synthetic AMD/Intel/SMBIOS sysfs trees | — |

Helpers used everywhere:

- `read_file_str(path, buf) -> (string, bool)` — one-shot read into a caller buffer.
- `open_path(path) -> (linux.Fd, linux.Errno)` — NUL-safe open (see §7).
- `set_section_label` / `set_group_label_at` — copy into the owned section/group label buffers.

## 3. Startup sequence

`main()` → parse args → `discover_all(&app, sys_root)` → one of `run_ui()`, `probe_run()`,
`snapshot_run()`.

`discover_all` order matters:

1. **Four fixed sections** added first, in `Section_Id` order: **CPU, Memory, GPU,
   Voltages**.
2. `topo_discover` — buses, cores, P/E or CCD grouping. Returns false if no CPUs.
3. CPU short name resolved.
4. Groups created:
   - CPU: `Package & Power`, `Thermal Headroom - Package`, then per class
     `CPU Core Clocks`, `CPU Core Usage`, `CPU Core Temperatures`, and
     `Distance from TjMax/Tcontrol` (labels get the real limits later).
   - Memory: `Usage`, `Modules`, `Temperatures`; GPU: `GPU`; Voltages: `Voltages`.
5. `discover_clocks` — one fd per physical core.
6. `discover_temps` — package + per-core temps, TjMax/Tcontrol, joined via `core_id`; updates
   the per-class distance group labels with the package limits.
7. `usage_init` — opens `/proc/stat`, primes deltas, creates computed usage metrics.
8. `discover_rapl` — package/IA power plus PL1/PL2 and their time windows.
9. `discover_spd` — DIMM temperatures and the SPD JEDEC reference.
10. `discover_gpu` — amdgpu hwmon rows, GPU busy, VRAM, subsystem-aware PCI name.
11. `discover_voltages` — every non-amdgpu `in*_input`.
12. `discover_memory_info` — SMBIOS speed/nominal voltage/per-DIMM capacity and
    `Installed Capacity`.
13. `meminfo_init` — opens `/proc/meminfo`, creates usage rows and samples them once.
14. `discover_storage` — one section per drive.
15. `discover_net` — one section per physical interface.
16. **Other Sensors** section created **after** drives/NICs, so it stays at the bottom;
    `discover_other_sensors` adds unclaimed hwmon temperatures and fans.
17. `discover_build_labels` — composes section titles from the resolved short names.

> **Rule:** anything that adds metrics must run during discovery. Adding metrics later would
> race with the sampler, so runtime changes only ever *update values* (see §6).

## 4. Threading model and ownership

| State | Owner | Notes |
| --- | --- | --- |
| `app.metrics[]` | **sampler thread** | UI reads only the snapshot copy |
| `app.sources[]` | sampler (values), discovery (creation) | perms refresh reopens fds on the sampler thread |
| `app.sections[]`, `app.groups[]` | **UI thread** | expanded flags, column widths, scroll |
| section/group **label strings** | UI thread | rebuilt via `perms.labels_dirty`; group labels are set during discovery |
| `sampler.snapshot[]` | written by sampler under `sampler.mu`, read by UI under the same mutex | 512 × `Sensor_Metric` copy per tick |
| `mem_state` | sampler thread | `/proc/meminfo` fd + metric indices; UI never touches it |
| `ui_copy_buf` | UI thread | 64 KB static staging buffer for clipboard text |
| `sampler.interval`, `sampler.quit` | guarded by `sampler.mu` | UI writes interval; sampler reads |
| `perms.state`, `perms.pending`, `perms.labels_dirty` | guarded by `perms.mu` | worker writes, UI/sampler read |

Threads:

- **UI / main thread** — all raylib calls, Copy button and clipboard. Never touches fds or
  metrics directly.
- **Sampler thread** — created in `run_ui`, loops forever until `quit`. Calls `sample_all`,
  `usage_update`, `net_update`, `meminfo_update`, then publishes. Sleeps in ≤50 ms slices so
  interval changes and shutdown are responsive.
- **Perms worker** — created on demand when the user clicks *Set up*. Runs `pkexec`, waits,
  records the result. Never touches app state beyond the `perms` flags.

**Why the UI does not perform refreshes:** reopening an fd or rewriting `app.metrics` from the
UI thread would race the sampler. Instead the UI sets `perms.pending`, and the sampler calls
`perms_apply_refresh` at the top of its loop.

**Why section titles are rebuilt on the UI thread:** they are `string`s pointing into
`section_label_buf`. The UI owns and reads them, so the sampler only raises a
`labels_dirty` flag. Group labels live in fixed-byte arrays and are not rebuilt at runtime.

**`--snapshot` is headless:** it samples on the main thread, copies `app.metrics` into the UI's
`ui_metrics` staging array, sets `ui_n`, and calls `ui_copy_build()` without opening a window.
Only the actual Copy button calls `SetClipboardText`.

## 5. Data flow

### Discovery
Every sensor becomes a `Sensor_Source` (one fd + parse kind + scale) and a `Sensor_Metric`
(label, unit, class, group, source index). `metric_add_computed` creates metrics with
`src == NO_SOURCE` for values that are not single files (CPU usage, capacity, memory rows,
installed/per-DIMM, limits).

`add_derived_row` creates a metric with `derived_from` and `limit` for values computed from
another metric; TjMax/Tcontrol distances are the current users.

### Sample
`sample_all` walks metrics, skips `NO_SOURCE`, reads each source:

- `read_value` seeks to 0, reads ≤64 bytes, parses an integer, multiplies by scale.
- RAPL sources keep the previous `energy_uj` and timestamp and return
  `Δenergy / (Δt · 10⁶)` watts, adding `max_energy_range_uj` on wrap. The first call stores
  the baseline and returns no value → row shows `--`.
- `derived_update` then computes `limit - source.cur` for derived rows.
- `usage_update` reads `/proc/stat` once and pushes per-core and package percentages.
- `net_update` reads `/proc/net/dev` and `/proc/net/wireless`.
- `meminfo_update` reads `/proc/meminfo` once and pushes physical/commit/swap rows.

All of these call `metric_push`, which maintains `cur/min/max` and the **time-weighted**
average.

### Snapshot
After sampling, the sampler copies the whole metric array into `sampler.snapshot` under
`sampler.mu`. The UI copies it out under the same lock each frame. This removes every data
race on metric values.

### Draw
`ui_draw_frame` → `sampler_get` → banner state → input → toolbar/banner/header/content
(scissored) → scrollbar.

Sections and groups are walked in insertion order. A section with exactly one non-empty group
renders its rows directly; multi-group sections render group headers. Empty groups are
skipped entirely.

`ui_draw_row` evaluates each of Current/Minimum/Maximum/Average independently through
`ui_temp_band_value`. A banded cell gets a filled box behind the text and white text; below
60 C the normal class/dim colours apply. Distance and static-limit rows are excluded.

### Copy / `--snapshot`
`ui_copy_build` walks the UI snapshot plus `app.sections`/`app.groups`, writes an aligned
text table into `ui_copy_buf`, and returns the length. `ui_copy_snapshot` then calls
`rl.SetClipboardText`. `--snapshot` uses the same builder against `app.metrics` and prints it.
No heap allocation is involved in either path.

## 6. Runtime mutation rules

The metric array's **shape is fixed after discovery**. Values may change; structure may not.
That is why:

- Memory Speed / SMBIOS Nominal Voltage rows are created **unconditionally**, showing `--`
  until SMBIOS is readable. This lets the permission self-heal fill them in place.
- Power rows exist even when `energy_uj` is unreadable (source `usable = false`,
  `root = true`), so a successful setup only needs to reopen the fd.
- Per-DIMM and `Installed Capacity` rows are created only when SMBIOS is readable at
  discovery. If the DMI setup runs in this same session, those rows require a restart; speed
  and nominal voltage still self-heal immediately.

`perms_apply_refresh` (sampler thread) does two things:

1. Reopen every source with `root == true`, using the `reopen_path` stored at discovery.
2. Re-read SMBIOS and call `memory_apply_identity` (speed/nominal voltage/name and the two
   static metric rows).

Then it sets `labels_dirty`; the UI calls `discover_build_labels` and the titles update.

Other sensor discovery (Other Sensors) is also fixed at startup; adding/removing a `hwmon`
device requires a restart.

## 7. Gotchas — read this before editing

These all caused real bugs. Each is now handled, but the handling is easy to undo by accident.

1. **`cstring(raw_data(s))` is not NUL-terminated.** Strings carved from a reused buffer keep
   the previous buffer's tail, so a shorter path silently resolves to garbage. Always go
   through `open_path` / `readlink_str`, which copy into a local buffer and append `\0`.
2. **Odin's `fmt` zero-pads numeric field widths.** `%8.1f` renders `000034.0`, not
   `    34.0`. Numeric columns are padded manually (`num_field`, `ui_text_right`).
3. **`thread.create` does not start the thread.** It blocks on a semaphore until
   `thread.start(t)` is called. Forgetting it gives a perfectly healthy-looking thread object
   that never runs.
4. **`hwmon` device symlinks are relative.** `readlink` on `/sys/class/hwmon/hwmon2/device`
   returns `../../nvme0`, not a full path. Match on `base_name()`.
5. **SMBIOS strings are space-padded** to a fixed width. `smbios_string` trims both ends.
   Type 17 `Size == 0x7FFF` means the real size is in the `Extended Size` dword at 0x1C.
6. **The SPD `eeprom` attribute only exposes page 0.** Reading at file offset 640 returns
   page-0 bytes again, so the XMP/EXPO region is unreachable through sysfs. That is why memory
   *timings* are not implemented.
7. **`Section_Id` values are indices.** The **four** fixed sections must be created first and
   in enum order. Dynamic sections (drives, NICs, Other) append after them; Other is added
   after drive/NIC discovery so it is last.
8. **Section titles alias `section_label_buf`.** Never rebuild a title from the sampler thread.
   Group labels are fixed byte arrays and are safe to update during discovery.
9. **Odin has no ternary and no `var`.** Use if/else; declare with `:=`.
10. **Enum switches need `#partial switch` or every case.** Odin errors on unhandled cases.
11. **`os.Error` is a `#shared_nil` union**, so compare against `nil`, unlike
    `linux.Errno`, which uses `.NONE`.
12. **The pkexec script must not need escaping.** Rule and unit text are compiled in and
    base64-encoded, so nothing user-controlled ever reaches a shell.
13. **`card0` is not necessarily the amdgpu card.** Enumerate `drm/card[0-9]*` and check
    `device/vendor == 0x1002`.
14. **A sysfs attribute is not a device.** `MODE=` in udev cannot chmod `energy_uj`; use
    `RUN+=/bin/chmod`. And `/sys/firmware/dmi` has no uevent at all, so udev cannot touch it —
    hence the systemd unit.
15. **`pkg_dir` aliases the path buffer.** `add_power_limit_rows` must run before the core
    loop reuses `path_buf`; the code copies the path into `pkg_copy` first.
16. **Group counts were silently too small.** The old `MAX_GROUPS` 16 could fold groups
    together on an 8-CCD system with drives/NICs. The caps are now **128 groups / 64
    sections**; keep them consistent with the fixed/per-class/dynamic count.
17. **`MAX_LABEL` is 48.** The distance headers include the limit, e.g.
    `P-Cores - Distance from Tcontrol (84.0 C)`, and need the extra room.
18. **SMBIOS nominal voltage is not VDIMM.** Type 17's configured-voltage field often
    reports the JEDEC 1.2 V value even when the BIOS sets 1.35/1.37 V. It is firmware data,
    not a sensor; the row is named `SMBIOS Nominal Voltage` for that reason.
19. **Linux virtual memory has no exact Windows equivalent.** The Virtual Memory rows are
    commit charge (`Committed_AS` / `CommitLimit`); Swap is separate. Do not label commit
    charge as total memory.
20. **Temperature bands are per cell, not per row.** `ui_temp_band_value` is called for
    Current, Minimum, Maximum and Average independently and excludes distance rows,
    `Temp_Limit` rows and non-Celsius units.
21. **Group labels with limits are set after discovery.** `discover_temps` reads the package
    `crit`/`max` and then rewrites the class group labels via `set_group_label_at`; do not
    build those labels with hard-coded limits.

## 8. Decisions and rejected alternatives

| Decision | Why | Rejected alternative |
| --- | --- | --- |
| Odin + `vendor:raylib` | the spec's constraint; small, direct bindings | GTK/Qt (heavy), SDL (extra dep) |
| Static raylib built from tag 6.0 | distro ships 6.2 and the bindings declare 6.0; vendor tree had no x86-64 static lib | symlinking 6.2 (ABI mismatch), dynamic link (runtime dep) |
| Both GLFW backends | native Wayland where available, X11 fallback otherwise | X11-only (blurry through XWayland on HiDPI) |
| Fixed-capacity arrays | zero steady-state allocation, simple ownership | dynamic arrays (allocation, fragmentation) |
| One fd per metric | no directory walks, no parsing costs per tick | re-reading paths each sample |
| Time-weighted average | interval is user-editable; plain mean would skew | `sum/count` |
| Sections dynamic (`section_count`) | drives, NICs and Other are dynamic | fixed enum (cannot scale) |
| One CPU section with labeled groups | the old top-level CPU sections stacked poorly; one collapsible parent is easier to scan | seven or more top-level CPU sections |
| Other Sensors last | keeps the generic long tail out of the way | fixed section in the middle |
| SMBIOS for memory identity | the only vendor-neutral source of *configured* speed | SPD JEDEC (wrong when XMP is on), XMP decode (vendor-specific) |
| `/proc/meminfo` for usage | one fd, deltas not needed, commit/swap available | spawning `free` (tool + parse), sysinfo (no commit) |
| Commit charge for virtual memory | closest analogue to HWiNFO's Windows rows | reporting physical only, or pretending swap == virtual |
| Per-DIMM rows from SMBIOS | size/locator/speed are firmware ground truth | guessing from SPD order |
| Subsystem-first GPU name | `pci.ids` has the AIB entry; family name alone is useless | vendor:device only |
| Derived distance metrics | no second fd per core; stats work | reading `tempN_crit` every tick |
| Per-cell temperature bands | max/min/avg are independent historical values | one row background driven by current |
| `COPY` via static buffer | no heap, no external clipboard tool | `xclip`/`wl-copy` subprocess |
| `--snapshot` shares the copy builder | headless parity and testability | a separate formatter |
| wext ioctl for SSID | no subprocess, no dependency; cfg80211 still emulates it | `iw` subprocess (spawn cost), nl80211 (400+ lines) |
| `pkexec` for setup | password handled by polkit, never by us | setuid (dangerous), sudo (needs a TTY) |
| systemd unit for DMI | udev cannot match a device that does not exist | chmod at every launch (prompt each time) |
| Manual padding instead of fmt widths | Odin zero-pads numeric widths | fighting the formatter |

## 9. Build system

```sh
sudo scripts/build-raylib-static.sh   # once per machine; clones into temp/raylib-6.0
./build.sh                            # -> bin/vibehw64
python3 tests/run-fixtures.py
```

`build-raylib-static.sh`:

- clones raylib tag `6.0` into `temp/raylib-6.0` (relative to the repo root),
- builds with `PLATFORM=PLATFORM_DESKTOP GLFW_LINUX_ENABLE_X11=TRUE
  GLFW_LINUX_ENABLE_WAYLAND=TRUE`,
- installs `libraylib.a` into `$(odin root)/vendor/raylib/linux/`.

`build.sh` refuses to build if that archive is missing, then links with
`-define:RAYLIB_SHARED=false` plus the extra linker flags for GL, X11 extensions and Wayland.

**Portability:** the binary is only as portable as the build host's glibc (2.44 at v1.1). To
support older systems, build on the oldest glibc you intend to support.

## 10. Testing

- **Live** — `./bin/vibehw64 --probe --ticks 2` prints topology, every section and all four
  statistics. This is the primary development loop and works without a display.
- **Snapshot** — `./bin/vibehw64 --snapshot --ticks 2` prints exactly the Copy text; useful
  for checking formatting and for scripting.
- **Fixtures** — `python3 tests/run-fixtures.py` synthesizes:
  - a 5950X-like AMD tree: 16C/32T, two CCDs, one with a larger L3 → `CCD 0 [3D]`;
  - a 12600K-like Intel tree with no PMU masks: 6 P + 4 E → frequency-tier fallback;
  - a minimal SMBIOS type-17 table with two 16 GB DIMMs → per-DIMM capacity/speed.
  It runs `--probe --sys-root` against each and fails on a missing expected row/group.
- **No static fixture tree is checked in**; the script removes its temporary trees unless
  `--keep` is passed.
- **Not testable headlessly** — window rendering, column drag, scrollbar, clipboard,
  per-cell colours and the polkit dialog. The temperature-band decision function was checked
  with a transient `odin test` boundary test during development.

## 11. Adding a sensor family

1. Write `discover_<thing>(app, group)`.
2. For each file: `fd, ok := open_sensor(path)`, then
   `si := source_add(app, fd, .Milli_Int, 0.001, true)`, then
   `metric_add(app, label, .Celsius, .YourClass, group, si)`.
3. For values that are not a single file, use `metric_add_computed` and push with
   `metric_push` from a sampler hook (see `usage.odin`, `meminfo.odin`, `net.odin`).
4. For a value derived from an existing metric, use `add_derived_row` (source index + limit)
   and let `derived_update` compute it.
5. Add a unit in `Sensor_Unit`, `unit_str`, `unit_decimals` if needed.
6. Add a colour threshold/band in `ui_row_color` or `ui_temp_band_value` (gate Celsius).
7. Create a group under the right section, respecting the group/section caps.
8. Call it from `discover_all` **before** `discover_build_labels`.

## 12. Known gaps / sensible next steps

| Gap | Notes |
| --- | --- |
| CPU core voltage | needs MSR `IA32_PERF_STATUS` (`/dev/cpu/*/msr` + udev) or a bound Super I/O |
| Board rails on some boards | `it87 force_id=0x8689` returns `EBUSY`; would need `acpi_enforce_resources=lax` |
| Live VDIMM | not exposed by this board's `hwmon`; SMBIOS only reports nominal voltage |
| Memory timings (CL, tREFI) | SPD page 0 only; XMP/EXPO region unreachable |
| Wi-Fi SSID while associated | implemented but unverified here; radio down/absent |
| Wi-Fi temperature | may stay `--` until the driver reports |
| Per-DIMM temperature ↔ locator join | SPD address and SMBIOS locator are not reliably correlated |
| SATA temperatures | matching already exists; needs `drivetemp` loaded |
| Saved window/section state | deliberately absent |
| NVIDIA GPUs | out of scope |
| SMART / power-on hours | would need `smartctl` or ioctl work |
| Fan control | monitoring only; no PWM API |
| Graphs/history/logging/alerts | out of scope; would break the no-state/no-config design |

## 13. Glossary

- **RAPL** — Running Average Power Limit; Intel's energy counters in `powercap`.
- **PL1 / PL2** — long-term / short-term package power limits.
- **TAU** — the time window attached to a power limit.
- **TjMax** — maximum junction temperature; `coretemp` `tempN_crit`.
- **Tcontrol** — recommended maximum operating temperature; `coretemp` `tempN_max`.
- **CCD** — core complex die; one L3 domain on AMD, the natural grouping unit.
- **P/E core** — performance / efficiency core on Intel hybrid CPUs.
- **SPD** — the EEPROM on a DIMM describing the module.
- **SMBIOS / DMI** — firmware tables describing the machine, including memory devices.
- **hwmon** — the kernel's generic hardware-monitoring class, exposed under `/sys/class/hwmon`.
- **VRAM** — GPU memory; `mem_info_vram_used/total`.
- **Commit charge** — allocated address space counted against `CommitLimit`; used for the
  Virtual Memory rows.
- **GiB** — binary gigabyte (1024³); displayed as `GB` for RAM.
