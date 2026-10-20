package klavrasa

// Piano-roll renderer: falling note blocks above an 88-key keyboard.
//
// Time maps to the vertical axis: the current playback instant sits at the top
// edge of the keyboard ("now" line) and notes fall down toward it, lighting up
// the corresponding key as they land. Notes are coloured per track, shaded by
// octave so the layered tracks and registers stay readable.

import "core:fmt"
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

@(private = "file")
with_alpha :: proc(c: rl.Color, a: u8) -> rl.Color {
	return {c.r, c.g, c.b, a}
}

// Deep atmospheric backdrop: a vertical gradient with a soft glow near the top,
// drawn before everything else.
draw_background :: proc(screen_w, screen_h: f32) {
	rl.DrawRectangleGradientV(0, 0, i32(screen_w), i32(screen_h), {22, 21, 34, 255}, {9, 9, 14, 255})
	rl.DrawCircleGradient({screen_w / 2, screen_h * 0.12}, screen_w * 0.55, {52, 58, 96, 38}, {52, 58, 96, 0})
}

// Faint vertical guide lines at every octave boundary (each C), giving the roll
// a subtle musical grid.
@(private = "file")
draw_octave_guides :: proc(geo: [NUM_KEYS]Key_Geo, roll_bottom: f32) {
	for k in 0 ..< NUM_KEYS {
		midi := NOTE_MIN + k
		if midi % 12 != 0 do continue // C
		x := geo[k].x
		col := rl.Color{255, 255, 255, midi == 60 ? 18 : 9} // brighter at middle C
		rl.DrawLineEx({x, 0}, {x, roll_bottom}, 1, col)
	}
}

// Screen y for a song time, given the roll's bottom edge ("now").
@(private = "file")
time_to_y :: proc(t, now: f64, roll_bottom: f32) -> f32 {
	return roll_bottom - f32((t - now) / LOOKAHEAD_SEC) * roll_bottom
}

// Horizontal beat and bar lines scrolling down with the notes, with the bar
// number tucked against the left edge. Bars are brighter than beats; the
// downbeat that is about to land gets a soft highlight so the pulse reads.
draw_beat_grid :: proc(song: Song, time: f64, screen_w, screen_h: f32) {
	roll_bottom := screen_h - KEYBOARD_HEIGHT
	if len(song.beats) == 0 do return

	i := song_beat_index(song, time)
	if i > 0 do i -= 1 // include the beat currently in force
	for ; i < len(song.beats); i += 1 {
		b := song.beats[i]
		if b.time > time + LOOKAHEAD_SEC do break
		y := time_to_y(b.time, time, roll_bottom)
		if y < 0 || y > roll_bottom do continue

		if b.beat == 1 {
			rl.DrawLineEx({0, y}, {screen_w, y}, 1, {255, 255, 255, 34})
			label := fmt.ctprintf("%d", b.bar)
			draw_text(label, screen_w - 10 - text_size(label, 15).x, y - 20, 15, {150, 156, 178, 160})
		} else {
			rl.DrawLineEx({0, y}, {screen_w, y}, 1, {255, 255, 255, 11})
		}
	}
}

// Draw the falling notes. `active_keys[midi]` is set to true for any note that
// is currently sounding, so the keyboard pass can highlight it. Notes on muted
// tracks are drawn as faint outlines and never light up the keys.
draw_falling_notes :: proc(p: ^Player, screen_w, screen_h: f32, active_keys: ^[128]bool) {
	song := p.song
	time := p.time
	geo := keyboard_layout(screen_w)
	roll_bottom := screen_h - KEYBOARD_HEIGHT

	draw_octave_guides(geo, roll_bottom)

	for n in song.notes {
		if n.end_sec < time || n.start_sec > time + LOOKAHEAD_SEC do continue
		k := int(n.key) - NOTE_MIN
		if k < 0 || k >= NUM_KEYS do continue
		g := geo[k]
		audible := track_audible(p, n.track)

		y_start := roll_bottom - f32((n.start_sec - time) / LOOKAHEAD_SEC) * roll_bottom
		y_end := roll_bottom - f32((n.end_sec - time) / LOOKAHEAD_SEC) * roll_bottom
		y_start = min(y_start, roll_bottom) // don't bleed into the keyboard
		w := max(g.w - 2, 1)
		h := max(y_start - y_end, 3)
		rect := rl.Rectangle{g.x + 1, y_end, w, h}
		round := min(7 / min(w, h), 0.5)

		base := note_color(n.track, n.key)
		active := n.start_sec <= time && time < n.end_sec

		if !audible {
			// Ghost: a dim outline so you can still follow the muted part.
			rl.DrawRectangleRounded(rect, round, 6, with_alpha(base, 22))
			rl.DrawRectangleRoundedLinesEx(rect, round, 6, 1, with_alpha(base, 80))
			continue
		}
		if active do active_keys[n.key] = true

		// Soft glow around the block — wider and brighter while it's sounding.
		glow_layers := active ? 3 : 1
		for i in 0 ..< glow_layers {
			grow := f32(i + 1) * (active ? 4 : 2.5)
			a := u8(active ? 60 - i * 16 : 26)
			gr := rl.Rectangle{rect.x - grow, rect.y - grow, rect.width + grow * 2, rect.height + grow * 2}
			rl.DrawRectangleRounded(gr, round, 6, with_alpha(base, a))
		}

		// Glossy body: darker base + a lighter sheen across the top half.
		body := active ? rl.ColorBrightness(base, 0.25) : base
		rl.DrawRectangleRounded(rect, round, 6, rl.ColorBrightness(body, -0.10))
		sheen := rl.Rectangle{rect.x, rect.y, rect.width, max(rect.height * 0.5, 3)}
		rl.DrawRectangleRounded(sheen, round, 6, with_alpha(rl.ColorBrightness(body, 0.45), 150))

		// Crisp bright cap on the leading (top) edge.
		rl.DrawRectangleRounded({rect.x, rect.y, rect.width, 2.5}, 1, 4,
			with_alpha(rl.ColorBrightness(base, 0.7), 235))

		// When sounding, send a soft beam of light down onto the key.
		if active {
			beam_h := f32(46)
			cx := rect.x + rect.width / 2
			rl.DrawRectangleGradientV(
				i32(cx - rect.width * 0.6), i32(roll_bottom - beam_h),
				i32(rect.width * 1.2), i32(beam_h),
				with_alpha(base, 0), with_alpha(rl.ColorBrightness(base, 0.4), 130))
		}
	}
}

// Draw the keyboard along the bottom of the window, highlighting active keys.
draw_keyboard :: proc(screen_w, screen_h: f32, active_keys: ^[128]bool) {
	geo := keyboard_layout(screen_w)
	top := screen_h - KEYBOARD_HEIGHT
	black_h := f32(KEYBOARD_HEIGHT) * 0.62

	// Glow rising off any active key, behind the keys themselves.
	for k in 0 ..< NUM_KEYS {
		midi := NOTE_MIN + k
		if !active_keys[midi] do continue
		g := geo[k]
		rl.DrawRectangleGradientV(
			i32(g.x - g.w * 0.4), i32(top - 60), i32(g.w * 1.8), 60,
			{120, 205, 255, 0}, {120, 205, 255, 90})
	}

	// White keys: soft vertical gradient, brighter when active.
	for k in 0 ..< NUM_KEYS {
		g := geo[k]
		if g.black do continue
		midi := NOTE_MIN + k
		if active_keys[midi] {
			rl.DrawRectangleGradientV(i32(g.x), i32(top), i32(g.w), KEYBOARD_HEIGHT,
				{180, 226, 255, 255}, {120, 196, 250, 255})
		} else {
			rl.DrawRectangleGradientV(i32(g.x), i32(top), i32(g.w), KEYBOARD_HEIGHT,
				{246, 247, 250, 255}, {206, 209, 220, 255})
		}
		rl.DrawRectangleLinesEx({g.x, top, g.w, KEYBOARD_HEIGHT}, 1, {26, 26, 32, 200})
	}

	// Black keys on top, with a little gloss.
	for k in 0 ..< NUM_KEYS {
		g := geo[k]
		if !g.black do continue
		midi := NOTE_MIN + k
		if active_keys[midi] {
			rl.DrawRectangleGradientV(i32(g.x), i32(top), i32(g.w), i32(black_h),
				{96, 176, 232, 255}, {52, 120, 180, 255})
		} else {
			rl.DrawRectangleGradientV(i32(g.x), i32(top), i32(g.w), i32(black_h),
				{40, 40, 50, 255}, {16, 16, 22, 255})
		}
		// thin highlight along the top edge of the key
		rl.DrawRectangle(i32(g.x), i32(top), i32(g.w), 2, {255, 255, 255, 40})
	}

	// The "now" line: a glow fading upward, then a crisp bright line.
	rl.DrawRectangleGradientV(0, i32(top - 26), i32(screen_w), 26, {120, 205, 255, 0}, {120, 205, 255, 55})
	rl.DrawLineEx({0, top}, {screen_w, top}, 2, {150, 215, 255, 220})
}
