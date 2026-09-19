package resonance

// Turns parsed MIDI tracks into a playable, drawable timeline:
//   * a tempo map that converts ticks to absolute seconds (honouring tempo
//     changes, or a constant rate for SMPTE division),
//   * a flat list of `Note` spans (start/end in seconds) for rendering, and
//   * a time-sorted list of `Play_Event`s (note on/off) for driving the synth.

import "core:math"
import "core:slice"
import "core:strings"

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

// Per-track metadata gathered while flattening, for the track panel.
Track_Info :: struct {
	name:       string, // owned; "" when the file names no track
	note_count: int,
	lo, hi:     u8,     // pitch range of the track's notes
}

// One beat on the metrical grid. `bar`/`beat` are 1-based for display.
Beat :: struct {
	time:   f64,
	bar:    int,
	beat:   int,
	num:    u8, // time signature in force at this beat
	den:    u8,
}

// A stretch of constant tempo, in seconds.
Tempo_Seg :: struct {
	start_sec: f64,
	bpm:       f64,
}

Song :: struct {
	notes:        [dynamic]Note,
	events:       [dynamic]Play_Event, // sorted by time (offs before ons on ties)
	tracks:       [dynamic]Track_Info,
	beats:        [dynamic]Beat,       // sorted by time; empty for SMPTE files
	tempos:       [dynamic]Tempo_Seg,  // sorted by start_sec, first at 0
	track_count:  int,
	duration_sec: f64,
	initial_bpm:  f64,
	key_name:     cstring,             // e.g. "G major"; "" when unknown
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
	song.tempos = make([dynamic]Tempo_Seg)
	for t, i in tempos {
		append(&song.tempos, Tempo_Seg{cum[i], 60_000_000.0 / f64(t.us_per_quarter)})
	}

	// Walk each track, pairing note-ons with their matching note-offs.
	pending: [16][128]struct {
		on:    bool,
		tick:  u64,
		vel:   u8,
	}
	song.tracks = make([dynamic]Track_Info, len(file.tracks))
	last_tick: u64
	for track, ti in file.tracks {
		pending = {}
		info := &song.tracks[ti]
		info.lo = 127
		for ev in track.events {
			last_tick = max(last_tick, ev.tick)
			#partial switch d in ev.data {
			case Meta_Text:
				// 0x03 = sequence/track name. Copy it: `text` aliases file bytes.
				if d.kind == 0x03 && info.name == "" {
					info.name = strings.clone(strings.trim_space(d.text))
				}
			case Key_Signature:
				if song.key_name == "" do song.key_name = key_signature_name(d)
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

	for n in song.notes {
		info := &song.tracks[n.track]
		info.note_count += 1
		info.lo = min(info.lo, n.key)
		info.hi = max(info.hi, n.key)
	}

	song.beats = build_beat_grid(file, tempos[:], cum[:], last_tick)

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
	for t in song.tracks do delete(t.name)
	delete(song.tracks)
	delete(song.notes)
	delete(song.events)
	delete(song.beats)
	delete(song.tempos)
	song^ = {}
}

// --- queries ----------------------------------------------------------------

// Tempo in force at `time`.
song_bpm_at :: proc(song: Song, time: f64) -> f64 {
	bpm := song.initial_bpm
	for t in song.tempos {
		if t.start_sec > time do break
		bpm = t.bpm
	}
	return bpm
}

// Index of the first beat at or after `time` (== len when past the end).
song_beat_index :: proc(song: Song, time: f64) -> int {
	lo, hi := 0, len(song.beats)
	for lo < hi {
		mid := (lo + hi) / 2
		if song.beats[mid].time < time {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// The beat in force at `time` (the last one that started at or before it).
song_beat_at :: proc(song: Song, time: f64) -> (Beat, bool) {
	i := song_beat_index(song, time)
	if i < len(song.beats) && song.beats[i].time == time do return song.beats[i], true
	if i == 0 do return {}, false
	return song.beats[i - 1], true
}

// Index of the first play event at or after `time`.
song_event_index :: proc(song: Song, time: f64) -> int {
	lo, hi := 0, len(song.events)
	for lo < hi {
		mid := (lo + hi) / 2
		if song.events[mid].time < time {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
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

// Lay a beat/bar grid over the whole song, honouring every time signature
// change. Metrical division only; SMPTE files get no grid.
@(private = "file")
build_beat_grid :: proc(file: MIDI_File, tempos: []Tempo_Point, cum: []f64, last_tick: u64) -> [dynamic]Beat {
	beats := make([dynamic]Beat)
	if file.division.is_smpte || last_tick == 0 do return beats

	Sig :: struct { tick: u64, num, den: u8 }
	sigs := make([dynamic]Sig, context.temp_allocator)
	for track in file.tracks {
		for ev in track.events {
			if ts, ok := ev.data.(Time_Signature); ok && ts.numerator > 0 {
				den := u8(1) << clamp(ts.denominator, 0, 6) // stored as a power of two
				append(&sigs, Sig{ev.tick, ts.numerator, den})
			}
		}
	}
	slice.sort_by(sigs[:], proc(a, b: Sig) -> bool { return a.tick < b.tick })
	if len(sigs) == 0 || sigs[0].tick != 0 {
		inject_at(&sigs, 0, Sig{0, 4, 4})
	}

	tpq := u64(file.division.ticks_per_quarter)
	if tpq == 0 do tpq = 480

	bar := 1
	for sig, si in sigs {
		seg_end := si + 1 < len(sigs) ? sigs[si + 1].tick : last_tick + 1
		beat_ticks := max(tpq * 4 / u64(sig.den), 1)
		tick := sig.tick
		beat := 1
		for tick < seg_end {
			append(&beats, Beat{tick_to_sec(tick, tempos, cum, file.division), bar, beat, sig.num, sig.den})
			tick += beat_ticks
			beat += 1
			if beat > int(sig.num) {
				beat = 1
				bar += 1
			}
		}
		// A signature change mid-bar starts a fresh bar.
		if beat != 1 do bar += 1
	}
	return beats
}

// Human-readable key name from a key-signature meta event.
@(private = "file")
key_signature_name :: proc(k: Key_Signature) -> cstring {
	MAJOR := [?]cstring{"Cb major", "Gb major", "Db major", "Ab major", "Eb major", "Bb major", "F major",
		"C major", "G major", "D major", "A major", "E major", "B major", "F# major", "C# major"}
	MINOR := [?]cstring{"Ab minor", "Eb minor", "Bb minor", "F minor", "C minor", "G minor", "D minor",
		"A minor", "E minor", "B minor", "F# minor", "C# minor", "G# minor", "D# minor", "A# minor"}
	i := int(k.sharps_flats) + 7
	if i < 0 || i >= len(MAJOR) do return ""
	return k.minor ? MINOR[i] : MAJOR[i]
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
