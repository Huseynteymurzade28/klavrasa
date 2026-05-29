package resonance

// MIDI binary parser, implemented from scratch (no external MIDI libraries).
//
// Supports Standard MIDI File Format 0 (single track) and Format 1 (multiple
// synchronous tracks). Handles variable-length quantities, running status,
// meta events (tempo, time/key signature, text), and SysEx events.
//
// Memory model: `MIDI_File` owns the raw file bytes in `raw`. SysEx and text
// payloads are zero-copy slices into `raw`, so they stay valid for the lifetime
// of the file. Call `midi_destroy` to release everything.

import "core:os"

// --- Public data model ------------------------------------------------------

MIDI_Format :: enum u16 {
	Single_Track = 0, // Format 0: one track containing all channels
	Multi_Track  = 1, // Format 1: multiple synchronous tracks
	Multi_Song   = 2, // Format 2: multiple independent sequences
}

// Time division: either ticks-per-quarter-note (metrical) or SMPTE (absolute).
Time_Division :: struct {
	is_smpte:          bool,
	ticks_per_quarter: u16, // valid when !is_smpte (lower 15 bits)
	fps:               u8,  // valid when is_smpte: 24, 25, 29 (drop), or 30
	ticks_per_frame:   u8,  // valid when is_smpte
}

// --- Event payloads (one variant per MIDI message of interest) --------------

Note_On          :: struct { channel, key, velocity: u8 }
Note_Off         :: struct { channel, key, velocity: u8 }
Poly_Pressure    :: struct { channel, key, pressure: u8 }
Control_Change   :: struct { channel, controller, value: u8 }
Program_Change   :: struct { channel, program: u8 }
Channel_Pressure :: struct { channel, pressure: u8 }
Pitch_Bend       :: struct { channel: u8, value: i16 } // -8192..=8191, 0 = center

Set_Tempo      :: struct { us_per_quarter: u32 } // microseconds per quarter note
Time_Signature :: struct { numerator, denominator, clocks_per_click, notated_32nd_per_quarter: u8 }
Key_Signature  :: struct { sharps_flats: i8, minor: bool }
End_Of_Track   :: struct {}
Meta_Text      :: struct { kind: u8, text: string } // kind 0x01..=0x0F; text aliases `raw`
Sysex          :: struct { data: []byte } // aliases `raw`
Unknown_Meta   :: struct { kind: u8, data: []byte } // aliases `raw`

Event_Data :: union {
	Note_On, Note_Off, Poly_Pressure, Control_Change, Program_Change,
	Channel_Pressure, Pitch_Bend,
	Set_Tempo, Time_Signature, Key_Signature, End_Of_Track,
	Meta_Text, Sysex, Unknown_Meta,
}

Event :: struct {
	delta: u32,        // delta ticks since previous event in this track
	tick:  u64,        // absolute tick from start of track (accumulated)
	data:  Event_Data,
}

Track :: struct {
	events: [dynamic]Event,
}

MIDI_File :: struct {
	format:   MIDI_Format,
	division: Time_Division,
	tracks:   []Track,
	raw:      []byte, // owned; payload slices point into this
}

MIDI_Error :: enum {
	None,
	File_Read_Failed,
	Bad_Header,
	Bad_Track_Header,
	Unexpected_EOF,
	Bad_Running_Status,
}

// --- Byte reader ------------------------------------------------------------

Reader :: struct {
	data: []byte,
	pos:  int,
}

@(private = "file")
read_u8 :: proc(r: ^Reader) -> (val: u8, ok: bool) {
	if r.pos >= len(r.data) do return 0, false
	val = r.data[r.pos]
	r.pos += 1
	return val, true
}

@(private = "file")
read_u16 :: proc(r: ^Reader) -> (val: u16, ok: bool) {
	hi := read_u8(r) or_return
	lo := read_u8(r) or_return
	return u16(hi) << 8 | u16(lo), true
}

@(private = "file")
read_u32 :: proc(r: ^Reader) -> (val: u32, ok: bool) {
	b0 := read_u8(r) or_return
	b1 := read_u8(r) or_return
	b2 := read_u8(r) or_return
	b3 := read_u8(r) or_return
	return u32(b0) << 24 | u32(b1) << 16 | u32(b2) << 8 | u32(b3), true
}

@(private = "file")
read_bytes :: proc(r: ^Reader, n: int) -> (val: []byte, ok: bool) {
	if n < 0 || r.pos + n > len(r.data) do return nil, false
	val = r.data[r.pos : r.pos + n]
	r.pos += n
	return val, true
}

// Variable-length quantity: 7 data bits per byte, high bit = "more follow".
// Capped at 4 bytes per the SMF spec.
@(private = "file")
read_vlq :: proc(r: ^Reader) -> (val: u32, ok: bool) {
	for _ in 0 ..< 4 {
		b := read_u8(r) or_return
		val = val << 7 | u32(b & 0x7F)
		if b & 0x80 == 0 do return val, true
	}
	return val, true
}

// --- Parsing ----------------------------------------------------------------

// Load and parse a Standard MIDI File from disk. On success the caller owns the
// returned file and must call `midi_destroy`. On error a zeroed file is
// returned and any partially read data is freed.
midi_load :: proc(path: string) -> (file: MIDI_File, err: MIDI_Error) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil do return {}, .File_Read_Failed

	// midi_parse takes ownership of `data` and frees it on error.
	return midi_parse(data)
}

// Parse a Standard MIDI File from an in-memory buffer. Takes ownership of
// `data`: on success it is stored in `file.raw`; on error it is freed.
midi_parse :: proc(data: []byte) -> (file: MIDI_File, err: MIDI_Error) {
	r := Reader{data = data}

	magic, ok := read_bytes(&r, 4)
	if !ok || string(magic) != "MThd" {
		delete(data)
		return {}, .Bad_Header
	}

	hdr_len   := read_u32(&r) or_else 0
	fmt_raw   := read_u16(&r) or_else 0
	ntrks     := read_u16(&r) or_else 0
	div_raw   := read_u16(&r) or_else 0
	if hdr_len < 6 {
		delete(data)
		return {}, .Bad_Header
	}

	// Skip any extra header bytes beyond the standard 6 (forward compatible).
	if hdr_len > 6 {
		r.pos += int(hdr_len) - 6
	}

	file.raw = data
	file.format = MIDI_Format(fmt_raw)
	if div_raw & 0x8000 == 0 {
		file.division = {is_smpte = false, ticks_per_quarter = div_raw & 0x7FFF}
	} else {
		// High byte is a negative SMPTE frame rate; low byte is ticks/frame.
		file.division = {
			is_smpte        = true,
			fps             = u8(-i8(div_raw >> 8)),
			ticks_per_frame = u8(div_raw & 0xFF),
		}
	}

	tracks := make([dynamic]Track, 0, int(ntrks))
	for _ in 0 ..< ntrks {
		tmagic, tok := read_bytes(&r, 4)
		if !tok do break // tolerate a header that over-counts tracks
		if string(tmagic) != "MTrk" do return midi_partial_fail(tracks, file.raw, .Bad_Track_Header)

		tlen, lok := read_u32(&r)
		if !lok do return midi_partial_fail(tracks, file.raw, .Unexpected_EOF)

		track_data, dok := read_bytes(&r, int(tlen))
		if !dok do return midi_partial_fail(tracks, file.raw, .Unexpected_EOF)

		track, terr := parse_track(track_data)
		if terr != .None {
			delete(track.events)
			return midi_partial_fail(tracks, file.raw, terr)
		}
		append(&tracks, track)
	}

	file.tracks = tracks[:]
	return file, .None
}

@(private = "file")
midi_partial_fail :: proc(tracks: [dynamic]Track, raw: []byte, err: MIDI_Error) -> (MIDI_File, MIDI_Error) {
	for t in tracks do delete(t.events)
	delete(tracks)
	delete(raw)
	return {}, err
}

// Parse the event stream of a single MTrk chunk. `data` is the track body only
// (length already consumed by the caller). On error the partially built event
// list is freed before returning.
@(private = "file")
parse_track :: proc(data: []byte) -> (track: Track, err: MIDI_Error) {
	r := Reader{data = data}
	track.events = make([dynamic]Event)
	defer if err != .None do delete(track.events)

	running_status: u8 // last channel status byte, for running-status decoding
	abs_tick: u64

	for r.pos < len(r.data) {
		delta, ok := read_vlq(&r)
		if !ok do return track, .Unexpected_EOF
		abs_tick += u64(delta)

		status, sok := read_u8(&r)
		if !sok do return track, .Unexpected_EOF

		ev := Event{delta = delta, tick = abs_tick}

		switch {
		case status == 0xFF:
			// Meta event: 0xFF, type byte, VLQ length, payload.
			running_status = 0
			meta_type, mok := read_u8(&r)
			length, lok := read_vlq(&r)
			if !mok || !lok do return track, .Unexpected_EOF
			payload, pok := read_bytes(&r, int(length))
			if !pok do return track, .Unexpected_EOF
			ev.data = decode_meta(meta_type, payload)

		case status == 0xF0 || status == 0xF7:
			// SysEx event (normal or escape): VLQ length, payload.
			running_status = 0
			length, lok := read_vlq(&r)
			if !lok do return track, .Unexpected_EOF
			payload, pok := read_bytes(&r, int(length))
			if !pok do return track, .Unexpected_EOF
			ev.data = Sysex{data = payload}

		case:
			// Channel voice message, possibly using running status.
			data1: u8
			if status & 0x80 != 0 {
				running_status = status
				d1, dok := read_u8(&r)
				if !dok do return track, .Unexpected_EOF
				data1 = d1
			} else {
				// No status byte: this byte is the first data byte and we
				// reuse the previous channel status.
				if running_status == 0 do return track, .Bad_Running_Status
				data1 = status
				status = running_status
			}
			edata, derr := decode_channel(&r, status, data1)
			if derr != .None do return track, derr
			ev.data = edata
		}

		append(&track.events, ev)
	}

	return track, .None
}

// Decode a channel voice message. `data1` (the first data byte) has already
// been read; this consumes the second data byte where the message needs one.
@(private = "file")
decode_channel :: proc(r: ^Reader, status, data1: u8) -> (Event_Data, MIDI_Error) {
	channel := status & 0x0F
	switch status & 0xF0 {
	case 0x80:
		vel, ok := read_u8(r)
		if !ok do return nil, .Unexpected_EOF
		return Note_Off{channel, data1, vel}, .None
	case 0x90:
		vel, ok := read_u8(r)
		if !ok do return nil, .Unexpected_EOF
		// Note On with velocity 0 is conventionally a Note Off.
		if vel == 0 do return Note_Off{channel, data1, 0}, .None
		return Note_On{channel, data1, vel}, .None
	case 0xA0:
		pressure, ok := read_u8(r)
		if !ok do return nil, .Unexpected_EOF
		return Poly_Pressure{channel, data1, pressure}, .None
	case 0xB0:
		value, ok := read_u8(r)
		if !ok do return nil, .Unexpected_EOF
		return Control_Change{channel, data1, value}, .None
	case 0xC0:
		return Program_Change{channel, data1}, .None // single data byte
	case 0xD0:
		return Channel_Pressure{channel, data1}, .None // single data byte
	case 0xE0:
		msb, ok := read_u8(r)
		if !ok do return nil, .Unexpected_EOF
		bend := i16(u16(msb) << 7 | u16(data1)) - 8192
		return Pitch_Bend{channel, bend}, .None
	}
	return nil, .Bad_Running_Status
}

@(private = "file")
decode_meta :: proc(meta_type: u8, payload: []byte) -> Event_Data {
	switch meta_type {
	case 0x2F:
		return End_Of_Track{}
	case 0x51:
		if len(payload) >= 3 {
			us := u32(payload[0]) << 16 | u32(payload[1]) << 8 | u32(payload[2])
			return Set_Tempo{us}
		}
	case 0x58:
		if len(payload) >= 4 {
			return Time_Signature{payload[0], payload[1], payload[2], payload[3]}
		}
	case 0x59:
		if len(payload) >= 2 {
			return Key_Signature{i8(payload[0]), payload[1] != 0}
		}
	case 0x01 ..= 0x0F:
		return Meta_Text{meta_type, string(payload)}
	}
	return Unknown_Meta{meta_type, payload}
}

// Free everything owned by a parsed file.
midi_destroy :: proc(file: ^MIDI_File) {
	for t in file.tracks do delete(t.events)
	delete(file.tracks)
	delete(file.raw)
	file^ = {}
}
