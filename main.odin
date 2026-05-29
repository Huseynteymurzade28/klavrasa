package resonance

// Entry point. For now this is a thin harness that opens a window, accepts a
// .mid file via drag-and-drop (or a command-line argument), parses it with the
// MIDI parser, and shows a short summary. The piano-roll renderer, audio
// synthesis, and playback controls are layered on top of this in later files.

import "core:fmt"
import "core:strings"
import "core:os"
import rl "vendor:raylib"

WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 720

main :: proc() {
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Resonance — MIDI Piano Roll")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	loaded: bool
	file: MIDI_File
	current_path: string // owned (cloned); empty when nothing is loaded
	load_error: MIDI_Error = .None

	// Allow loading a file passed on the command line: `resonance song.mid`.
	if len(os.args) > 1 {
		loaded, current_path, load_error = try_load(&file, os.args[1], loaded, current_path)
	}

	for !rl.WindowShouldClose() {
		// --- Input: drag-and-drop a .mid file onto the window ---------------
		if rl.IsFileDropped() {
			dropped := rl.LoadDroppedFiles()
			defer rl.UnloadDroppedFiles(dropped)
			if dropped.count > 0 {
				path := string(dropped.paths[0])
				loaded, current_path, load_error = try_load(&file, path, loaded, current_path)
			}
		}

		// --- Draw -----------------------------------------------------------
		rl.BeginDrawing()
		rl.ClearBackground({18, 18, 24, 255})

		if loaded {
			rl.DrawText("Loaded:", 20, 20, 24, rl.RAYWHITE)
			rl.DrawText(strings.clone_to_cstring(current_path, context.temp_allocator), 20, 52, 20, rl.SKYBLUE)
			rl.DrawText(
				fmt.ctprintf(
					"Format: %v    Tracks: %d    %s",
					file.format,
					len(file.tracks),
					division_text(file.division),
				),
				20, 88, 20, rl.LIGHTGRAY,
			)
			rl.DrawText("(piano roll + audio coming next — see console for details)", 20, 120, 18, rl.GRAY)
		} else if load_error != .None {
			rl.DrawText(fmt.ctprintf("Load failed: %v", load_error), 20, 20, 24, rl.RED)
			rl.DrawText("Drop a valid .mid file onto the window", 20, 56, 20, rl.LIGHTGRAY)
		} else {
			rl.DrawText("Drop a .mid file onto this window", 20, 20, 28, rl.RAYWHITE)
		}

		rl.EndDrawing()

		// Reclaim per-frame scratch allocations (ctprintf / clone_to_cstring).
		free_all(context.temp_allocator)
	}

	if loaded do midi_destroy(&file)
	if current_path != "" do delete(current_path)
}

// Parse `path` into `file`, replacing any previously loaded file. Returns the
// updated (loaded, path, error) state. On failure the previous file is still
// freed and `loaded` becomes false.
try_load :: proc(
	file: ^MIDI_File,
	path: string,
	was_loaded: bool,
	old_path: string,
) -> (loaded: bool, current_path: string, err: MIDI_Error) {
	if was_loaded do midi_destroy(file)
	if old_path != "" do delete(old_path)

	new_file, perr := midi_load(path)
	if perr != .None {
		fmt.eprintfln("Failed to load %q: %v", path, perr)
		return false, "", perr
	}

	file^ = new_file
	midi_print_summary(file^, path)
	return true, strings.clone(path), .None
}

division_text :: proc(d: Time_Division) -> string {
	if d.is_smpte {
		return fmt.tprintf("SMPTE %d fps, %d ticks/frame", d.fps, d.ticks_per_frame)
	}
	return fmt.tprintf("%d ticks/quarter", d.ticks_per_quarter)
}

// Print a human-readable summary of a parsed file to the console: useful for
// verifying the parser against real-world .mid files.
midi_print_summary :: proc(file: MIDI_File, path: string) {
	fmt.println("───────────────────────────────────────────────")
	fmt.printfln("MIDI: %s", path)
	fmt.printfln("  format:   %v", file.format)
	fmt.printfln("  division: %s", division_text(file.division))
	fmt.printfln("  tracks:   %d", len(file.tracks))

	for track, i in file.tracks {
		notes, tempo_us: int
		first_tempo: u32 = 0
		end_tick: u64 = 0
		for ev in track.events {
			#partial switch d in ev.data {
			case Note_On:
				notes += 1
			case Set_Tempo:
				if first_tempo == 0 do first_tempo = d.us_per_quarter
				tempo_us += 1
			}
			end_tick = max(end_tick, ev.tick)
		}
		bpm := first_tempo > 0 ? 60_000_000.0 / f64(first_tempo) : 0
		fmt.printfln(
			"  track %d: %d events, %d notes, %d tempo change(s), first BPM %.1f, length %d ticks",
			i, len(track.events), notes, tempo_us, bpm, end_tick,
		)
	}
	fmt.println("───────────────────────────────────────────────")
}
