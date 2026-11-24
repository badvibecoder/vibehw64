package main

// Sensor discovery from sysfs / hwmon / powercap.
//
// Every metric owns a file descriptor opened exactly once at discovery time.
// Sampling re-seeks those descriptors into stack buffers, so the steady-state
// loop never walks a directory and never allocates.

import "core:fmt"
import "core:strconv"
import "core:sys/linux"
import "core:time"

MAX_SENSORS   :: 512
MAX_SOURCES   :: 512
MAX_GROUPS    :: 128
MAX_SECTIONS  :: 64

Sensor_Unit :: enum u8 {
	MHz,
	Celsius,
	Watts,
	RPM,
	Percent,
	Millivolts,
	Volts,
	MTs,
	Gigabytes,
	Terabytes,
	Gibibytes,
	Mbps,
	DBm,
	Seconds,
	Milliseconds,
}

Sensor_Class :: enum u8 {
	CPU_Pkg,
	CPU_Core,
	CPU_TjMax_Distance,
	CPU_Max_Distance,
	DIMM,
	GPU_Edge,
	GPU_Junction,
	GPU_Mem,
	GPU_Power,
	GPU_Fan,
	GPU_Clock,
	GPU_Busy,
	Voltage,
	Drive,
	Other,
	Temp_Limit,
}

Parse_Kind :: enum u8 {
	Milli_Int,
	Micro_Int,
	Raw_Int,
	Pct_Int,
	Hz,
	Drm_Int,
	Energy_Uj,
}

Section_Id :: enum u8 {
	CPU,
	Memory,
	GPU,
	Voltages,
}

NO_SOURCE :: u16(0xFFFF)
NO_METRIC :: u16(0xFFFF)

Section :: struct {
	label:    string,
	expanded: bool,
}

Group :: struct {
	label:     [MAX_LABEL]u8,
	label_len: u8,
	section:   u8,
	expanded:  bool,
}

Sensor_Source :: struct {
	fd:        linux.Fd,
	kind:      Parse_Kind,
	scale:     f64,
	usable:    bool,
	root:      bool, // needs elevated permissions (EACCES on energy_uj)
	prev_uj:    u64,
	prev_t:     time.Time,
	have_prev:  bool,
	max_range:  u64,
	reopen_path: [160]u8,
	reopen_len:  u8,
}

Sensor_Metric :: struct {
	label:        [MAX_LABEL]u8,
	label_len:    u8,
	unit:         Sensor_Unit,
	class:        Sensor_Class,
	group:        u8,
	src:          u16,
	derived_from: u16, // source metric for derived rows (NO_METRIC if none)
	limit:        f64, // TjMax for distance rows
	cur:          f64,
	min:          f64,
	max:          f64,
	wsum:         f64,
	wtime:        f64,
	seen:         bool,
}

App :: struct {
	topo:          Topology,
	cpu_short:     [72]u8,
	cpu_short_len: u8,
	gpu_short:     [72]u8,
	gpu_short_len: u8,
	ram_short:     [72]u8,
	ram_short_len: u8,
	ram_speed_mt:  int,
	ram_voltage_mv: int,
	ram_jedec_mt:  int,
	dmi_ok:        bool,
	memory_speed_metric:   u16,
	memory_voltage_metric: u16,
	usage_fd:      linux.Fd,
	usage_primed:  bool,
	usage_metric:  [MAX_CPUS]u16,
	pkg_usage_metric: u16,
	prev_total:    [MAX_CPUS + 1]u64,
	prev_busy:     [MAX_CPUS + 1]u64,
	sections:     [MAX_SECTIONS]Section,
	section_count: int,
	groups:       [MAX_GROUPS]Group,
	group_count:  int,
	metrics:      [MAX_SENSORS]Sensor_Metric,
	metric_count: int,
	sources:      [MAX_SOURCES]Sensor_Source,
	source_count: int,
	interval_ms:  int,
	sys_root:     string,
}

// ---------------------------------------------------------------------------
// registry helpers
// ---------------------------------------------------------------------------

group_add :: proc(app: ^App, section: Section_Id, label: string, expanded: bool) -> u8 {
	return group_add_at(app, u8(section), label, expanded)
}

metric_add_computed :: proc(app: ^App, label: string, unit: Sensor_Unit, class: Sensor_Class, group: u8) -> int {
	if app.metric_count >= MAX_SENSORS {
		return -1
	}
	m := &app.metrics[app.metric_count]
	m.label_len = label_set(m.label[:], label)
	m.unit = unit
	m.class = class
	m.group = group
	m.src = NO_SOURCE
	m.derived_from = NO_METRIC
	app.metric_count += 1
	return app.metric_count - 1
}

source_add :: proc(app: ^App, fd: linux.Fd, kind: Parse_Kind, scale: f64, usable: bool) -> int {
	if app.source_count >= MAX_SOURCES {
		if fd >= 0 {
			linux.close(fd)
		}
		return -1
	}
	s := &app.sources[app.source_count]
	s.fd = fd
	s.kind = kind
	s.scale = scale
	s.usable = usable
	app.source_count += 1
	return app.source_count - 1
}

metric_add :: proc(app: ^App, label: string, unit: Sensor_Unit, class: Sensor_Class, group: u8, si: int) -> int {
	if app.metric_count >= MAX_SENSORS || si < 0 {
		return -1
	}
	m := &app.metrics[app.metric_count]
	m.label_len = label_set(m.label[:], label)
	m.unit = unit
	m.class = class
	m.group = group
	m.src = u16(si)
	m.derived_from = NO_METRIC
	app.metric_count += 1
	return app.metric_count - 1
}

	add_derived_row :: proc(
	app: ^App,
	label: string,
	class: Sensor_Class,
	group: u8,
	src: int,
	limit: f64,
) {
	if src < 0 {
		return
	}
	di := metric_add_computed(app, label, .Celsius, class, group)
	if di >= 0 {
		app.metrics[di].derived_from = u16(src)
		app.metrics[di].limit = limit
	}
}

open_sensor :: proc(path: string) -> (linux.Fd, bool) {
	fd, err := open_path(path)
	return fd, err == .NONE
}

// ---------------------------------------------------------------------------
// sampling
// ---------------------------------------------------------------------------

read_value :: proc(app: ^App, si: int) -> (f64, bool) {
	if si < 0 || si >= app.source_count {
		return 0, false
	}
	src := &app.sources[si]
	if !src.usable {
		return 0, false
	}
	buf: [64]u8
	if _, err := linux.lseek(src.fd, 0, .SET); err != .NONE {
		return 0, false
	}
	n, rerr := linux.read(src.fd, buf[:])
	if rerr != .NONE || n <= 0 {
		return 0, false
	}

	if src.kind == .Energy_Uj {
		v: u64 = 0
		good := true
		for i in 0 ..< n {
			c := buf[i]
			if c == '\n' || c == '\r' || c == ' ' {
				break
			}
			if c < '0' || c > '9' {
				good = false
				break
			}
			v = v * 10 + u64(c - '0')
		}
		if !good {
			return 0, false
		}
		now := time.now()
		if !src.have_prev {
			src.prev_uj = v
			src.prev_t = now
			src.have_prev = true
			return 0, false
		}
		dt_ns := time.duration_nanoseconds(time.diff(src.prev_t, now))
		if dt_ns <= 0 {
			return 0, false
		}
		delta: u64
		if v >= src.prev_uj {
			delta = v - src.prev_uj
		} else {
			delta = (v + src.max_range) - src.prev_uj
		}
		src.prev_uj = v
		src.prev_t = now
		return f64(delta) / (f64(dt_ns) / 1.0e9) / 1.0e6, true
	}

	v, ok := strconv.parse_int(trim_ws(string(buf[:n])), 10)
	if !ok {
		return 0, false
	}
	return f64(v) * src.scale, true
}

metric_push :: proc(app: ^App, idx: int, v: f64, dt_sec: f64) {
	if idx < 0 || idx >= app.metric_count {
		return
	}
	m := &app.metrics[idx]
	m.cur = v
	if !m.seen {
		m.min = v
		m.max = v
		m.seen = true
	}
	if v < m.min {
		m.min = v
	}
	if v > m.max {
		m.max = v
	}
	m.wsum += v * dt_sec
	m.wtime += dt_sec
}

// Sets a metric whose value never changes (e.g. a configured memory voltage).
metric_set_static :: proc(app: ^App, idx: int, v: f64) {
	if idx < 0 || idx >= app.metric_count {
		return
	}
	m := &app.metrics[idx]
	m.cur = v
	m.min = v
	m.max = v
	m.wsum = v
	m.wtime = 1
	m.seen = true
}

// Derived rows reuse an already-sampled metric instead of opening a second fd.
// TjMax distance is the first user: crit is static, the temperature is not.
derived_update :: proc(app: ^App, dt_sec: f64) {
	for i in 0 ..< app.metric_count {
		m := &app.metrics[i]
		if m.derived_from == NO_METRIC {
			continue
		}
		src := &app.metrics[m.derived_from]
		if !src.seen {
			continue
		}
		metric_push(app, i, m.limit - src.cur, dt_sec)
	}
}

sample_all :: proc(app: ^App, dt_sec: f64) {
	for i in 0 ..< app.metric_count {
		if app.metrics[i].src == NO_SOURCE {
			continue
		}
		v, ok := read_value(app, int(app.metrics[i].src))
		if !ok {
			continue
		}
		metric_push(app, i, v, dt_sec)
	}
	derived_update(app, dt_sec)
}

metric_avg :: proc(m: ^Sensor_Metric) -> f64 {
	if m.wtime <= 0 {
		return m.cur
	}
	return m.wsum / m.wtime
}

reset_stats :: proc(app: ^App) {
	for i in 0 ..< app.metric_count {
		m := &app.metrics[i]
		m.min = m.cur
		m.max = m.cur
		m.wsum = 0
		m.wtime = 0
	}
	for i in 0 ..< app.source_count {
		app.sources[i].have_prev = false
	}
}

// ---------------------------------------------------------------------------
// discovery
// ---------------------------------------------------------------------------

section_label_buf: [MAX_SECTIONS][128]u8

section_add :: proc(app: ^App, label: string, expanded: bool) -> u8 {
	i := app.section_count
	if i >= MAX_SECTIONS {
		return 0
	}
	buf := &section_label_buf[i]
	app.sections[i].label = fmt.bprintf(buf[:], "%s", label)
	app.sections[i].expanded = expanded
	app.section_count += 1
	return u8(i)
}

set_section_label_at :: proc(app: ^App, idx: u8, label: string) {
	if int(idx) >= app.section_count {
		return
	}
	buf := &section_label_buf[idx]
	app.sections[idx].label = fmt.bprintf(buf[:], "%s", label)
}

set_group_label_at :: proc(app: ^App, idx: u8, label: string) {
	if int(idx) >= app.group_count {
		return
	}
	g := &app.groups[idx]
	g.label_len = label_set(g.label[:], label)
}

group_add_at :: proc(app: ^App, section: u8, label: string, expanded: bool) -> u8 {
	i := app.group_count
	if i >= MAX_GROUPS {
		return 0
	}
	g := &app.groups[i]
	g.label_len = label_set(g.label[:], label)
	g.section = section
	g.expanded = expanded
	app.group_count += 1
	return u8(i)
}

set_section_label :: proc(app: ^App, si: Section_Id, base: string, suffix: string) {
	buf := &section_label_buf[si]
	if len(suffix) > 0 {
		app.sections[si].label = fmt.bprintf(buf[:], "%s - %s", base, suffix)
	} else {
		app.sections[si].label = fmt.bprintf(buf[:], "%s", base)
	}
}

discover_build_labels :: proc(app: ^App) {
	cpu_n := label_str(app.cpu_short[:], app.cpu_short_len)
	gpu_n := label_str(app.gpu_short[:], app.gpu_short_len)
	ram_n := label_str(app.ram_short[:], app.ram_short_len)
	// Configured speed above the SPD's JEDEC bin means an overclock profile is on.
	profile_buf: [128]u8
	if app.ram_speed_mt > 0 && app.ram_jedec_mt > 0 && app.ram_speed_mt > app.ram_jedec_mt {
		ram_n = fmt.bprintf(profile_buf[:], "%s  XMP/EXPO", ram_n)
	}
	set_section_label(app, .CPU, "CPU", cpu_n)
	mem_base := "Memory"
	if app.ram_jedec_mt > 0 {
		mem_base = "Memory (DDR5 SPD)"
	}
	set_section_label(app, .Memory, mem_base, ram_n)
	set_section_label(app, .GPU, "GPU (AMD)", gpu_n)
	set_section_label(app, .Voltages, "CPU & Board Voltages", "")
}

discover_all :: proc(app: ^App, sys_root: string) -> bool {
	app.sys_root = sys_root
	if app.interval_ms == 0 {
		app.interval_ms = 1500
	}
	app.section_count = 0
	app.group_count = 0
	app.metric_count = 0
	app.source_count = 0
	// Fixed sections, added in Section_Id order so enum values stay valid.
	section_add(app, "CPU", true)
	section_add(app, "Memory (DDR5 SPD)", true)
	section_add(app, "GPU (AMD)", true)
	section_add(app, "CPU & Board Voltages", true)

	if !topo_discover(&app.topo, sys_root) {
		return false
	}

	{
		scratch: [128]u8
		model := label_str(app.topo.model[:], app.topo.model_len)
		app.cpu_short_len = label_set(app.cpu_short[:], cpu_short_name(model, scratch[:]))
	}

	pkg_g := group_add(app, .CPU, "Package & Power", true)
	thermal_pkg_g := group_add(app, .CPU, "Thermal Headroom - Package", true)
	mem_usage_g := group_add(app, .Memory, "Usage", true)
	mem_modules_g := group_add(app, .Memory, "Modules", true)
	mem_temp_g := group_add(app, .Memory, "Temperatures", true)
	gpu_g := group_add(app, .GPU, "GPU", true)

	clock_g: [MAX_CLASSES]u8
	temp_g: [MAX_CLASSES]u8
	usage_g: [MAX_CLASSES]u8
	tj_g: [MAX_CLASSES]u8
	max_g: [MAX_CLASSES]u8
	g_lab: [MAX_LABEL]u8

	for ci in 0 ..< app.topo.class_count {
		lab := class_label(&app.topo, u8(ci))
		exp := app.topo.classes[ci].expanded
		lbl := fmt_label(&g_lab, "CPU Core Clocks - %s", lab)
		clock_g[ci] = group_add(app, .CPU, lbl, exp)
	}
	for ci in 0 ..< app.topo.class_count {
		lab := class_label(&app.topo, u8(ci))
		exp := app.topo.classes[ci].expanded
		lbl := fmt_label(&g_lab, "CPU Core Usage - %s", lab)
		usage_g[ci] = group_add(app, .CPU, lbl, exp)
	}
	for ci in 0 ..< app.topo.class_count {
		lab := class_label(&app.topo, u8(ci))
		exp := app.topo.classes[ci].expanded
		lbl := fmt_label(&g_lab, "CPU Core Temperatures - %s", lab)
		temp_g[ci] = group_add(app, .CPU, lbl, exp)
	}

	for ci in 0 ..< app.topo.class_count {
		lab := class_label(&app.topo, u8(ci))
		exp := app.topo.classes[ci].expanded
		tj_lab := fmt_label(&g_lab, "%s - Distance from TjMax", lab)
		tj_g[ci] = group_add(app, .CPU, tj_lab, exp)
		max_lab := fmt_label(&g_lab, "%s - Distance from Tcontrol", lab)
		max_g[ci] = group_add(app, .CPU, max_lab, exp)
	}
	volt_g := group_add(app, .Voltages, "Voltages", true)

	discover_clocks(app, clock_g[:])
	discover_temps(app, temp_g[:], pkg_g,
		Temp_Groups{core = tj_g[:], pkg = thermal_pkg_g},
		Temp_Groups{core = max_g[:], pkg = thermal_pkg_g})
	usage_init(app, usage_g[:], pkg_g)
	discover_rapl(app, pkg_g)
	discover_spd(app, mem_temp_g)
	discover_gpu(app, gpu_g)
	discover_voltages(app, volt_g)
	discover_memory_info(app, mem_usage_g, mem_modules_g)
	meminfo_init(app, mem_usage_g)
	discover_storage(app)
	discover_net(app)

	// Keep the generic board/peripheral sensors at the very bottom of the list.
	other_sec := section_add(app, "Other Sensors", true)
	other_temp_g := group_add_at(app, other_sec, "Temperatures", true)
	other_fan_g := group_add_at(app, other_sec, "Fans", true)
	discover_other_sensors(app, other_temp_g, other_fan_g)

	discover_build_labels(app)

	return app.metric_count > 0
}

discover_clocks :: proc(app: ^App, groups: []u8) {
	path_buf: [512]u8
	label_buf: [MAX_LABEL]u8
	for c in 0 ..< app.topo.core_count {
		core := &app.topo.cores[c]
		p := fmt_path(
			&path_buf,
			"%s/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq",
			app.sys_root,
			core.cpu,
		)
		fd, ok := open_sensor(p)
		if !ok {
			continue
		}
		si := source_add(app, fd, .Milli_Int, 0.001, true)
		tag := class_tag(&app.topo, core.class)
		lbl := fmt_label(&label_buf, "Core %d [%s]", core.cpu, tag)
		metric_add(app, lbl, .MHz, .CPU_Core, groups[core.class], si)
	}
}

Temp_Entry :: struct {
	fd:           linux.Fd,
	core_id:      i32,
	has_id:       bool,
	crit:         f64,
	has_crit:     bool,
	max_temp:     f64,
	has_max_temp: bool,
	raw:          [MAX_LABEL]u8,
	raw_len:      u8,
}

Temp_Groups :: struct {
	core: []u8,
	pkg:  u8,
}

// coretemp documents tempX_crit as TjMax and tempX_max as Tcontrol, the
// recommended operating limit at which all cooling devices should be on.
read_temp_limit :: proc(app: ^App, h: int, i: int, which: string) -> (f64, bool) {
	path_buf: [512]u8
	buf: [64]u8
	p := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/temp%d_%s", app.sys_root, h, i, which)
	s, ok := read_file_str(p, buf[:])
	if !ok {
		return 0, false
	}
	v, vok := strconv.parse_int(trim_ws(s), 10)
	if !vok || v <= 0 {
		return 0, false
	}
	return f64(v) / 1000.0, true
}

discover_temps :: proc(
	app: ^App,
	groups: []u8,
	pkg_group: u8,
	tj: Temp_Groups,
	tmax: Temp_Groups,
) {
	path_buf: [512]u8
	name_buf: [256]u8
	label_buf: [MAX_LABEL]u8
	entries: [MAX_CPUS]Temp_Entry
	n := 0
	pkg_crit: f64 = 0
	pkg_tmax: f64 = 0

	for h in 0 ..< 64 {
		p := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/name", app.sys_root, h)
		s, ok := read_file_str(p, name_buf[:])
		if !ok || trim_ws(s) != "coretemp" {
			continue
		}

		for i in 1 ..= 64 {
			lp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/temp%d_label", app.sys_root, h, i)
			ls, lok := read_file_str(lp, name_buf[:])
			if !lok {
				continue
			}
			lab := trim_ws(ls)
			vp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/temp%d_input", app.sys_root, h, i)
			fd, fok := open_sensor(vp)
			if !fok {
				continue
			}

			if len(lab) >= 10 && lab[:10] == "Package id" {
				si := source_add(app, fd, .Milli_Int, 0.001, true)
				mi := metric_add(app, "Package Temp", .Celsius, .CPU_Pkg, pkg_group, si)
				if mi >= 0 {
					if crit, cok := read_temp_limit(app, h, i, "crit"); cok {
						pkg_crit = crit
						ti := metric_add_computed(app, "TjMax", .Celsius, .Temp_Limit, tj.pkg)
						metric_set_static(app, ti, crit)
						add_derived_row(app, "Distance from TjMax", .CPU_TjMax_Distance, tj.pkg, mi, crit)
					}
					if tmax_v, tok := read_temp_limit(app, h, i, "max"); tok {
						pkg_tmax = tmax_v
						ti := metric_add_computed(app, "Tcontrol", .Celsius, .Temp_Limit, tmax.pkg)
						metric_set_static(app, ti, tmax_v)
						add_derived_row(app, "Distance from Tcontrol", .CPU_Max_Distance, tmax.pkg, mi, tmax_v)
					}
				}
				continue
			}
			if len(lab) > 5 && lab[:5] == "Core " {
				if n >= MAX_CPUS {
					linux.close(fd)
					continue
				}
				e := &entries[n]
				e.fd = fd
				e.has_id = false
				e.has_crit = false
				e.crit = 0
				e.has_max_temp = false
				e.max_temp = 0
				e.raw_len = label_set(e.raw[:], lab)
				if v, vok := strconv.parse_int(lab[5:], 10); vok {
					e.core_id = i32(v)
					e.has_id = true
				}
				if crit, cok := read_temp_limit(app, h, i, "crit"); cok {
					e.crit = crit
					e.has_crit = true
				}
				if tmax_v, tok := read_temp_limit(app, h, i, "max"); tok {
					e.max_temp = tmax_v
					e.has_max_temp = true
				}
				n += 1
				continue
			}
			linux.close(fd)
		}
	}

	// Put the real package limits in the per-class subsection headers.
	for ci in 0 ..< app.topo.class_count {
		base := class_label(&app.topo, u8(ci))
		if pkg_crit > 0 {
			lbl := fmt_label(&label_buf, "%s - Distance from TjMax (%.1f C)", base, pkg_crit)
			set_group_label_at(app, tj.core[ci], lbl)
		}
		if pkg_tmax > 0 {
			lbl := fmt_label(&label_buf, "%s - Distance from Tcontrol (%.1f C)", base, pkg_tmax)
			set_group_label_at(app, tmax.core[ci], lbl)
		}
	}

	// Only relabel through core_id when the sets reconcile exactly.
	map_ok := n == app.topo.core_count
	if map_ok {
		for i in 0 ..< n {
			if !entries[i].has_id || core_by_id(&app.topo, entries[i].core_id) < 0 {
				map_ok = false
				break
			}
		}
	}

	for i in 0 ..< n {
		e := &entries[i]
		si := source_add(app, e.fd, .Milli_Int, 0.001, true)
		if map_ok {
			ci := core_by_id(&app.topo, e.core_id)
			core := &app.topo.cores[ci]
			tag := class_tag(&app.topo, core.class)
			lbl := fmt_label(&label_buf, "Core %d [%s]", core.cpu, tag)
			mi := metric_add(app, lbl, .Celsius, .CPU_Core, groups[core.class], si)
			if mi >= 0 {
				if e.has_crit {
					add_derived_row(app, lbl, .CPU_TjMax_Distance, tj.core[core.class], mi, e.crit)
				}
				if e.has_max_temp {
					add_derived_row(app, lbl, .CPU_Max_Distance, tmax.core[core.class], mi, e.max_temp)
				}
			}
		} else {
			raw := label_str(e.raw[:], e.raw_len)
			mi := metric_add(app, raw, .Celsius, .CPU_Core, groups[0], si)
			if mi >= 0 {
				if e.has_crit {
					add_derived_row(app, raw, .CPU_TjMax_Distance, tj.core[0], mi, e.crit)
				}
				if e.has_max_temp {
					add_derived_row(app, raw, .CPU_Max_Distance, tmax.core[0], mi, e.max_temp)
				}
			}
		}
	}
}

add_power_metric :: proc(app: ^App, label: string, dir: string, group: u8) {
	path_buf: [512]u8
	p := fmt_path(&path_buf, "%s/energy_uj", dir)
	fd, err := open_path(p)
	if err != .NONE {
		si := source_add(app, linux.Fd(-1), .Energy_Uj, 1, false)
		if si >= 0 {
			app.sources[si].root = err == .EACCES
			app.sources[si].reopen_len = label_set(app.sources[si].reopen_path[:], dir)
		}
		metric_add(app, label, .Watts, .CPU_Pkg, group, si)
		return
	}

	mr: u64 = 0
	mp := fmt_path(&path_buf, "%s/max_energy_range_uj", dir)
	if mfd, merr := open_path(mp); merr == .NONE {
		buf: [64]u8
		if rn, rerr := linux.read(mfd, buf[:]); rerr == .NONE && rn > 0 {
			if v, vok := strconv.parse_int(trim_ws(string(buf[:rn])), 10); vok {
				mr = u64(v)
			}
		}
		linux.close(mfd)
	}

	si := source_add(app, fd, .Energy_Uj, 1, true)
	if si >= 0 {
		app.sources[si].max_range = mr
	}
	metric_add(app, label, .Watts, .CPU_Pkg, group, si)
}

// PL1/PL2 and their time windows, read once and published as static rows.
// The kernel names the constraints, so match long_term/short_term rather than
// trusting index order (some platforms also expose a peak/PL4 constraint).
add_power_limit_rows :: proc(app: ^App, group: u8, pkg_dir: string) {
	path_buf: [512]u8
	name_buf: [64]u8
	val_buf: [64]u8
	label_buf: [MAX_LABEL]u8

	for c in 0 ..< 3 {
		np := fmt_path(&path_buf, "%s/constraint_%d_name", pkg_dir, c)
		ns, ok := read_file_str(np, name_buf[:])
		if !ok {
			continue
		}
		nm := trim_ws(ns)
		pl: string
		if nm == "long_term" {
			pl = "PL1"
		} else if nm == "short_term" {
			pl = "PL2"
		} else {
			continue
		}

		lp := fmt_path(&path_buf, "%s/constraint_%d_power_limit_uw", pkg_dir, c)
		if ls, lok := read_file_str(lp, val_buf[:]); lok {
			if uw, uok := strconv.parse_int(trim_ws(ls), 10); uok && uw > 0 {
				lbl := fmt_label(&label_buf, "%s Power Limit", pl)
				idx := metric_add_computed(app, lbl, .Watts, .CPU_Pkg, group)
				metric_set_static(app, idx, f64(uw) / 1.0e6)
			}
		}

		wp := fmt_path(&path_buf, "%s/constraint_%d_time_window_us", pkg_dir, c)
		if ws, wok := read_file_str(wp, val_buf[:]); wok {
			if us, uok := strconv.parse_int(trim_ws(ws), 10); uok && us > 0 {
				// TAU windows range from milliseconds to tens of seconds;
				// pick the unit that keeps the number readable.
				unit := Sensor_Unit.Seconds
				val := f64(us) / 1.0e6
				if us < 1_000_000 {
					unit = .Milliseconds
					val = f64(us) / 1.0e3
				}
				lbl := fmt_label(&label_buf, "%s Time Window", pl)
				idx := metric_add_computed(app, lbl, unit, .CPU_Pkg, group)
				metric_set_static(app, idx, val)
			}
		}
	}
}

// RAPL. intel-rapl and intel-rapl-mmio mirror the same counters, so only one
// prefix is used: the MSR-backed tree when present.
discover_rapl :: proc(app: ^App, pkg_group: u8) {
	path_buf: [512]u8
	name_buf: [128]u8
	prefixes := [3]string{"intel-rapl", "amd-rapl", "intel-rapl-mmio"}

	dom := -1
	dom_prefix := ""
	for pf in prefixes {
		for i in 0 ..< 4 {
			p := fmt_path(&path_buf, "%s/class/powercap/%s:%d/name", app.sys_root, pf, i)
			s, ok := read_file_str(p, name_buf[:])
			if !ok {
				continue
			}
			if trim_ws(s) == "package-0" {
				dom = i
				dom_prefix = pf
				break
			}
		}
		if dom >= 0 {
			break
		}
	}
	if dom < 0 {
		return
	}

	pkg_dir := fmt_path(&path_buf, "%s/class/powercap/%s:%d", app.sys_root, dom_prefix, dom)
	add_power_metric(app, "Package Power", pkg_dir, pkg_group)
	// pkg_dir aliases path_buf, which the loop below reuses; keep a copy so the
	// limit rows can be appended after the measured power rows.
	pkg_copy: [256]u8
	pkg_len := label_set(pkg_copy[:], pkg_dir)

	for j in 0 ..< 8 {
		p := fmt_path(&path_buf, "%s/class/powercap/%s:%d:%d/name", app.sys_root, dom_prefix, dom, j)
		s, ok := read_file_str(p, name_buf[:])
		if !ok {
			continue
		}
		if trim_ws(s) == "core" {
			core_dir := fmt_path(&path_buf, "%s/class/powercap/%s:%d:%d", app.sys_root, dom_prefix, dom, j)
			add_power_metric(app, "IA Cores Power", core_dir, pkg_group)
			break
		}
	}

	add_power_limit_rows(app, pkg_group, label_str(pkg_copy[:], pkg_len))
}

i2c_addr_from_target :: proc(s: string) -> (u32, bool) {
	start := len(s)
	for start > 0 && s[start - 1] != '-' {
		start -= 1
	}
	if start <= 0 || start >= len(s) {
		return 0, false
	}
	v: u32 = 0
	for i in start ..< len(s) {
		c := s[i]
		d: u32
		switch {
		case c >= '0' && c <= '9':
			d = u32(c - '0')
		case c >= 'a' && c <= 'f':
			d = u32(c - 'a') + 10
		case c >= 'A' && c <= 'F':
			d = u32(c - 'A') + 10
		case:
			return 0, false
		}
		v = v * 16 + d
	}
	return v, true
}

discover_spd :: proc(app: ^App, group: u8) {
	path_buf: [512]u8
	name_buf: [128]u8
	link_buf: [512]u8
	label_buf: [MAX_LABEL]u8
	dimm := 0

	for h in 0 ..< 64 {
		p := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/name", app.sys_root, h)
		s, ok := read_file_str(p, name_buf[:])
		if !ok {
			continue
		}
		nm := trim_ws(s)
		if nm != "spd5118" && nm != "jc42" {
			continue
		}

		vp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/temp1_input", app.sys_root, h)
		fd, fok := open_sensor(vp)
		if !fok {
			continue
		}

		if app.ram_jedec_mt == 0 {
			ep := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/device/eeprom", app.sys_root, h)
			scratch: [96]u8
			if sum, mt := spd_summary(ep, scratch[:]); len(sum) > 0 {
				app.ram_short_len = label_set(app.ram_short[:], sum)
				app.ram_jedec_mt = mt
			}
		}

		addr: u32 = 0
		has_addr := false
		lp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/device", app.sys_root, h)
		if ln, lok2 := readlink_str(lp, link_buf[:]); lok2 && ln > 0 {
			addr, has_addr = i2c_addr_from_target(string(link_buf[:ln]))
		}

		lbl: string
		if has_addr {
			lbl = fmt_label(&label_buf, "DIMM #%d (0x%X)", dimm, addr)
		} else {
			lbl = fmt_label(&label_buf, "DIMM #%d", dimm)
		}
		si := source_add(app, fd, .Milli_Int, 0.001, true)
		metric_add(app, lbl, .Celsius, .DIMM, group, si)
		dimm += 1
	}
}

discover_gpu :: proc(app: ^App, group: u8) {
	path_buf: [512]u8
	name_buf: [128]u8
	label_buf: [MAX_LABEL]u8
	found := false

	for h in 0 ..< 64 {
		p := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/name", app.sys_root, h)
		s, ok := read_file_str(p, name_buf[:])
		if !ok || trim_ws(s) != "amdgpu" {
			continue
		}
		found = true

		for i in 1 ..= 4 {
			lp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/temp%d_label", app.sys_root, h, i)
			tl, lok := read_file_str(lp, name_buf[:])
			if !lok {
				continue
			}
			label := trim_ws(tl)
			vp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/temp%d_input", app.sys_root, h, i)
			fd, fok := open_sensor(vp)
			if !fok {
				continue
			}
			cls := Sensor_Class.GPU_Edge
			switch label {
			case "junction":
				cls = .GPU_Junction
			case "mem":
				cls = .GPU_Mem
			}
			lbl := fmt_label(&label_buf, "GPU %s", label)
			si := source_add(app, fd, .Milli_Int, 0.001, true)
			metric_add(app, lbl, .Celsius, cls, group, si)
		}

		pv := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/power1_input", app.sys_root, h)
		if fd, fok := open_sensor(pv); fok {
			plabel := "Power"
			lp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/power1_label", app.sys_root, h)
			if ls, lok := read_file_str(lp, name_buf[:]); lok {
				if t := trim_ws(ls); len(t) > 0 {
					plabel = t
				}
			}
			lbl := fmt_label(&label_buf, "GPU Power (%s)", plabel)
			si := source_add(app, fd, .Micro_Int, 0.000001, true)
			metric_add(app, lbl, .Watts, .GPU_Power, group, si)
		}

		fv := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/fan1_input", app.sys_root, h)
		if fd, fok := open_sensor(fv); fok {
			si := source_add(app, fd, .Raw_Int, 1, true)
			metric_add(app, "GPU Fan", .RPM, .GPU_Fan, group, si)
		}

		for fi in 1 ..= 2 {
			lp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/freq%d_label", app.sys_root, h, fi)
			fl, lok := read_file_str(lp, name_buf[:])
			if !lok {
				continue
			}
			label := trim_ws(fl)
			vp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/freq%d_input", app.sys_root, h, fi)
			fd, fok := open_sensor(vp)
			if !fok {
				continue
			}
			lbl := fmt_label(&label_buf, "GPU %s", label)
			si := source_add(app, fd, .Hz, 0.000001, true)
			metric_add(app, lbl, .MHz, .GPU_Clock, group, si)
		}

		vv := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/in0_input", app.sys_root, h)
		if fd, fok := open_sensor(vv); fok {
			si := source_add(app, fd, .Raw_Int, 1, true)
			metric_add(app, "GPU vddgfx", .Millivolts, .Voltage, group, si)
		}
	}

	if !found {
		return
	}

	// GPU busy lives on the DRM card, not in hwmon. Never assume card0.
	for ci in 0 ..< 10 {
		vp := fmt_path(&path_buf, "%s/class/drm/card%d/device/vendor", app.sys_root, ci)
		s, ok := read_file_str(vp, name_buf[:])
		if !ok || trim_ws(s) != "0x1002" {
			continue
		}
		dp := fmt_path(&path_buf, "%s/class/drm/card%d/device/device", app.sys_root, ci)
		if ds, dok := read_file_str(dp, name_buf[:]); dok {
			if id, iok := parse_hex_id(trim_ws(ds)); iok {
				sub_v: u16
				sub_d: u16
				sv_ok := false
				sd_ok := false
				svp := fmt_path(&path_buf, "%s/class/drm/card%d/device/subsystem_vendor", app.sys_root, ci)
				if ss, ok := read_file_str(svp, name_buf[:]); ok {
					if v, pok := parse_hex_id(trim_ws(ss)); pok {
						sub_v = v
						sv_ok = true
					}
				}
				sdp := fmt_path(&path_buf, "%s/class/drm/card%d/device/subsystem_device", app.sys_root, ci)
				if ss, ok := read_file_str(sdp, name_buf[:]); ok {
					if v, pok := parse_hex_id(trim_ws(ss)); pok {
						sub_d = v
						sd_ok = true
					}
				}
				scratch: [96]u8
				nm: string
				if sv_ok && sd_ok {
					nm = pci_ids_lookup(0x1002, id, sub_v, sub_d, scratch[:])
				} else {
					nm = pci_ids_lookup(0x1002, id, 0, 0, scratch[:])
				}
				if len(nm) > 0 {
					app.gpu_short_len = label_set(app.gpu_short[:], nm)
				}
			}
		}
		bp := fmt_path(&path_buf, "%s/class/drm/card%d/device/gpu_busy_percent", app.sys_root, ci)
		if fd, fok := open_sensor(bp); fok {
			si := source_add(app, fd, .Pct_Int, 1, true)
			metric_add(app, "GPU Usage", .Percent, .GPU_Busy, group, si)
		}
		up := fmt_path(&path_buf, "%s/class/drm/card%d/device/mem_info_vram_used", app.sys_root, ci)
		if fd, fok := open_sensor(up); fok {
			si := source_add(app, fd, .Raw_Int, 1.0 / 1073741824.0, true)
			metric_add(app, "VRAM Used", .Gibibytes, .GPU_Mem, group, si)
		}
		tp := fmt_path(&path_buf, "%s/class/drm/card%d/device/mem_info_vram_total", app.sys_root, ci)
		if fd, fok := open_sensor(tp); fok {
			si := source_add(app, fd, .Raw_Int, 1.0 / 1073741824.0, true)
			metric_add(app, "VRAM Total", .Gibibytes, .GPU_Mem, group, si)
		}
		break
	}
}

// Generic hwmon voltage scan. Boards with nct6775/it87 expose Vcore, VDIMM,
// +12V and friends here; this board has only gigabyte_wmi (temperatures), so
// the section stays hidden unless something is exposed.
discover_voltages :: proc(app: ^App, group: u8) {
	path_buf: [512]u8
	name_buf: [256]u8
	nm_buf: [32]u8
	label_buf: [MAX_LABEL]u8

	for h in 0 ..< 64 {
		p := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/name", app.sys_root, h)
		s, ok := read_file_str(p, name_buf[:])
		if !ok {
			continue
		}
		nm := trim_ws(s)
		if nm == "amdgpu" { // already covered by the GPU section
			continue
		}
		nm_len := label_set(nm_buf[:], nm)

		for i in 0 ..< 8 {
			vp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/in%d_input", app.sys_root, h, i)
			fd, fok := open_sensor(vp)
			if !fok {
				continue
			}
			lbl := fmt_label(&label_buf, "%s in%d", label_str(nm_buf[:], nm_len), i)
			lp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/in%d_label", app.sys_root, h, i)
			if ls, lok := read_file_str(lp, name_buf[:]); lok {
				if t := trim_ws(ls); len(t) > 0 {
					lbl = fmt_label(&label_buf, "%s %s", label_str(nm_buf[:], nm_len), t)
				}
			}
			si := source_add(app, fd, .Raw_Int, 1, true)
			metric_add(app, lbl, .Millivolts, .Voltage, group, si)
		}
	}
}

hwmon_claimed :: proc(name: string) -> bool {
	return name == "coretemp" ||
		name == "amdgpu" ||
		name == "spd5118" ||
		name == "jc42" ||
		name == "nvme" ||
		name == "drivetemp"
}

// Generic hwmon temperatures and fans. Everything already handled by a more
// specific section (CPU, GPU, DIMMs, drives) is skipped; what remains is the
// board/NIC/Wi-Fi/EC long tail.
discover_other_sensors :: proc(app: ^App, temp_group: u8, fan_group: u8) {
	path_buf: [512]u8
	name_buf: [64]u8
	idx_buf: [64]u8
	label_buf: [MAX_LABEL]u8
	dev_buf: [32]u8

	for h in 0 ..< 64 {
		np := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/name", app.sys_root, h)
		ns, ok := read_file_str(np, name_buf[:])
		if !ok {
			continue
		}
		name := trim_ws(ns)
		if len(name) == 0 || hwmon_claimed(name) {
			continue
		}
		if name == "acpitz" {
			name = "ACPI Zone"
		}
		dev_len := label_set(dev_buf[:], name)
		dev := label_str(dev_buf[:], dev_len)

		for i in 1 ..= 16 {
			vp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/temp%d_input", app.sys_root, h, i)
			fd, fok := open_sensor(vp)
			if !fok {
				continue
			}
			lbl: string
			lab := ""
			lp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/temp%d_label", app.sys_root, h, i)
			if ls, lok := read_file_str(lp, idx_buf[:]); lok {
				lab = trim_ws(ls)
			}
			if len(lab) > 0 {
				lbl = fmt_label(&label_buf, "%s %s", dev, lab)
			} else if i == 1 {
				lbl = fmt_label(&label_buf, "%s Temperature", dev)
			} else {
				lbl = fmt_label(&label_buf, "%s temp%d", dev, i)
			}
			si := source_add(app, fd, .Milli_Int, 0.001, true)
			metric_add(app, lbl, .Celsius, .Other, temp_group, si)
		}

		for i in 1 ..= 16 {
			vp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/fan%d_input", app.sys_root, h, i)
			fd, fok := open_sensor(vp)
			if !fok {
				continue
			}
			lbl: string
			lab := ""
			lp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/fan%d_label", app.sys_root, h, i)
			if ls, lok := read_file_str(lp, idx_buf[:]); lok {
				lab = trim_ws(ls)
			}
			if len(lab) > 0 {
				lbl = fmt_label(&label_buf, "%s %s", dev, lab)
			} else {
				lbl = fmt_label(&label_buf, "%s Fan %d", dev, i)
			}
			si := source_add(app, fd, .Raw_Int, 1, true)
			metric_add(app, lbl, .RPM, .Other, fan_group, si)
		}
	}
}

// ---------------------------------------------------------------------------
// display helpers
// ---------------------------------------------------------------------------

unit_str :: proc(u: Sensor_Unit) -> string {
	switch u {
	case .MHz:
		return "MHz"
	case .Celsius:
		return "C"
	case .Watts:
		return "W"
	case .RPM:
		return "RPM"
	case .Percent:
		return "%"
	case .Millivolts:
		return "mV"
	case .Volts:
		return "V"
	case .MTs:
		return "MT/s"
	case .Gigabytes:
		return "GB"
	case .Terabytes:
		return "TB"
	case .Gibibytes:
		// RAM is quoted in binary gigabytes; keep the familiar GB label.
		return "GB"
	case .Mbps:
		return "Mb/s"
	case .DBm:
		return "dBm"
	case .Seconds:
		return "s"
	case .Milliseconds:
		return "ms"
	}
	return ""
}

unit_decimals :: proc(u: Sensor_Unit) -> int {
	switch u {
	case .Watts:
		return 2
	case .Celsius:
		return 1
	case .MHz:
		return 0
	case .RPM:
		return 0
	case .Percent:
		return 0
	case .Millivolts:
		return 0
	case .Volts:
		return 3
	case .MTs:
		return 0
	case .Gigabytes:
		return 0
	case .Terabytes:
		return 1
	case .Gibibytes:
		return 2
	case .Mbps:
		return 0
	case .DBm:
		return 0
	case .Seconds, .Milliseconds:
		return 2
	}
	return 1
}
