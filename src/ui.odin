package main

// raylib UI: a collapsible sensor tree in the style of HWiNFO's Sensors window.
//
// Layout: toolbar, table header, scrollable tree, and a dedicated scrollbar
// strip on the right that never overlaps the table. Columns are drag-resizable
// and double-clicking a column boundary auto-sizes that column.

import "core:c"
import "core:fmt"
import "core:math"
import rl "vendor:raylib"

FONT_BYTES :: #load("assets/DejaVuSansMono.ttf")

// Window icon, embedded at compile time so the binary stays self-contained.
ICON_256 :: #load("assets/icon-256.png")
ICON_64  :: #load("assets/icon-64.png")
ICON_48  :: #load("assets/icon-48.png")
ICON_32  :: #load("assets/icon-32.png")
ICON_16  :: #load("assets/icon-16.png")

WINDOW_W :: 760
WINDOW_H :: 820
FONT_SIZE :: f32(16.0)
ROW_H :: f32(22.0)
TOOLBAR_H :: f32(34.0)
HEADER_H :: f32(24.0)
BANNER_H :: f32(26.0)
INDENT_ROOT :: f32(14.0)
INDENT_GROUP :: f32(30.0)
INDENT_ROW :: f32(46.0)

SCROLLBAR_W :: f32(13.0)
COL_COUNT :: 6
COL_MIN :: f32(44.0)
COL_SENSOR :: 0
COL_CUR :: 1
COL_MIN_C :: 2
COL_MAX_C :: 3
COL_AVG :: 4
COL_UNIT :: 5

COL_BG      :: rl.Color{17, 17, 20, 255}
COL_PANEL   :: rl.Color{28, 28, 34, 255}
COL_ROW_ALT :: rl.Color{22, 22, 27, 255}
COL_BTN     :: rl.Color{56, 56, 66, 255}
COL_FIELD   :: rl.Color{16, 16, 20, 255}
COL_BORDER  :: rl.Color{70, 70, 82, 255}
COL_TEXT    :: rl.Color{210, 210, 216, 255}
COL_DIM     :: rl.Color{128, 128, 142, 255}
COL_ACCENT  :: rl.Color{120, 178, 255, 255}
COL_AMBER   :: rl.Color{236, 172, 62, 255}
COL_RED     :: rl.Color{240, 84, 72, 255}
COL_RED_DIM :: rl.Color{104, 30, 30, 255}
COL_WHITE      :: rl.Color{255, 255, 255, 255}
COL_TEMP_GREEN :: rl.Color{56, 142, 60, 255}
COL_TEMP_ORANGE:: rl.Color{230, 120, 30, 255}
COL_TEMP_RED   :: rl.Color{198, 40, 40, 255}

ui_font:           rl.Font
ui_scroll:         f32
ui_metrics:        [MAX_SENSORS]Sensor_Metric
ui_n:              int
ui_interval_focus: bool
ui_interval_buf:   [8]u8
ui_interval_len:   int
ui_copy_flash:     int
ui_copy_buf:       [65536]u8
ui_copy_len:       int

ui_col_w:       [COL_COUNT]f32 = {340, 82, 82, 82, 82, 50}
ui_last_w:      f32
ui_drag_col:    int = -1
ui_drag_scroll: bool
ui_last_click_t: f64
ui_last_click_col: int = -1
ui_block_rows:  bool
ui_frame:       int
ui_banner_visible: bool
ui_hover_boundary: int = -1

ui_reset_rect :: proc() -> rl.Rectangle {
	return {8, 6, 136, 22}
}

ui_copy_rect :: proc(w: f32) -> rl.Rectangle {
	return {w - 84, 6, 76, 22}
}

ui_interval_field_rect :: proc() -> rl.Rectangle {
	return {226, 6, 62, 22}
}

// ---------------------------------------------------------------------------
// text helpers (raylib wants NUL-terminated strings)
// ---------------------------------------------------------------------------

ui_text :: proc(s: string, x, y, size: f32, color: rl.Color) {
	buf: [200]u8
	n := len(s)
	if n > len(buf) - 1 {
		n = len(buf) - 1
	}
	for i in 0 ..< n {
		buf[i] = s[i]
	}
	buf[n] = 0
	rl.DrawTextEx(ui_font, cstring(raw_data(buf[:])), rl.Vector2{x, y}, size, 0, color)
}

ui_text_width :: proc(s: string, size: f32) -> f32 {
	buf: [200]u8
	n := len(s)
	if n > len(buf) - 1 {
		n = len(buf) - 1
	}
	for i in 0 ..< n {
		buf[i] = s[i]
	}
	buf[n] = 0
	return rl.MeasureTextEx(ui_font, cstring(raw_data(buf[:])), size, 0).x
}

ui_lerp_color :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	tt := t
	if tt < 0 {
		tt = 0
	}
	if tt > 1 {
		tt = 1
	}
	return rl.Color {
		u8(f32(a[0]) + (f32(b[0]) - f32(a[0])) * tt),
		u8(f32(a[1]) + (f32(b[1]) - f32(a[1])) * tt),
		u8(f32(a[2]) + (f32(b[2]) - f32(a[2])) * tt),
		255,
	}
}

ui_text_right :: proc(s: string, right, y, size: f32, color: rl.Color) {
	ui_text(s, right - ui_text_width(s, size), y, size, color)
}

ui_num_str :: proc(buf: []u8, v: f64, decimals: int) -> string {
	switch decimals {
	case 0:
		return fmt.bprintf(buf, "%.0f", v)
	case 1:
		return fmt.bprintf(buf, "%.1f", v)
	case 2:
		return fmt.bprintf(buf, "%.2f", v)
	}
	return fmt.bprintf(buf, "%.3f", v)
}

// ---------------------------------------------------------------------------
// columns
// ---------------------------------------------------------------------------

ui_col_x :: proc() -> [COL_COUNT]f32 {
	x: [COL_COUNT]f32
	x[0] = INDENT_ROOT
	for i in 1 ..< COL_COUNT {
		x[i] = x[i - 1] + ui_col_w[i - 1]
	}
	return x
}

ui_col_right :: proc(x: [COL_COUNT]f32, i: int) -> f32 {
	return x[i] + ui_col_w[i] - 10
}

ui_content_w :: proc(w: f32) -> f32 {
	return w - SCROLLBAR_W
}

// Widest needed width for a column, over all rows plus the header label.
ui_auto_size :: proc(col: int) {
	headers := [COL_COUNT]string{"Sensor", "Current", "Minimum", "Maximum", "Average", "Unit"}
	widest := ui_text_width(headers[col], FONT_SIZE)

	for i in 0 ..< ui_n {
		m := &ui_metrics[i]
		s: string
		buf: [24]u8
		switch col {
		case COL_SENSOR:
			s = label_str(m.label[:], m.label_len)
		case COL_UNIT:
			s = unit_str(m.unit)
		case COL_CUR:
			s = ui_num_str(buf[:], m.cur, unit_decimals(m.unit))
		case COL_MIN_C:
			s = ui_num_str(buf[:], m.min, unit_decimals(m.unit))
		case COL_MAX_C:
			s = ui_num_str(buf[:], m.max, unit_decimals(m.unit))
		case COL_AVG:
			s = ui_num_str(buf[:], metric_avg(m), unit_decimals(m.unit))
		case:
		}
		if len(s) == 0 {
			continue
		}
		sw := ui_text_width(s, FONT_SIZE)
		if sw > widest {
			widest = sw
		}
	}
	ui_col_w[col] = max(COL_MIN, widest + 26)
}

// ---------------------------------------------------------------------------
// layout helpers
// ---------------------------------------------------------------------------

ui_section_has_rows :: proc(si: int) -> bool {
	for i in 0 ..< ui_n {
		g := int(ui_metrics[i].group)
		if g < app.group_count && int(app.groups[g].section) == si {
			return true
		}
	}
	return false
}

ui_group_count :: proc(si: int) -> int {
	n := 0
	for g in 0 ..< app.group_count {
		if int(app.groups[g].section) == si && ui_rows_in_group(g) > 0 {
			n += 1
		}
	}
	return n
}

ui_rows_in_group :: proc(gi: int) -> int {
	n := 0
	for i in 0 ..< ui_n {
		if int(ui_metrics[i].group) == gi {
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// clipboard snapshot
// ---------------------------------------------------------------------------

ui_copy_add :: proc(format: string, args: ..any) {
	tmp: [256]u8
	s := fmt.bprintf(tmp[:], format, ..args)
	room := len(ui_copy_buf) - 1 - ui_copy_len
	if room <= 0 {
		return
	}
	n := len(s)
	if n > room {
		n = room
	}
	for i in 0 ..< n {
		ui_copy_buf[ui_copy_len + i] = s[i]
	}
	ui_copy_len += n
}

ui_copy_left :: proc(s: string, width: int) {
	ui_copy_add("%s", s)
	for i := len(s); i < width; i += 1 {
		ui_copy_add(" ")
	}
}

ui_copy_right :: proc(s: string, width: int) {
	for i := len(s); i < width; i += 1 {
		ui_copy_add(" ")
	}
	ui_copy_add("%s", s)
}

ui_copy_row :: proc(m: ^Sensor_Metric) {
	label := label_str(m.label[:], m.label_len)
	ui_copy_add("    ")
	ui_copy_left(label, 30)
	ui_copy_add(" ")

	if m.src != NO_SOURCE && app.sources[m.src].root {
		ui_copy_add("[Root Required]\n")
		return
	}
	if !m.seen {
		ui_copy_right("--", 10)
		ui_copy_add("\n")
		return
	}

	d := unit_decimals(m.unit)
	b1, b2, b3, b4: [24]u8
	cur := num_field(b1[:], m.cur, d, 10)
	mn := num_field(b2[:], m.min, d, 10)
	mx := num_field(b3[:], m.max, d, 10)
	av := num_field(b4[:], metric_avg(m), d, 10)
	ui_copy_add("%s %s %s %s  %s\n", cur, mn, mx, av, unit_str(m.unit))
}

ui_copy_build :: proc() -> int {
	ui_copy_len = 0
	ui_copy_buf[0] = 0

	ui_copy_add("vibehw64 snapshot\n")
	cpu := label_str(app.cpu_short[:], app.cpu_short_len)
	if len(cpu) > 0 {
		ui_copy_add("CPU: %s\n", cpu)
	}
	if app.gpu_short_len > 0 {
		ui_copy_add("GPU: %s\n", label_str(app.gpu_short[:], app.gpu_short_len))
	}
	if app.ram_short_len > 0 {
		ui_copy_add("Memory: %s\n", label_str(app.ram_short[:], app.ram_short_len))
	}
	ui_copy_add("Interval: %d ms\n\n", app.interval_ms)

	ui_copy_add("    ")
	ui_copy_left("Sensor", 30)
	ui_copy_add(" ")
	ui_copy_right("Current", 10)
	ui_copy_add(" ")
	ui_copy_right("Minimum", 10)
	ui_copy_add(" ")
	ui_copy_right("Maximum", 10)
	ui_copy_add(" ")
	ui_copy_right("Average", 10)
	ui_copy_add("  Unit\n")
	ui_copy_add("------------------------------------------------------------------------------\n")

	for si in 0 ..< app.section_count {
		if !ui_section_has_rows(si) {
			continue
		}
		ui_copy_add("[%s]\n", app.sections[si].label)
		gcount := ui_group_count(si)
		for g in 0 ..< app.group_count {
			if int(app.groups[g].section) != si {
				continue
			}
			if ui_rows_in_group(g) == 0 {
				continue
			}
			if gcount > 1 {
				ui_copy_add("  %s\n", label_str(app.groups[g].label[:], app.groups[g].label_len))
			}
			for i in 0 ..< ui_n {
				if int(ui_metrics[i].group) == g {
					ui_copy_row(&ui_metrics[i])
				}
			}
		}
		ui_copy_add("\n")
	}

	ui_copy_buf[ui_copy_len] = 0
	return ui_copy_len
}

ui_copy_snapshot :: proc() {
	ui_copy_build()
	rl.SetClipboardText(cstring(raw_data(ui_copy_buf[:])))
}

ui_content_height :: proc() -> f32 {
	h: f32 = 0
	for si in 0 ..< app.section_count {
		if !ui_section_has_rows(si) {
			continue
		}
		h += ROW_H
		if !app.sections[si].expanded {
			continue
		}
		gcount := ui_group_count(si)
		for g in 0 ..< app.group_count {
			if int(app.groups[g].section) != si {
				continue
			}
			rows := ui_rows_in_group(g)
			if rows == 0 {
				continue
			}
			if gcount > 1 {
				h += ROW_H
				if !app.groups[g].expanded {
					continue
				}
			}
			h += f32(rows) * ROW_H
		}
	}
	return h
}

ui_row_color :: proc(m: ^Sensor_Metric) -> rl.Color {
	if m.unit != .Celsius {
		return COL_TEXT
	}
	#partial switch m.class {
	case .CPU_Pkg, .CPU_Core:
		if m.cur >= 95 {
			return COL_RED
		}
		if m.cur >= 85 {
			return COL_AMBER
		}
	case .CPU_TjMax_Distance:
		// Distance is inverted: keep the same 85/95 C thresholds as the
		// temperature rows by converting back through this core's TjMax.
		t := m.limit - m.cur
		if t >= 95 {
			return COL_RED
		}
		if t >= 85 {
			return COL_AMBER
		}
	case .CPU_Max_Distance:
		// Tcontrol is the recommended operating limit: at or above it is red,
		// within 5 C of it is amber.
		if m.cur <= 0 {
			return COL_RED
		}
		if m.cur <= 5 {
			return COL_AMBER
		}
	case .DIMM:
		if m.cur >= 75 {
			return COL_RED
		}
		if m.cur >= 65 {
			return COL_AMBER
		}
	case .GPU_Edge:
		if m.cur >= 90 {
			return COL_RED
		}
		if m.cur >= 80 {
			return COL_AMBER
		}
	case .GPU_Junction:
		if m.cur >= 105 {
			return COL_RED
		}
		if m.cur >= 95 {
			return COL_AMBER
		}
	case .GPU_Mem:
		if m.cur >= 95 {
			return COL_RED
		}
		if m.cur >= 85 {
			return COL_AMBER
		}
	case .Drive:
		if m.cur >= 80 {
			return COL_RED
		}
		if m.cur >= 70 {
			return COL_AMBER
		}
	}
	return COL_TEXT
}

// Per-value bands for measured temperatures. Static limits and the distance
// rows are excluded: their values are not live temperatures.
ui_temp_band_value :: proc(m: ^Sensor_Metric, v: f64) -> (rl.Color, bool) {
	if m.unit != .Celsius || !m.seen {
		return {}, false
	}
	#partial switch m.class {
	case .CPU_TjMax_Distance, .CPU_Max_Distance, .Temp_Limit:
		return {}, false
	}
	if m.src != NO_SOURCE && app.sources[m.src].root {
		return {}, false
	}
	if v >= 80 {
		return COL_TEMP_RED, true
	}
	if v >= 70 {
		return COL_TEMP_ORANGE, true
	}
	if v >= 60 {
		return COL_TEMP_GREEN, true
	}
	return {}, false
}

ui_draw_value_cell :: proc(s: string, right, y: f32, m: ^Sensor_Metric, v: f64, base: rl.Color) {
	band, highlighted := ui_temp_band_value(m, v)
	if highlighted {
		tw := ui_text_width(s, FONT_SIZE)
		rl.DrawRectangleRec(
			rl.Rectangle{right - tw - 5, y + 2, tw + 10, ROW_H - 4},
			band,
		)
		ui_text(s, right - tw, y + 3, FONT_SIZE, COL_WHITE)
	} else {
		ui_text_right(s, right, y + 3, FONT_SIZE, base)
	}
}

// ---------------------------------------------------------------------------
// interval field
// ---------------------------------------------------------------------------

ui_interval_sync :: proc() {
	digits: [8]u8
	ms := app.interval_ms
	n := 0
	if ms <= 0 {
		ui_interval_buf[0] = '0'
		ui_interval_len = 1
		return
	}
	for ms > 0 && n < 5 {
		digits[n] = u8('0' + ms % 10)
		ms /= 10
		n += 1
	}
	for i in 0 ..< n {
		ui_interval_buf[i] = digits[n - 1 - i]
	}
	ui_interval_len = n
}

ui_interval_commit :: proc() {
	v := 0
	for i in 0 ..< ui_interval_len {
		v = v * 10 + int(ui_interval_buf[i] - '0')
	}
	sampler_set_interval(v)
	ui_interval_sync()
}

ui_interval_text :: proc() -> string {
	return string(ui_interval_buf[:ui_interval_len])
}

// ---------------------------------------------------------------------------
// scrollbar
// ---------------------------------------------------------------------------

ui_header_top :: proc() -> f32 {
	top := TOOLBAR_H
	if ui_banner_visible {
		top += BANNER_H
	}
	return top
}

ui_content_top :: proc() -> f32 {
	return ui_header_top() + HEADER_H
}

ui_view :: proc(h: f32) -> (top: f32, view: f32) {
	top = ui_content_top()
	view = h - top
	return
}

ui_thumb :: proc(w: f32, h: f32, content: f32) -> (thumb: rl.Rectangle, ok: bool) {
	top, view := ui_view(h)
	if content <= view || view <= 0 {
		return {}, false
	}
	thumb_h := max(f32(30), view * view / content)
	max_scroll := content - view
	t: f32 = 0
	if max_scroll > 0 {
		t = ui_scroll / max_scroll
	}
	thumb = rl.Rectangle {
		w - SCROLLBAR_W + 2,
		top + (view - thumb_h) * t,
		SCROLLBAR_W - 4,
		thumb_h,
	}
	return thumb, true
}

ui_draw_scrollbar :: proc(w: f32, h: f32, content: f32) {
	top, view := ui_view(h)
	rl.DrawRectangleRec(rl.Rectangle{w - SCROLLBAR_W, top, SCROLLBAR_W, view}, COL_PANEL)
	thumb, ok := ui_thumb(w, h, content)
	if !ok {
		return
	}
	col := COL_BTN
	if ui_drag_scroll {
		col = COL_ACCENT
	}
	rl.DrawRectangleRec(thumb, col)
}

// ---------------------------------------------------------------------------
// drawing
// ---------------------------------------------------------------------------

ui_draw_toolbar :: proc(w: f32) {
	rl.DrawRectangleRec(rl.Rectangle{0, 0, w, TOOLBAR_H}, COL_PANEL)
	rl.DrawRectangleRec(rl.Rectangle{0, TOOLBAR_H - 1, w, 1}, COL_BORDER)

	reset := ui_reset_rect()
	rl.DrawRectangleRec(reset, COL_BTN)
	label := "Reset Min/Max"
	ui_text(
		label,
		reset.x + (reset.width - ui_text_width(label, FONT_SIZE)) / 2,
		10,
		FONT_SIZE,
		COL_TEXT,
	)

	copy := ui_copy_rect(w)
	border := COL_BORDER
	text_col := COL_TEXT
	if ui_copy_flash > 0 {
		border = COL_ACCENT
		text_col = COL_ACCENT
	}
	rl.DrawRectangleRec(copy, COL_BTN)
	rl.DrawRectangleLinesEx(copy, 1, border)
	copy_label := "Copy"
	if ui_copy_flash > 0 {
		copy_label = "Copied"
	}
	ui_text(
		copy_label,
		copy.x + (copy.width - ui_text_width(copy_label, FONT_SIZE)) / 2,
		10,
		FONT_SIZE,
		text_col,
	)

	ui_text("Interval", 156, 10, FONT_SIZE, COL_DIM)
	field := ui_interval_field_rect()
	rl.DrawRectangleRec(field, COL_FIELD)
	border = COL_BORDER
	if ui_interval_focus {
		border = COL_ACCENT
	}
	rl.DrawRectangleLinesEx(field, 1, border)
	ui_text(ui_interval_text(), field.x + 8, 10, FONT_SIZE, COL_TEXT)
	ui_text("ms", field.x + field.width + 6, 10, FONT_SIZE, COL_DIM)

}

ui_draw_banner :: proc(w: f32, st: Perms_State) {
	rl.DrawRectangleRec(rl.Rectangle{0, TOOLBAR_H, w, BANNER_H}, COL_PANEL)
	rl.DrawRectangleRec(rl.Rectangle{0, TOOLBAR_H + BANNER_H - 1, w, 1}, COL_BORDER)

	msg := "Power and memory detail need one-time setup"
	btn_label := "Set up"
	btn_live := true
	#partial switch st {
	case .Running:
		msg = "Waiting for authentication..."
		btn_label = "Waiting"
		btn_live = false
	case .Failed:
		msg = "Setup failed - run scripts/install-permissions.sh manually"
		btn_label = "Retry"
	case .Done:
		msg = "Setup complete"
		btn_label = "Done"
		btn_live = false
	}

	ui_text(msg, 12, TOOLBAR_H + 5, FONT_SIZE, COL_TEXT)
	btn := rl.Rectangle{w - SCROLLBAR_W - 132, TOOLBAR_H + 3, 124, 20}

	fill := COL_BTN
	col := COL_DIM
	border := COL_BORDER
	if btn_live {
		// Slow red breathing so the call to action is hard to miss but not jarring.
		pulse := f32(0.5 + 0.5 * math.sin(f64(rl.GetTime()) * 6.28318 * 0.8))
		fill = ui_lerp_color(COL_BTN, COL_RED_DIM, pulse)
		col = ui_lerp_color(COL_DIM, COL_RED, pulse)
		border = ui_lerp_color(COL_BORDER, COL_RED, pulse)
	}
	rl.DrawRectangleRec(btn, fill)
	rl.DrawRectangleLinesEx(btn, 1, border)
	ui_text(btn_label, btn.x + (btn.width - ui_text_width(btn_label, FONT_SIZE)) / 2, TOOLBAR_H + 6, FONT_SIZE, col)
}

ui_draw_header :: proc(w: f32) {
	y := ui_header_top()
	cw := ui_content_w(w)
	rl.DrawRectangleRec(rl.Rectangle{0, y, cw, HEADER_H}, COL_PANEL)
	rl.DrawRectangleRec(rl.Rectangle{0, y + HEADER_H - 1, cw, 1}, COL_BORDER)

	x := ui_col_x()
	ty := y + 4
	ui_text("Sensor", x[COL_SENSOR] + 2, ty, FONT_SIZE, COL_DIM)
	ui_text_right("Current", ui_col_right(x, COL_CUR), ty, FONT_SIZE, COL_DIM)
	ui_text_right("Minimum", ui_col_right(x, COL_MIN_C), ty, FONT_SIZE, COL_DIM)
	ui_text_right("Maximum", ui_col_right(x, COL_MAX_C), ty, FONT_SIZE, COL_DIM)
	ui_text_right("Average", ui_col_right(x, COL_AVG), ty, FONT_SIZE, COL_DIM)
	ui_text("Unit", x[COL_UNIT] + 2, ty, FONT_SIZE, COL_DIM)

	// Faint separators so the draggable column lines are discoverable.
	for i in 1 ..< COL_COUNT {
		rl.DrawRectangleRec(rl.Rectangle{x[i], y + 2, 1, HEADER_H - 4}, COL_BORDER)
	}
}

ui_draw_section :: proc(si: int, y: f32, w: f32) {
	rl.DrawRectangleRec(rl.Rectangle{0, y, w, ROW_H}, COL_PANEL)
	marker := "[+]"
	if app.sections[si].expanded {
		marker = "[-]"
	}
	ui_text(marker, INDENT_ROOT, y + 3, FONT_SIZE, COL_ACCENT)
	ui_text(app.sections[si].label, INDENT_ROOT + 30, y + 3, FONT_SIZE, COL_ACCENT)
}

ui_draw_group :: proc(gi: int, y: f32) {
	g := &app.groups[gi]
	marker := "[+]"
	if g.expanded {
		marker = "[-]"
	}
	ui_text(marker, INDENT_GROUP, y + 3, FONT_SIZE, COL_DIM)
	ui_text(label_str(g.label[:], g.label_len), INDENT_GROUP + 30, y + 3, FONT_SIZE, COL_TEXT)
}

ui_draw_row :: proc(m: ^Sensor_Metric, y: f32, w: f32, alt: bool) {
	if alt {
		rl.DrawRectangleRec(rl.Rectangle{0, y, w, ROW_H}, COL_ROW_ALT)
	}
	x := ui_col_x()
	lab := label_str(m.label[:], m.label_len)
	ui_text(lab, x[COL_SENSOR] + 2, y + 3, FONT_SIZE, COL_TEXT)

	if m.src != NO_SOURCE && app.sources[m.src].root {
		ui_text("[Root Required]", x[COL_CUR] + 2, y + 3, FONT_SIZE, COL_DIM)
		return
	}
	if !m.seen {
		ui_text_right("--", ui_col_right(x, COL_CUR), y + 3, FONT_SIZE, COL_DIM)
		return
	}

	d := unit_decimals(m.unit)
	b1, b2, b3, b4: [24]u8
	cur := ui_num_str(b1[:], m.cur, d)
	mn := ui_num_str(b2[:], m.min, d)
	mx := ui_num_str(b3[:], m.max, d)
	av := ui_num_str(b4[:], metric_avg(m), d)
	ui_draw_value_cell(cur, ui_col_right(x, COL_CUR), y, m, m.cur, ui_row_color(m))
	ui_draw_value_cell(mn, ui_col_right(x, COL_MIN_C), y, m, m.min, COL_DIM)
	ui_draw_value_cell(mx, ui_col_right(x, COL_MAX_C), y, m, m.max, COL_DIM)
	ui_draw_value_cell(av, ui_col_right(x, COL_AVG), y, m, metric_avg(m), COL_DIM)
	ui_text(unit_str(m.unit), x[COL_UNIT] + 2, y + 3, FONT_SIZE, COL_DIM)
}

ui_draw_content :: proc(w: f32, h: f32) {
	cw := ui_content_w(w)
	top, _ := ui_view(h)
	bottom := h
	y := top - ui_scroll
	mouse := rl.GetMousePosition()
	clicked := rl.IsMouseButtonPressed(.LEFT) && !ui_block_rows

	for si in 0 ..< app.section_count {
		if !ui_section_has_rows(si) {
			continue
		}
		visible := y > top - ROW_H && y < bottom
		if clicked && visible && mouse.x < cw && rl.CheckCollisionPointRec(mouse, rl.Rectangle{0, y, cw, ROW_H}) {
			app.sections[si].expanded = !app.sections[si].expanded
			clicked = false
		}
		if visible {
			ui_draw_section(si, y, cw)
		}
		y += ROW_H
		if !app.sections[si].expanded {
			continue
		}

		gcount := ui_group_count(si)
		for g in 0 ..< app.group_count {
			if int(app.groups[g].section) != si {
				continue
			}
			if ui_rows_in_group(g) == 0 {
				continue
			}
			if gcount > 1 {
				gvisible := y > top - ROW_H && y < bottom
				if clicked && gvisible && mouse.x < cw && rl.CheckCollisionPointRec(mouse, rl.Rectangle{0, y, cw, ROW_H}) {
					app.groups[g].expanded = !app.groups[g].expanded
					clicked = false
				}
				if gvisible {
					ui_draw_group(g, y)
				}
				y += ROW_H
				if !app.groups[g].expanded {
					continue
				}
			}
			alt := false
			for i in 0 ..< ui_n {
				if int(ui_metrics[i].group) != g {
					continue
				}
				if y > top - ROW_H && y < bottom {
					ui_draw_row(&ui_metrics[i], y, cw, alt)
				}
				alt = !alt
				y += ROW_H
			}
		}
	}
}

// ---------------------------------------------------------------------------
// input
// ---------------------------------------------------------------------------

ui_handle_columns :: proc() -> bool {
	x := ui_col_x()
	mouse := rl.GetMousePosition()
	htop := ui_header_top()
	in_header := mouse.y >= htop && mouse.y <= htop + HEADER_H

	near := -1
	if in_header {
		for i in 1 ..< COL_COUNT {
			if abs(mouse.x - x[i]) <= 7 {
				near = i
			}
		}
	}

	// Excel-style affordance: resize cursor over a boundary, arrow elsewhere.
	if near > 0 || ui_drag_col >= 0 {
		ui_hover_boundary = near
		if ui_hover_boundary <= 0 {
			ui_hover_boundary = ui_drag_col + 1
		}
	} else {
		ui_hover_boundary = -1
	}
	if near > 0 || ui_drag_col >= 0 {
		rl.SetMouseCursor(.RESIZE_EW)
	} else {
		rl.SetMouseCursor(.DEFAULT)
	}

	if rl.IsMouseButtonPressed(.LEFT) && near > 0 {
		now := rl.GetTime()
		col := near - 1
		if ui_last_click_col == col && now - ui_last_click_t < 0.45 {
			ui_auto_size(col)
			ui_last_click_col = -1
			return true
		}
		ui_last_click_t = now
		ui_last_click_col = col
		ui_drag_col = col
		return true
	}

	if ui_drag_col >= 0 {
		if rl.IsMouseButtonDown(.LEFT) {
			cw := mouse.x - x[ui_drag_col]
			if cw < COL_MIN {
				cw = COL_MIN
			}
			ui_col_w[ui_drag_col] = cw
			return true
		}
		ui_drag_col = -1
	}
	return near > 0
}

ui_handle_scrollbar :: proc(w: f32, h: f32, content: f32) -> bool {
	top, view := ui_view(h)
	thumb, ok := ui_thumb(w, h, content)
	if !ok {
		ui_drag_scroll = false
		return false
	}
	mouse := rl.GetMousePosition()
	max_scroll := content - view

	in_strip := mouse.x >= w - SCROLLBAR_W && mouse.y >= top
	if rl.IsMouseButtonPressed(.LEFT) && in_strip {
		ui_drag_scroll = true
	}
	if ui_drag_scroll {
		if !rl.IsMouseButtonDown(.LEFT) {
			ui_drag_scroll = false
		} else {
			span := view - thumb.height
			if span > 0 {
				t := (mouse.y - top - thumb.height / 2) / span
				if t < 0 {
					t = 0
				}
				if t > 1 {
					t = 1
				}
				ui_scroll = t * max_scroll
			}
			return true
		}
	}
	return in_strip
}

ui_handle_input :: proc(w: f32, h: f32, content: f32) -> bool {
	ui_block_rows = false
	mouse := rl.GetMousePosition()

	if ui_handle_columns() {
		ui_block_rows = true
	}
	if ui_handle_scrollbar(w, h, content) {
		ui_block_rows = true
	}

	if ui_banner_visible && rl.IsMouseButtonPressed(.LEFT) {
		btn := rl.Rectangle{w - SCROLLBAR_W - 132, TOOLBAR_H + 3, 124, 20}
		if rl.CheckCollisionPointRec(mouse, btn) {
			perms_start_setup()
			ui_block_rows = true
		}
	}

	if rl.IsMouseButtonPressed(.LEFT) && !ui_block_rows {
		reset := ui_reset_rect()
		copy := ui_copy_rect(w)
		field := ui_interval_field_rect()
		if rl.CheckCollisionPointRec(mouse, copy) {
			ui_copy_snapshot()
			ui_copy_flash = 15
			ui_interval_focus = false
		} else if rl.CheckCollisionPointRec(mouse, reset) {
			sampler_reset()
			ui_interval_focus = false
		} else if rl.CheckCollisionPointRec(mouse, field) {
			ui_interval_focus = true
		} else {
			ui_interval_focus = false
		}
	}

	// Text-entry cursor over the interval field, unless a column line is active.
	if ui_hover_boundary <= 0 && !ui_block_rows {
		field := ui_interval_field_rect()
		if rl.CheckCollisionPointRec(mouse, field) {
			rl.SetMouseCursor(.IBEAM)
		}
	}

	top, view := ui_view(h)
	if mouse.y > top && mouse.x < w - SCROLLBAR_W {
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			ui_scroll -= wheel * 48
		}
	}

	max_scroll := content - view
	if max_scroll < 0 {
		max_scroll = 0
	}
	if ui_scroll > max_scroll {
		ui_scroll = max_scroll
	}
	if ui_scroll < 0 {
		ui_scroll = 0
	}

	if ui_interval_focus {
		for {
			r := rl.GetCharPressed()
			if r == 0 {
				break
			}
			if r >= '0' && r <= '9' && ui_interval_len < 5 {
				ui_interval_buf[ui_interval_len] = u8(r)
				ui_interval_len += 1
			}
		}
		if rl.IsKeyPressed(.BACKSPACE) && ui_interval_len > 0 {
			ui_interval_len -= 1
		}
		if rl.IsKeyPressed(.ENTER) {
			ui_interval_commit()
			ui_interval_focus = false
		}
		if rl.IsKeyPressed(.ESCAPE) {
			ui_interval_sync()
			ui_interval_focus = false
		}
		return ui_block_rows
	}

	if rl.IsKeyPressed(.R) {
		sampler_reset()
	}
	return ui_block_rows
}

ui_draw_frame :: proc() {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())

	// Growing the window widens the sensor column so the table keeps filling it.
	if ui_last_w > 0 && w != ui_last_w {
		ui_col_w[COL_SENSOR] = max(COL_MIN, ui_col_w[COL_SENSOR] + (w - ui_last_w))
	}
	ui_last_w = w

	if perms_take_labels_dirty() {
		discover_build_labels(&app)
	}
	ps := perms_state_get()
	ui_banner_visible = perms_needed(&app) || ps == .Running || ps == .Failed

	ui_n = sampler_get(ui_metrics[:])
	if ui_frame % 30 == 0 {
		net_refresh_wifi(&app)
	}
	ui_frame += 1
	if ui_copy_flash > 0 {
		ui_copy_flash -= 1
	}
	content := ui_content_height()
	ui_handle_input(w, h, content)

	rl.BeginDrawing()
	rl.ClearBackground(COL_BG)
	ui_draw_toolbar(w)
	if ui_banner_visible {
		ui_draw_banner(w, ps)
	}
	ui_draw_header(w)

	top, _ := ui_view(h)
	rl.BeginScissorMode(0, c.int(top), c.int(ui_content_w(w)), c.int(h - top))
	ui_draw_content(w, h)
	rl.EndScissorMode()

	ui_draw_scrollbar(w, h, content)

	// Highlight the column boundary under the cursor / being dragged.
	if ui_hover_boundary > 0 && ui_hover_boundary < COL_COUNT {
		bx := ui_col_x()[ui_hover_boundary]
		rl.DrawRectangleRec(rl.Rectangle{bx, TOOLBAR_H, 1, h - TOOLBAR_H}, COL_ACCENT)
	}
	rl.EndDrawing()
}

// ---------------------------------------------------------------------------
// entry point
// ---------------------------------------------------------------------------

// Hands the embedded PNGs to the window manager. GLFW copies the pixels, so the
// raylib images can be unloaded immediately afterwards. Native Wayland ignores
// runtime window icons (it resolves them from a .desktop file), so this takes
// effect under X11/XWayland only.
ui_set_window_icon :: proc() {
	icons := [5]rl.Image {
		rl.LoadImageFromMemory(".png", raw_data(ICON_256), c.int(len(ICON_256))),
		rl.LoadImageFromMemory(".png", raw_data(ICON_64), c.int(len(ICON_64))),
		rl.LoadImageFromMemory(".png", raw_data(ICON_48), c.int(len(ICON_48))),
		rl.LoadImageFromMemory(".png", raw_data(ICON_32), c.int(len(ICON_32))),
		rl.LoadImageFromMemory(".png", raw_data(ICON_16), c.int(len(ICON_16))),
	}
	valid: [5]rl.Image
	n := 0
	for i in 0 ..< len(icons) {
		if rl.IsImageReady(icons[i]) {
			valid[n] = icons[i]
			n += 1
		}
	}
	if n > 0 {
		rl.SetWindowIcons(&valid[0], c.int(n))
	}
	for i in 0 ..< len(icons) {
		if rl.IsImageReady(icons[i]) {
			rl.UnloadImage(icons[i])
		}
	}
}

ui_title_buf: [128]u8

ui_title :: proc() -> cstring {
	model := label_str(app.topo.model[:], app.topo.model_len)
	s := fmt.bprintf(ui_title_buf[:], "vibehw64 — %s", model)
	n := len(s)
	ui_title_buf[n] = 0
	return cstring(raw_data(ui_title_buf[:]))
}

run_ui :: proc() -> bool {
	// GLFW on Wayland cannot set window position, and raylib centres the window
	// on init, which produces harmless warnings. Keep logs at ERROR.
	rl.SetTraceLogLevel(.ERROR)
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_HIGHDPI})
	rl.InitWindow(WINDOW_W, WINDOW_H, ui_title())
	if !rl.IsWindowReady() {
		fmt.eprintln("vibehw64: no display available — DISPLAY and WAYLAND_DISPLAY are both unusable")
		fmt.eprintln("        run `vibehw64 --probe` for headless sensor output")
		return false
	}
	rl.SetWindowMinSize(640, 480)
	ui_set_window_icon()
	rl.SetTargetFPS(10)

	ui_font = rl.LoadFontFromMemory(
		".ttf",
		raw_data(FONT_BYTES),
		c.int(len(FONT_BYTES)),
		16,
		nil,
		0,
	)
	ui_interval_sync()

	sampler_start(app.interval_ms)
	defer sampler_stop()

	for !rl.WindowShouldClose() {
		if rl.IsWindowMinimized() {
			// Keep the frame clock and event pump alive without doing any work.
			rl.BeginDrawing()
			rl.ClearBackground(COL_BG)
			rl.EndDrawing()
			continue
		}
		ui_draw_frame()
	}

	rl.UnloadFont(ui_font)
	rl.CloseWindow()
	return true
}
