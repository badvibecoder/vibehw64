package main

// Memory identity rows and per-drive sections.
//
// Drives follow HWiNFO's shape: each physical drive is its own section, with
// capacity, filesystem usage, and whatever temperatures the kernel exposes.
// NVMe controllers publish temps through a hwmon whose device path contains
// "/nvme/nvmeN"; SATA drives only get temperatures if the `drivetemp` module is
// loaded, and are matched via their SCSI device name.

import "core:fmt"
import "core:strconv"
import "core:sys/linux"

MAX_MOUNTS :: 128

mount_devs:       [MAX_MOUNTS][64]u8
mount_dev_lens:   [MAX_MOUNTS]u8
mount_points:     [MAX_MOUNTS][96]u8
mount_point_lens: [MAX_MOUNTS]u8
mount_count:      int
mounts_loaded:    bool

starts_with :: proc(s, prefix: string) -> bool {
	if len(prefix) > len(s) {
		return false
	}
	for i in 0 ..< len(prefix) {
		if s[i] != prefix[i] {
			return false
		}
	}
	return true
}

contains :: proc(hay, needle: string) -> bool {
	if len(needle) == 0 || len(needle) > len(hay) {
		return false
	}
	for i in 0 ..= len(hay) - len(needle) {
		ok := true
		for j in 0 ..< len(needle) {
			if hay[i + j] != needle[j] {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

base_name :: proc(s: string) -> string {
	i := len(s)
	for i > 0 && s[i - 1] != '/' {
		i -= 1
	}
	return s[i:]
}

// ---------------------------------------------------------------------------
// filesystem usage
// ---------------------------------------------------------------------------

load_mounts :: proc() {
	if mounts_loaded {
		return
	}
	mounts_loaded = true
	fd, err := open_path("/proc/mounts")
	if err != .NONE {
		return
	}
	defer linux.close(fd)

	buf: [32768]u8
	n, rerr := linux.read(fd, buf[:])
	if rerr != .NONE || n <= 0 {
		return
	}

	i := 0
	for i < n && mount_count < MAX_MOUNTS {
		end := i
		for end < n && buf[end] != '\n' {
			end += 1
		}
		p := i
		for p < end && buf[p] != ' ' {
			p += 1
		}
		dev_len := p - i
		for p < end && buf[p] == ' ' {
			p += 1
		}
		mp_start := p
		for p < end && buf[p] != ' ' {
			p += 1
		}
		mp_len := p - mp_start

		// Only real block devices: /dev/...
		if dev_len > 5 && buf[i] == '/' && buf[i + 1] == 'd' && buf[i + 2] == 'e' && buf[i + 3] == 'v' && buf[i + 4] == '/' {
			if dev_len <= 63 && mp_len <= 95 {
				for k in 0 ..< dev_len {
					mount_devs[mount_count][k] = buf[i + k]
				}
				mount_dev_lens[mount_count] = u8(dev_len)
				for k in 0 ..< mp_len {
					mount_points[mount_count][k] = buf[mp_start + k]
				}
				mount_point_lens[mount_count] = u8(mp_len)
				mount_count += 1
			}
		}
		i = end + 1
	}
}

fs_usage :: proc(drive: string) -> (used_pct, free_gb, total_gb: f64, ok: bool) {
	load_mounts()
	path: [128]u8
	st: linux.Stat_FS

	for m in 0 ..< mount_count {
		dev := string(mount_devs[m][:mount_dev_lens[m]])
		if !starts_with(dev[5:], drive) {
			continue
		}
		plen := int(mount_point_lens[m])
		for k in 0 ..< plen {
			path[k] = mount_points[m][k]
		}
		path[plen] = 0
		if linux.statfs(cstring(raw_data(path[:])), &st) != .NONE {
			continue
		}
		frs := st.frsize
		if frs <= 0 {
			frs = st.bsize
		}
		if frs <= 0 {
			continue
		}
		total := f64(st.blocks * frs)
		free := f64(st.bavail * frs)
		if total <= 0 {
			continue
		}
		return (total - free) / total * 100.0, free / 1.0e9, total / 1.0e9, true
	}
	return 0, 0, 0, false
}

// ---------------------------------------------------------------------------
// block device helpers
// ---------------------------------------------------------------------------

block_bytes :: proc(app: ^App, name: string) -> u64 {
	path_buf: [512]u8
	buf: [64]u8
	sp := fmt_path(&path_buf, "%s/class/block/%s/size", app.sys_root, name)
	s, ok := read_file_str(sp, buf[:])
	if !ok {
		return 0
	}
	sectors, sok := strconv.parse_int(trim_ws(s), 10)
	if !sok || sectors <= 0 {
		return 0
	}
	bs: u64 = 512
	lp := fmt_path(&path_buf, "%s/class/block/%s/queue/logical_block_size", app.sys_root, name)
	if ls, lok := read_file_str(lp, buf[:]); lok {
		if v, vok := strconv.parse_int(trim_ws(ls), 10); vok && v > 0 {
			bs = u64(v)
		}
	}
	return u64(sectors) * bs
}

hwmon_device :: proc(app: ^App, h: int, out: []u8) -> (string, bool) {
	path_buf: [512]u8
	lp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/device", app.sys_root, h)
	if ln, ok := readlink_str(lp, out); ok && ln > 0 {
		return string(out[:ln]), true
	}
	return "", false
}

// Attaches every tempN of the matching hwmon as Drive rows.
add_drive_temps :: proc(app: ^App, group: u8, h: int) {
	path_buf: [512]u8
	name_buf: [256]u8
	for i in 1 ..= 4 {
		lp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/temp%d_label", app.sys_root, h, i)
		ls, lok := read_file_str(lp, name_buf[:])
		if !lok {
			continue
		}
		label := trim_ws(ls)
		for len(label) > 0 && (label[len(label) - 1] == ' ' || label[len(label) - 1] == '\t') {
			label = label[:len(label) - 1]
		}
		vp := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/temp%d_input", app.sys_root, h, i)
		fd, fok := open_sensor(vp)
		if !fok {
			continue
		}
		si := source_add(app, fd, .Milli_Int, 0.001, true)
		metric_add(app, label, .Celsius, .Drive, group, si)
	}
}

add_capacity_rows :: proc(app: ^App, group: u8, drive: string, size_bytes: u64) {
	if size_bytes >= 1_000_000_000_000 {
		idx := metric_add_computed(app, "Capacity", .Terabytes, .Drive, group)
		metric_set_static(app, idx, f64(size_bytes) / 1.0e12)
	} else if size_bytes > 0 {
		idx := metric_add_computed(app, "Capacity", .Gigabytes, .Drive, group)
		metric_set_static(app, idx, f64(size_bytes) / 1.0e9)
	}

	if used, free_gb, _, ok := fs_usage(drive); ok {
		idx := metric_add_computed(app, "Used", .Percent, .Drive, group)
		metric_set_static(app, idx, used)
		if free_gb >= 1000 {
			f := metric_add_computed(app, "Free", .Terabytes, .Drive, group)
			metric_set_static(app, f, free_gb / 1000.0)
		} else {
			f := metric_add_computed(app, "Free", .Gigabytes, .Drive, group)
			metric_set_static(app, f, free_gb)
		}
	}
}

// ---------------------------------------------------------------------------
// discovery
// ---------------------------------------------------------------------------

discover_storage :: proc(app: ^App) {
	path_buf: [512]u8
	name_buf: [256]u8
	model_buf: [80]u8
	sec_buf: [128]u8
	target_buf: [512]u8

	// --- NVMe controllers ---------------------------------------------------
	for n in 0 ..< 8 {
		mp := fmt_path(&path_buf, "%s/class/nvme/nvme%d/model", app.sys_root, n)
		ms, ok := read_file_str(mp, name_buf[:])
		if !ok {
			continue
		}
		model_len := label_set(model_buf[:], trim_ws(ms))

		block_buf: [24]u8
		block := fmt.bprintf(block_buf[:], "nvme%dn1", n)
		size := block_bytes(app, block)

		label := fmt.bprintf(sec_buf[:], "%s [NVMe]", label_str(model_buf[:], u8(model_len)))
		sec := section_add(app, label, true)
		g := group_add_at(app, sec, "Drive", true)

		// The hwmon's device link is relative (e.g. "../../nvme0"), so match the
		// last path component against the controller name.
		want_buf: [32]u8
		want := fmt.bprintf(want_buf[:], "nvme%d", n)
		for h in 0 ..< 64 {
			tgt, tok := hwmon_device(app, h, target_buf[:])
			if !tok || base_name(tgt) != want {
				continue
			}
			add_drive_temps(app, g, h)
			break
		}

		add_capacity_rows(app, g, block, size)
	}

	// --- SATA / USB drives --------------------------------------------------
	for d in 0 ..< 26 {
		name_buf2: [16]u8
		block := fmt.bprintf(name_buf2[:], "sd%c", rune(int('a') + d))

		model_path := fmt_path(&path_buf, "%s/class/block/%s/device/model", app.sys_root, block)
		ms, ok := read_file_str(model_path, name_buf[:])
		if !ok {
			continue
		}
		model_len := label_set(model_buf[:], trim_ws(ms))

		rot := 0
		rp := fmt_path(&path_buf, "%s/class/block/%s/queue/rotational", app.sys_root, block)
		if rs, rok := read_file_str(rp, name_buf[:]); rok {
			if v, vok := strconv.parse_int(trim_ws(rs), 10); vok {
				rot = int(v)
			}
		}
		kind := "SSD"
		if rot == 1 {
			kind = "HDD"
		}

		size := block_bytes(app, block)
		label := fmt.bprintf(sec_buf[:], "%s [%s]", label_str(model_buf[:], u8(model_len)), kind)
		sec := section_add(app, label, true)
		g := group_add_at(app, sec, "Drive", true)

		// drivetemp hwmon shares the SCSI device name (e.g. "0:0:0:0").
		dev_path_buf: [256]u8
		dev_link := fmt_path(&path_buf, "%s/class/block/%s/device", app.sys_root, block)
		dev_name := ""
		if ln, lok := readlink_str(dev_link, dev_path_buf[:]); lok && ln > 0 {
			dev_name = base_name(string(dev_path_buf[:ln]))
		}
		if len(dev_name) > 0 {
			for h in 0 ..< 64 {
				tgt, tok := hwmon_device(app, h, target_buf[:])
				if !tok {
					continue
				}
				if base_name(tgt) == dev_name {
					nm := fmt_path(&path_buf, "%s/class/hwmon/hwmon%d/name", app.sys_root, h)
					if ns, nok := read_file_str(nm, name_buf[:]); nok && trim_ws(ns) == "drivetemp" {
						add_drive_temps(app, g, h)
					}
					break
				}
			}
		}

		add_capacity_rows(app, g, block, size)
	}
}

// ---------------------------------------------------------------------------
// memory identity rows
// ---------------------------------------------------------------------------

path_access :: proc(path: string) -> (exists: bool, denied: bool) {
	fd, err := open_path(path)
	if err == .NONE {
		linux.close(fd)
		return true, false
	}
	if err == .ENOENT {
		return false, false
	}
	return true, true
}

discover_memory_info :: proc(app: ^App, group: u8) {
	path_buf: [512]u8
	scratch: [96]u8

	app.dmi_ok = false
	app.memory_speed_metric = u16(metric_add_computed(app, "Memory Speed", .MTs, .DIMM, group))
	app.memory_voltage_metric = u16(metric_add_computed(app, "Memory Voltage", .Volts, .DIMM, group))

	dp := fmt_path(&path_buf, "%s/firmware/dmi/tables/DMI", app.sys_root)
	info := smbios_memory(dp)
	if info.ok {
		app.dmi_ok = true
		app.ram_speed_mt = info.speed_mt
		app.ram_voltage_mv = info.volt_mv
		if len(info.part) > 0 && !info.mixed {
			label := fmt.bprintf(scratch[:], "%dMT  %s", info.speed_mt, info.part)
			app.ram_short_len = label_set(app.ram_short[:], label)
		} else {
			label := fmt.bprintf(scratch[:], "%dMT", info.speed_mt)
			app.ram_short_len = label_set(app.ram_short[:], label)
		}
		if app.memory_speed_metric != NO_METRIC {
			metric_set_static(app, int(app.memory_speed_metric), f64(info.speed_mt))
		}
		if app.ram_voltage_mv > 0 && app.memory_voltage_metric != NO_METRIC {
			metric_set_static(app, int(app.memory_voltage_metric), f64(app.ram_voltage_mv) / 1000.0)
		}
	} else {
		// A missing table (non-x86) is not a permission problem; unreadable is.
		exists, _ := path_access(dp)
		app.dmi_ok = !exists
	}
}
