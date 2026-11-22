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
   │ read fds / proc / statfs → stats   │        │ copy snapshot → draw → handle input│
   │ periodically copy into snapshot    │───────▶│ owns section/group expanded state, │
   │ (mutex-guarded)                    │        │ column widths, scroll, interval UI │
   └────────────────────────────────────┘        └────────────────────────────────────┘
                                    ▲
                     perms worker thread (on demand): pkexec → result flag
```

Everything is **statically allocated**. There are no dynamic containers, no per-frame
allocations, and no per-sample allocations. Discovery may build paths on the stack but never
on the heap.

The binary is a single executable with the font compiled in. raylib is linked statically.

---

## 2. Module map

| File | Responsibility | Key types |
| --- | --- | --- |
| `main.odin` | entry point, arg parsing, `--probe` rendering | — |
| `topology.odin` | CPU packages/groups/cores, `core_id` join, path helpers | `Topology`, `Core`, `Core_Class` |
| `sensors_linux.odin` | sensor model, registry, discovery, display helpers | `App`, `Sensor_Source`, `Sensor_Metric`, `Group`, `Section` |
| `storage.odin` | per-drive sections, memory identity rows | `fs_usage`, `block_bytes`, `discover_storage`, `discover_memory_info` |
| `net.odin` | per-NIC sections, Wi-Fi SSID/signal | `Net_Iface`, `discover_net`, `net_update` |
| `usage.odin` | CPU utilisation from `/proc/stat` | `usage_init`, `usage_update`, `usage_parse` |
| `names.odin` | CPU short name, `pci.ids`, SMBIOS, SPD decode | `SMB_Memory`, `cpu_short_name`, `pci_ids_lookup`, `spd_summary` |
| `perms.odin` | in-app privilege setup via pkexec | `Perms`, `Perms_State`, `perms_*` |
| `sampler.odin` | sampling thread, snapshot, reset, interval | `Sampler` |
| `ui.odin` | raylib window, tree, columns, scrollbar, banner | `ui_*` globals + helpers |
| `assets/` | embedded font + licence | `FONT_BYTES :: #load(...)` |

Two small helpers used everywhere:

- `read_file_str(path, buf) -> (string, bool)` — one-shot read into a caller buffer.
- `open_path(path) -> (linux.Fd, linux.Errno)` — NUL-safe open (see §7).

---

## 3. Startup sequence

`main()` → parse args → `discover_all(&app, sys_root)` → either `run_ui()` or `probe_run()`.

`discover_all` order matters:

1. **Fixed sections** added first, in `Section_Id` order, so enum values remain valid indices.
2. `topo_discover` — buses, cores, P/E or CCD grouping. Returns false if no CPUs.
3. Per-class groups created for clocks, temperatures and usage.
4. `discover_clocks` — one fd per physical core.
5. `discover_temps` — package + per-core temps, joined via `core_id`.
6. `usage_init` — opens `/proc/stat`, primes deltas, creates computed usage metrics.
7. `discover_rapl` — package and IA-core energy counters.
8. `discover_spd` — DIMM temperatures and the SPD JEDEC reference.
9. `discover_gpu` — amdgpu hwmon rows, GPU busy, PCI id lookup for the name.
10. `discover_voltages` — every non-amdgpu `in*_input`.
11. `discover_memory_info` — SMBIOS speed/voltage/part, always creates the two rows.
12. `discover_storage` — one section per drive.
13. `discover_net` — one section per physical interface.
14. `discover_build_labels` — composes section titles from the resolved short names.

> **Rule:** anything that adds metrics must run during discovery. Adding metrics later would
> race with the sampler, so runtime changes only ever *update values* (see §6).

---

## 4. Threading model and ownership

| State | Owner | Notes |
| --- | --- | --- |
| `app.metrics[]` | **sampler thread** | UI reads only the snapshot copy |
| `app.sources[]` | sampler (values), discovery (creation) | perms refresh reopens fds on the sampler thread |
| `app.sections[]`, `app.groups[]` | **UI thread** | expanded flags, column widths, scroll |
| section **title strings** | UI thread | rebuilt via `perms.labels_dirty` |
| `sampler.snapshot[]` | written by sampler under `sampler.mu`, read by UI under the same mutex | 512 × `Sensor_Metric` copy per tick |
| `sampler.interval`, `sampler.quit` | guarded by `sampler.mu` | UI writes interval; sampler reads |
| `perms.state`, `perms.pending`, `perms.labels_dirty` | guarded by `perms.mu` | worker writes, UI/sampler read |

Threads:

- **UI / main thread** — all raylib calls. Never touches fds or metrics directly.
- **Sampler thread** — created in `run_ui`, loops forever until `quit`. Sleeps in ≤50 ms
  slices so interval changes and shutdown are responsive, ~20 wake-ups/s at idle.
- **Perms worker** — created on demand when the user clicks *Set up*. Runs `pkexec`, waits,
  records the result. Never touches app state beyond the `perms` flags.

**Why the UI does not perform refreshes:** reopening an fd or rewriting `app.metrics` from the
UI thread would race the sampler. Instead the UI sets `perms.pending`, and the sampler calls
`perms_apply_refresh` at the top of its loop.

**Why section titles are rebuilt on the UI thread:** they are `string`s pointing into
`section_label_buf`. The UI owns and reads them, so the sampler only raises a
`labels_dirty` flag.

---

## 5. Data flow

### Discovery
Every sensor becomes a `Sensor_Source` (one fd + parse kind + scale) and a `Sensor_Metric`
(label, unit, class, group, source index). `metric_add_computed` creates metrics with
`src == NO_SOURCE` for values that are not single files (CPU usage, capacity, memory rows).

### Sample
`sample_all` walks metrics, skips `NO_SOURCE`, reads each source:

- `read_value` seeks to 0, reads ≤64 bytes, parses an integer, multiplies by scale.
- RAPL sources are special: they keep the previous `energy_uj` and timestamp and return
  `Δenergy / (Δt · 10⁶)` watts, adding `max_energy_range_uj` on wrap.
  The first call stores the baseline and returns no value → row shows `--`.
- `usage_update` reads `/proc/stat` once and pushes per-core and package percentages.
- `net_update` reads `/proc/net/dev` and `/proc/net/wireless`.

All of these call `metric_push`, which maintains `cur/min/max` and the **time-weighted**
average.

### Snapshot
After sampling, the sampler copies the whole metric array into `sampler.snapshot` under
`sampler.mu`. The UI copies it out under the same lock each frame. This is cheap (≈57 KB) at
10 FPS and removes every data race on metric values.

### Draw
`ui_draw_frame` → `sampler_get` → compute banner visibility → handle input → draw toolbar,
banner, header, content (scissored), scrollbar.

Sections and groups are walked in insertion order. A section with exactly one group renders
its rows directly; multi-group sections render group headers.

---

## 6. Runtime mutation rules

The metric array's **shape is fixed after discovery**. Values may change; structure may not.
That is why:

- Memory Speed/Voltage rows are created **unconditionally**, showing `--` until SMBIOS is
  readable. This lets the permission self-heal fill them in place.
- Power rows exist even when `energy_uj` is unreadable (source `usable = false`,
  `root = true`), so a successful setup only needs to reopen the fd.

`perms_apply_refresh` (sampler thread) does exactly two things:

1. Reopen every source with `root == true`, using the `reopen_path` stored at discovery.
2. Re-read SMBIOS and `metric_set_static` the two memory rows.

Then it sets `labels_dirty`; the UI calls `discover_build_labels` and the titles update.

---

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
6. **The SPD `eeprom` attribute only exposes page 0.** Reading at file offset 640 returns
   page-0 bytes again, so the XMP/EXPO region is unreachable through sysfs. That is why memory
   *timings* are not implemented.
7. **`Section_Id` values are indices.** The seven fixed sections must be created first and in
   enum order. Dynamic sections append after them.
8. **Section titles alias `section_label_buf`.** Never rebuild a title from the sampler thread.
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

---

## 8. Decisions and rejected alternatives

| Decision | Why | Rejected alternative |
| --- | --- | --- |
| Odin + `vendor:raylib` | the spec's constraint; small, direct bindings | GTK/Qt (heavy), SDL (extra dep) |
| Static raylib built from tag 6.0 | distro ships 6.2 and the bindings declare 6.0; vendor tree had no x86-64 static lib | symlinking 6.2 (ABI mismatch), dynamic link (runtime dep) |
| Both GLFW backends | native Wayland where available, X11 fallback otherwise | X11-only (blurry through XWayland on HiDPI) |
| Fixed-capacity arrays | zero steady-state allocation, simple ownership | dynamic arrays (allocation, fragmentation) |
| One fd per metric | no directory walks, no parsing costs per tick | re-reading paths each sample |
| Time-weighted average | interval is user-editable; plain mean would skew | `sum/count` |
| Sections dynamic (`section_count`) | drives and NICs are one-section-each | fixed enum (cannot scale) |
| SMBIOS for memory speed | the only vendor-neutral source of *configured* speed | SPD JEDEC (wrong when XMP is on), XMP decode (vendor-specific) |
| wext ioctl for SSID | no subprocess, no dependency; cfg80211 still emulates it | `iw` subprocess (spawn cost), nl80211 (400+ lines) |
| `pkexec` for setup | password handled by polkit, never by us | setuid (dangerous), sudo (needs a TTY) |
| systemd unit for DMI | udev cannot match a device that does not exist | chmod at every launch (prompt each time) |
| Manual padding instead of fmt widths | Odin zero-pads numeric widths | fighting the formatter |

---

## 9. Build system

```sh
sudo scripts/build-raylib-static.sh   # once per machine
./build.sh                            # -> bin/vibehw64
```

`build-raylib-static.sh`:

- clones raylib tag `6.0` into `temp/raylib-6.0` (relative to the repo root),
- builds with `PLATFORM=PLATFORM_DESKTOP GLFW_LINUX_ENABLE_X11=TRUE
  GLFW_LINUX_ENABLE_WAYLAND=TRUE`,
- installs `libraylib.a` into `$(odin root)/vendor/raylib/linux/`.

`build.sh` refuses to build if that archive is missing, then links with
`-define:RAYLIB_SHARED=false` plus the extra linker flags for GL, X11 extensions and Wayland.

**Portability:** the binary is only as portable as the build host's glibc (2.44 at v1.0). To
support older systems, build on the oldest glibc you intend to support.

---

## 10. Testing

- **Live** — `./bin/vibehw64 --probe --ticks 2` prints topology, every section and all four
  statistics. This is the primary development loop and works without a display.
- **Fixtures** — `--sys-root DIR` prefixes every sysfs path, so synthetic trees can emulate
  hardware. `ARCHIVE/temp/fixture-amd/` models a 5950X (two CCDs, one with larger L3);
  `ARCHIVE/temp/fixture-intel-fallback/` models a 12600K without PMU masks.
  A synthetic `firmware/dmi/tables/DMI` blob in the same tree exercises the SMBIOS walker.
- **Permission check** — `--probe | grep perms` reports whether setup is needed.
- **Not testable headlessly** — window rendering, column drag, scrollbar, the polkit dialog.

---

## 11. Adding a sensor family

1. Write `discover_<thing>(app, group)`.
2. For each file: `fd, ok := open_sensor(path)`, then
   `si := source_add(app, fd, .Milli_Int, 0.001, true)`, then
   `metric_add(app, label, .Celsius, .YourClass, group, si)`.
3. For values that are not a single file, use `metric_add_computed` and push with
   `metric_push` from a sampler hook (see `usage.odin`, `net.odin`).
4. Add a unit in `Sensor_Unit`, `unit_str`, `unit_decimals` if needed.
5. Add a colour threshold in `ui_row_color` (and gate it on `.Celsius`).
6. Call it from `discover_all` **before** `discover_build_labels`.

## 12. Known gaps / sensible next steps

| Gap | Notes |
| --- | --- |
| CPU core voltage | needs MSR `IA32_PERF_STATUS` (`/dev/cpu/*/msr` + udev) or a bound Super I/O |
| Board rails on this board | `it87 force_id=0x8689` returns `EBUSY` → would need `acpi_enforce_resources=lax`; not adopted |
| Memory timings (CL, tREFI) | SPD page 0 only; XMP/EXPO region unreachable |
| Wi-Fi SSID while associated | implemented but unverified — radio was down during development |
| SATA temperatures | implement matching already exists; needs `drivetemp` loaded |
| Saved window/section state | deliberately absent in v1 |
| NVIDIA GPUs | out of scope |

## 13. Glossary

- **RAPL** — Running Average Power Limit; Intel's energy counters in `powercap`.
- **CCD** — core complex die; one L3 domain on AMD, the natural grouping unit.
- **P/E core** — performance / efficiency core on Intel hybrid CPUs.
- **SPD** — the EEPROM on a DIMM describing the module.
- **SMBIOS / DMI** — firmware tables describing the machine, including memory devices.
- **hwmon** — the kernel's generic hardware-monitoring class, exposed under `/sys/class/hwmon`.
