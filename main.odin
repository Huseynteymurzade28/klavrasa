package resonance

// Entry point and playback engine. Opens a window, loads MIDI files (via
// drag-and-drop or a command-line argument), advances a song clock, fires
// note events into the synth, and draws the piano roll + overlay each frame.

import "core:fmt"
import "core:path/filepath"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 720

END_PAD_SEC :: 1.5 // silence held at the end before looping

Player :: struct {
	loaded:       bool,
	song:         Song,
	path:         string, // owned full path
	display_name: string, // owned base name, for the overlay
	time:         f64,     // current song time in seconds
	speed:        f64,     // 0.5 / 1 / 2
	paused:       bool,
	cursor:       int,     // index into song.events
}

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Resonance — MIDI Piano Roll")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	ui_load_assets()
	defer ui_unload_assets()

	audio: Audio
	audio_init(&audio)
	defer audio_shutdown(&audio)

	player := Player{speed = 1}

	if len(os.args) > 1 {
		load_song(&player, &audio, os.args[1])
	}

	for !rl.WindowShouldClose() {
		screen_w := f32(rl.GetScreenWidth())
		screen_h := f32(rl.GetScreenHeight())

		// --- Input ----------------------------------------------------------
		if rl.IsFileDropped() {
			dropped := rl.LoadDroppedFiles()
			defer rl.UnloadDroppedFiles(dropped)
			if dropped.count > 0 {
				load_song(&player, &audio, string(dropped.paths[0]))
			}
		}
		handle_controls(&player, &audio)

		// --- Update ---------------------------------------------------------
		if player.loaded && !player.paused {
			player.time += f64(rl.GetFrameTime()) * player.speed
			advance_events(&player, &audio)
			if player.time > player.song.duration_sec + END_PAD_SEC {
				restart(&player, &audio)
			}
		}
		audio_update(&audio)

		// --- Draw -----------------------------------------------------------
		active_keys: [128]bool
		rl.BeginDrawing()
		rl.ClearBackground({16, 16, 22, 255})
		draw_background(screen_w, screen_h)
		if player.loaded {
			draw_falling_notes(player.song, player.time, screen_w, screen_h, &active_keys)
		}
		draw_keyboard(screen_w, screen_h, &active_keys)
		draw_overlay(player, screen_w, screen_h)
		rl.EndDrawing()

		free_all(context.temp_allocator)
	}

	unload_song(&player)
}

// Advance the event cursor, firing every note on/off up to the current time.
advance_events :: proc(p: ^Player, a: ^Audio) {
	for p.cursor < len(p.song.events) && p.song.events[p.cursor].time <= p.time {
		e := p.song.events[p.cursor]
		if e.on {
			audio_note_on(a, e.key, e.velocity, e.track)
		} else {
			audio_note_off(a, e.key, e.track)
		}
		p.cursor += 1
	}
}

handle_controls :: proc(p: ^Player, a: ^Audio) {
	if rl.IsKeyPressed(.SPACE) && p.loaded {
		p.paused = !p.paused
		if p.paused {
			rl.PauseAudioStream(a.stream)
		} else {
			rl.ResumeAudioStream(a.stream)
		}
	}
	if rl.IsKeyPressed(.ONE) do p.speed = 0.5
	if rl.IsKeyPressed(.TWO) do p.speed = 1.0
	if rl.IsKeyPressed(.THREE) do p.speed = 2.0
	if rl.IsKeyPressed(.R) && p.loaded do restart(p, a)
}

restart :: proc(p: ^Player, a: ^Audio) {
	p.time = 0
	p.cursor = 0
	audio_all_off(a)
}

// Parse `path`, replace any currently loaded song, and reset playback.
load_song :: proc(p: ^Player, a: ^Audio, path: string) {
	file, err := midi_load(path)
	if err != .None {
		fmt.eprintfln("Failed to load %q: %v", path, err)
		return
	}

	unload_song(p)
	audio_all_off(a)

	p.song = build_song(file)
	p.path = strings.clone(path)
	p.display_name = strings.clone(filepath.base(path))
	p.loaded = true
	p.time = 0
	p.cursor = 0
	p.paused = false
	rl.ResumeAudioStream(a.stream)

	midi_print_summary(file, path)
	fmt.printfln(
		"  -> %d notes, %.1fs, %.0f BPM",
		len(p.song.notes), p.song.duration_sec, p.song.initial_bpm,
	)
	midi_destroy(&file) // notes/events are now resolved into the Song
}

unload_song :: proc(p: ^Player) {
	if !p.loaded do return
	song_destroy(&p.song)
	delete(p.path)
	delete(p.display_name)
	p.loaded = false
	p.path = ""
	p.display_name = ""
}

// Print a human-readable summary of a parsed file to the console.
midi_print_summary :: proc(file: MIDI_File, path: string) {
	fmt.println("───────────────────────────────────────────────")
	fmt.printfln("MIDI: %s", path)
	fmt.printfln("  format:   %v", file.format)
	if file.division.is_smpte {
		fmt.printfln("  division: SMPTE %d fps, %d ticks/frame", file.division.fps, file.division.ticks_per_frame)
	} else {
		fmt.printfln("  division: %d ticks/quarter", file.division.ticks_per_quarter)
	}
	fmt.printfln("  tracks:   %d", len(file.tracks))
}
