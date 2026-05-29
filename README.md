# Resonance

A MIDI piano-roll visualizer written in [Odin](https://odin-lang.org/) using [Raylib](https://www.raylib.com/).

Resonance loads Standard MIDI Files and renders them as a falling-note piano roll
with real-time audio playback via sine-wave synthesis. The MIDI parser is written
from scratch — no external MIDI libraries.

## Requirements

- [Odin compiler](https://odin-lang.org/docs/install/) (the `vendor:raylib`
  bindings ship with Odin, so Raylib needs no separate install)
- A desktop OS with OpenGL (developed on Linux / Arch)

## Build & Run

```sh
# Run directly (compiles to a temp binary, then runs)
odin run .

# …optionally with a file to load on startup
odin run . -- song.mid

# Or build a standalone binary
odin build . -out:resonance
./resonance song.mid
```

Once the window is open, **drag and drop** any `.mid` file onto it to load it.
A summary of the parsed file (format, division, tracks, note counts, tempo) is
printed to the console — handy for verifying the parser against real files.

A tiny test file is included at [`assets/sample.mid`](assets/sample.mid):

```sh
odin run . -- assets/sample.mid
```

## Testing

The MIDI parser has a unit-test suite (hand-built byte streams covering tempo
meta events, running status, note-on-velocity-0, SMPTE division, and malformed
headers):

```sh
odin test .
```

## Project structure

```
resonance/
├── main.odin        # entry point: window, drag-and-drop, parser harness
├── midi.odin        # MIDI binary parser (Format 0 & 1)
├── midi_test.odin   # parser unit tests
├── piano_roll.odin  # falling-note rendering + keyboard   (planned)
├── audio.odin       # sine-wave synthesis + mixing         (planned)
├── ui.odin          # BPM display, speed controls          (planned)
└── assets/
    └── sample.mid   # small test file
```

## Roadmap

- [x] **MIDI parser** — Format 0/1, variable-length quantities, running status,
      note on/off, velocity, delta/absolute ticks, tempo & meta events, SysEx
- [ ] **Piano-roll renderer** — falling note blocks, 88-key keyboard, per-octave colors
- [ ] **Multi-track rendering** — one color per track, layered
- [ ] **Audio playback** — sine-wave synthesis (equal temperament, A4 = 440 Hz), polyphonic mixing
- [ ] **Playback controls** — 0.5×/1×/2× speed, pause/resume, BPM display
- [ ] **Drag-and-drop** loading at runtime

## License

MIT
