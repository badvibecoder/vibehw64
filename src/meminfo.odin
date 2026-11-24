package main

// Physical and virtual memory usage from /proc/meminfo.
//
// Linux has no single "virtual memory" counter. The closest analogue to
// HWiNFO's virtual-memory rows is commit charge (Committed_AS / CommitLimit),
// so those rows are labelled Virtual Used / Available / Load. Swap is reported
// separately.

import "core:sys/linux"

KB_PER_GIB :: 1024.0 * 1024.0

Mem_Metrics :: struct {
	total:      u16,
	used:       u16,
	available:  u16,
	phys_load:  u16,
	virt_used:  u16,
	virt_avail: u16,
	virt_load:  u16,
	swap_used:  u16,
	swap_total: u16,
	swap_load:  u16,
}

Mem_State :: struct {
	fd:      linux.Fd,
	metrics: Mem_Metrics,
}

mem_state: Mem_State
meminfo_buf: [16384]u8

mem_metric_add :: proc(app: ^App, label: string, unit: Sensor_Unit, group: u8) -> u16 {
	i := metric_add_computed(app, label, unit, .Other, group)
	if i < 0 {
		return NO_METRIC
	}
	return u16(i)
}

mem_push :: proc(app: ^App, idx: u16, v: f64, dt: f64) {
	if idx != NO_METRIC {
		metric_push(app, int(idx), v, dt)
	}
}

// Value in kB for a "Key:  12345 kB" line.
meminfo_value :: proc(buf: []u8, key: string) -> (int, bool) {
	i := 0
	for i < len(buf) {
		end := i
		for end < len(buf) && buf[end] != '\n' {
			end += 1
		}
		line := string(buf[i:end])
		if len(line) > len(key) && line[len(key)] == ':' {
			match := true
			for k in 0 ..< len(key) {
				if line[k] != key[k] {
					match = false
					break
				}
			}
			if match {
				p := len(key) + 1
				for p < len(line) && (line[p] == ' ' || line[p] == '\t') {
					p += 1
				}
				v := 0
				digits := 0
				for p < len(line) && line[p] >= '0' && line[p] <= '9' {
					v = v * 10 + int(line[p] - '0')
					p += 1
					digits += 1
				}
				if digits > 0 {
					return v, true
				}
			}
		}
		i = end + 1
	}
	return 0, false
}

meminfo_init :: proc(app: ^App, group: u8) {
	mem_state.fd = linux.Fd(-1)
	fd, err := open_path("/proc/meminfo")
	if err != .NONE {
		return
	}
	mem_state.fd = fd
	mem_state.metrics = Mem_Metrics {
		total      = mem_metric_add(app, "Usable Memory", .Gibibytes, group),
		used       = mem_metric_add(app, "Physical Memory Used", .Gibibytes, group),
		available  = mem_metric_add(app, "Physical Memory Available", .Gibibytes, group),
		phys_load  = mem_metric_add(app, "Physical Memory Load", .Percent, group),
		virt_used  = mem_metric_add(app, "Virtual Memory Used", .Gibibytes, group),
		virt_avail = mem_metric_add(app, "Virtual Memory Available", .Gibibytes, group),
		virt_load  = mem_metric_add(app, "Virtual Memory Load", .Percent, group),
		swap_used  = mem_metric_add(app, "Swap Used", .Gibibytes, group),
		swap_total = mem_metric_add(app, "Swap Total", .Gibibytes, group),
		swap_load  = mem_metric_add(app, "Swap Load", .Percent, group),
	}
	meminfo_update(app, 0)
}

meminfo_update :: proc(app: ^App, dt: f64) {
	if mem_state.fd < 0 {
		return
	}
	if _, err := linux.lseek(mem_state.fd, 0, .SET); err != .NONE {
		return
	}
	n, rerr := linux.read(mem_state.fd, meminfo_buf[:])
	if rerr != .NONE || n <= 0 {
		return
	}
	buf := meminfo_buf[:n]

	total_kb, tok := meminfo_value(buf, "MemTotal")
	if !tok {
		return
	}

	avail_kb, aok := meminfo_value(buf, "MemAvailable")
	if !aok {
		// Kernels before MemAvailable: free + buffers + cached.
		free_kb, fok := meminfo_value(buf, "MemFree")
		if fok {
			avail_kb = free_kb
			if v, ok := meminfo_value(buf, "Buffers"); ok {
				avail_kb += v
			}
			if v, ok := meminfo_value(buf, "Cached"); ok {
				avail_kb += v
			}
			aok = true
		}
	}
	used_kb := total_kb - avail_kb
	if used_kb < 0 {
		used_kb = 0
	}

	mem_push(app, mem_state.metrics.total, f64(total_kb) / KB_PER_GIB, dt)
	if aok {
		mem_push(app, mem_state.metrics.used, f64(used_kb) / KB_PER_GIB, dt)
		mem_push(app, mem_state.metrics.available, f64(avail_kb) / KB_PER_GIB, dt)
		if total_kb > 0 {
			mem_push(app, mem_state.metrics.phys_load, f64(used_kb) / f64(total_kb) * 100.0, dt)
		}
	}

	commit_kb, cok := meminfo_value(buf, "Committed_AS")
	limit_kb, lok := meminfo_value(buf, "CommitLimit")
	if cok && lok && limit_kb > 0 {
		mem_push(app, mem_state.metrics.virt_used, f64(commit_kb) / KB_PER_GIB, dt)
		avail_kb_v := limit_kb - commit_kb
		if avail_kb_v < 0 {
			avail_kb_v = 0
		}
		mem_push(app, mem_state.metrics.virt_avail, f64(avail_kb_v) / KB_PER_GIB, dt)
		mem_push(app, mem_state.metrics.virt_load, f64(commit_kb) / f64(limit_kb) * 100.0, dt)
	}

	swap_total_kb, stok := meminfo_value(buf, "SwapTotal")
	swap_free_kb, sfok := meminfo_value(buf, "SwapFree")
	if stok {
		swap_used_kb := 0
		if sfok {
			swap_used_kb = swap_total_kb - swap_free_kb
			if swap_used_kb < 0 {
				swap_used_kb = 0
			}
		}
		mem_push(app, mem_state.metrics.swap_total, f64(swap_total_kb) / KB_PER_GIB, dt)
		mem_push(app, mem_state.metrics.swap_used, f64(swap_used_kb) / KB_PER_GIB, dt)
		if swap_total_kb > 0 {
			mem_push(app, mem_state.metrics.swap_load, f64(swap_used_kb) / f64(swap_total_kb) * 100.0, dt)
		} else {
			mem_push(app, mem_state.metrics.swap_load, 0, dt)
		}
	}
}
