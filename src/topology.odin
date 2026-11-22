package main

// CPU topology discovery: Package -> Group (core class) -> Physical core.
//
// Nothing about core counts, 6/8-core CCDs, or specific Intel SKUs is
// hard-coded. Groups are discovered from sysfs, in this order:
//
//   Intel hybrid : /sys/devices/cpu_core/cpus + cpu_atom/cpus  (authoritative)
//   AMD          : cache/index3/shared_cpu_list                (one CCD per L3 domain)
//   fallback     : cpuinfo_max_freq tiers (lowest tier = E, rest = P)
//
// "Core N" labels in coretemp are package core IDs, NOT Linux CPU indices.
// topology/core_id is the join key between the two; see core_by_id.

import "core:fmt"
import "core:strconv"
import "core:sys/linux"

MAX_CPUS    :: 256
MAX_CLASSES :: 8
MAX_LABEL   :: 40

Core :: struct {
	cpu:     u16,
	core_id: i32,
	pkg:     i32,
	class:   u8,
}

Core_Class :: struct {
	label:      [MAX_LABEL]u8,
	label_len:  u8,
	tag:        [8]u8,
	tag_len:    u8,
	expanded:   bool,
	is_p:       bool,
	cores:      [MAX_CPUS]u16,
	core_count: int,
}

Topology :: struct {
	vendor:      [16]u8,
	vendor_len:  u8,
	model:       [64]u8,
	model_len:   u8,
	cores:       [MAX_CPUS]Core,
	core_count:  int,
	classes:     [MAX_CLASSES]Core_Class,
	class_count: int,
	smt:         bool,
	hybrid:      bool,
}

// ---------------------------------------------------------------------------
// small string / file helpers (discovery only; allocation-free)
// ---------------------------------------------------------------------------

// sysfs paths are short-lived strings carved out of a reusable buffer, so they
// are NOT NUL-terminated. Copy into a local buffer and terminate before handing
// anything to the kernel; otherwise a shorter path inherits the tail of the
// previous longer one and silently resolves to nothing.
open_path :: proc(path: string) -> (linux.Fd, linux.Errno) {
	buf: [512]u8
	n := len(path)
	if n == 0 || n >= len(buf) {
		return linux.Fd(-1), .ENOENT
	}
	for i in 0 ..< n {
		buf[i] = path[i]
	}
	buf[n] = 0
	return linux.open(cstring(raw_data(buf[:])), {})
}

readlink_str :: proc(path: string, out: []u8) -> (int, bool) {
	buf: [512]u8
	n := len(path)
	if n == 0 || n >= len(buf) {
		return 0, false
	}
	for i in 0 ..< n {
		buf[i] = path[i]
	}
	buf[n] = 0
	rn, err := linux.readlink(cstring(raw_data(buf[:])), out)
	return rn, err == .NONE
}

read_file_str :: proc(path: string, buf: []u8) -> (string, bool) {
	fd, err := open_path(path)
	if err != .NONE {
		return "", false
	}
	defer linux.close(fd)
	n, rerr := linux.read(fd, buf)
	if rerr != .NONE || n <= 0 {
		return "", false
	}
	return string(buf[:n]), true
}

trim_ws :: proc(s: string) -> string {
	end := len(s)
	for end > 0 {
		c := s[end - 1]
		if c == '\n' || c == '\r' || c == ' ' || c == '\t' {
			end -= 1
		} else {
			break
		}
	}
	return s[:end]
}

value_after_colon :: proc(line: string) -> string {
	i := 0
	for i < len(line) && line[i] != ':' {
		i += 1
	}
	if i >= len(line) {
		return ""
	}
	i += 1
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i += 1
	}
	return trim_ws(line[i:])
}

label_set :: proc(dst: []u8, s: string) -> u8 {
	n := len(s)
	if n > len(dst) {
		n = len(dst)
	}
	for i in 0 ..< n {
		dst[i] = s[i]
	}
	return u8(n)
}

label_str :: proc(dst: []u8, n: u8) -> string {
	return string(dst[:n])
}

fmt_path :: proc(buf: ^[512]u8, format: string, args: ..any) -> string {
	return fmt.bprintf(buf[:], format, ..args)
}

fmt_label :: proc(buf: ^[MAX_LABEL]u8, format: string, args: ..any) -> string {
	return fmt.bprintf(buf[:], format, ..args)
}

// Parses a kernel cpumask list such as "0-7" or "0,2,4-7".
parse_cpu_list :: proc(s: string, set: ^[MAX_CPUS]bool) -> bool {
	i := 0
	found := false
	for i < len(s) {
		c := s[i]
		if c == ',' || c == '\n' || c == '\r' || c == ' ' {
			i += 1
			continue
		}
		if c < '0' || c > '9' {
			return false
		}
		lo := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			lo = lo * 10 + int(s[i] - '0')
			i += 1
		}
		hi := lo
		if i < len(s) && s[i] == '-' {
			i += 1
			hi = 0
			for i < len(s) && s[i] >= '0' && s[i] <= '9' {
				hi = hi * 10 + int(s[i] - '0')
				i += 1
			}
		}
		if lo < 0 || hi >= MAX_CPUS || hi < lo {
			return false
		}
		for n in lo ..= hi {
			set[n] = true
			found = true
		}
	}
	return found
}

class_add :: proc(t: ^Topology, label, tag: string, expanded: bool) -> u8 {
	i := t.class_count
	if i >= MAX_CLASSES {
		return 0
	}
	cl := &t.classes[i]
	cl.label_len = label_set(cl.label[:], label)
	cl.tag_len = label_set(cl.tag[:], tag)
	cl.expanded = expanded
	t.class_count += 1
	return u8(i)
}

class_append :: proc(t: ^Topology, ci: u8, cpu: u16) {
	cl := &t.classes[ci]
	if cl.core_count < MAX_CPUS {
		cl.cores[cl.core_count] = cpu
		cl.core_count += 1
	}
}

core_by_id :: proc(t: ^Topology, core_id: i32) -> int {
	for c in 0 ..< t.core_count {
		if t.cores[c].core_id == core_id {
			return c
		}
	}
	return -1
}

class_tag :: proc(t: ^Topology, ci: u8) -> string {
	cl := &t.classes[ci]
	return label_str(cl.tag[:], cl.tag_len)
}

class_label :: proc(t: ^Topology, ci: u8) -> string {
	cl := &t.classes[ci]
	return label_str(cl.label[:], cl.label_len)
}

// ---------------------------------------------------------------------------
// discovery
// ---------------------------------------------------------------------------

topo_discover :: proc(t: ^Topology, sys_root: string) -> bool {
	file_buf: [8192]u8
	path_buf: [512]u8
	online: [MAX_CPUS]bool

	// --- Vendor and model: /proc/cpuinfo's first block has both. Resolved
	// relative to sys_root so a fixture tree can stand in for real hardware.
	cpuinfo_path := fmt_path(&path_buf, "%s/../proc/cpuinfo", sys_root)
	if s, ok := read_file_str(cpuinfo_path, file_buf[:]); ok {
		pos := 0
		for pos < len(s) {
			end := pos
			for end < len(s) && s[end] != '\n' {
				end += 1
			}
			line := s[pos:end]
			if len(line) >= 9 && line[:9] == "vendor_id" {
				t.vendor_len = label_set(t.vendor[:], value_after_colon(line))
			} else if len(line) >= 10 && line[:10] == "model name" {
				t.model_len = label_set(t.model[:], value_after_colon(line))
			}
			pos = end + 1
		}
	}

	// --- Which CPUs are online.
	p := fmt_path(&path_buf, "%s/devices/system/cpu/online", sys_root)
	if s, ok := read_file_str(p, file_buf[:]); ok {
		if !parse_cpu_list(s, &online) {
			for i in 0 ..< MAX_CPUS {
				online[i] = true
			}
		}
	} else {
		for i in 0 ..< MAX_CPUS {
			online[i] = true
		}
	}

	// --- Physical cores, with SMT siblings collapsed to the lowest CPU.
	for cpu in 0 ..< MAX_CPUS {
		if !online[cpu] {
			continue
		}
		sib: [MAX_CPUS]bool
		p = fmt_path(&path_buf, "%s/devices/system/cpu/cpu%d/topology/thread_siblings_list", sys_root, cpu)
		if s, ok := read_file_str(p, file_buf[:]); ok {
			parse_cpu_list(s, &sib)
		}
		is_rep := true
		for other in 0 ..< cpu {
			if sib[other] {
				is_rep = false
				break
			}
		}
		if !is_rep {
			t.smt = true
			continue
		}

		core := Core {
			cpu     = u16(cpu),
			core_id = -1,
			class   = 0,
		}
		p = fmt_path(&path_buf, "%s/devices/system/cpu/cpu%d/topology/core_id", sys_root, cpu)
		if s, ok := read_file_str(p, file_buf[:]); ok {
			if v, vok := strconv.parse_int(trim_ws(s), 10); vok {
				core.core_id = i32(v)
			}
		}
		p = fmt_path(&path_buf, "%s/devices/system/cpu/cpu%d/topology/physical_package_id", sys_root, cpu)
		if s, ok := read_file_str(p, file_buf[:]); ok {
			if v, vok := strconv.parse_int(trim_ws(s), 10); vok {
				core.pkg = i32(v)
			}
		}
		if t.core_count < MAX_CPUS {
			t.cores[t.core_count] = core
			t.core_count += 1
		}
	}

	if t.core_count == 0 {
		return false
	}

	// --- Classify.
	if topo_try_intel(t, sys_root) {
		t.hybrid = true
	} else if label_str(t.vendor[:], t.vendor_len) == "AuthenticAMD" {
		topo_classify_amd(t, sys_root)
	} else {
		topo_classify_freq(t, sys_root)
	}

	if t.class_count == 0 {
		ci := class_add(t, "All Cores", "", true)
		for c in 0 ..< t.core_count {
			t.cores[c].class = ci
			class_append(t, ci, t.cores[c].cpu)
		}
	}
	return true
}

// Intel hybrid PMU cpumasks. Present on kernels that expose hybrid PMUs.
topo_try_intel :: proc(t: ^Topology, sys_root: string) -> bool {
	path_buf: [512]u8
	file_buf: [8192]u8
	p_mask, e_mask: [MAX_CPUS]bool

	p := fmt_path(&path_buf, "%s/devices/cpu_core/cpus", sys_root)
	s, ok := read_file_str(p, file_buf[:])
	if !ok || !parse_cpu_list(s, &p_mask) {
		return false
	}
	p = fmt_path(&path_buf, "%s/devices/cpu_atom/cpus", sys_root)
	s, ok = read_file_str(p, file_buf[:])
	if !ok || !parse_cpu_list(s, &e_mask) {
		return false
	}

	p_i := class_add(t, "P-Cores", "P", true)
	e_i := class_add(t, "E-Cores", "E", false)
	for c in 0 ..< t.core_count {
		core := &t.cores[c]
		if p_mask[core.cpu] {
			core.class = p_i
			class_append(t, p_i, core.cpu)
		} else if e_mask[core.cpu] {
			core.class = e_i
			class_append(t, e_i, core.cpu)
		}
	}
	return true
}

// AMD: one CCD per L3 domain. Cores sharing index3/shared_cpu_list share a CCD.
// The CCD with the larger L3 is the stacked-cache (X3D) die.
topo_classify_amd :: proc(t: ^Topology, sys_root: string) {
	path_buf: [512]u8
	file_buf: [512]u8

	keys: [MAX_CLASSES][64]u8
	key_lens: [MAX_CLASSES]int
	key_size: [MAX_CLASSES]u64
	core_key: [MAX_CPUS]u8
	key_count := 0

	for c in 0 ..< t.core_count {
		core := &t.cores[c]
		core_key[c] = 0
		p := fmt_path(&path_buf, "%s/devices/system/cpu/cpu%d/cache/index3/shared_cpu_list", sys_root, core.cpu)
		s, ok := read_file_str(p, file_buf[:])
		if !ok {
			continue
		}
		key := trim_ws(s)
		idx := -1
		for k in 0 ..< key_count {
			if key_lens[k] == len(key) && string(keys[k][:key_lens[k]]) == key {
				idx = k
				break
			}
		}
		if idx < 0 {
			if key_count >= MAX_CLASSES {
				continue
			}
			idx = key_count
			key_lens[idx] = len(key)
			for i in 0 ..< len(key) {
				keys[idx][i] = key[i]
			}
			size: u64 = 0
			sp := fmt_path(&path_buf, "%s/devices/system/cpu/cpu%d/cache/index3/size", sys_root, core.cpu)
			if ss, sok := read_file_str(sp, file_buf[:]); sok {
				size = parse_leading_u64(trim_ws(ss))
			}
			key_size[idx] = size
			key_count += 1
		}
		core_key[c] = u8(idx)
	}

	min_size: u64 = 0
	for k in 0 ..< key_count {
		if min_size == 0 || key_size[k] < min_size {
			min_size = key_size[k]
		}
	}

	lab_buf: [MAX_LABEL]u8
	tag_buf: [MAX_LABEL]u8
	class_of_key: [MAX_CLASSES]u8
	for k in 0 ..< key_count {
		is_3d := min_size > 0 && key_size[k] > min_size
		tag := fmt_label(&tag_buf, "CCD%d", k)
		lab: string
		if is_3d {
			lab = fmt_label(&lab_buf, "CCD %d [3D]", k)
		} else {
			lab = fmt_label(&lab_buf, "CCD %d", k)
		}
		class_of_key[k] = class_add(t, lab, tag, k == 0)
	}

	for c in 0 ..< t.core_count {
		k := core_key[c]
		if int(k) >= key_count {
			continue
		}
		t.cores[c].class = class_of_key[k]
		class_append(t, class_of_key[k], t.cores[c].cpu)
	}
}

// Last resort: bucket cores by cpuinfo_max_freq. Lowest tier is treated as E.
topo_classify_freq :: proc(t: ^Topology, sys_root: string) {
	path_buf: [512]u8
	file_buf: [256]u8
	freqs: [MAX_CPUS]u64

	fmin: u64 = 0
	fmax: u64 = 0
	for c in 0 ..< t.core_count {
		core := &t.cores[c]
		p := fmt_path(&path_buf, "%s/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", sys_root, core.cpu)
		freqs[c] = 0
		if s, ok := read_file_str(p, file_buf[:]); ok {
			if v, vok := strconv.parse_int(trim_ws(s), 10); vok && v > 0 {
				freqs[c] = u64(v)
			}
		}
		if freqs[c] > 0 {
			if fmin == 0 || freqs[c] < fmin {
				fmin = freqs[c]
			}
			if freqs[c] > fmax {
				fmax = freqs[c]
			}
		}
	}

	if fmin == 0 || fmin == fmax {
		ci := class_add(t, "All Cores", "", true)
		for c in 0 ..< t.core_count {
			t.cores[c].class = ci
			class_append(t, ci, t.cores[c].cpu)
		}
		return
	}

	p_i := class_add(t, "P-Cores", "P", true)
	e_i := class_add(t, "E-Cores", "E", false)
	for c in 0 ..< t.core_count {
		ci := p_i
		if freqs[c] == fmin {
			ci = e_i
		}
		t.cores[c].class = ci
		class_append(t, ci, t.cores[c].cpu)
	}
}

parse_leading_u64 :: proc(s: string) -> u64 {
	v: u64 = 0
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			break
		}
		v = v * 10 + u64(s[i] - '0')
	}
	return v
}
