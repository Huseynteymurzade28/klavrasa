package resonance

// Heads-up overlay: file name, BPM, playback speed / state, a progress bar, a
// clock, and a keycap-style shortcut legend.
//
// Everything is drawn on translucent rounded panels with soft text shadows so
// the readout stays legible over the busy falling-note field and the bright
// keyboard. An optional TTF (assets/font.ttf) is used when present, otherwise
// we fall back to Raylib's built-in font.

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// --- palette ----------------------------------------------------------------

PANEL_FILL   :: rl.Color{ 24,  26,  36, 215}
PANEL_STROKE :: rl.Color{ 70,  76,  98, 170}
TEXT_PRIMARY :: rl.Color{236, 239, 248, 255}
TEXT_MUTED   :: rl.Color{160, 166, 186, 255}
TEXT_SHADOW  :: rl.Color{  0,   0,   0, 170}
ACCENT_GOLD  :: rl.Color{255, 205, 110, 255}
ACCENT_BLUE  :: rl.Color{120, 205, 255, 255}
ACCENT_WARN  :: rl.Color{255, 168,  92, 255}
KEYCAP_FILL  :: rl.Color{ 46,  50,  64, 245}
KEYCAP_EDGE  :: rl.Color{ 96, 102, 124, 255}

// --- font -------------------------------------------------------------------

@(private = "file") ui_font:       rl.Font
@(private = "file") ui_font_ready: bool

// Load UI assets. Safe to call once after InitWindow; a missing font is fine.
ui_load_assets :: proc() {
	if rl.FileExists("assets/font.ttf") {
		ui_font = rl.LoadFontEx("assets/font.ttf", 64, nil, 0)
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

@(private = "file")
font_spacing :: proc(size: f32) -> f32 {
	return ui_font_ready ? size / 18 : size / 10
}

@(private = "file")
text_size :: proc(s: cstring, size: f32) -> rl.Vector2 {
	font := ui_font_ready ? ui_font : rl.GetFontDefault()
	return rl.MeasureTextEx(font, s, size, font_spacing(size))
}

// Text with a soft drop shadow for legibility over any background.
@(private = "file")
draw_text :: proc(s: cstring, x, y, size: f32, col: rl.Color) {
	font := ui_font_ready ? ui_font : rl.GetFontDefault()
	sp := font_spacing(size)
	rl.DrawTextEx(font, s, {x + 1.5, y + 1.5}, size, sp, TEXT_SHADOW)
	rl.DrawTextEx(font, s, {x, y}, size, sp, col)
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

// --- overlay ----------------------------------------------------------------

draw_overlay :: proc(p: Player, screen_w, screen_h: f32) {
	if !p.loaded {
		draw_empty_state(screen_w, screen_h)
		return
	}

	pad :: f32(16)

	// Top-left: file name on a panel, with a small note accent.
	{
		name := strings.clone_to_cstring(p.display_name, context.temp_allocator)
		title := fmt.ctprintf("♪  %s", name)
		ts := text_size(title, 25)
		draw_panel(pad, pad, ts.x + 28, ts.y + 18)
		draw_text(title, pad + 14, pad + 9, 25, TEXT_PRIMARY)
	}

	// Top-right: BPM (gold) above the speed / play-state line.
	{
		bpm := fmt.ctprintf("%.0f BPM", p.song.initial_bpm)
		speed := fmt.ctprintf("%.2gx", p.speed)
		state: cstring = p.paused ? "PAUSED" : "PLAYING"
		state_col := p.paused ? ACCENT_WARN : ACCENT_BLUE

		bs := text_size(bpm, 31)
		sw := text_size(speed, 22).x
		stw := text_size(state, 22).x
		row2 := sw + 12 + stw
		panel_w := max(bs.x, row2) + 28
		px := screen_w - panel_w - pad

		draw_panel(px, pad, panel_w, 70)
		draw_text(bpm, px + panel_w - bs.x - 14, pad + 9, 31, ACCENT_GOLD)
		ry := pad + 42
		draw_text(speed, px + panel_w - row2 - 14, ry, 22, TEXT_MUTED)
		draw_text(state, px + panel_w - stw - 14, ry, 22, state_col)
	}

	// Bottom (in the dark roll area, above the keyboard): legend, clock, bar.
	roll_bottom := screen_h - KEYBOARD_HEIGHT
	bar_h :: f32(6)
	bar_y := roll_bottom - 18

	// Progress bar with a glowing playhead.
	track := rl.Rectangle{pad, bar_y, screen_w - pad * 2, bar_h}
	rl.DrawRectangleRounded(track, 1, 4, {54, 58, 72, 230})
	if p.song.duration_sec > 0 {
		frac := f32(clamp(p.time / p.song.duration_sec, 0, 1))
		fill_w := (screen_w - pad * 2) * frac
		if fill_w > bar_h {
			rl.DrawRectangleRounded({pad, bar_y, fill_w, bar_h}, 1, 4, ACCENT_BLUE)
		}
		head_x := pad + fill_w
		rl.DrawCircleV({head_x, bar_y + bar_h / 2}, 7, {ACCENT_BLUE.r, ACCENT_BLUE.g, ACCENT_BLUE.b, 70})
		rl.DrawCircleV({head_x, bar_y + bar_h / 2}, 4, rl.RAYWHITE)
	}

	// Clock just above the bar: elapsed (left) / total (right).
	clock := fmt.ctprintf("%02d:%02d", int(p.time) / 60, int(p.time) % 60)
	total := fmt.ctprintf("%02d:%02d", int(p.song.duration_sec) / 60, int(p.song.duration_sec) % 60)
	clock_y := bar_y - 26
	draw_text(clock, pad, clock_y, 20, TEXT_PRIMARY)
	tw := text_size(total, 20).x
	draw_text(total, screen_w - pad - tw, clock_y, 20, TEXT_MUTED)

	// Keycap legend row, above the clock — all on the dark roll background.
	draw_legend(pad, clock_y - 42)
}

// A row of key-caps with short descriptions.
@(private = "file")
draw_legend :: proc(x, y: f32) {
	h :: f32(29)
	gap :: f32(8)
	lbl :: f32(17)
	cx := x

	cap :: proc(cx: ^f32, y, h, gap: f32, key, label: cstring) {
		cx^ += draw_keycap(cx^, y, h, key) + gap
		lw := text_size(label, 17).x
		draw_text(label, cx^, y + (h - 17) / 2 - 1, 17, TEXT_MUTED)
		cx^ += lw + gap * 2.4
	}

	cap(&cx, y, h, gap, "Space", "Pause")
	cap(&cx, y, h, gap, "1 2 3", "Speed")
	cap(&cx, y, h, gap, "R", "Restart")
	draw_text("drop a .mid to load", cx, y + (h - 17) / 2 - 1, 17, {120, 126, 146, 255})
}

@(private = "file")
draw_empty_state :: proc(screen_w, screen_h: f32) {
	cx := screen_w / 2
	cy := screen_h / 2

	icon: cstring = "♪"
	is := text_size(icon, 84)
	draw_text(icon, cx - is.x / 2, cy - 128, 84, {110, 165, 230, 255})

	msg: cstring = "Drop a .mid file to begin"
	ms := text_size(msg, 34)
	draw_text(msg, cx - ms.x / 2, cy - 24, 34, TEXT_PRIMARY)

	hint: cstring = "…or pass a path on the command line"
	hs := text_size(hint, 20)
	draw_text(hint, cx - hs.x / 2, cy + 18, 20, TEXT_MUTED)

	draw_legend(cx - 235, cy + 76)
}
