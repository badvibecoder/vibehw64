package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

app: App

usage :: proc() {
	fmt.println("vibehw64 — Linux hardware sensor monitor")
	fmt.println("")
	fmt.println("usage: vibehw64 [--probe] [--snapshot] [--ticks N] [--interval MS] [--sys-root DIR]")
	fmt.println("")
	fmt.println("  --probe          discover sensors, sample N times, print, exit")
	fmt.println("  --snapshot       print the copy-to-clipboard text and exit")
	fmt.println("  --ticks N        samples to take in probe/snapshot mode (default 3)")
	fmt.println("  --interval MS    sample interval in milliseconds (default 1500)")
	fmt.println("  --sys-root DIR   sysfs root; test hook, defaults to /sys")
}

main :: proc() {
	probe := false
	snapshot := false
	ticks := 3
	interval := 1500
	sys_root := "/sys"

	args := os.args
	i := 1
	for i < len(args) {
		a := args[i]
		switch a {
		case "--probe":
			probe = true
			i += 1
		case "--snapshot":
			snapshot = true
			i += 1
		case "--ticks":
			if i + 1 < len(args) {
				if v, ok := strconv.parse_int(args[i + 1], 10); ok {
					ticks = int(v)
				}
				i += 2
			} else {
				i += 1
			}
		case "--interval":
			if i + 1 < len(args) {
				if v, ok := strconv.parse_int(args[i + 1], 10); ok {
					interval = int(v)
				}
				i += 2
			} else {
				i += 1
			}
		case "--sys-root":
			if i + 1 < len(args) {
				sys_root = args[i + 1]
				i += 2
			} else {
				i += 1
			}
		case "-h", "--help", "help":
			usage()
			return
		case:
			fmt.eprintfln("unknown argument: %s", a)
			usage()
			os.exit(2)
		}
	}

	if interval < 100 {
		interval = 100
	}
	if interval > 10000 {
		interval = 10000
	}
	if ticks < 1 {
		ticks = 1
	}
	app.interval_ms = interval

	if !discover_all(&app, sys_root) {
		fmt.eprintln("error: no sensors discovered")
		os.exit(1)
	}

	if snapshot {
		snapshot_run(ticks, interval)
		return
	}

	if !probe {
		if !run_ui() {
			os.exit(1)
		}
		return
	}

	probe_run(ticks)
}

snapshot_run :: proc(ticks: int, interval: int) {
	dt := f64(interval) / 1000.0
	for t in 0 ..< ticks {
		if t > 0 {
			time.sleep(time.Duration(interval) * time.Millisecond)
		}
		sample_all(&app, dt)
		usage_update(&app, dt)
		net_update(&app, dt)
		meminfo_update(&app, dt)
	}
	for i in 0 ..< app.metric_count {
		ui_metrics[i] = app.metrics[i]
	}
	ui_n = app.metric_count
	n := ui_copy_build()
	fmt.print(string(ui_copy_buf[:n]))
}

probe_run :: proc(ticks: int) {
	smt_s := "no"
	if app.topo.smt {
		smt_s = "yes"
	}
	hyb_s := "no"
	if app.topo.hybrid {
		hyb_s = "yes"
	}

	fmt.printfln("vibehw64 probe")
	fmt.printfln(
		"cpu     %s (%s)",
		label_str(app.topo.model[:], app.topo.model_len),
		label_str(app.topo.vendor[:], app.topo.vendor_len),
	)
	fmt.printfln(
		"topo    %d physical cores · SMT %s · hybrid %s",
		app.topo.core_count,
		smt_s,
		hyb_s,
	)
	for ci in 0 ..< app.topo.class_count {
		cl := &app.topo.classes[ci]
		state := "collapsed"
		if cl.expanded {
			state = "expanded"
		}
		fmt.printfln(
			"group   %-10s %v cores  %s",
			class_label(&app.topo, u8(ci)),
			cl.core_count,
			state,
		)
	}
	fmt.printfln(
		"names   cpu=\"%s\" gpu=\"%s\" ram=\"%s\"",
		label_str(app.cpu_short[:], app.cpu_short_len),
		label_str(app.gpu_short[:], app.gpu_short_len),
		label_str(app.ram_short[:], app.ram_short_len),
	)
	for si in 0 ..< app.section_count {
		fmt.printfln("section %s", app.sections[si].label)
	}
	perms_s := "ok"
	if perms_needed(&app) {
		perms_s = "setup needed (run the GUI and click Set up, or run scripts/install-permissions.sh)"
	}
	fmt.printfln("perms   %s", perms_s)
	fmt.printfln("sensors %d · sources %d · interval %dms", app.metric_count, app.source_count, app.interval_ms)

	dt := f64(app.interval_ms) / 1000.0
	for t in 0 ..< ticks {
		if t > 0 {
			time.sleep(time.Duration(app.interval_ms) * time.Millisecond)
		}
		sample_all(&app, dt)
		usage_update(&app, dt)
		net_update(&app, dt)
		meminfo_update(&app, dt)
		fmt.printfln("")
		fmt.printfln("--- sample %d/%d ---", t + 1, ticks)
		print_snapshot()
	}
}

print_group_rows :: proc(gi: int) -> int {
	n := 0
	for m in 0 ..< app.metric_count {
		if int(app.metrics[m].group) == gi {
			n += 1
		}
	}
	return n
}

print_snapshot :: proc() {
	for si in 0 ..< app.section_count {
		gcount := 0
		for g in 0 ..< app.group_count {
			if int(app.groups[g].section) == si && print_group_rows(g) > 0 {
				gcount += 1
			}
		}
		has_rows := false
		for m in 0 ..< app.metric_count {
			gg := int(app.metrics[m].group)
			if gg < app.group_count && int(app.groups[gg].section) == si {
				has_rows = true
				break
			}
		}
		if !has_rows {
			continue
		}

		fmt.printfln("[%s]", app.sections[si].label)
		for g in 0 ..< app.group_count {
			if int(app.groups[g].section) != si {
				continue
			}
			if print_group_rows(g) == 0 {
				continue
			}
			if gcount > 1 {
				fmt.printfln("  %s", label_str(app.groups[g].label[:], app.groups[g].label_len))
			}
			for m in 0 ..< app.metric_count {
				if int(app.metrics[m].group) != g {
					continue
				}
				print_row(&app.metrics[m])
			}
		}
	}
}

print_row :: proc(m: ^Sensor_Metric) {
	lab := label_str(m.label[:], m.label_len)
	root_required := false
	if m.src != NO_SOURCE {
		root_required = app.sources[m.src].root
	}

	if root_required {
		fmt.printfln("    %-24s  %s", lab, "[Root Required]")
		return
	}
	if !m.seen {
		fmt.printfln("    %-24s  %s", lab, "--")
		return
	}

	d := unit_decimals(m.unit)
	b1, b2, b3, b4: [24]u8
	cur := num_field(b1[:], m.cur, d, 8)
	mn := num_field(b2[:], m.min, d, 8)
	mx := num_field(b3[:], m.max, d, 8)
	av := num_field(b4[:], metric_avg(m), d, 8)
	fmt.printfln("    %-24s %s %s %s %s  %s", lab, cur, mn, mx, av, unit_str(m.unit))
}

// Odin's fmt zero-pads any numeric field width (%8.1f -> "000034.0"), so
// columns are padded by hand to keep tables readable.
num_field :: proc(dst: []u8, v: f64, decimals: int, width: int) -> string {
	tmp: [40]u8
	s: string
	switch decimals {
	case 0:
		s = fmt.bprintf(tmp[:], "%.0f", v)
	case 1:
		s = fmt.bprintf(tmp[:], "%.1f", v)
	case 2:
		s = fmt.bprintf(tmp[:], "%.2f", v)
	case:
		s = fmt.bprintf(tmp[:], "%.3f", v)
	}
	n := len(s)
	if n >= width {
		for i in 0 ..< n {
			dst[i] = s[i]
		}
		return string(dst[:n])
	}
	pad := width - n
	for i in 0 ..< pad {
		dst[i] = ' '
	}
	for i in 0 ..< n {
		dst[pad + i] = s[i]
	}
	return string(dst[:width])
}
