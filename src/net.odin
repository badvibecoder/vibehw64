package main

// Network interfaces: one section each.
//
// Wired: link speed from sysfs, utilisation from /proc/net/dev byte deltas.
// WiFi:  SSID via the Wireless Extensions ioctl (SIOCGIWESSID). cfg80211 still
//        emulates wext when CONFIG_CFG80211_WEXT=y, which avoids spawning `iw`
//        or speaking nl80211. Signal level also comes from /proc/net/wireless.
//
// Nothing here needs elevation.

import "core:fmt"
import "core:sys/linux"

SIOCGIWESSID :: u32(0x8B1B)
AF_INET      :: linux.Address_Family(2)
IPPROTO_IP   :: linux.Protocol(0)
MAX_NET      :: 8

// struct iw_point { void *pointer; __u16 length; __u16 flags; }
Iw_Point :: struct {
	pointer: rawptr,
	length:  u16,
	flags:   u16,
}

// struct iwreq { char ifrn_name[IFNAMSIZ]; union { struct iw_point essid; } u; }
Iw_Req :: struct {
	ifrn_name: [16]u8,
	u:         Iw_Point,
}

Net_Iface :: struct {
	name:        [16]u8,
	name_len:    u8,
	wireless:    bool,
	section:     u8,
	util_metric: u16,
	sig_metric:  u16,
	speed_mbps:  int,
	prev_rx:     u64,
	prev_tx:     u64,
	primed:      bool,
	last_up:     bool,
	last_ssid:   [64]u8,
	last_ssid_len: u8,
}

net_ifaces: [MAX_NET]Net_Iface
net_count:  int

net_name :: proc(n: ^Net_Iface) -> string {
	return string(n.name[:n.name_len])
}

path_exists :: proc(path: string) -> bool {
	fd, err := open_path(path)
	if err != .NONE {
		return false
	}
	linux.close(fd)
	return true
}

net_iface_up :: proc(app: ^App, name: string) -> bool {
	path_buf: [512]u8
	buf: [32]u8
	p := fmt_path(&path_buf, "%s/class/net/%s/operstate", app.sys_root, name)
	s, ok := read_file_str(p, buf[:])
	return ok && trim_ws(s) == "up"
}

// Reads the current SSID into `out`. Returns false when unavailable.
wifi_ssid :: proc(name: string, out: []u8) -> (int, bool) {
	fd, err := linux.socket(AF_INET, .DGRAM, {}, IPPROTO_IP)
	if err != .NONE {
		return 0, false
	}
	defer linux.close(fd)

	req: Iw_Req
	n := len(name)
	if n > 15 {
		n = 15
	}
	for i in 0 ..< n {
		req.ifrn_name[i] = name[i]
	}
	req.u.pointer = rawptr(raw_data(out))
	req.u.length = u16(len(out))

	ret := linux.ioctl(fd, SIOCGIWESSID, uintptr(&req))
	if i64(ret) < 0 {
		return 0, false
	}
	// Kernel reports the ESSID length in place.
	ln := int(req.u.length)
	if ln <= 0 || ln > len(out) {
		return 0, false
	}
	return ln, true
}

// Signal level (dBm) for a wireless interface from /proc/net/wireless.
wifi_signal :: proc(name: string) -> (int, bool) {
	fd, err := open_path("/proc/net/wireless")
	if err != .NONE {
		return 0, false
	}
	defer linux.close(fd)
	buf: [4096]u8
	n, rerr := linux.read(fd, buf[:])
	if rerr != .NONE || n <= 0 {
		return 0, false
	}

	i := 0
	for i < n {
		end := i
		for end < n && buf[end] != '\n' {
			end += 1
		}
		// "name: status link level noise ..."
		line := string(buf[i:end])
		if starts_with(line, name) && len(line) > len(name) && line[len(name)] == ':' {
			// Third numeric field is the level.
			pos := len(name) + 1
			field := 0
			for pos < len(line) {
				for pos < len(line) && line[pos] == ' ' {
					pos += 1
				}
				neg := false
				if pos < len(line) && line[pos] == '-' {
					neg = true
					pos += 1
				}
				v := 0
				digits := 0
				for pos < len(line) && line[pos] >= '0' && line[pos] <= '9' {
					v = v * 10 + int(line[pos] - '0')
					pos += 1
					digits += 1
				}
				// skip trailing '.' and fraction
				for pos < len(line) && line[pos] == '.' {
					pos += 1
					for pos < len(line) && line[pos] >= '0' && line[pos] <= '9' {
						pos += 1
					}
				}
				if digits == 0 {
					break
				}
				if field == 2 {
					if neg {
						v = -v
					}
					return v, true
				}
				field += 1
			}
		}
		i = end + 1
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// discovery
// ---------------------------------------------------------------------------

discover_net :: proc(app: ^App) {
	fd, err := open_path("/proc/net/dev")
	if err != .NONE {
		return
	}
	defer linux.close(fd)
	buf: [8192]u8
	n, rerr := linux.read(fd, buf[:])
	if rerr != .NONE || n <= 0 {
		return
	}

	path_buf: [512]u8
	name_buf: [64]u8
	ssid_buf: [64]u8
	label_buf: [128]u8

	i := 0
	for i < n && net_count < MAX_NET {
		end := i
		for end < n && buf[end] != '\n' {
			end += 1
		}
		line := string(buf[i:end])
		colon := -1
		for k in 0 ..< len(line) {
			if line[k] == ':' {
				colon = k
				break
			}
		}
		if colon > 0 {
			name := trim_ws(line[:colon])
			// Skip loopback and anything without a backing device.
			dev_path := fmt_path(&path_buf, "%s/class/net/%s/device", app.sys_root, name)
			if name != "lo" && path_exists(dev_path) {
				net_add(app, name, &path_buf, &name_buf, &ssid_buf, &label_buf)
			}
		}
		i = end + 1
	}
}

net_add :: proc(
	app: ^App,
	name: string,
	path_buf: ^[512]u8,
	name_buf: ^[64]u8,
	ssid_buf: ^[64]u8,
	label_buf: ^[128]u8,
) {
	ni := &net_ifaces[net_count]
	ni.name_len = label_set(ni.name[:], name)

	wl := fmt_path(path_buf, "%s/class/net/%s/wireless", app.sys_root, name)
	ni.wireless = path_exists(wl)

	// Link speed, where the kernel provides one.
	ni.speed_mbps = 0
	sp := fmt_path(path_buf, "%s/class/net/%s/speed", app.sys_root, name)
	if s, ok := read_file_str(sp, name_buf[:]); ok {
		if v, vok := parse_int_simple(trim_ws(s)); vok && v > 0 {
			ni.speed_mbps = v
		}
	}

	label: string
	if ni.wireless {
		if net_iface_up(app, name) {
			if ln, ok := wifi_ssid(name, ssid_buf[:]); ok {
				ni.last_up = true
				ni.last_ssid_len = u8(ln)
				for k in 0 ..< ln {
					ni.last_ssid[k] = ssid_buf[k]
				}
				label = fmt.bprintf(label_buf[:], "Wi-Fi %s - %s", name, string(ssid_buf[:ln]))
			} else {
				label = fmt.bprintf(label_buf[:], "Wi-Fi %s - connected", name)
			}
		} else {
			label = fmt.bprintf(label_buf[:], "Wi-Fi %s - disconnected", name)
		}
	} else {
		label = fmt.bprintf(label_buf[:], "Ethernet %s", name)
	}
	ni.section = section_add(app, label, true)
	g := group_add_at(app, ni.section, "Link", true)

	if ni.speed_mbps > 0 {
		idx := metric_add_computed(app, "Link Speed", .Mbps, .Other, g)
		metric_set_static(app, idx, f64(ni.speed_mbps))
	}

	if ni.wireless {
		ni.sig_metric = u16(metric_add_computed(app, "Signal", .DBm, .Other, g))
	} else {
		ni.util_metric = u16(metric_add_computed(app, "Utilization", .Percent, .Other, g))
	}

	net_count += 1
}

parse_int_simple :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	i := 0
	neg := false
	if s[0] == '-' {
		neg = true
		i = 1
	}
	v := 0
	digits := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = v * 10 + int(s[i] - '0')
		i += 1
		digits += 1
	}
	if digits == 0 {
		return 0, false
	}
	if neg {
		v = -v
	}
	return v, true
}

// ---------------------------------------------------------------------------
// sampling
// ---------------------------------------------------------------------------

net_update :: proc(app: ^App, dt: f64) {
	if net_count == 0 || dt <= 0 {
		return
	}
	fd, err := open_path("/proc/net/dev")
	if err != .NONE {
		return
	}
	defer linux.close(fd)
	buf: [8192]u8
	n, rerr := linux.read(fd, buf[:])
	if rerr != .NONE || n <= 0 {
		return
	}

	i := 0
	for i < n {
		end := i
		for end < n && buf[end] != '\n' {
			end += 1
		}
		line := string(buf[i:end])
		colon := -1
		for k in 0 ..< len(line) {
			if line[k] == ':' {
				colon = k
				break
			}
		}
		if colon > 0 {
			name := trim_ws(line[:colon])
			for k in 0 ..< net_count {
				ni := &net_ifaces[k]
				if net_name(ni) != name {
					continue
				}
				if ni.wireless {
					if sig, ok := wifi_signal(name); ok {
						metric_push(app, int(ni.sig_metric), f64(sig), dt)
					}
					continue
				}
				// rx bytes are field 0 after the colon, tx bytes field 8.
				rx, tx := parse_dev_counters(line[colon + 1:])
				if !ni.primed {
					ni.prev_rx = rx
					ni.prev_tx = tx
					ni.primed = true
					continue
				}
				drx := rx - ni.prev_rx
				dtx := tx - ni.prev_tx
				ni.prev_rx = rx
				ni.prev_tx = tx
				if ni.speed_mbps <= 0 {
					continue
				}
				// Utilisation of the busier direction, capped at 100%.
				peak := drx
				if dtx > peak {
					peak = dtx
				}
				rate_bps := f64(peak) * 8.0 / dt
				pct := rate_bps / (f64(ni.speed_mbps) * 1_000_000.0) * 100.0
				if pct > 100.0 {
					pct = 100.0
				}
				metric_push(app, int(ni.util_metric), pct, dt)
			}
		}
		i = end + 1
	}
}

parse_dev_counters :: proc(s: string) -> (rx: u64, tx: u64) {
	pos := 0
	field := 0
	for pos < len(s) && field <= 8 {
		for pos < len(s) && s[pos] == ' ' {
			pos += 1
		}
		v: u64 = 0
		digits := 0
		for pos < len(s) && s[pos] >= '0' && s[pos] <= '9' {
			v = v * 10 + u64(s[pos] - '0')
			pos += 1
			digits += 1
		}
		if digits == 0 {
			break
		}
		if field == 0 {
			rx = v
		} else if field == 8 {
			tx = v
		}
		field += 1
	}
	return rx, tx
}

// Refreshes the Wi-Fi section labels. Runs on the UI thread, which owns the
// section labels, so nothing races with the sampler.
net_refresh_wifi :: proc(app: ^App) {
	for i in 0 ..< net_count {
		n := &net_ifaces[i]
		if !n.wireless {
			continue
		}
		up := net_iface_up(app, net_name(n))
		ssid_buf: [64]u8
		ssid_len := 0
		if up {
			if ln, ok := wifi_ssid(net_name(n), ssid_buf[:]); ok {
				ssid_len = ln
			}
		}

		same := up == n.last_up && ssid_len == int(n.last_ssid_len)
		if same && ssid_len > 0 {
			same = string(ssid_buf[:ssid_len]) == string(n.last_ssid[:n.last_ssid_len])
		}
		if same {
			continue
		}

		n.last_up = up
		n.last_ssid_len = u8(ssid_len)
		for k in 0 ..< ssid_len {
			n.last_ssid[k] = ssid_buf[k]
		}

		label_buf: [128]u8
		label: string
		if up {
			if ssid_len > 0 {
				label = fmt.bprintf(label_buf[:], "Wi-Fi %s - %s", net_name(n), string(ssid_buf[:ssid_len]))
			} else {
				label = fmt.bprintf(label_buf[:], "Wi-Fi %s - connected", net_name(n))
			}
		} else {
			label = fmt.bprintf(label_buf[:], "Wi-Fi %s - disconnected", net_name(n))
		}
		set_section_label_at(app, n.section, label)
	}
}
