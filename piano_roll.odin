package resonance

// Piano-roll renderer: falling note blocks above an 88-key keyboard.
//
// Time maps to the vertical axis: the current playback instant sits at the top
// edge of the keyboard ("now" line) and notes fall down toward it, lighting up
// the corresponding key as they land. Notes are coloured per track, shaded by
// octave so the layered tracks and registers stay readable.

import rl "vendor:raylib"

NOTE_MIN        :: 21  // A0
NOTE_MAX        :: 108 // C8
NUM_KEYS        :: NOTE_MAX - NOTE_MIN + 1 // 88
WHITE_COUNT     :: 52  // white keys on an 88-key piano
KEYBOARD_HEIGHT :: 140
LOOKAHEAD_SEC   :: 4.0 // seconds of upcoming notes visible at once

// Distinct base hue per track; reused cyclically beyond the palette length.
TRACK_PALETTE := [?]rl.Color {
	{ 88, 160, 255, 255}, // blue
	{255, 122,  90, 255}, // coral
	{120, 220, 140, 255}, // green
	{235, 190,  80, 255}, // amber
	{200, 120, 245, 255}, // violet
	{ 90, 220, 225, 255}, // cyan
	{245, 130, 190, 255}, // pink
	{170, 200,  90, 255}, // olive
}

KEY_HIGHLIGHT :: rl.Color{120, 205, 255, 255}

Key_Geo :: struct {
	x:     f32,
	w:     f32,
	black: bool,
}

@(private = "file")
is_black_key :: proc(midi: int) -> bool {
	switch midi % 12 {
	case 1, 3, 6, 8, 10:
		return true
	}
	return false
}

// Compute x position and width for every key given the screen width.
keyboard_layout :: proc(screen_w: f32) -> (geo: [NUM_KEYS]Key_Geo) {
	white_w := screen_w / f32(WHITE_COUNT)
	wi := 0 // running count of white keys placed so far
	for k in 0 ..< NUM_KEYS {
		midi := NOTE_MIN + k
		if is_black_key(midi) {
			// Black keys straddle the boundary before the next white key.
			geo[k] = {x = f32(wi) * white_w - white_w * 0.3, w = white_w * 0.6, black = true}
		} else {
			geo[k] = {x = f32(wi) * white_w, w = white_w, black = false}
			wi += 1
		}
	}
	return geo
}

// Colour for a note: track hue, lightened/darkened by octave.
note_color :: proc(track: int, key: u8) -> rl.Color {
	base := TRACK_PALETTE[track % len(TRACK_PALETTE)]
	octave := int(key) / 12 // 0..10
	return rl.ColorBrightness(base, f32(octave - 5) * 0.07)
}

// Draw the falling notes. `active_keys[midi]` is set to true for any note that
// is currently sounding, so the keyboard pass can highlight it.
draw_falling_notes :: proc(song: Song, time: f64, screen_w, screen_h: f32, active_keys: ^[128]bool) {
	geo := keyboard_layout(screen_w)
	roll_bottom := screen_h - KEYBOARD_HEIGHT

	for n in song.notes {
		if n.end_sec < time || n.start_sec > time + LOOKAHEAD_SEC do continue
		k := int(n.key) - NOTE_MIN
		if k < 0 || k >= NUM_KEYS do continue
		g := geo[k]

		y_start := roll_bottom - f32((n.start_sec - time) / LOOKAHEAD_SEC) * roll_bottom
		y_end := roll_bottom - f32((n.end_sec - time) / LOOKAHEAD_SEC) * roll_bottom
		rect := rl.Rectangle{g.x + 1, y_end, max(g.w - 2, 1), max(y_start - y_end, 2)}

		col := note_color(n.track, n.key)
		if n.start_sec <= time && time < n.end_sec {
			active_keys[n.key] = true
			col = rl.ColorBrightness(col, 0.35)
		}
		rl.DrawRectangleRounded(rect, 0.35, 4, col)
	}
}

// Draw the keyboard along the bottom of the window, highlighting active keys.
draw_keyboard :: proc(screen_w, screen_h: f32, active_keys: ^[128]bool) {
	geo := keyboard_layout(screen_w)
	top := screen_h - KEYBOARD_HEIGHT
	black_h := f32(KEYBOARD_HEIGHT) * 0.62

	// White keys first.
	for k in 0 ..< NUM_KEYS {
		g := geo[k]
		if g.black do continue
		midi := NOTE_MIN + k
		rect := rl.Rectangle{g.x, top, g.w, KEYBOARD_HEIGHT}
		col := active_keys[midi] ? KEY_HIGHLIGHT : rl.Color{238, 238, 240, 255}
		rl.DrawRectangleRec(rect, col)
		rl.DrawRectangleLinesEx(rect, 1, {30, 30, 36, 255})
	}

	// Black keys on top.
	for k in 0 ..< NUM_KEYS {
		g := geo[k]
		if !g.black do continue
		midi := NOTE_MIN + k
		rect := rl.Rectangle{g.x, top, g.w, black_h}
		col := active_keys[midi] ? rl.ColorBrightness(KEY_HIGHLIGHT, -0.25) : rl.Color{24, 24, 30, 255}
		rl.DrawRectangleRec(rect, col)
	}

	// The "now" line where notes meet the keyboard.
	rl.DrawLineEx({0, top}, {screen_w, top}, 2, {120, 205, 255, 200})
}
