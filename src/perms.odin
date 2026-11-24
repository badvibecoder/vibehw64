package main

// One-time privilege setup, driven from inside the app.
//
// The app never sees the user's password. It spawns
//     pkexec /bin/sh -c "<fixed script>"
// and polkit shows the desktop's own authentication dialog. The script writes
// the udev rule and the systemd unit, reloads both, and enables the unit.
//
// The file contents are compiled into the binary and base64-encoded in the
// script, so nothing has to be escaped and no user input ever reaches a shell.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:sys/linux"
import "core:thread"

RULE_B64 :: "IyB2aWJlaHc2NDogYWxsb3cgdW5wcml2aWxlZ2VkIHJlYWRzIG9mIFJBUEwgZW5lcmd5IGNvdW50ZXJzIChwb3dlciBzZW5zb3JzIG9ubHkpLgpBQ1RJT049PSJhZGR8Y2hhbmdlIiwgU1VCU1lTVEVNPT0icG93ZXJjYXAiLCBLRVJORUw9PSJpbnRlbC1yYXBsOioiLCAgICAgIFJVTis9Ii9iaW4vY2htb2QgMDQ0NCAvc3lzL2NsYXNzL3Bvd2VyY2FwLyVrL2VuZXJneV91aiIKQUNUSU9OPT0iYWRkfGNoYW5nZSIsIFNVQlNZU1RFTT09InBvd2VyY2FwIiwgS0VSTkVMPT0iaW50ZWwtcmFwbC1tbWlvOioiLCBSVU4rPSIvYmluL2NobW9kIDA0NDQgL3N5cy9jbGFzcy9wb3dlcmNhcC8lay9lbmVyZ3lfdWoiCkFDVElPTj09ImFkZHxjaGFuZ2UiLCBTVUJTWVNURU09PSJwb3dlcmNhcCIsIEtFUk5FTD09ImFtZC1yYXBsOioiLCAgICAgICAgUlVOKz0iL2Jpbi9jaG1vZCAwNDQ0IC9zeXMvY2xhc3MvcG93ZXJjYXAvJWsvZW5lcmd5X3VqIgo="

UNIT_B64 :: "W1VuaXRdCkRlc2NyaXB0aW9uPXZpYmVodzY0OiBhbGxvdyB1bnByaXZpbGVnZWQgcmVhZHMgb2YgdGhlIFNNQklPUy9ETUkgdGFibGUKQWZ0ZXI9c3lzaW5pdC50YXJnZXQKCltTZXJ2aWNlXQpUeXBlPW9uZXNob3QKRXhlY1N0YXJ0PS9iaW4vc2ggLWMgJ2NobW9kIDA0NDQgL3N5cy9maXJtd2FyZS9kbWkvdGFibGVzL0RNSSAyPi9kZXYvbnVsbCB8fCB0cnVlJwpSZW1haW5BZnRlckV4aXQ9eWVzCgpbSW5zdGFsbF0KV2FudGVkQnk9bXVsdGktdXNlci50YXJnZXQK"

Perms_State :: enum u8 {
	Idle,
	Running,
	Done,
	Failed,
}

Perms :: struct {
	mu:           sync.Mutex,
	state:        Perms_State,
	pending:      bool,
	labels_dirty: bool,
	thread:       ^thread.Thread,
}

perms: Perms

perms_build_script :: proc(buf: []u8) -> string {
	return fmt.bprintf(
		buf,
		"printf %%s '%s' | base64 -d > /etc/udev/rules.d/99-vibehw64-power.rules; " +
		"chmod 644 /etc/udev/rules.d/99-vibehw64-power.rules; " +
		"udevadm control --reload-rules; " +
		"udevadm trigger --action=add --subsystem-match=powercap; " +
		"printf %%s '%s' | base64 -d > /etc/systemd/system/vibehw64-dmi-perms.service; " +
		"chmod 644 /etc/systemd/system/vibehw64-dmi-perms.service; " +
		"systemctl daemon-reload; " +
		"systemctl enable --now vibehw64-dmi-perms.service >/dev/null 2>&1; " +
		"exit 0",
		RULE_B64,
		UNIT_B64,
	)
}

perms_run_setup :: proc() -> bool {
	script_buf: [4096]u8
	script := perms_build_script(script_buf[:])
	desc := os.Process_Desc {
		command = []string{"/usr/bin/pkexec", "/bin/sh", "-c", script},
	}
	child, err := os.process_start(desc)
	if err != nil {
		return false
	}
	state, werr := os.process_wait(child)
	if werr != nil {
		return false
	}
	return state.exited && state.exit_code == 0
}

perms_thread_proc :: proc(_: ^thread.Thread) {
	ok := perms_run_setup()
	sync.mutex_lock(&perms.mu)
	if ok {
		perms.state = .Done
		perms.pending = true
	} else {
		perms.state = .Failed
	}
	sync.mutex_unlock(&perms.mu)
}

perms_start_setup :: proc() {
	sync.mutex_lock(&perms.mu)
	if perms.state == .Running {
		sync.mutex_unlock(&perms.mu)
		return
	}
	perms.state = .Running
	sync.mutex_unlock(&perms.mu)

	perms.thread = thread.create(perms_thread_proc)
	if perms.thread != nil {
		thread.start(perms.thread)
	}
}

perms_state_get :: proc() -> Perms_State {
	sync.mutex_lock(&perms.mu)
	s := perms.state
	sync.mutex_unlock(&perms.mu)
	return s
}

perms_take_pending :: proc() -> bool {
	sync.mutex_lock(&perms.mu)
	p := perms.pending
	perms.pending = false
	sync.mutex_unlock(&perms.mu)
	return p
}

perms_take_labels_dirty :: proc() -> bool {
	sync.mutex_lock(&perms.mu)
	d := perms.labels_dirty
	perms.labels_dirty = false
	sync.mutex_unlock(&perms.mu)
	return d
}

// True when something we want is still root-only.
perms_needed :: proc(app: ^App) -> bool {
	if !app.dmi_ok {
		return true
	}
	for i in 0 ..< app.source_count {
		if app.sources[i].root {
			return true
		}
	}
	return false
}

// Runs on the sampler thread so no metric or fd state is mutated concurrently.
perms_apply_refresh :: proc(app: ^App) {
	// Power: reopen the counters that failed with EACCES.
	for i in 0 ..< app.source_count {
		src := &app.sources[i]
		if !src.root || src.reopen_len == 0 {
			continue
		}
		dir := string(src.reopen_path[:src.reopen_len])
		epath: [220]u8
		eps := fmt.bprintf(epath[:], "%s/energy_uj", dir)
		fd, err := open_path(eps)
		if err != .NONE {
			continue
		}
		mr: u64 = 0
		mbuf: [64]u8
		mpath: [220]u8
		mps := fmt.bprintf(mpath[:], "%s/max_energy_range_uj", dir)
		if mfd, merr := open_path(mps); merr == .NONE {
			if rn, rerr := linux.read(mfd, mbuf[:]); rerr == .NONE && rn > 0 {
				if v, vok := strconv.parse_int(trim_ws(string(mbuf[:rn])), 10); vok {
					mr = u64(v)
				}
			}
			linux.close(mfd)
		}
		src.fd = fd
		src.usable = true
		src.root = false
		src.max_range = mr
		src.have_prev = false
	}

	// Memory identity from SMBIOS.
	path_buf: [512]u8
	dp := fmt_path(&path_buf, "%s/firmware/dmi/tables/DMI", app.sys_root)
	info := smbios_memory(dp)
	if info.ok {
		memory_apply_identity(app, info)
	}

	sync.mutex_lock(&perms.mu)
	perms.labels_dirty = true
	sync.mutex_unlock(&perms.mu)
}
