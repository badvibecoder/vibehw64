package main

// Human-readable short names.
//
// CPU: there is no short name anywhere in sysfs — only the CPUID brand string.
//   Rather than a per-SKU table, strip the fixed set of vendor decorations and
//   drop "N-Core" tokens. Falls back to the full brand string if nothing is left.
//
// GPU: sysfs exposes only PCI vendor:device. The distro's pci.ids maps those to
//   marketing names, so the "infinite names" problem is the OS's, not ours.
//   Missing file just means no suffix.
//
// RAM: the SPD5118 EEPROM is world-readable. Data rate and CAS latency are
//   derived from tCKAVGmin (bytes 20-21) and tAAmin (bytes 30-31), both in ps.
//   The SPD reports the JEDEC base profile, not an XMP/EXPO rating.

import "core:fmt"
import "core:sys/linux"

copy_out :: proc(out: []u8, s: string) -> string {
	n := len(s)
	if n > len(out) {
		n = len(out)
	}
	for i in 0 ..< n {
		out[i] = s[i]
	}
	return string(out[:n])
}

find_sub :: proc(hay: []u8, n: int, needle: string) -> int {
	m := len(needle)
	if m == 0 || m > n {
		return -1
	}
	for i in 0 ..= n - m {
		ok := true
		for j in 0 ..< m {
			if hay[i + j] != needle[j] {
				ok = false
				break
			}
		}
		if ok {
			return i
		}
	}
	return -1
}

delete_all :: proc(buf: []u8, n_in: int, needle: string) -> int {
	m := len(needle)
	n := n_in
	if m == 0 {
		return n
	}
	for {
		idx := find_sub(buf, n, needle)
		if idx < 0 {
			return n
		}
		for k in idx ..< n - m {
			buf[k] = buf[k + m]
		}
		n -= m
	}
}

trim_space :: proc(buf: []u8, n: int) -> int {
	start := 0
	for start < n && buf[start] == ' ' {
		start += 1
	}
	end := n
	for end > start && buf[end - 1] == ' ' {
		end -= 1
	}
	if start > 0 {
		for i in start ..< end {
			buf[i - start] = buf[i]
		}
	}
	return end - start
}

// Drops whole tokens that end in "-Core" (e.g. AMD's "16-Core").
drop_core_tokens :: proc(buf: []u8, n: int) -> int {
	out: [128]u8
	on := 0
	i := 0
	for i < n {
		start := i
		for i < n && buf[i] != ' ' {
			i += 1
		}
		end := i
		is_core := false
		if end - start >= 5 && string(buf[end - 5:end]) == "-Core" {
			is_core = true
		}
		if !is_core && end > start {
			if on > 0 && on < len(out) {
				out[on] = ' '
				on += 1
			}
			for k in start ..< end {
				if on < len(out) {
					out[on] = buf[k]
					on += 1
				}
			}
		}
		for i < n && buf[i] == ' ' {
			i += 1
		}
	}
	for k in 0 ..< on {
		buf[k] = out[k]
	}
	return on
}

cpu_short_name :: proc(full: string, out: []u8) -> string {
	tmp: [128]u8
	n := 0
	for i in 0 ..< len(full) {
		if n >= len(tmp) {
			break
		}
		tmp[n] = full[i]
		n += 1
	}

	patterns := [7]string{"Intel(R) ", "Core(TM) ", "(R)", "(TM)", "AMD ", " CPU", " Processor"}
	for pat in patterns {
		n = delete_all(tmp[:], n, pat)
	}
	n = drop_core_tokens(tmp[:], n)
	n = trim_space(tmp[:], n)

	if n == 0 {
		return copy_out(out, full)
	}
	return copy_out(out, string(tmp[:n]))
}

// Prefers the marketing name inside [...] over the codename before it.
pick_short :: proc(s: string) -> string {
	l := -1
	r := -1
	for i in 0 ..< len(s) {
		if s[i] == '[' && l < 0 {
			l = i
		} else if s[i] == ']' && r < 0 {
			r = i
		}
	}
	if l >= 0 && r > l {
		return s[l + 1:r]
	}
	return s
}

parse_hex_id :: proc(s: string) -> (u16, bool) {
	v: u32 = 0
	start := 0
	if len(s) > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		start = 2
	}
	if start >= len(s) {
		return 0, false
	}
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
	return u16(v), true
}

// Streams pci.ids so the 1.6 MB file never has to be held in memory.
// When the subsystem vendor/device is known it prefers that entry (e.g. an
// AIB model) over the generic vendor:device family name.
pci_ids_lookup :: proc(vendor, device, subvendor, subdevice: u16, out: []u8) -> string {
	fd, err := open_path("/usr/share/hwdata/pci.ids")
	if err != .NONE {
		return ""
	}
	defer linux.close(fd)

	vbuf: [8]u8
	dbuf: [8]u8
	svbuf: [8]u8
	sdbuf: [8]u8
	want_v := fmt.bprintf(vbuf[:], "%04x", vendor)
	want_d := fmt.bprintf(dbuf[:], "%04x", device)
	want_sv := fmt.bprintf(svbuf[:], "%04x", subvendor)
	want_sd := fmt.bprintf(sdbuf[:], "%04x", subdevice)

	chunk: [65536]u8
	line: [192]u8
	ln := 0
	vendor_seen := false
	device_seen := false
	device_name := ""
	sub_name := ""

	scan: for {
		got, rerr := linux.read(fd, chunk[:])
		if rerr != .NONE || got <= 0 {
			break
		}
		for i in 0 ..< got {
			c := chunk[i]
			if c != '\n' {
				if ln < len(line) {
					line[ln] = c
					ln += 1
				}
				continue
			}
			if ln >= 5 && line[0] != '\t' && line[4] == ' ' {
				vendor_seen = string(line[0:4]) == want_v
				device_seen = false
			} else if vendor_seen && ln >= 6 && line[0] == '\t' && line[1] != '\t' {
				device_seen = string(line[1:5]) == want_d
				if device_seen {
					s := 5
					for s < ln && (line[s] == ' ' || line[s] == '\t') {
						s += 1
					}
					device_name = pick_short(string(line[s:ln]))
				}
			} else if device_seen && ln >= 12 && line[0] == '\t' && line[1] == '\t' {
				if string(line[2:6]) == want_sv && string(line[7:11]) == want_sd {
					s := 11
					for s < ln && (line[s] == ' ' || line[s] == '\t') {
						s += 1
					}
					sub_name = pick_short(string(line[s:ln]))
					break scan
				}
			}
			ln = 0
		}
	}

	name := sub_name
	if len(name) == 0 {
		name = device_name
	}
	if len(name) == 0 {
		return ""
	}
	return copy_out(out, name)
}

// ---------------------------------------------------------------------------
// SMBIOS type 17 (Memory Device) — the only vendor-neutral source of the
// *running* memory speed. Needs read access to the DMI table, which a boot-time
// systemd unit grants (see scripts/install-permissions.sh).
//
// Offsets: Size 0x0C, Device Locator 0x10, Speed 0x15, Part Number 0x1A,
// Configured Memory Speed 0x20 (SMBIOS 3.3+). Older boards lack 0x20 and we
// fall back to Speed, which is the module's rated speed there.
// ---------------------------------------------------------------------------

smbios_raw: [32768]u8

smbios_string :: proc(buf: []u8, start: int, end: int, index: u8) -> string {
	if index == 0 {
		return ""
	}
	idx := 1
	i := start
	for i < end {
		j := i
		for j < end && buf[j] != 0 {
			j += 1
		}
		if idx == int(index) {
			// SMBIOS string fields are space-padded to a fixed width.
			start := i
			for start < j && buf[start] == ' ' {
				start += 1
			}
			end := j
			for end > start && buf[end - 1] == ' ' {
				end -= 1
			}
			return string(buf[start:end])
		}
		idx += 1
		i = j + 1
	}
	return ""
}

MAX_DIMMS :: 16

SMB_Dimm :: struct {
	size_mb:     int,
	speed_mt:    int,
	locator:     [32]u8,
	locator_len: u8,
}

SMB_Memory :: struct {
	ok:           bool,
	speed_mt:     int,
	volt_mv:      int,
	part:         string,
	mixed:        bool,
	installed_mb: int,
	dimm_count:   int,
	dimms:        [MAX_DIMMS]SMB_Dimm,
}

smbios_part: [64]u8

smbios_memory :: proc(path: string) -> SMB_Memory {
	info := SMB_Memory{}
	fd, err := open_path(path)
	if err != .NONE {
		return info
	}
	defer linux.close(fd)
	total, rerr := linux.read(fd, smbios_raw[:])
	if rerr != .NONE || total < 8 {
		return info
	}
	buf := smbios_raw[:total]

	speed_sum := 0
	speed_n := 0
	part_len := 0
	part_mixed := false
	volt := 0
	installed_mb := 0

	i := 0
	for i + 4 <= total {
		stype := buf[i]
		length := int(buf[i + 1])
		if length < 4 || i + length > total {
			break
		}
		j := i + length
		for j + 1 < total {
			if buf[j] == 0 && buf[j + 1] == 0 {
				break
			}
			j += 1
		}
		if stype == 17 && length >= 0x16 {
			size := u16(buf[i + 0x0C]) | (u16(buf[i + 0x0D]) << 8)
			size_mb := int(size)
			// 0x7FFF means the real size is in the Extended Size dword.
			if size == 0x7FFF && length >= 0x20 {
				size_mb = int(
					u32(buf[i + 0x1C]) |
					(u32(buf[i + 0x1D]) << 8) |
					(u32(buf[i + 0x1E]) << 16) |
					(u32(buf[i + 0x1F]) << 24),
				)
			}
			if size_mb > 0 && size != 0xFFFF {
				got := 0
				// Configured Memory Speed (SMBIOS 3.3+) wins over the rated Speed.
				if length >= 0x22 {
					cfg := int(u16(buf[i + 0x20]) | (u16(buf[i + 0x21]) << 8))
					if cfg > 0 {
						got = cfg
					}
				}
				if got == 0 {
					got = int(u16(buf[i + 0x15]) | (u16(buf[i + 0x16]) << 8))
				}
				if got > 0 {
					speed_sum += got
					speed_n += 1
				}
				if length >= 0x28 && volt == 0 {
					v := int(u16(buf[i + 0x26]) | (u16(buf[i + 0x27]) << 8))
					if v > 0 {
						volt = v
					}
				}
				if length >= 0x1B {
					ps := smbios_string(buf, i + length, j, buf[i + 0x1A])
					if len(ps) > 0 {
						if part_len == 0 {
							part_len = int(label_set(smbios_part[:], ps))
						} else if string(smbios_part[:part_len]) != ps {
							part_mixed = true
						}
					}
				}

				installed_mb += size_mb
				if info.dimm_count < MAX_DIMMS {
					d := &info.dimms[info.dimm_count]
					d.size_mb = size_mb
					d.speed_mt = got
					if length > 0x10 {
						loc := smbios_string(buf, i + length, j, buf[i + 0x10])
						d.locator_len = label_set(d.locator[:], loc)
					}
					info.dimm_count += 1
				}
			}
		}
		i = j + 2
	}

	if speed_n == 0 && info.dimm_count == 0 {
		return info
	}
	info.ok = true
	if speed_n > 0 {
		info.speed_mt = (speed_sum + speed_n / 2) / speed_n
	}
	info.volt_mv = volt
	info.mixed = part_mixed
	info.installed_mb = installed_mb
	if part_len > 0 {
		info.part = string(smbios_part[:part_len])
	}
	return info
}

// DDR5 SPD page 0: tCKAVGmin at 20-21, tAAmin at 30-31, both in picoseconds.
// Data rate = 2e6 / tCK_ps MT/s; CAS latency = tAA_ps / tCK_ps.
spd_summary :: proc(eeprom_path: string, out: []u8) -> (string, int) {
	fd, err := open_path(eeprom_path)
	if err != .NONE {
		return "", 0
	}
	defer linux.close(fd)

	raw: [48]u8
	n, rerr := linux.read(fd, raw[:])
	if rerr != .NONE || n < 36 {
		return "", 0
	}
	if raw[0] != 0x30 { // SPD5 (DDR5) hub key only; skip DDR4 and anything else
		return "", 0
	}

	tck := u64(raw[20]) | (u64(raw[21]) << 8)
	taa := u64(raw[30]) | (u64(raw[31]) << 8)
	if tck < 200 || tck > 1000 { // ~2-10 GT/s
		return "", 0
	}

	mt := int((2_000_000 + tck / 2) / tck)
	mt = ((mt + 50) / 100) * 100
	if mt < 3200 || mt > 12000 {
		return "", 0
	}

	cl := 0
	if taa > 0 {
		cl = int((taa + tck / 2) / tck)
	}
	if cl < 10 || cl > 80 {
		cl = 0
	}

	// This is the SPD's JEDEC base bin, not an XMP/EXPO rating: a 6000 CL36
	// kit declares 4800 CL40 here for fallback boot. Say so rather than imply
	// it is the running configuration.
	if cl > 0 {
		return fmt.bprintf(out, "%dMT CL%d (JEDEC)", mt, cl), mt
	}
	return fmt.bprintf(out, "%dMT (JEDEC)", mt), mt
}
