package resonance

// Heads-up overlay: BPM, playback speed, pause state, file name, a progress
// bar, and the keyboard-shortcut legend.

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

draw_overlay :: proc(p: Player, screen_w, screen_h: f32) {
	if !p.loaded {
		msg: cstring = "Drop a .mid file onto this window"
		w := rl.MeasureText(msg, 30)
		rl.DrawText(msg, i32(screen_w) / 2 - w / 2, i32(screen_h) / 2 - 15, 30, rl.RAYWHITE)
		hint: cstring = "(or pass a path on the command line)"
		hw := rl.MeasureText(hint, 18)
		rl.DrawText(hint, i32(screen_w) / 2 - hw / 2, i32(screen_h) / 2 + 22, 18, {150, 150, 160, 255})
		return
	}

	// Top-left: file name.
	name := strings.clone_to_cstring(p.display_name, context.temp_allocator)
	rl.DrawText(name, 16, 12, 22, rl.RAYWHITE)

	// Top-right: BPM and effective tempo with the speed multiplier applied.
	bpm := fmt.ctprintf("%.0f BPM", p.song.initial_bpm)
	bw := rl.MeasureText(bpm, 28)
	rl.DrawText(bpm, i32(screen_w) - bw - 16, 12, 28, rl.GOLD)

	speed := fmt.ctprintf("%.2gx  %s", p.speed, p.paused ? "PAUSED" : "PLAYING")
	sw := rl.MeasureText(speed, 20)
	rl.DrawText(speed, i32(screen_w) - sw - 16, 46, 20, p.paused ? rl.ORANGE : rl.LIGHTGRAY)

	// Progress bar just above the keyboard.
	bar_y := screen_h - KEYBOARD_HEIGHT - 14
	rl.DrawRectangle(16, i32(bar_y), i32(screen_w) - 32, 5, {60, 60, 70, 255})
	if p.song.duration_sec > 0 {
		frac := f32(clamp(p.time / p.song.duration_sec, 0, 1))
		rl.DrawRectangle(16, i32(bar_y), i32((screen_w - 32) * frac), 5, rl.SKYBLUE)
	}
	clock := fmt.ctprintf("%02d:%02d / %02d:%02d",
		int(p.time) / 60, int(p.time) % 60,
		int(p.song.duration_sec) / 60, int(p.song.duration_sec) % 60)
	rl.DrawText(clock, 16, i32(bar_y) - 24, 18, rl.LIGHTGRAY)

	// Bottom hint line.
	help: cstring = "SPACE pause   1/2/3 speed   R restart   drop a .mid to load"
	rl.DrawText(help, 16, i32(screen_h) - 22, 16, {140, 140, 150, 255})
}
