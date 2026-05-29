package resonance

import "core:slice"
import "core:testing"

// A hand-built Format 1 file with one track exercising: tempo meta, note-on,
// running status, note-off, note-on-velocity-0 (as note-off), and end-of-track.
@(test)
test_parse_basic :: proc(t: ^testing.T) {
	bytes := []byte {
		// Header: MThd, len 6, format 1, 1 track, 96 ticks/quarter
		'M', 'T', 'h', 'd', 0x00, 0x00, 0x00, 0x06,
		0x00, 0x01, 0x00, 0x01, 0x00, 0x60,
		// Track: MTrk, length 0x19 (25 bytes)
		'M', 'T', 'r', 'k', 0x00, 0x00, 0x00, 0x19,
		0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, // tempo = 500000 us/qn (120 BPM)
		0x00, 0x90, 0x3C, 0x64,                   // note on  C4 (60) vel 100
		0x00, 0x3E, 0x64,                         // running status: note on D4 (62) vel 100
		0x60, 0x80, 0x3C, 0x40,                   // +96 ticks: note off C4
		0x00, 0x3E, 0x00,                         // running status: note on D4 vel 0 (= note off)
		0x00, 0xFF, 0x2F, 0x00,                   // end of track
	}

	file, err := midi_parse(slice.clone(bytes))
	defer midi_destroy(&file)

	testing.expect_value(t, err, MIDI_Error.None)
	testing.expect_value(t, file.format, MIDI_Format.Multi_Track)
	testing.expect(t, !file.division.is_smpte, "expected metrical division")
	testing.expect_value(t, file.division.ticks_per_quarter, u16(96))
	testing.expect_value(t, len(file.tracks), 1)

	evs := file.tracks[0].events
	testing.expect_value(t, len(evs), 6)

	tempo, ok := evs[0].data.(Set_Tempo)
	testing.expect(t, ok, "event 0 should be Set_Tempo")
	testing.expect_value(t, tempo.us_per_quarter, u32(500_000))

	on1, ok1 := evs[1].data.(Note_On)
	testing.expect(t, ok1, "event 1 should be Note_On")
	testing.expect_value(t, on1.key, u8(60))
	testing.expect_value(t, on1.velocity, u8(100))
	testing.expect_value(t, evs[1].tick, u64(0))

	on2, ok2 := evs[2].data.(Note_On) // decoded via running status
	testing.expect(t, ok2, "event 2 should be Note_On (running status)")
	testing.expect_value(t, on2.key, u8(62))

	off1, ok3 := evs[3].data.(Note_Off)
	testing.expect(t, ok3, "event 3 should be Note_Off")
	testing.expect_value(t, off1.key, u8(60))
	testing.expect_value(t, evs[3].tick, u64(96))

	// Note On with velocity 0 must decode as Note_Off.
	off2, ok4 := evs[4].data.(Note_Off)
	testing.expect(t, ok4, "event 4 should be Note_Off (note-on vel 0)")
	testing.expect_value(t, off2.key, u8(62))

	_, ok5 := evs[5].data.(End_Of_Track)
	testing.expect(t, ok5, "event 5 should be End_Of_Track")
}

// Reject a buffer whose magic number is not "MThd".
@(test)
test_bad_header :: proc(t: ^testing.T) {
	bytes := []byte{'X', 'X', 'X', 'X', 0, 0, 0, 6}
	file, err := midi_parse(slice.clone(bytes))
	defer midi_destroy(&file)
	testing.expect_value(t, err, MIDI_Error.Bad_Header)
}

// Decode an SMPTE time division (negative frame rate in the high byte).
@(test)
test_smpte_division :: proc(t: ^testing.T) {
	bytes := []byte {
		'M', 'T', 'h', 'd', 0x00, 0x00, 0x00, 0x06,
		0x00, 0x00, 0x00, 0x01, 0xE2, 0x28, // -30 fps, 40 ticks/frame
		'M', 'T', 'r', 'k', 0x00, 0x00, 0x00, 0x04,
		0x00, 0xFF, 0x2F, 0x00,
	}
	file, err := midi_parse(slice.clone(bytes))
	defer midi_destroy(&file)
	testing.expect_value(t, err, MIDI_Error.None)
	testing.expect(t, file.division.is_smpte, "expected SMPTE division")
	testing.expect_value(t, file.division.fps, u8(30))
	testing.expect_value(t, file.division.ticks_per_frame, u8(40))
}
