package main

// Per-core and package CPU utilisation, derived from /proc/stat deltas.
//
// /proc/stat is one file describing every CPU, so these metrics cannot own a
// file descriptor each the way sensor metrics do: they are "computed" metrics
// (src == NO_SOURCE) that sample_all skips and usage_update fills in.
//
// Numbers are deltas over the configured interval, so with the default 1500 ms
// each reading is the average utilisation across that window.

import "core:sys/linux"

usage_buf: [16384]u8

usage_parse :: proc(app: ^App, cur_total: ^[MAX_CPUS + 1]u64, cur_busy: ^[MAX_CPUS + 1]u64, have: ^[MAX_CPUS + 1]bool) -> bool {
	if _, err := linux.lseek(app.usage_fd, 0, .SET); err != .NONE {
		return false
	}
	n, rerr := linux.read(app.usage_fd, usage_buf[:])
	if rerr != .NONE || n <= 0 {
		return false
	}

	i := 0
	for i < n {
		end := i
		for end < n && usage_buf[end] != '\n' {
			end += 1
		}
		// Lines of interest all start with "cpu".
		if end - i > 3 && usage_buf[i] == 'c' && usage_buf[i + 1] == 'p' && usage_buf[i + 2] == 'u' {
			pos := i + 3
			slot := MAX_CPUS // aggregate "cpu " line
			if pos < end && usage_buf[pos] >= '0' && usage_buf[pos] <= '9' {
				id := 0
				for pos < end && usage_buf[pos] >= '0' && usage_buf[pos] <= '9' {
					id = id * 10 + int(usage_buf[pos] - '0')
					pos += 1
				}
				slot = id
			}

			vals: [10]u64
			got := 0
			for pos < end && got < 10 {
				for pos < end && usage_buf[pos] == ' ' {
					pos += 1
				}
				if pos >= end {
					break
				}
				v: u64 = 0
				digits := 0
				for pos < end && usage_buf[pos] >= '0' && usage_buf[pos] <= '9' {
					v = v * 10 + u64(usage_buf[pos] - '0')
					pos += 1
					digits += 1
				}
				if digits == 0 {
					break
				}
				vals[got] = v
				got += 1
			}

			if got >= 5 && slot >= 0 && slot <= MAX_CPUS {
				// user nice system idle iowait irq softirq steal ...
				total: u64 = 0
				for k in 0 ..< got {
					total += vals[k]
				}
				idle := vals[3] + vals[4]
				cur_total[slot] = total
				cur_busy[slot] = total - idle
				have[slot] = true
			}
		}
		i = end + 1
	}
	return true
}

usage_update :: proc(app: ^App, dt: f64) {
	cur_total: [MAX_CPUS + 1]u64
	cur_busy: [MAX_CPUS + 1]u64
	have: [MAX_CPUS + 1]bool
	if !usage_parse(app, &cur_total, &cur_busy, &have) {
		return
	}

	if !app.usage_primed {
		app.prev_total = cur_total
		app.prev_busy = cur_busy
		app.usage_primed = true
		return
	}

	if have[MAX_CPUS] && app.pkg_usage_metric != NO_METRIC {
		dt_total := cur_total[MAX_CPUS] - app.prev_total[MAX_CPUS]
		dt_busy := cur_busy[MAX_CPUS] - app.prev_busy[MAX_CPUS]
		if dt_total > 0 {
			metric_push(app, int(app.pkg_usage_metric), f64(dt_busy) / f64(dt_total) * 100.0, dt)
		}
	}

	for k in 0 ..< app.topo.core_count {
		mi := app.usage_metric[k]
		if mi == NO_METRIC {
			continue
		}
		cpu := int(app.topo.cores[k].cpu)
		if cpu >= MAX_CPUS || !have[cpu] {
			continue
		}
		dt_total := cur_total[cpu] - app.prev_total[cpu]
		if dt_total == 0 {
			continue
		}
		dt_busy := cur_busy[cpu] - app.prev_busy[cpu]
		metric_push(app, int(mi), f64(dt_busy) / f64(dt_total) * 100.0, dt)
	}

	app.prev_total = cur_total
	app.prev_busy = cur_busy
}

usage_init :: proc(app: ^App, groups: []u8, pkg_group: u8) -> bool {
	fd, err := open_path("/proc/stat")
	if err != .NONE {
		return false
	}
	app.usage_fd = fd
	app.pkg_usage_metric = NO_METRIC
	for k in 0 ..< MAX_CPUS {
		app.usage_metric[k] = NO_METRIC
	}

	// Prime the deltas so the very first displayed sample is meaningful.
	app.usage_primed = false
	usage_update(app, 0)

	app.pkg_usage_metric = u16(metric_add_computed(app, "CPU Usage", .Percent, .CPU_Pkg, pkg_group))
	label_buf: [MAX_LABEL]u8
	for k in 0 ..< app.topo.core_count {
		core := &app.topo.cores[k]
		tag := class_tag(&app.topo, core.class)
		lbl := fmt_label(&label_buf, "Core %d [%s]", core.cpu, tag)
		idx := metric_add_computed(app, lbl, .Percent, .CPU_Core, groups[core.class])
		if idx >= 0 {
			app.usage_metric[k] = u16(idx)
		}
	}
	return true
}
