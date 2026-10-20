package klavrasa

// Heads-up overlay and mouse interaction.
//
// Top-left: file name with key / time signature / stats, then the track panel
// (click a row to mute, right-click to solo). Top-right: live BPM, speed, play
// state, sound and volume. Bottom: a seekable progress bar with clock, a short
// keycap legend, and transient toasts. `H` opens a full shortcut sheet.
//
// Everything is drawn on translucent rounded panels with soft text shadows so
// the readout stays legible over the busy falling-note field and the bright
// keyboard. An optional TTF (assets/font.ttf) is used when present, otherwise
// we fall back to Raylib's built-in font.

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

// --- palette ----------------------------------------------------------------

PANEL_FILL   :: rl.Color{ 24,  26,  36, 215}
PANEL_STROKE :: rl.Color{ 70,  76,  98, 170}
ROW_HOVER    :: rl.Color{255, 255, 255,  18}
TEXT_PRIMARY :: rl.Color{236, 239, 248, 255}
TEXT_MUTED   :: rl.Color{160, 166, 186, 255}
TEXT_DIM     :: rl.Color{110, 116, 138, 255}
TEXT_SHADOW  :: rl.Color{  0,   0,   0, 170}
ACCENT_GOLD  :: rl.Color{255, 205, 110, 255}
ACCENT_BLUE  :: rl.Color{120, 205, 255, 255}
ACCENT_WARN  :: rl.Color{255, 168,  92, 255}
ACCENT_MUTE  :: rl.Color{255, 110, 110, 255}
KEYCAP_FILL  :: rl.Color{ 46,  50,  64, 245}
KEYCAP_EDGE  :: rl.Color{ 96, 102, 124, 255}

PAD :: f32(16)

// --- state ------------------------------------------------------------------

TOAST_SECONDS :: f32(2.4)
TOAST_FADE    :: f32(0.5)
MAX_TRACK_ROWS :: 12

@(private = "file") ui_font:       rl.Font
@(private = "file") ui_font_ready: bool

@(private = "file") toast_buf:  [160]u8
@(private = "file") toast_len:  int
@(private = "file") toast_left: f32

@(private = "file") dragging_bar: bool
@(private = "file") show_help:    bool

// Load UI assets. Safe to call once after InitWindow; a missing font is fine.
ui_load_assets :: proc() {
	if rl.FileExists("assets/font.ttf") {
		// Printable ASCII plus the handful of symbols the overlay uses; Raylib
		// only rasterises the codepoints it is given.
		cps := make([dynamic]rune, context.temp_allocator)
		for c in 32 ..= 126 do append(&cps, rune(c))
		for c in "·…−×" do append(&cps, c)
		ui_font = rl.LoadFontEx("assets/font.ttf", 64, raw_data(cps), i32(len(cps)))
		if ui_font.texture.id != 0 {
			rl.SetTextureFilter(ui_font.texture, .BILINEAR)
			ui_font_ready = true
		}
	}
}

ui_unload_assets :: proc() {
	if ui_font_ready do rl.UnloadFont(ui_font)
	ui_font_ready = false
}

// Show a short message near the bottom of the roll. The text is copied, so
// temp-allocated strings (fmt.ctprintf) are fine.
ui_toast :: proc(msg: cstring) {
	s := string(msg)
	n := min(len(s), len(toast_buf) - 1)
	copy(toast_buf[:n], s[:n])
	toast_buf[n] = 0
	toast_len = n
	toast_left = TOAST_SECONDS
}

ui_update :: proc(dt: f32) {
	if toast_left > 0 do toast_left = max(toast_left - dt, 0)
	if rl.IsKeyPressed(.H) do show_help = !show_help
	if show_help && rl.IsKeyPressed(.ESCAPE) do show_help = false
}

// --- text -------------------------------------------------------------------

@(private = "file")
font_spacing :: proc(size: f32) -> f32 {
	return ui_font_ready ? size / 18 : size / 10
}

text_size :: proc(s: cstring, size: f32) -> rl.Vector2 {
	font := ui_font_ready ? ui_font : rl.GetFontDefault()
	return rl.MeasureTextEx(font, s, size, font_spacing(size))
}

// Text with a soft drop shadow for legibility over any background.
draw_text :: proc(s: cstring, x, y, size: f32, col: rl.Color) {
	font := ui_font_ready ? ui_font : rl.GetFontDefault()
	sp := font_spacing(size)
	rl.DrawTextEx(font, s, {x + 1.5, y + 1.5}, size, sp, TEXT_SHADOW)
	rl.DrawTextEx(font, s, {x, y}, size, sp, col)
}

// Truncate `s` with an ellipsis so it fits within `max_w` at `size`.
@(private = "file")
fit_text :: proc(s: string, size, max_w: f32) -> cstring {
	full := strings.clone_to_cstring(s, context.temp_allocator)
	if text_size(full, size).x <= max_w do return full
	n := len(s)
	for n > 0 {
		n -= 1
		// back up to a UTF-8 boundary
		for n > 0 && s[n] & 0xC0 == 0x80 do n -= 1
		c := fmt.ctprintf("%s…", s[:n])
		if text_size(c, size).x <= max_w do return c
	}
	return "…"
}

// --- primitives -------------------------------------------------------------

@(private = "file")
draw_panel :: proc(x, y, w, h: f32) {
	r := min(14 / min(w, h), 1)
	rl.DrawRectangleRounded({x, y, w, h}, r, 8, PANEL_FILL)
	rl.DrawRectangleRoundedLinesEx({x, y, w, h}, r, 8, 1, PANEL_STROKE)
}

// Draw one keyboard key-cap with `label` centred; returns its width.
@(private = "file")
draw_keycap :: proc(x, y, h: f32, label: cstring) -> f32 {
	size := h * 0.52
	tw := text_size(label, size).x
	pad := h * 0.40
	w := tw + pad * 2
	rl.DrawRectangleRounded({x, y, w, h}, 0.32, 6, KEYCAP_FILL)
	rl.DrawRectangleRoundedLinesEx({x, y, w, h}, 0.32, 6, 1.5, KEYCAP_EDGE)
	draw_text(label, x + pad, y + (h - size) / 2 - size * 0.08, size, TEXT_PRIMARY)
	return w
}

// An eighth-note glyph drawn with primitives (the bundled font has none).
// `size` is the overall height; returns the width used.
draw_note_icon :: proc(x, y, size: f32, col: rl.Color) -> f32 {
	head_rx, head_ry := size * 0.22, size * 0.16
	stem_w := max(size * 0.07, 1.5)
	hx := x + head_rx
	hy := y + size - head_ry
	// shadow
	sh := rl.Color{0, 0, 0, 120}
	rl.DrawEllipse(i32(hx + 1.5), i32(hy + 1.5), head_rx, head_ry, sh)
	rl.DrawRectangleV({hx + head_rx - stem_w + 1.5, y + size * 0.08 + 1.5}, {stem_w, size - head_ry - size * 0.08}, sh)
	// head, stem, flag
	rl.DrawEllipse(i32(hx), i32(hy), head_rx, head_ry, col)
	sx := hx + head_rx - stem_w
	rl.DrawRectangleV({sx, y + size * 0.08}, {stem_w, size - head_ry - size * 0.08}, col)
	rl.DrawLineBezier({sx + stem_w / 2, y + size * 0.08}, {sx + size * 0.34, y + size * 0.42}, stem_w * 1.1, col)
	return size * 0.6
}

// A small rounded badge (used for M / S markers); returns its width.
@(private = "file")
draw_badge :: proc(x, y, h: f32, label: cstring, col: rl.Color) -> f32 {
	size := h * 0.62
	tw := text_size(label, size).x
	w := tw + h * 0.55
	rl.DrawRectangleRounded({x, y, w, h}, 0.4, 6, {col.r, col.g, col.b, 46})
	rl.DrawRectangleRoundedLinesEx({x, y, w, h}, 0.4, 6, 1, {col.r, col.g, col.b, 170})
	draw_text(label, x + (w - tw) / 2, y + (h - size) / 2 - size * 0.06, size, col)
	return w
}

// --- layout -----------------------------------------------------------------

@(private = "file")
title_panel_height :: proc() -> f32 { return 68 }

@(private = "file")
track_panel_origin :: proc() -> (x, y: f32) {
	return PAD, PAD + title_panel_height() + 10
}

TRACK_ROW_H   :: f32(27)
TRACK_PANEL_W :: f32(250)

@(private = "file")
progress_rect :: proc(screen_w, screen_h: f32) -> rl.Rectangle {
	roll_bottom := screen_h - KEYBOARD_HEIGHT
	return {PAD, roll_bottom - 18, screen_w - PAD * 2, 6}
}

// Rows in the track panel, in order: only tracks that contain notes.
@(private = "file")
visible_tracks :: proc(p: ^Player) -> (rows: [MAX_TRACK_ROWS]int, count, total: int) {
	for t, ti in p.song.tracks {
		if t.note_count == 0 do continue
		if count < MAX_TRACK_ROWS {
			rows[count] = ti
			count += 1
		}
		total += 1
	}
	return
}

// --- mouse ------------------------------------------------------------------

ui_handle_mouse :: proc(p: ^Player, a: ^Audio, screen_w, screen_h: f32) {
	if !p.loaded do return
	m := rl.GetMousePosition()
	cursor := rl.MouseCursor.DEFAULT
	defer rl.SetMouseCursor(cursor)

	if show_help {
		if rl.IsMouseButtonPressed(.LEFT) do show_help = false
		return
	}

	// Progress bar: click or drag to seek. A generous hit area around the bar.
	bar := progress_rect(screen_w, screen_h)
	hit := rl.Rectangle{bar.x, bar.y - 12, bar.width, bar.height + 24}
	if rl.CheckCollisionPointRec(m, hit) || dragging_bar {
		cursor = .POINTING_HAND
		if rl.IsMouseButtonPressed(.LEFT) do dragging_bar = true
	}
	if dragging_bar {
		if rl.IsMouseButtonDown(.LEFT) {
			frac := clamp((m.x - bar.x) / bar.width, 0, 1)
			seek(p, a, f64(frac) * p.song.duration_sec)
		} else {
			dragging_bar = false
		}
		return
	}

	// Track panel rows.
	rows, count, _ := visible_tracks(p)
	px, py := track_panel_origin()
	for i in 0 ..< count {
		r := rl.Rectangle{px, py + 8 + f32(i) * TRACK_ROW_H, TRACK_PANEL_W, TRACK_ROW_H}
		if !rl.CheckCollisionPointRec(m, r) do continue
		cursor = .POINTING_HAND
		if rl.IsMouseButtonPressed(.LEFT) {
			if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
				toggle_solo(p, a, rows[i])
			} else {
				toggle_mute(p, a, rows[i])
			}
		}
		if rl.IsMouseButtonPressed(.RIGHT) do toggle_solo(p, a, rows[i])
	}
}

// --- overlay ----------------------------------------------------------------

draw_overlay :: proc(p: ^Player, a: ^Audio, screen_w, screen_h: f32) {
	if !p.loaded {
		draw_empty_state(screen_w, screen_h)
		draw_toast(screen_w, screen_h)
		if show_help do draw_help(screen_w, screen_h)
		return
	}

	draw_title_panel(p, screen_w)
	draw_track_panel(p)
	draw_status_panel(p, a, screen_w)
	draw_transport(p, screen_w, screen_h)
	draw_toast(screen_w, screen_h)
	if show_help do draw_help(screen_w, screen_h)
}

// Top-left: file name, then key / time signature / track & note counts.
@(private = "file")
draw_title_panel :: proc(p: ^Player, screen_w: f32) {
	max_w := screen_w * 0.42
	title := fit_text(p.display_name, 25, max_w - 30)

	sb := strings.builder_make(context.temp_allocator)
	if p.song.key_name != "" do fmt.sbprintf(&sb, "%s  ·  ", p.song.key_name)
	if b, ok := song_beat_at(p.song, max(p.time, 0)); ok do fmt.sbprintf(&sb, "%d/%d  ·  ", b.num, b.den)
	_, _, ntracks := visible_tracks(p)
	fmt.sbprintf(&sb, "%d track%s  ·  %d notes", ntracks, ntracks == 1 ? "" : "s", len(p.song.notes))
	sub := fit_text(strings.to_string(sb), 15, max_w)

	ts := text_size(title, 25)
	ss := text_size(sub, 15)
	w := max(ts.x + 30, ss.x) + 28
	draw_panel(PAD, PAD, w, title_panel_height())
	draw_note_icon(PAD + 14, PAD + 11, 22, ACCENT_BLUE)
	draw_text(title, PAD + 44, PAD + 8, 25, TEXT_PRIMARY)
	draw_text(sub, PAD + 14, PAD + 42, 15, TEXT_MUTED)
}

// Left column: one row per track with a colour swatch, name, note count and
// mute / solo badges.
@(private = "file")
draw_track_panel :: proc(p: ^Player) {
	rows, count, total := visible_tracks(p)
	if count == 0 do return
	px, py := track_panel_origin()
	m := rl.GetMousePosition()

	extra := total > count ? f32(22) : 0
	draw_panel(px, py, TRACK_PANEL_W, 16 + f32(count) * TRACK_ROW_H + extra)

	for i in 0 ..< count {
		t := rows[i]
		info := p.song.tracks[t]
		ry := py + 8 + f32(i) * TRACK_ROW_H
		row := rl.Rectangle{px, ry, TRACK_PANEL_W, TRACK_ROW_H}
		audible := track_audible(p, t)

		if rl.CheckCollisionPointRec(m, row) && !show_help {
			rl.DrawRectangleRounded({px + 4, ry, TRACK_PANEL_W - 8, TRACK_ROW_H}, 0.35, 6, ROW_HOVER)
		}

		// Swatch
		col := TRACK_PALETTE[t % len(TRACK_PALETTE)]
		cx, cy := px + 20, ry + TRACK_ROW_H / 2
		if audible {
			rl.DrawCircleV({cx, cy}, 6.5, {col.r, col.g, col.b, 70})
			rl.DrawCircleV({cx, cy}, 4.5, col)
		} else {
			rl.DrawRing({cx, cy}, 3.5, 5, 0, 360, 24, {col.r, col.g, col.b, 140})
		}

		// Badges on the right, measured first so the name can fill what's left.
		badge_h := f32(17)
		bx := px + TRACK_PANEL_W - 12
		count_s := fmt.ctprintf("%d", info.note_count)
		cw := text_size(count_s, 13).x
		bx -= cw
		draw_text(count_s, bx, cy - 7, 13, audible ? TEXT_DIM : {80, 84, 100, 255})
		if p.solo[t] {
			bx -= 6
			w := text_size("S", badge_h * 0.62).x + badge_h * 0.55
			bx -= w
			draw_badge(bx, cy - badge_h / 2, badge_h, "S", ACCENT_GOLD)
		}
		if p.muted[t] {
			bx -= 6
			w := text_size("M", badge_h * 0.62).x + badge_h * 0.55
			bx -= w
			draw_badge(bx, cy - badge_h / 2, badge_h, "M", ACCENT_MUTE)
		}

		// Name
		name := info.name != "" ? info.name : fmt.tprintf("Track %d", t + 1)
		nx := px + 36
		label := fit_text(name, 16, bx - nx - 10)
		draw_text(label, nx, cy - 9, 16, audible ? TEXT_PRIMARY : TEXT_DIM)
	}

	if total > count {
		more := fmt.ctprintf("+%d more", total - count)
		draw_text(more, px + 36, py + 8 + f32(count) * TRACK_ROW_H + 2, 13, TEXT_DIM)
	}
}

// Top-right: live BPM, then speed / state, then sound / volume.
@(private = "file")
draw_status_panel :: proc(p: ^Player, a: ^Audio, screen_w: f32) {
	bpm := fmt.ctprintf("%.0f BPM", song_bpm_at(p.song, max(p.time, 0)))
	speed := fmt.ctprintf("%.2gx", p.speed)
	state: cstring = p.paused ? "PAUSED" : "PLAYING"
	state_col := p.paused ? ACCENT_WARN : ACCENT_BLUE
	sound := fmt.ctprintf("%s  ·  vol %d%%", WAVEFORM_NAMES[a.wave], int(a.master * 100 + 0.5))

	bs := text_size(bpm, 31)
	sw := text_size(speed, 20).x
	stw := text_size(state, 20).x
	row2 := sw + 12 + stw
	row3 := text_size(sound, 14).x
	panel_w := max(bs.x, row2, row3) + 28
	panel_h := f32(96)
	px := screen_w - panel_w - PAD

	draw_panel(px, PAD, panel_w, panel_h)
	right := px + panel_w - 14
	draw_text(bpm, right - bs.x, PAD + 8, 31, ACCENT_GOLD)
	ry := PAD + 44
	draw_text(speed, right - row2, ry, 20, TEXT_MUTED)
	draw_text(state, right - stw, ry, 20, state_col)
	draw_text(sound, right - row3, PAD + 72, 14, TEXT_DIM)
}

// Bottom of the roll: seekable progress bar, clock, bar counter and legend.
@(private = "file")
draw_transport :: proc(p: ^Player, screen_w, screen_h: f32) {
	bar := progress_rect(screen_w, screen_h)
	m := rl.GetMousePosition()
	hit := rl.Rectangle{bar.x, bar.y - 12, bar.width, bar.height + 24}
	hover := (rl.CheckCollisionPointRec(m, hit) || dragging_bar) && !show_help
	if hover {
		// Fatten the bar slightly under the pointer so it reads as a control.
		bar.y -= 1
		bar.height += 2
	}

	rl.DrawRectangleRounded(bar, 1, 4, {54, 58, 72, 230})
	dur := p.song.duration_sec
	if dur > 0 {
		// Faint bar ticks along the track: every 4th bar, so it stays readable.
		for b in p.song.beats {
			if b.beat != 1 || b.bar % 4 != 1 || b.time <= 0 do continue
			x := bar.x + bar.width * f32(b.time / dur)
			rl.DrawRectangle(i32(x), i32(bar.y), 1, i32(bar.height), {255, 255, 255, 40})
		}

		frac := f32(clamp(p.time / dur, 0, 1))
		fill_w := bar.width * frac
		if fill_w > bar.height {
			rl.DrawRectangleRounded({bar.x, bar.y, fill_w, bar.height}, 1, 4, ACCENT_BLUE)
		}
		head_x := bar.x + fill_w
		head_y := bar.y + bar.height / 2
		rl.DrawCircleV({head_x, head_y}, hover ? 9 : 7, {ACCENT_BLUE.r, ACCENT_BLUE.g, ACCENT_BLUE.b, 70})
		rl.DrawCircleV({head_x, head_y}, hover ? 5 : 4, rl.RAYWHITE)

		// Hover tooltip with the time under the pointer.
		if hover {
			hx := clamp(m.x, bar.x, bar.x + bar.width)
			ht := f64((hx - bar.x) / bar.width) * dur
			tip := fmt.ctprintf("%s", fmt_clock(ht))
			if b, ok := song_beat_at(p.song, ht); ok do tip = fmt.ctprintf("%s  ·  bar %d", fmt_clock(ht), b.bar)
			ts := text_size(tip, 14)
			tw, th := ts.x + 16, ts.y + 8
			tx := clamp(hx - tw / 2, PAD, screen_w - PAD - tw)
			ty := bar.y - th - 14
			rl.DrawRectangleRounded({tx, ty, tw, th}, 0.4, 6, {36, 40, 54, 240})
			draw_text(tip, tx + 8, ty + 4, 14, TEXT_PRIMARY)
			rl.DrawRectangle(i32(hx), i32(bar.y - 4), 1, i32(bar.height + 8), {255, 255, 255, 120})
		}
	}

	// Clock (left) and bar counter + total (right), just above the bar.
	clock_y := bar.y - 26
	shown := max(p.time, 0)
	draw_text(fmt_clock(shown), PAD, clock_y, 20, TEXT_PRIMARY)
	right := fmt_clock(dur)
	if b, ok := song_beat_at(p.song, shown); ok && p.time >= 0 {
		right = fmt.ctprintf("bar %d · %d    %s", b.bar, b.beat, fmt_clock(dur))
	} else if p.time < 0 {
		right = fmt.ctprintf("starting in %d    %s", int(math.ceil(-p.time)), fmt_clock(dur))
	}
	tw := text_size(right, 20).x
	draw_text(right, screen_w - PAD - tw, clock_y, 20, TEXT_MUTED)

	draw_legend(PAD, clock_y - 42)
}

@(private = "file")
fmt_clock :: proc(t: f64) -> cstring {
	s := int(t + 0.5)
	return fmt.ctprintf("%02d:%02d", s / 60, s % 60)
}

// Compact key-cap legend; the full sheet lives behind `H`.
@(private = "file")
draw_legend :: proc(x, y: f32) {
	h :: f32(29)
	gap :: f32(8)
	cx := x

	cap :: proc(cx: ^f32, y, h, gap: f32, key, label: cstring) {
		cx^ += draw_keycap(cx^, y, h, key) + gap
		lw := text_size(label, 17).x
		draw_text(label, cx^, y + (h - 17) / 2 - 1, 17, TEXT_MUTED)
		cx^ += lw + gap * 2.4
	}

	cap(&cx, y, h, gap, "Space", "Pause")
	cap(&cx, y, h, gap, "< >", "Seek")
	cap(&cx, y, h, gap, "1 2 3", "Speed")
	cap(&cx, y, h, gap, "W", "Sound")
	cap(&cx, y, h, gap, "H", "All shortcuts")
}

// Full shortcut sheet, centred over everything.
@(private = "file")
draw_help :: proc(screen_w, screen_h: f32) {
	rl.DrawRectangle(0, 0, i32(screen_w), i32(screen_h), {0, 0, 0, 150})

	Row :: struct { key, what: cstring }
	rows := [?]Row {
		{"Space",        "Pause / resume"},
		{"Left / Right",  "Seek 5 seconds"},
		{"Home / R",     "Restart"},
		{"1 2 3",        "Speed 0.5x / 1x / 2x"},
		{"- +",          "Speed in 0.25x steps"},
		{"W",            "Cycle sound (piano, sine, triangle, square, saw)"},
		{"Up / Down",     "Volume"},
		{"F1-F8",        "Mute track 1-8"},
		{"Shift+F1-F8",  "Solo track 1-8"},
		{"Click track",  "Mute  ·  right-click or Shift+click: solo"},
		{"Click bar",    "Seek (drag to scrub)"},
		{"Drop .mid",    "Load a file"},
		{"H / Esc",      "Close this sheet"},
	}

	row_h :: f32(30)
	key_w := f32(0)
	for r in rows do key_w = max(key_w, text_size(r.key, 15).x + 24)
	w := f32(560)
	h := 62 + f32(len(rows)) * row_h + 12
	x := (screen_w - w) / 2
	y := (screen_h - h) / 2 - 30

	draw_panel(x, y, w, h)
	draw_text("Shortcuts", x + 22, y + 16, 24, TEXT_PRIMARY)
	for r, i in rows {
		ry := y + 58 + f32(i) * row_h
		draw_keycap(x + 22, ry, 24, r.key)
		draw_text(r.what, x + 22 + key_w + 14, ry + 3, 16, TEXT_MUTED)
	}
}

// Transient message, floating above the transport, fading out at the end.
@(private = "file")
draw_toast :: proc(screen_w, screen_h: f32) {
	if toast_left <= 0 || toast_len == 0 do return
	alpha := f32(1)
	if toast_left < TOAST_FADE do alpha = toast_left / TOAST_FADE
	msg := cstring(&toast_buf[0])
	ts := text_size(msg, 18)
	w, h := ts.x + 32, ts.y + 16
	x := (screen_w - w) / 2
	y := screen_h - KEYBOARD_HEIGHT - 120 - (1 - alpha) * 8
	a := u8(alpha * 255)
	rl.DrawRectangleRounded({x, y, w, h}, 0.5, 8, {30, 33, 46, u8(f32(230) * alpha)})
	rl.DrawRectangleRoundedLinesEx({x, y, w, h}, 0.5, 8, 1, {ACCENT_BLUE.r, ACCENT_BLUE.g, ACCENT_BLUE.b, u8(f32(120) * alpha)})
	draw_text(msg, x + 16, y + 8, 18, {TEXT_PRIMARY.r, TEXT_PRIMARY.g, TEXT_PRIMARY.b, a})
}

@(private = "file")
draw_empty_state :: proc(screen_w, screen_h: f32) {
	cx := screen_w / 2
	cy := (screen_h - KEYBOARD_HEIGHT) / 2

	// A drop zone: a soft, rounded well in the middle of the roll.
	w, h := min(screen_w * 0.55, 620), f32(300)
	zone := rl.Rectangle{cx - w / 2, cy - h / 2, w, h}
	rl.DrawRectangleRounded(zone, 0.08, 10, {255, 255, 255, 8})
	rl.DrawRectangleRoundedLinesEx(zone, 0.08, 10, 1.5, {120, 205, 255, 70})

	draw_note_icon(cx - 26, cy - 116, 84, {110, 165, 230, 255})

	msg: cstring = "Drop a .mid file to begin"
	ms := text_size(msg, 32)
	draw_text(msg, cx - ms.x / 2, cy - 4, 32, TEXT_PRIMARY)

	hint: cstring = "…or pass a path on the command line"
	hs := text_size(hint, 18)
	draw_text(hint, cx - hs.x / 2, cy + 40, 18, TEXT_MUTED)

	hint2: cstring = "H  for shortcuts"
	hs2 := text_size(hint2, 15)
	draw_text(hint2, cx - hs2.x / 2, cy + 96, 15, TEXT_DIM)
}
