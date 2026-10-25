<div align="center">

# 🌊 Tide

**An audio-reactive media visualizer for the Omarchy bar — playback, artwork and synced lyrics in one capsule.**

[![License](https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Omarchy-6aa6f8?style=flat-square)](https://omarchy.org/)
[![Quickshell](https://img.shields.io/badge/Quickshell-0.3.x-1f6feb?style=flat-square)](https://quickshell.org/)
[![PipeWire](https://img.shields.io/badge/audio-PipeWire-e5484d?style=flat-square)](https://pipewire.org/)

</div>

Tide lives in your bar as a small, living waveform: it breathes with the music, opens into a full player when you click it, and can hand the current track's lyrics to a second, independently positioned widget. It talks to any MPRIS player and reads real PipeWire peak levels, so the animation follows what you actually hear rather than a fixed loop.

## ✨ Features

| | |
|---|---|
| 🌊 **Five visualizer modes** | `wave`, `bars`, `dots`, `particles` and `pulse`, all driven by the active player's live audio level. |
| 🎛 **Floating player** | Album-art backdrop, seekable waveform, transport controls, per-app volume vial and a source switcher that hands playback over when you change players. |
| 🎤 **Synced lyrics** | A companion bar widget fetching from LRCLIB: duration-ranked matching, per-word highlighting, multi-timestamp LRC support, automatic fold-away when no lyrics exist. |
| 💾 **Persistent settings** | Visualizer mode and text visibility are stored per widget in `~/.config/omarchy/shell.json` and survive restarts. |
| 🔌 **Scriptable** | Every action is reachable over IPC — transport, volume, source switching, visualizer mode. |
| 🩹 **Honest audio levels** | When a stream exposes no usable channel map (Spotify), the meter falls back to the default sink monitor instead of freezing at zero — and stays off on Bluetooth to avoid A2DP→HFP profile switching. |

## 🚀 Install

```bash
# 1. Clone and enable the plugin
omarchy plugin add https://github.com/elliotalien/tide --enable

# 2. Install the Tide Lyrics companion (the plugin manager only clones)
~/.config/omarchy/plugins/io.github.elliotalien.tide/install.sh
```

The installer validates both manifests, places **Tide** and **Tide Lyrics** in your bar and disables the stock `omarchy.media` widget so the two services don't compete.

## 🎛 Usage

| Gesture | Action |
|---|---|
| **Left click** | Open the player popup |
| **Right click** | Toggle the track text on the bar |
| **Middle click** | Play / pause |
| **Scroll** | Previous / next track |

The popup carries artwork, a click-to-seek waveform, transport buttons, a hover volume vial and one tile per detected source. The lyrics button opens **Tide Lyrics** beside it.

## ⚙️ Configuration

Both settings live in this widget's entry in `~/.config/omarchy/shell.json` and can be changed live:

| Key | Default | Values |
|---|---|---|
| `visualizerMode` | `wave` | `wave`, `bars`, `dots`, `particles`, `pulse` |
| `showText` | `true` | `true`, `false` |

```jsonc
{
  "id": "io.github.elliotalien.tide",
  "visualizerMode": "wave",
  "showText": false
}
```

## 🔌 IPC

**Media** — `omarchy-shell media <command>`:

| Command | Description |
|---|---|
| `status` | JSON snapshot: track, artist, art URL, position, level, capabilities |
| `sources` | Detected players with playback state and stream counts |
| `playPause` · `play` · `pause` | Transport |
| `next` · `previous` | Track skipping |
| `sourceNext` · `sourcePrevious` | Cycle sources without transferring playback |
| `sourceSwitch` · `sourceSwitchPrevious` | Cycle sources and move playback with them |
| `volumeUp` · `volumeDown` · `setVolume <0-1>` · `toggleMute` | Per-app volume |

**Visualizer** — `qs -p /usr/share/omarchy/shell ipc call flow <command>`:

| Command | Description |
|---|---|
| `getMode` · `setMode <mode>` | Read or change the visualizer mode |
| `getShowText` · `setShowText <on\|off>` | Read or change bar text |

## 🧩 How the audio level works

Tide first tries Quickshell's `PwNodePeakMonitor` on the player's own stream. Some streams (Spotify) map their channels as `Unknown`, which that monitor cannot read — it reports a flat zero and logs an error per sample. For those, Tide captures the default sink's monitor with `pw-record` and computes the peak itself, throttled to run only while a track is playing. On a Bluetooth sink that fallback is deliberately disabled, since capturing the output can force the headset out of A2DP into the mono HFP profile.

## 📦 Project layout

```
io.github.elliotalien.tide/
├── BarWidget.qml          bar capsule, popup and visualizer canvases
├── Service.qml            MPRIS + PipeWire service (single source of truth)
├── MediaModel.js          pure helpers: matching, cleaning, artwork, lyrics queries
├── manifest.json          plugin manifest (service + bar widget)
├── lyrics-mic.svg         lyrics button glyph
├── install.sh             installer, also drops the lyrics companion
├── update.sh              in-place update for git installs
├── uninstall.sh           removes both plugins and restores the stock widget
├── scripts/configure_bar.py   shared shell.json layout editor
└── companions/synced-lyrics/  Tide Lyrics widget + manifest template
```

## 🙏 Credits

- [Clifford Baidoo](https://github.com/Clifford-Baidoo) — original [omarchy-music-flow](https://github.com/Clifford-Baidoo/omarchy-music-flow)
- [Rajesh Bandi](https://github.com/Rajesh-bandi) — Music Flow fork with synced lyrics
- [elliotalien](https://github.com/elliotalien) — Tide: visual redesign, visualizer modes, player popup, volume vial, lyrics widget rework and bug fixes

## 📄 License

[MIT](LICENSE) — the original copyright notices are retained.

Spotify controls use the running player's standard MPRIS interface; no subscription features are involved.
