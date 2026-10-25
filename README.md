# Tide

An audio-reactive media visualizer for the [Omarchy](https://omarchy.org/) bar, with a floating player and a companion synced-lyrics widget.

Tide is a fork of [Music Flow](https://github.com/Rajesh-bandi/music-flow) by Rajesh Bandi — itself a community derivative of [Clifford Baidoo's omarchy-music-flow](https://github.com/Clifford-Baidoo/omarchy-music-flow). The original MIT notice is retained; the UI, visualizer modes, player popup, volume control and lyrics widget were redesigned and extended here.

## Features

- **Five visualizer modes** in the bar capsule — `wave`, `bars`, `dots`, `particles`, `pulse` — with amplitude driven by the active player's real PipeWire peak level.
- **Floating player**: artwork backdrop, seekable waveform, transport controls, per-app volume vial, and a source switcher that transfers playback when you change players.
- **Synced lyrics** as an independently positionable companion widget: LRCLIB lookup, duration-ranked record selection, per-word highlighting, multi-timestamp LRC support.
- **Settings persist** in `~/.config/omarchy/shell.json` per bar entry (`visualizerMode`, `showText`).
- **IPC** for scripting: `omarchy-shell media …` (transport, volume, sources) and `omarchy-shell flow …` (visualizer mode, text).

When a player's PipeWire stream exposes no usable channel map (Spotify does this), the peak meter falls back to the default sink monitor, so the visualizer still follows the music; on Bluetooth outputs that fallback stays off to avoid A2DP→HFP profile switching.

## Install

```bash
omarchy plugin add https://github.com/elliotalien/tide --enable
~/.config/omarchy/plugins/io.github.elliotalien.tide/install.sh
```

The plugin manager only clones the repository, so the second step is what installs the **Tide Lyrics** companion next to the main plugin, validates both manifests and registers them in your bar.

## Usage

- **Left click** the capsule: open the player. **Right click**: toggle title text. **Middle click**: play/pause. **Scroll**: previous/next.
- **Lyrics**: the lyrics button in the player, or `omarchy-shell io.github.elliotalien.tide-lyrics toggle`.
- **Visualizer mode**: `qs -p /usr/share/omarchy/shell ipc call flow setMode bars` (or `wave`, `dots`, `particles`, `pulse`).
- **Status**: `omarchy-shell media status`, `omarchy-shell media sources`.

## Requirements

Omarchy with Quickshell 0.3.x, PipeWire, `curl` and `python3` (used for artwork validation and the audio-level fallback).

## Credits

- [Clifford Baidoo](https://github.com/Clifford-Baidoo) — original omarchy-music-flow
- [Rajesh Bandi](https://github.com/Rajesh-bandi) — Music Flow fork with synced lyrics
- [elliotalien](https://github.com/elliotalien) — Tide: visual redesign, visualizer modes, player popup, volume vial, lyrics widget rework, bug fixes

## License

MIT — see [LICENSE](LICENSE).

Spotify controls use the running player's standard MPRIS interface; no Spotify Premium or subscription features are involved.
