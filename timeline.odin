package resonance

// Turns parsed MIDI tracks into a playable, drawable timeline:
//   * a tempo map that converts ticks to absolute seconds (honouring tempo
//     changes, or a constant rate for SMPTE division),
//   * a flat list of `Note` spans (start/end in seconds) for rendering, and
//   * a time-sorted list of `Play_Event`s (note on/off) for driving the synth.

import "core:math"
import "core:slice"

// A single sounding note, resolved to absolute seconds.
Note :: struct {
	track:     int,
	channel:   u8,
	key:       u8,
	velocity:  u8,
	start_sec: f64,
	end_sec:   f64,
}

// A note-on / note-off moment on the playback clock.
Play_Event :: struct {
	time:     f64,
	on:       bool,
	key:      u8,
	velocity: u8,
	track:    int,
}

Song :: struct {
	notes:        [dynamic]Note,
	events:       [dynamic]Play_Event, // sorted by time (offs before ons on ties)
	track_count:  int,
	duration_sec: f64,
	initial_bpm:  f64,
}

@(private = "file")
Tempo_Point :: struct {
	tick:           u64,
	us_per_quarter: u32,
}

DEFAULT_TEMPO_US :: 500_000 // 120 BPM

// MIDI note number -> frequency in Hz (equal temperament, A4/key 69 = 440 Hz).
key_to_freq :: proc(key: u8) -> f32 {
	return 440.0 * math.pow_f32(2.0, f32(int(key) - 69) / 12.0)
}

// Flatten a parsed file into a `Song`. The caller owns the result and must call
// `song_destroy`.
build_song :: proc(file: MIDI_File) -> (song: Song) {
	song.track_count = len(file.tracks)
	song.notes = make([dynamic]Note)
	song.events = make([dynamic]Play_Event)

	tempos := build_tempo_map(file)
	defer delete(tempos)

	// Cumulative seconds at the start of each tempo segment (metrical only).
	cum := make([]f64, len(tempos))
	defer delete(cum)
	for i in 1 ..< len(tempos) {
		dt := tempos[i].tick - tempos[i - 1].tick
		cum[i] = cum[i - 1] + segment_seconds(dt, tempos[i - 1].us_per_quarter, file.division)
	}

	song.initial_bpm = 60_000_000.0 / f64(tempos[0].us_per_quarter)

	// Walk each track, pairing note-ons with their matching note-offs.
	pending: [16][128]struct {
		on:    bool,
		tick:  u64,
		vel:   u8,
	}
	for track, ti in file.tracks {
		pending = {}
		for ev in track.events {
			#partial switch d in ev.data {
			case Note_On:
				// A second on without an off: close the previous span first.
				if pending[d.channel][d.key].on {
					emit_note(&song, ti, d.channel, d.key, pending[d.channel][d.key], ev.tick, tempos[:], cum[:], file.division)
				}
				pending[d.channel][d.key] = {true, ev.tick, d.velocity}
			case Note_Off:
				p := pending[d.channel][d.key]
				if p.on {
					emit_note(&song, ti, d.channel, d.key, p, ev.tick, tempos[:], cum[:], file.division)
					pending[d.channel][d.key].on = false
				}
			}
		}
	}

	// Build the playback event stream and sort it.
	for n in song.notes {
		append(&song.events, Play_Event{n.start_sec, true, n.key, n.velocity, n.track})
		append(&song.events, Play_Event{n.end_sec, false, n.key, 0, n.track})
		song.duration_sec = max(song.duration_sec, n.end_sec)
	}
	slice.sort_by(song.events[:], proc(a, b: Play_Event) -> bool {
		if a.time != b.time do return a.time < b.time
		return !a.on && b.on // process note-offs before note-ons at the same instant
	})

	return song
}

song_destroy :: proc(song: ^Song) {
	delete(song.notes)
	delete(song.events)
	song^ = {}
}

// --- helpers ----------------------------------------------------------------

@(private = "file")
emit_note :: proc(
	song: ^Song,
	track: int,
	channel, key: u8,
	p: struct { on: bool, tick: u64, vel: u8 },
	end_tick: u64,
	tempos: []Tempo_Point,
	cum: []f64,
	div: Time_Division,
) {
	start := tick_to_sec(p.tick, tempos, cum, div)
	end := tick_to_sec(end_tick, tempos, cum, div)
	if end <= start do return // skip zero-length notes
	append(&song.notes, Note{track, channel, key, p.vel, start, end})
}

// Collect every Set_Tempo across all tracks into a sorted map with a guaranteed
// entry at tick 0.
@(private = "file")
build_tempo_map :: proc(file: MIDI_File) -> [dynamic]Tempo_Point {
	raw := make([dynamic]Tempo_Point)
	defer delete(raw)
	for track in file.tracks {
		for ev in track.events {
			if t, ok := ev.data.(Set_Tempo); ok {
				append(&raw, Tempo_Point{ev.tick, t.us_per_quarter})
			}
		}
	}
	slice.sort_by(raw[:], proc(a, b: Tempo_Point) -> bool { return a.tick < b.tick })

	tempos := make([dynamic]Tempo_Point)
	if len(raw) == 0 || raw[0].tick != 0 {
		append(&tempos, Tempo_Point{0, DEFAULT_TEMPO_US})
	}
	for t in raw do append(&tempos, t)
	return tempos
}

// Seconds spanned by `ticks` at a given tempo / division.
@(private = "file")
segment_seconds :: proc(ticks: u64, us_per_quarter: u32, div: Time_Division) -> f64 {
	if div.is_smpte {
		rate := f64(div.fps) * f64(div.ticks_per_frame)
		return rate > 0 ? f64(ticks) / rate : 0
	}
	tpq := f64(div.ticks_per_quarter)
	if tpq <= 0 do tpq = 480
	return f64(ticks) * f64(us_per_quarter) / tpq / 1_000_000.0
}

// Absolute seconds for an absolute tick.
@(private = "file")
tick_to_sec :: proc(tick: u64, tempos: []Tempo_Point, cum: []f64, div: Time_Division) -> f64 {
	if div.is_smpte {
		rate := f64(div.fps) * f64(div.ticks_per_frame)
		return rate > 0 ? f64(tick) / rate : 0
	}
	// Find the last tempo segment that starts at or before `tick`.
	idx := 0
	for i in 0 ..< len(tempos) {
		if tempos[i].tick <= tick {
			idx = i
		} else {
			break
		}
	}
	return cum[idx] + segment_seconds(tick - tempos[idx].tick, tempos[idx].us_per_quarter, div)
}
