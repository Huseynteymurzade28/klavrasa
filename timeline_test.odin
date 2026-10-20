package klavrasa

import "core:slice"
import "core:testing"

// Format 1 file: a conductor track (name, 3/4, G major, 120 BPM, then 150 BPM
// at bar 3) and a named melody track with one quarter note per beat for 3 bars.
@(private = "file")
build_fixture :: proc() -> []byte {
	tpq :: 96
	bar :: tpq * 3
	return slice.clone([]byte {
		'M', 'T', 'h', 'd', 0, 0, 0, 6, 0, 1, 0, 2, 0, tpq,
		// --- conductor track (41 bytes)
		'M', 'T', 'r', 'k', 0, 0, 0, 41,
		0x00, 0xFF, 0x03, 0x04, 'C', 'o', 'n', 'd',        // track name
		0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08,    // 3/4
		0x00, 0xFF, 0x59, 0x02, 0x01, 0x00,                // G major
		0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,          // 120 BPM
		0x84, 0x40, 0xFF, 0x51, 0x03, 0x06, 0x1A, 0x80,    // +576 ticks (2 bars): 150 BPM
		0x00, 0xFF, 0x2F, 0x00,
		// --- melody track (43 bytes)
		'M', 'T', 'r', 'k', 0, 0, 0, 43,
		0x00, 0xFF, 0x03, 0x03, 'M', 'e', 'l',
		0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0,            // beat 1
		0x00, 0x90, 62, 100, 0x60, 0x80, 62, 0,            // beat 2
		0x00, 0x90, 64, 100, 0x60, 0x80, 64, 0,            // beat 3
		0x00, 0x90, 65, 100, 0x60, 0x80, 65, 0,            // bar 2 beat 1
		0x00, 0xFF, 0x2F, 0x00,
	})
}

@(test)
test_song_metadata :: proc(t: ^testing.T) {
	file, err := midi_parse(build_fixture())
	defer midi_destroy(&file)
	testing.expect_value(t, err, MIDI_Error.None)

	song := build_song(file)
	defer song_destroy(&song)

	testing.expect_value(t, len(song.notes), 4)
	testing.expect_value(t, song.key_name, cstring("G major"))
	testing.expect_value(t, song.tracks[0].name, "Cond")
	testing.expect_value(t, song.tracks[0].note_count, 0)
	testing.expect_value(t, song.tracks[1].name, "Mel")
	testing.expect_value(t, song.tracks[1].note_count, 4)
	testing.expect_value(t, song.tracks[1].lo, u8(60))
	testing.expect_value(t, song.tracks[1].hi, u8(65))
}

@(test)
test_beat_grid_and_tempo :: proc(t: ^testing.T) {
	file, err := midi_parse(build_fixture())
	defer midi_destroy(&file)
	testing.expect_value(t, err, MIDI_Error.None)

	song := build_song(file)
	defer song_destroy(&song)

	// Beats are laid out at least up to the last event (the 150 BPM change at
	// tick 576 = start of bar 3), so bars 1 and 2 are complete: 6 beats + 1.
	testing.expect(t, len(song.beats) >= 7, "expected at least 7 beats")
	b0 := song.beats[0]
	testing.expect_value(t, b0.bar, 1)
	testing.expect_value(t, b0.beat, 1)
	testing.expect_value(t, b0.num, u8(3))
	testing.expect_value(t, b0.den, u8(4))
	testing.expect_value(t, song.beats[3].bar, 2)
	testing.expect_value(t, song.beats[3].beat, 1)
	testing.expect_value(t, song.beats[6].bar, 3)

	// At 120 BPM a beat is 0.5 s, so bar 2 starts at 1.5 s.
	testing.expect(t, abs(song.beats[3].time - 1.5) < 1e-9, "bar 2 should start at 1.5s")

	// Tempo map: 120 until bar 3 (3.0 s), then 150.
	testing.expect(t, abs(song_bpm_at(song, 0.0) - 120) < 1e-6, "120 BPM at start")
	testing.expect(t, abs(song_bpm_at(song, 2.9) - 120) < 1e-6, "120 BPM before change")
	testing.expect(t, abs(song_bpm_at(song, 3.0) - 150) < 1e-6, "150 BPM after change")

	// Beat lookup: 1.6 s is bar 2, beat 1; a seek to 0.5 s lands on the
	// note-off/note-on pair at that instant.
	b, ok := song_beat_at(song, 1.6)
	testing.expect(t, ok, "beat lookup")
	testing.expect_value(t, b.bar, 2)
	testing.expect_value(t, b.beat, 1)
	idx := song_event_index(song, 0.5)
	testing.expect(t, idx < len(song.events) && song.events[idx].time == 0.5, "event index at 0.5s")
	testing.expect(t, idx == 0 || song.events[idx - 1].time < 0.5, "previous event is earlier")
}
