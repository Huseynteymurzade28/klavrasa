package klavrasa

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
LEAD_IN_SEC :: 2.0 // the clock starts this far before the first tick, so the
                   // opening notes fall into view instead of appearing on the keys
SEEK_STEP   :: 5.0 // seconds per arrow-key press
SPEED_MIN   :: 0.25
SPEED_MAX   :: 4.0

Player :: struct {
	loaded:       bool,
	song:         Song,
	path:         string, // owned full path
	display_name: string, // owned base name, for the overlay
	time:         f64,     // current song time in seconds (negative during lead-in)
	speed:        f64,     // SPEED_MIN..SPEED_MAX
	paused:       bool,
	cursor:       int,     // index into song.events
	muted:        []bool,  // per track; owned
	solo:         []bool,  // per track; owned
	any_solo:     bool,    // cached: is any track soloed?
}

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Klavrasa — MIDI Piano Roll")
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
		ui_handle_mouse(&player, &audio, screen_w, screen_h)

		// --- Update ---------------------------------------------------------
		if player.loaded && !player.paused {
			player.time += f64(rl.GetFrameTime()) * player.speed
			advance_events(&player, &audio)
			if player.time > player.song.duration_sec + END_PAD_SEC {
				restart(&player, &audio)
			}
		}
		audio_update(&audio)
		ui_update(rl.GetFrameTime())

		// --- Draw -----------------------------------------------------------
		active_keys: [128]bool
		rl.BeginDrawing()
		rl.ClearBackground({16, 16, 22, 255})
		draw_background(screen_w, screen_h)
		if player.loaded {
			draw_beat_grid(player.song, player.time, screen_w, screen_h)
			draw_falling_notes(&player, screen_w, screen_h, &active_keys)
		}
		draw_keyboard(screen_w, screen_h, &active_keys)
		draw_overlay(&player, &audio, screen_w, screen_h)
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
			if track_audible(p, e.track) do audio_note_on(a, e.key, e.velocity, e.track)
		} else {
			audio_note_off(a, e.key, e.track)
		}
		p.cursor += 1
	}
}

// Whether a track should sound / draw fully, given the mute & solo state.
track_audible :: proc(p: ^Player, track: int) -> bool {
	if track < 0 || track >= len(p.muted) do return true
	if p.any_solo do return p.solo[track]
	return !p.muted[track]
}

handle_controls :: proc(p: ^Player, a: ^Audio) {
	if rl.IsKeyPressed(.SPACE) && p.loaded do toggle_pause(p, a)

	// Playback speed: presets on 1/2/3, fine steps on -/+ (or [ / ]).
	if rl.IsKeyPressed(.ONE)   do set_speed(p, 0.5)
	if rl.IsKeyPressed(.TWO)   do set_speed(p, 1.0)
	if rl.IsKeyPressed(.THREE) do set_speed(p, 2.0)
	if rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT) do set_speed(p, p.speed - 0.25)
	if rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD)      do set_speed(p, p.speed + 0.25)

	if rl.IsKeyPressed(.R) && p.loaded do restart(p, a)

	// Seeking: arrows step, Home jumps to the start.
	if p.loaded {
		if rl.IsKeyPressed(.LEFT)  || rl.IsKeyPressedRepeat(.LEFT)  do seek(p, a, p.time - SEEK_STEP)
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) do seek(p, a, p.time + SEEK_STEP)
		if rl.IsKeyPressed(.HOME) do restart(p, a)
	}

	// Sound: waveform cycles on W, volume on up/down.
	if rl.IsKeyPressed(.W) {
		w := audio_next_waveform(a)
		ui_toast(fmt.ctprintf("Sound: %s", WAVEFORM_NAMES[w]))
	}
	if rl.IsKeyPressed(.UP)   || rl.IsKeyPressedRepeat(.UP)   do set_volume(a, a.master + 0.1)
	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressedRepeat(.DOWN) do set_volume(a, a.master - 0.1)

	// Track mute / solo from the keyboard: F1..F8 mute, Shift+F1..F8 solo.
	if p.loaded {
		fkeys := [?]rl.KeyboardKey{.F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8}
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		for k, i in fkeys {
			if !rl.IsKeyPressed(k) do continue
			t := nth_track_with_notes(p, i)
			if t < 0 do continue
			if shift {
				toggle_solo(p, a, t)
			} else {
				toggle_mute(p, a, t)
			}
		}
	}
}

toggle_pause :: proc(p: ^Player, a: ^Audio) {
	p.paused = !p.paused
	if p.paused {
		rl.PauseAudioStream(a.stream)
	} else {
		rl.ResumeAudioStream(a.stream)
	}
}

set_speed :: proc(p: ^Player, v: f64) {
	p.speed = clamp(v, SPEED_MIN, SPEED_MAX)
	ui_toast(fmt.ctprintf("Speed %.2gx", p.speed))
}

set_volume :: proc(a: ^Audio, v: f32) {
	audio_set_master(a, v)
	ui_toast(fmt.ctprintf("Volume %d%%", int(a.master * 100 + 0.5)))
}

restart :: proc(p: ^Player, a: ^Audio) {
	seek(p, a, -LEAD_IN_SEC)
}

// Jump the song clock to `t`, silencing everything and re-sounding any notes
// that are mid-way through at the new position.
seek :: proc(p: ^Player, a: ^Audio, t: f64) {
	p.time = clamp(t, -LEAD_IN_SEC, p.song.duration_sec)
	p.cursor = song_event_index(p.song, p.time)
	audio_all_off(a)
	if p.paused do return
	for n in p.song.notes {
		if n.start_sec < p.time && p.time < n.end_sec && track_audible(p, n.track) {
			audio_note_on(a, n.key, n.velocity, n.track)
		}
	}
}

// --- track mute / solo --------------------------------------------------------

toggle_mute :: proc(p: ^Player, a: ^Audio, track: int) {
	if track < 0 || track >= len(p.muted) do return
	p.muted[track] = !p.muted[track]
	apply_track_state(p, a)
	ui_toast(fmt.ctprintf("%s %s", track_label(p, track), p.muted[track] ? "muted" : "unmuted"))
}

toggle_solo :: proc(p: ^Player, a: ^Audio, track: int) {
	if track < 0 || track >= len(p.solo) do return
	p.solo[track] = !p.solo[track]
	apply_track_state(p, a)
	ui_toast(fmt.ctprintf("%s %s", track_label(p, track), p.solo[track] ? "solo" : "solo off"))
}

// Recompute the solo cache and cut off any voice that is no longer audible.
@(private = "file")
apply_track_state :: proc(p: ^Player, a: ^Audio) {
	p.any_solo = false
	for s in p.solo do p.any_solo |= s
	for t in 0 ..< len(p.muted) {
		if !track_audible(p, t) do audio_release_track(a, t)
	}
	// Tracks that just became audible again pick up from their next note-on;
	// re-sound the ones that are mid-note right now so it doesn't feel laggy.
	if !p.paused {
		for n in p.song.notes {
			if n.start_sec < p.time && p.time < n.end_sec && track_audible(p, n.track) &&
			   !audio_is_sounding(a, n.key, n.track) {
				audio_note_on(a, n.key, n.velocity, n.track)
			}
		}
	}
}

// The i-th track (0-based) that actually contains notes, or -1.
nth_track_with_notes :: proc(p: ^Player, i: int) -> int {
	seen := 0
	for t, ti in p.song.tracks {
		if t.note_count == 0 do continue
		if seen == i do return ti
		seen += 1
	}
	return -1
}

// Display name for a track: its MIDI name, or "Track N".
track_label :: proc(p: ^Player, track: int) -> cstring {
	if track < len(p.song.tracks) && p.song.tracks[track].name != "" {
		return strings.clone_to_cstring(p.song.tracks[track].name, context.temp_allocator)
	}
	return fmt.ctprintf("Track %d", track + 1)
}

// Parse `path`, replace any currently loaded song, and reset playback.
load_song :: proc(p: ^Player, a: ^Audio, path: string) {
	file, err := midi_load(path)
	if err != .None {
		fmt.eprintfln("Failed to load %q: %v", path, err)
		ui_toast(fmt.ctprintf("Couldn't load %s: %v", filepath.base(path), err))
		return
	}

	unload_song(p)
	audio_all_off(a)

	p.song = build_song(file)
	p.path = strings.clone(path)
	p.display_name = strings.clone(filepath.base(path))
	p.muted = make([]bool, p.song.track_count)
	p.solo = make([]bool, p.song.track_count)
	p.any_solo = false
	p.loaded = true
	p.time = -LEAD_IN_SEC
	p.cursor = 0
	p.paused = false
	rl.ResumeAudioStream(a.stream)
	ui_toast(fmt.ctprintf("Loaded %s", filepath.base(path)))

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
	delete(p.muted)
	delete(p.solo)
	p.muted = nil
	p.solo = nil
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
