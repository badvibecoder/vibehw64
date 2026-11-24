package main

// Background sampler thread.
//
// The sampler owns app.metrics. Each tick it reads every pre-opened file
// descriptor, updates the running stats, then copies a snapshot into a
// mutex-guarded buffer that the UI thread reads. The interval can be changed
// at any time without restarting the thread and without resetting stats.

import "core:sync"
import "core:thread"
import "core:time"

Sampler :: struct {
	thread:     ^thread.Thread,
	mu:         sync.Mutex,
	quit:       bool,
	interval:   int,
	snapshot:   [MAX_SENSORS]Sensor_Metric,
	snap_count: int,
	running:    bool,
}

sampler: Sampler

sampler_publish_locked :: proc() {
	sampler.snap_count = app.metric_count
	for i in 0 ..< app.metric_count {
		sampler.snapshot[i] = app.metrics[i]
	}
}

sampler_thread_proc :: proc(_: ^thread.Thread) {
	deadline := time.now()

	for {
		sync.mutex_lock(&sampler.mu)
		quit := sampler.quit
		interval := sampler.interval
		sync.mutex_unlock(&sampler.mu)
		if quit {
			return
		}
		if perms_take_pending() {
			perms_apply_refresh(&app)
		}
		if interval < 100 {
			interval = 100
		}

		now := time.now()
		elapsed := time.duration_nanoseconds(time.diff(deadline, now))
		target := i64(interval) * 1_000_000

		if elapsed >= target {
			dt := f64(elapsed) / 1.0e9
			if dt <= 0 {
				dt = f64(interval) / 1000.0
			}
			sample_all(&app, dt)
			usage_update(&app, dt)
			net_update(&app, dt)
			meminfo_update(&app, dt)

			sync.mutex_lock(&sampler.mu)
			sampler_publish_locked()
			sync.mutex_unlock(&sampler.mu)

			deadline = now
			continue
		}

		// Sleep in bounded slices so quit and interval changes are noticed
		// promptly without busy-waiting.
		remaining := target - elapsed
		if remaining > 50_000_000 {
			remaining = 50_000_000
		}
		time.sleep(time.Duration(remaining))
	}
}

sampler_start :: proc(interval_ms: int) {
	sampler.interval = interval_ms
	sampler.quit = false
	sampler_publish_locked()
	sampler.running = true
	sampler.thread = thread.create(sampler_thread_proc)
	thread.start(sampler.thread)
}

sampler_stop :: proc() {
	if !sampler.running {
		return
	}
	sync.mutex_lock(&sampler.mu)
	sampler.quit = true
	sync.mutex_unlock(&sampler.mu)
	thread.join(sampler.thread)
	thread.destroy(sampler.thread)
	sampler.running = false
}

sampler_set_interval :: proc(ms_in: int) {
	ms := ms_in
	if ms < 100 {
		ms = 100
	}
	if ms > 10000 {
		ms = 10000
	}
	sync.mutex_lock(&sampler.mu)
	sampler.interval = ms
	sync.mutex_unlock(&sampler.mu)
	app.interval_ms = ms
}

sampler_interval :: proc() -> int {
	sync.mutex_lock(&sampler.mu)
	ms := sampler.interval
	sync.mutex_unlock(&sampler.mu)
	return ms
}

// Copies the latest snapshot for the UI. Returns the row count.
sampler_get :: proc(out: []Sensor_Metric) -> int {
	sync.mutex_lock(&sampler.mu)
	n := sampler.snap_count
	for i in 0 ..< n {
		out[i] = sampler.snapshot[i]
	}
	sync.mutex_unlock(&sampler.mu)
	return n
}

sampler_reset :: proc() {
	sync.mutex_lock(&sampler.mu)
	reset_stats(&app)
	sampler_publish_locked()
	sync.mutex_unlock(&sampler.mu)
}
