package klavrasa

// Polyphonic synthesizer driven by note-on / note-off calls.
//
// Audio runs on its own real-time sample clock (so pitch is always correct);
// the playback engine just calls `audio_note_on` / `audio_note_off` as the song
// clock crosses each event. Every voice runs through an ADSR envelope whose
// timings come from the selected waveform preset, and the summed voices pass
// through a soft clipper so dense chords don't distort.

import "core:math"
import rl "vendor:raylib"

SAMPLE_RATE  :: 44_100
MAX_VOICES   :: 64
AUDIO_FRAMES :: 1024 // samples generated per stream refill

Waveform :: enum {
	Piano,
	Sine,
	Triangle,
	Square,
	Saw,
}

WAVEFORM_NAMES := [Waveform]cstring {
	.Piano    = "Piano",
	.Sine     = "Sine",
	.Triangle = "Triangle",
	.Square   = "Square",
	.Saw      = "Saw",
}

// Envelope timings (seconds) and levels (0..1) for a waveform preset.
Preset :: struct {
	attack:  f32,
	decay:   f32,
	sustain: f32,
	release: f32,
	gain:    f32, // per-voice loudness trim, so presets sit at similar volume
}

WAVE_PRESETS := [Waveform]Preset {
	.Piano    = {0.003, 1.40, 0.00, 0.25, 0.30},
	.Sine     = {0.005, 0.30, 0.70, 0.15, 0.28},
	.Triangle = {0.008, 0.40, 0.65, 0.18, 0.30},
	.Square   = {0.006, 0.15, 0.55, 0.12, 0.13},
	.Saw      = {0.010, 0.25, 0.60, 0.15, 0.14},
}

Voice_State :: enum {
	Off,
	Attack,
	Decay,
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
	wave:         Waveform,
	// Per-sample envelope coefficients derived from the active preset.
	attack_rate:  f32, // linear rise per sample
	decay_mul:    f32, // exponential approach toward the sustain level
	sustain:      f32,
	release_rate: f32, // linear fall per sample
	voice_gain:   f32,
	master:       f32,
}

audio_init :: proc(a: ^Audio) {
	rl.InitAudioDevice()
	rl.SetAudioStreamBufferSizeDefault(AUDIO_FRAMES)
	a.stream = rl.LoadAudioStream(SAMPLE_RATE, 32, 1) // 32-bit float, mono
	a.master = 0.6
	audio_set_waveform(a, .Piano)
	rl.PlayAudioStream(a.stream)
}

audio_shutdown :: proc(a: ^Audio) {
	rl.StopAudioStream(a.stream)
	rl.UnloadAudioStream(a.stream)
	rl.CloseAudioDevice()
}

// Switch waveform preset. Sounding voices keep playing and simply adopt the
// new timbre and envelope rates.
audio_set_waveform :: proc(a: ^Audio, w: Waveform) {
	p := WAVE_PRESETS[w]
	sr := f32(SAMPLE_RATE)
	a.wave = w
	a.attack_rate = 1.0 / (sr * max(p.attack, 0.001))
	// Three time constants over `decay` seconds: ~95% of the way to sustain.
	a.decay_mul = math.exp(-3.0 / (sr * max(p.decay, 0.001)))
	a.sustain = p.sustain
	a.release_rate = 1.0 / (sr * max(p.release, 0.001))
	a.voice_gain = p.gain
}

audio_next_waveform :: proc(a: ^Audio) -> Waveform {
	next := Waveform((int(a.wave) + 1) % len(Waveform))
	audio_set_waveform(a, next)
	return next
}

audio_set_master :: proc(a: ^Audio, v: f32) {
	a.master = clamp(v, 0, 1)
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

	// A gently curved velocity response: soft notes stay soft, loud ones pop.
	vel := f32(velocity) / 127.0
	v := &a.voices[idx]
	v.state = .Attack
	v.key = key
	v.track = track
	v.freq = key_to_freq(key)
	v.phase = 0
	v.gain = (0.25 + 0.75 * vel * vel) * a.voice_gain
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

// Release every sounding voice belonging to `track` (used when muting).
audio_release_track :: proc(a: ^Audio, track: int) {
	for &v in a.voices {
		if v.state != .Off && v.state != .Release && v.track == track {
			v.state = .Release
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
				v.state = .Decay
			}
		case .Decay:
			v.env = a.sustain + (v.env - a.sustain) * a.decay_mul
			if v.env - a.sustain < 0.002 {
				v.env = a.sustain
				// A fully-decayed percussive voice is silent: free it early.
				if a.sustain <= 0.001 {
					v.state = .Off
					continue
				}
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

		dt := v.freq / f32(SAMPLE_RATE)
		mix += oscillator(a.wave, v.phase, dt, v.env) * v.env * v.gain
		v.phase += dt
		if v.phase >= 1 do v.phase -= 1
	}

	out := mix * a.master
	return out / (1 + abs(out)) // soft clip into (-1, 1)
}

// One sample of the chosen waveform at phase `t` (0..1). `dt` is the phase
// increment per sample, used to band-limit the discontinuous shapes. `env` is
// the envelope level, which the piano preset uses to darken the tone as it
// decays, the way a real string loses its upper partials first.
@(private = "file")
oscillator :: proc(w: Waveform, t, dt, env: f32) -> f32 {
	switch w {
	case .Sine:
		return math.sin(t * 2 * math.PI)
	case .Triangle:
		return 4 * abs(t - 0.5) - 1
	case .Saw:
		return (2 * t - 1) - poly_blep(t, dt)
	case .Square:
		v: f32 = t < 0.5 ? 1 : -1
		v += poly_blep(t, dt)
		t2 := t + 0.5
		if t2 >= 1 do t2 -= 1
		return v - poly_blep(t2, dt)
	case .Piano:
		p := t * 2 * math.PI
		bright := 0.35 + 0.65 * env
		return (math.sin(p) +
			math.sin(2 * p) * 0.50 * bright +
			math.sin(3 * p) * 0.25 * bright +
			math.sin(4 * p) * 0.12 * bright * bright +
			math.sin(5 * p) * 0.06 * bright * bright) / 1.6
	}
	return 0
}

// Polynomial band-limited step: smooths the jump in saw/square waves so they
// don't alias into harsh high-frequency noise.
@(private = "file")
poly_blep :: proc(t, dt: f32) -> f32 {
	if t < dt {
		x := t / dt
		return x + x - x * x - 1
	} else if t > 1 - dt {
		x := (t - 1) / dt
		return x * x + x + x + 1
	}
	return 0
}

// Is a voice for this key/track currently held (not off or releasing)?
audio_is_sounding :: proc(a: ^Audio, key: u8, track: int) -> bool {
	for v in a.voices {
		if v.state != .Off && v.state != .Release && v.key == key && v.track == track do return true
	}
	return false
}
