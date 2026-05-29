package resonance

// Polyphonic sine-wave synthesizer driven by note-on / note-off calls.
//
// Audio runs on its own real-time sample clock (so pitch is always correct);
// the playback engine just calls `audio_note_on` / `audio_note_off` as the song
// clock crosses each event. A short attack/release envelope avoids clicks, and
// the summed voices pass through a soft clipper so dense chords don't distort.

import "core:math"
import rl "vendor:raylib"

SAMPLE_RATE  :: 44_100
MAX_VOICES   :: 64
AUDIO_FRAMES :: 1024 // samples generated per stream refill

Voice_State :: enum {
	Off,
	Attack,
	Sustain,
	Release,
}

Voice :: struct {
	state: Voice_State,
	key:   u8,
	track: int,
	freq:  f32,
	phase: f32, // 0..1 cycles
	gain:  f32,
	env:   f32, // current envelope level 0..1
}

Audio :: struct {
	stream:       rl.AudioStream,
	voices:       [MAX_VOICES]Voice,
	buffer:       [AUDIO_FRAMES]f32,
	attack_rate:  f32,
	release_rate: f32,
	master:       f32,
}

audio_init :: proc(a: ^Audio) {
	rl.InitAudioDevice()
	rl.SetAudioStreamBufferSizeDefault(AUDIO_FRAMES)
	a.stream = rl.LoadAudioStream(SAMPLE_RATE, 32, 1) // 32-bit float, mono
	a.attack_rate = 1.0 / (f32(SAMPLE_RATE) * 0.005)  // ~5 ms attack
	a.release_rate = 1.0 / (f32(SAMPLE_RATE) * 0.120) // ~120 ms release
	a.master = 0.6
	rl.PlayAudioStream(a.stream)
}

audio_shutdown :: proc(a: ^Audio) {
	rl.StopAudioStream(a.stream)
	rl.UnloadAudioStream(a.stream)
	rl.CloseAudioDevice()
}

audio_note_on :: proc(a: ^Audio, key, velocity: u8, track: int) {
	idx := -1
	for v, i in a.voices {
		if v.state == .Off {
			idx = i
			break
		}
	}
	if idx < 0 {
		// All voices busy: steal the quietest one.
		lowest := max(f32)
		for v, i in a.voices {
			if v.env < lowest {
				lowest = v.env
				idx = i
			}
		}
	}

	v := &a.voices[idx]
	v.state = .Attack
	v.key = key
	v.track = track
	v.freq = key_to_freq(key)
	v.phase = 0
	v.gain = f32(velocity) / 127.0 * 0.25
	v.env = 0
}

audio_note_off :: proc(a: ^Audio, key: u8, track: int) {
	for &v in a.voices {
		if v.state != .Off && v.state != .Release && v.key == key && v.track == track {
			v.state = .Release
			return
		}
	}
}

audio_all_off :: proc(a: ^Audio) {
	for &v in a.voices do v.state = .Off
}

// Refill any drained stream buffers. Call once per frame.
audio_update :: proc(a: ^Audio) {
	for rl.IsAudioStreamProcessed(a.stream) {
		for i in 0 ..< AUDIO_FRAMES {
			a.buffer[i] = audio_next_sample(a)
		}
		rl.UpdateAudioStream(a.stream, &a.buffer[0], AUDIO_FRAMES)
	}
}

@(private = "file")
audio_next_sample :: proc(a: ^Audio) -> f32 {
	mix: f32 = 0
	for &v in a.voices {
		if v.state == .Off do continue

		switch v.state {
		case .Off:
		case .Attack:
			v.env += a.attack_rate
			if v.env >= 1 {
				v.env = 1
				v.state = .Sustain
			}
		case .Sustain:
		case .Release:
			v.env -= a.release_rate
			if v.env <= 0 {
				v.env = 0
				v.state = .Off
				continue
			}
		}

		mix += math.sin(v.phase * 2 * math.PI) * v.env * v.gain
		v.phase += v.freq / f32(SAMPLE_RATE)
		if v.phase >= 1 do v.phase -= 1
	}

	out := mix * a.master
	return out / (1 + abs(out)) // soft clip into (-1, 1)
}
