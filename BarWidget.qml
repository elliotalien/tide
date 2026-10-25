import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons
import "MediaModel.js" as MediaModel

BarWidget {
  id: root
  moduleName: "io.github.elliotalien.tide"

  property var service: null

  // Circular transport control used by the player popup.
  component TransportButton: BorderSurface {
    id: transportButton
    required property string glyph
    // Optional SVG artwork (file:// url) rendered instead of the font glyph,
    // e.g. Spotify's lyrics-mic icon. Colorized to follow the text colour.
    property string glyphIcon: ""
    // iconExtent must match the paired FONT glyph's ink size (e.g. the
    // volume button next to the lyrics one) or the two read at different
    // sizes on the same row.
    property real iconExtent: primary ? Style.space(18) : Math.round(Style.font.body * 0.9)
    property bool primary: false
    // Secondary buttons can opt out of the outline (e.g. prev/next are shown
    // as bare glyphs); primary is always borderless.
    property bool bordered: true
    signal activated()

    width: primary ? Style.space(42) : Style.space(32)
    height: width
    // Row only aligns children's tops; anchor so mixed sizes (42px primary
    // vs 32px secondary) share one vertical centre line.
    anchors.verticalCenter: parent.verticalCenter
    radius: width / 2
    color: !enabled ? "transparent"
      : primary ? (transportHover.containsMouse ? Qt.lighter(Color.accent, 1.12) : Color.accent)
      : (transportHover.containsMouse ? Style.hoverFillFor(popup.fg, Color.accent) : "transparent")
    borderSpec: primary || !enabled || !bordered ? Border.none() : Border.controlSpec("normal", popup.fg, Color.accent)
    opacity: enabled ? 1.0 : 0.35

    Behavior on color { ColorAnimation { duration: 140 } }

    // SVG icon when provided (original app artwork, tinted to the button's
    // text colour); the font glyph only renders when the image can't load.
    Image {
      id: transportIcon
      anchors.centerIn: parent
      source: transportButton.glyphIcon
      visible: transportButton.glyphIcon.length > 0 && status === Image.Ready
      fillMode: Image.PreserveAspectFit
      sourceSize.width: Math.round(width * Screen.devicePixelRatio)
      sourceSize.height: Math.round(height * Screen.devicePixelRatio)
      width: transportButton.iconExtent
      height: width
    }

    Text {
      anchors.centerIn: parent
      visible: !transportIcon.visible
      text: transportButton.glyph
      textFormat: Text.PlainText
      color: transportButton.primary ? Color.background : popup.fg
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: transportButton.primary ? Style.font.iconLarge : Style.font.body
      font.bold: true
    }

    MouseArea {
      id: transportHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: transportButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: transportButton.activated()
    }
  }

  // ------------------------------------------------------------------
  // Persisted visualizer preferences.
  //
  // These must survive shell restarts and widget repositioning, so they are
  // round-tripped through this widget's inline bar-layout entry in
  // ~/.config/omarchy/shell.json - the same per-widget settings mechanism the
  // bar host already uses for e.g. clock formats (base BarWidget.setting(),
  // Bar.qml injects/patched on config reload, PluginShellApi.updateEntryInline
  // persists). Explicit write gates below mark each binding as user-owned so
  // a shell.json reload mid-session applies changed values without clobbering
  // ones the user just clicked in an unwatched instance.
  // ------------------------------------------------------------------

  // "wave", "bars", "dots", "particles", "pulse"
  property string visualizerMode: "wave"

  // Toggle track title / artist text in bar capsule
  property bool showText: true

  // Ordered palette for the flow canvas: a hue-rotation-ish loop whose last
  // entry blends smoothly back into the first, so the scrollable gradient the
  // visualizer paints through is seamless and reads as a color music flow.
  readonly property var flowPalette: ["#4fc3f7", "#ba68c8", "#f06292", "#ffb74d", "#4ade80"]

  function flowPaletteColor(u, alpha) {
    // u drifts in cycle units, so negative positions still wrap forward.
    var n = root.flowPalette.length
    var i = Math.floor(u)
    var f = u - i
    var t = f * f * (3 - 2 * f) // smoothstep blend between neighbor colors
    var a = Qt.color(root.flowPalette[((i % n) + n) % n])
    var b = Qt.color(root.flowPalette[(((i + 1) % n) + n) % n])
    return Qt.rgba(
      a.r + (b.r - a.r) * t,
      a.g + (b.g - a.g) * t,
      a.b + (b.b - a.b) * t,
      alpha === undefined ? 1.0 : alpha)
  }

  // Both flow settings have no visible controls (the picker and "Words ON /
  // Pure Flow" pills were removed): they are configured via terminal -
  // the inline settings in shell.json, read back by applyVisualizerSettings -
  // OR via the plugin's IpcHandler (target "flow", one call to the running
  // shell, same persistence as the removed picker tiles had). The gates hold
  // the settings watcher's readback off while an interaction persists a value.
  property bool _writeModeGate: false
  property bool _writeTextGate: false

  onVisualizerModeChanged: {
    if (!_writeModeGate) return
    _writeModeGate = false
    persistVisualizerSetting("visualizerMode", visualizerMode)
  }

  onShowTextChanged: {
    if (!_writeTextGate) return
    _writeTextGate = false
    persistVisualizerSetting("showText", showText)
  }

  // Re-apply persisted preferences whenever the bar pushes this widget's
  // inline settings (initial injection, a shell.json reload, or the live
  // settings-delta patch after our own write). Tolerates "wave"/"true" string
  // values for robustness; anything invalid falls through to the defaults.
  function applyVisualizerSettings() {
    var rawMode = root.setting("visualizerMode", null)
    var mode = (rawMode === "wave" || rawMode === "bars" || rawMode === "dots"
      || rawMode === "particles" || rawMode === "pulse") ? rawMode : "wave"
    var rawText = root.setting("showText", null)
    var text = rawText === true || rawText === "true" ? true
      : (rawText === false || rawText === "false" ? false : true)
    if (mode !== root.visualizerMode) visualizerMode = mode
    if (text !== root.showText) showText = text
  }

  onSettingsChanged: applyVisualizerSettings()

  Component.onCompleted: applyVisualizerSettings()

  // Round-trip one preference into shell.json. The write gates exist because
  // updateEntryInline -> persistShellConfig reloads shell.json, which re-pushes
  // the merged settings into every live instance (per-monitor copies included);
  // without a gate the watcher would treat our own write as an external change
  // and re-apply the previous value back over it. persistShellConfig's reload
  // is synchronous, so a function-scoped local flag would already be false by
  // the time the re-entrant settings push landed - the gate lives in a
  // property instead so it survives across those notifications.
  function persistVisualizerSetting(key, value) {
    var shellObj = root.bar ? root.bar.shell : null
    if (!shellObj || typeof shellObj.updateEntryInline !== "function") return

    var current = root.setting(key, key === "showText" ? true : "wave")
    if (current === value) return

    // updateEntryInline REPLACES the layout entry with {id} + the settings it
    // is handed, so forward every current settings key (not just our two) to
    // avoid clobbering anything else the entry carries.
    var payload = {}
    var src = root.settings
    if (src && typeof src === "object") {
      for (var k in src) if (k !== "id") payload[k] = src[k]
    }
    payload[key] = value
    if (key === "visualizerMode") _writeModeGate = true
    else if (key === "showText") _writeTextGate = true
    shellObj.updateEntryInline(root.moduleName, payload)
  }

  // Validate and apply a flow mode change, then persist it exactly like the
  // removed picker tiles did (gate -> assignment -> updateEntryInline).
  function setFlowMode(desired) {
    var m = String(desired || "").toLowerCase()
    if (m !== "wave" && m !== "bars" && m !== "dots" && m !== "particles" && m !== "pulse") return false
    // No-op assignments fire no change signal, so arming the gate first would
    // leave it stuck and make the next external settings push look like user
    // input (and get written back to shell.json).
    if (m === root.visualizerMode) return true
    _writeModeGate = true
    root.visualizerMode = m
    waveCanvas.requestPaint()
    return true
  }

  // Terminal command surface for the flow (the in-popup picker is gone):
  //   qs -p /usr/share/omarchy/shell ipc call flow setMode bars
  //   qs -p /usr/share/omarchy/shell ipc call flow getMode
  //   qs -p /usr/share/omarchy/shell ipc call flow setShowText false
  // Wrapped by ~/.local/bin/omarchy-flow for nicer naming (sparks alias etc).
  IpcHandler {
    id: flowIpc
    target: "flow"

    function ping(): string { return "ok" }

    function getMode(): string { return root.visualizerMode }

    function setMode(desired: string): string {
      return root.setFlowMode(desired) ? "ok" : "invalid"
    }

    function getShowText(): string { return root.showText ? "true" : "false" }

    function setShowText(desired: string): string {
      if (desired === "true" || desired === "1" || desired === "on") {
        if (root.showText === true) return "ok"
        _writeTextGate = true
        root.showText = true
        return "ok"
      }
      if (desired === "false" || desired === "0" || desired === "off") {
        if (root.showText === false) return "ok"
        _writeTextGate = true
        root.showText = false
        return "ok"
      }
      return "invalid"
    }
  }

  // Tide was forked from a plugin that registered itself under a per-user id
  // (${USER_NAME}.media). Keep resolving that id as a fallback so an existing
  // install of the ancestor plugin still supplies the service while the user
  // migrates. Derived from the account running the shell, not hardcoded.
  readonly property string legacyUserPluginId: {
    var u = Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""
    return u ? (u + ".media") : ""
  }

  readonly property var mediaService: {
    if (service) return service
    if (!root.bar || !root.bar.shell) return null
    if (root.moduleName && root.bar.shell.serviceFor(root.moduleName))
      return root.bar.shell.serviceFor(root.moduleName)
    if (root.legacyUserPluginId && root.bar.shell.serviceFor(root.legacyUserPluginId))
      return root.bar.shell.serviceFor(root.legacyUserPluginId)
    if (root.bar.shell.serviceFor("omarchy.media"))
      return root.bar.shell.serviceFor("omarchy.media")
    if (root.bar.shell.firstPartyServiceFor("omarchy.media"))
      return root.bar.shell.firstPartyServiceFor("omarchy.media")
    return null
  }

  function deduplicatePlayers(players) {
    var list = []
    var seen = {}
    var raw = players || []
    for (var i = 0; i < raw.length; i++) {
      var p = raw[i]
      if (!p || MediaModel.isProxyPlayer(p)) continue
      var cKey = MediaModel.playerCanonicalKey(p)
      if (!cKey || seen[cKey]) continue
      seen[cKey] = true
      if (MediaModel.hasMetadata(p)) list.push(p)
    }
    return list
  }

  readonly property var fallbackPlayers: deduplicatePlayers(Mpris.players ? Mpris.players.values : [])

  function findFallbackActivePlayer() {
    var list = fallbackPlayers || []
    var fallback = null
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!p) continue
      if (p.isPlaying) return p
      if (!fallback && (p.trackTitle || p.trackArtist || p.canPlay)) fallback = p
    }
    return fallback
  }

  // Reading mediaService.activePlayer is a direct QML property access — QML tracks
  // it as a dependency and re-evaluates when the service's activePlayer changes.
  // The fallback reads Mpris.players.values directly so isPlaying changes still propagate.
  readonly property var activePlayer: {
    if (mediaService && mediaService.activePlayer) return mediaService.activePlayer
    return findFallbackActivePlayer()
  }
  readonly property var sourcePlayers: mediaService && mediaService.sourcePlayers && mediaService.sourcePlayers.length > 0 ? mediaService.sourcePlayers : fallbackPlayers
  // Prefer mediaService.isPlaying when the service backs the current activePlayer: it
  // also treats a player as playing when its PipeWire stream is actively flowing even
  // if MPRIS's own PlaybackStatus is stale (e.g. Chromium reporting "Stopped" while a
  // tab still has an unmuted, uncorked audio stream). The no-service fallback path has
  // no PipeWire correlation available, so it stays on raw MPRIS state.
  readonly property bool isPlaying: {
    if (mediaService && mediaService.activePlayer) return Boolean(mediaService.isPlaying)
    return (activePlayer && activePlayer.isPlaying) || false
  }

  // Per-app volume mirrors mediaService only — the standalone fallback path (no service)
  // has no PipeWire stream correlation available, so volume control is simply unavailable then.
  readonly property bool hasVolumeControl: Boolean(mediaService && mediaService.hasVolumeControl)
  readonly property real volume: hasVolumeControl ? mediaService.volume : 1.0
  readonly property bool muted: Boolean(mediaService && mediaService.muted)

  function setVolume(value) {
    if (mediaService && typeof mediaService.setVolume === "function") mediaService.setVolume(value)
  }

  function toggleMute() {
    if (mediaService && typeof mediaService.toggleMute === "function") mediaService.toggleMute()
  }

  // While playing, drive amplitude from the active player's real PipeWire peak level
  // (mediaService.audioLevel) so all visualizer modes react to actual loudness instead of
  // a constant.
  //
  // 100% music-follow mode: the energy IS the player stream's real PipeWire
  // peak, passed through unchanged. No synthetic floor (silence in the track
  // reads as flat, not as a fake minimum), no fake full-level fallback when
  // no stream is matched (no data must not fabricate music), and only a 30ms
  // micro-smooth (~2 frames) to kill single-sample flicker without any
  // readable lag. Hence gain 1.0: the 2.4→1.15 history predates this - those
  // boosts existed to compensate floors/fallbacks that made the amplitude
  // curve lie. Nothing lies anymore: amplitude == loudness.
  // (mediaService.audioLevel) so all visualizer modes react to actual loudness instead of
  // a constant. Falls back to the old fixed energy when no matching PipeWire stream could
  // be found for the player at all. Paused/idle keep the ambient drift levels.
  //
  // "Fake" look restored per preference: a synthetic floor keeps the shapes
  // breathing even in quiet passages, the no-stream fallback pins full
  // liveliness, and gain 1.15 keeps ordinary playback high on the curve.
  // The 160ms ease + pause→play snap give the flow its smooth, always-alive
  // character (favoured over the strict 1:1 peak-follow look, which read too
  // flat on a 30px-tall pill).
  property real audioGain: 1.15
  property real audioFloor: 0.15
  readonly property real liveAudioLevel: (mediaService && mediaService.audioLevel) || 0
  readonly property bool hasLiveAudioLevel: Boolean(mediaService && mediaService.hasLiveAudioLevel)
  readonly property color visualizerColor: {
    var foreground = root.bar ? root.bar.barForeground : Color.foreground
    if (root.currentEnergy > 0.82) return Qt.lighter(foreground, 1.35)
    if (root.currentEnergy > 0.58) return Qt.lighter(foreground, 1.15)
    return foreground
  }
  readonly property real targetEnergy: {
    if (!isPlaying) return 0
    if (!hasLiveAudioLevel) return 1.0
    return Math.max(audioFloor, Math.min(1.0, liveAudioLevel * audioGain))
  }
  property real currentEnergy: targetEnergy

  // Pressing play should start the visualizer *with* the audio, not a ramp
  // behind it: on a pause→play edge the ease is disabled for a tick so the
  // bound level jumps straight to its target, then the 160ms easing resumes
  // for ongoing changes. (The knob flips Behavior.enabled rather than writing
  // `currentEnergy` - an imperative write would permanently break the
  // targetEnergy binding.)
  property bool resumeSnap: false

  onIsPlayingChanged: {
    if (isPlaying) {
      resumeSnap = true
      resumeSnapTimer.restart()
    } else {
      resumeSnap = false
    }
  }

  Timer {
    id: resumeSnapTimer
    interval: 1
    onTriggered: root.resumeSnap = false
  }

  Behavior on currentEnergy {
    enabled: !root.resumeSnap
    NumberAnimation { duration: 160; easing.type: Easing.OutQuad }
  }
  onCurrentEnergyChanged: waveCanvas.requestPaint()

  readonly property real trackLength: {
    var value = activePlayer && Number(activePlayer.length)
    if (!isFinite(value) || value <= 0) return 0
    return value > 1000000 ? value / 1000000 : value
  }
  property real trackPosition: 0
  readonly property real trackProgress: trackLength > 0 ? Math.max(0, Math.min(1, trackPosition / trackLength)) : 0

  // Local position estimate, fed by MediaModel.samplePosition: the raw MPRIS
  // sample is frozen for players that never announce Position changes (Chrome,
  // verified), so a stale sample must not be copied straight into trackPosition.
  property var positionSync: ({ position: 0, reported: -1, sampleMs: 0 })
  property string positionSyncSignature: ""

  function readMprisPosition() {
    var raw = Number(activePlayer && activePlayer.position)
    if (!isFinite(raw) || raw < 0) return -1
    return raw > 1000000 ? raw / 1000000 : raw
  }

  // Reseed the estimator: `at` is the position to keep estimating from, and the
  // current raw sample is recorded as the comparison baseline (not as the
  // position) so a value frozen from a previous track or a long-closed popup
  // can never be trusted as authoritative on the next tick.
  function reseedPositionSync(at) {
    positionSync = { position: at || 0, reported: readMprisPosition(), sampleMs: Date.now() }
  }

  function syncTrackPosition() {
    if (!activePlayer) {
      trackPosition = 0
      positionSyncSignature = ""
      positionSync = { position: 0, reported: -1, sampleMs: 0 }
      return
    }
    // Track switch: start over from zero instead of seeding from the previous
    // track's frozen end position, which would park the bar at 100%.
    var signature = MediaModel.trackSignature(activePlayer)
    if (signature !== positionSyncSignature) {
      positionSyncSignature = signature
      trackPosition = 0
      reseedPositionSync(0)
      return
    }
    var value = MediaModel.samplePosition(positionSync, readMprisPosition(), isPlaying, Date.now())
    if (!isFinite(value) || value < 0) return
    if (trackLength > 0) value = Math.min(value, trackLength)
    trackPosition = value
    positionSync.position = value
  }

  function seekTrack(progress) {
    if (!activePlayer || trackLength <= 0) return
    var position = Math.max(0, Math.min(trackLength, progress * trackLength))
    // The local trackPosition is only an estimate, and it does not advance while
    // the popup is closed - for players that never announce Position changes
    // (Chrome) it can be far behind. A relative seek computed from it therefore
    // lands in the wrong place, so set the absolute position instead; MPRIS
    // players expose `position` as writable. `seek()` takes a *relative* offset,
    // so the fallback anchors it to the player's own reading.
    var realPosition = Number(activePlayer.position)
    if (typeof activePlayer.position === "number") {
      activePlayer.position = position
    } else if (typeof activePlayer.seek === "function") {
      var base = isFinite(realPosition) && realPosition >= 0 ? realPosition : root.trackPosition
      activePlayer.seek(position - base)
    }
    root.trackPosition = position
    root.reseedPositionSync(position)
  }

  function formatTime(seconds) {
    var total = Math.max(0, Math.floor(Number(seconds) || 0))
    return Math.floor(total / 60) + ":" + (total % 60 < 10 ? "0" : "") + (total % 60)
  }

  // 250ms keeps the sine-wave seek bar stepping smoothly. Gated on the popup
  // plus an active player only - not on isPlaying, which some players report
  // stale (Chromium "Stopped" while audio still flows) and which would stall
  // the timeline at the last known position.
  Timer {
    interval: 250
    running: root.popupOpen && root.activePlayer
    repeat: true
    onTriggered: root.syncTrackPosition()
  }

  function sourceBadgeColor(player) {
    var source = sourceName(player).toLowerCase()
    if (source.indexOf("spotify") !== -1) return Qt.lighter(root.visualizerColor, 1.15)
    if (source.indexOf("youtube") !== -1) return Qt.darker(root.visualizerColor, 1.15)
    if (source.indexOf("vlc") !== -1) return Qt.lighter(root.visualizerColor, 1.3)
    return root.visualizerColor
  }

  function openLyrics() {
    if (!root.title || !root.activePlayer) return
    Quickshell.execDetached(["omarchy-shell", "io.github.elliotalien.tide-lyrics", "toggle"])
  }

  readonly property bool hasMedia: activePlayer !== null && (Boolean(title) || Boolean(isPlaying) || Boolean(activePlayer.trackTitle || activePlayer.trackArtist))
  readonly property string playIcon: isPlaying ? "󰏤" : "󰐊"
  
  readonly property string title: {
    if (mediaService && mediaService.title) return MediaModel.sanitizeText(mediaService.title)
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    if (t) return MediaModel.cleanTitle(t, a)
    if (activePlayer.identity) return MediaModel.sanitizeText(activePlayer.identity)
    if (activePlayer.desktopEntry) return MediaModel.sanitizeText(activePlayer.desktopEntry)
    return "Playing"
  }

  readonly property string artist: {
    if (mediaService && mediaService.artist) return MediaModel.sanitizeText(mediaService.artist)
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    return MediaModel.cleanArtist(a, t, activePlayer)
  }

  readonly property string album: {
    if (mediaService && mediaService.album) return MediaModel.cleanAlbum(mediaService.album)
    if (!activePlayer) return ""
    if (activePlayer.trackAlbum) return MediaModel.cleanAlbum(activePlayer.trackAlbum)
    if (activePlayer.metadata && activePlayer.metadata["xesam:album"]) return MediaModel.cleanAlbum(activePlayer.metadata["xesam:album"])
    return ""
  }

  property string verifiedArtUrl: ""
  // Bumped for every new artwork candidate; artFetchGeneration records the value
  // the in-flight fetch was started for, so an exit from a superseded fetch can
  // be ignored (see onExited).
  property int artGeneration: 0
  property int artFetchGeneration: 0
  readonly property string rawCandidateArtUrl: {
    if (mediaService && mediaService.artUrl) return MediaModel.sanitizeArtUrl(mediaService.artUrl)
    if (!activePlayer) return ""
    return MediaModel.extractArtUrl(activePlayer)
  }

  readonly property string artUrl: verifiedArtUrl
  readonly property string artworkCachePath: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy/tide/artwork.cache"

  onRawCandidateArtUrlChanged: {
    var raw = root.rawCandidateArtUrl
    // Invalidate any fetch already in flight: Process.running = false only sends
    // SIGTERM, and the handler below still fires for it, so without this a
    // superseded or cancelled fetch would write its (older) result over the
    // value the current candidate just set.
    root.artGeneration++
    if (!raw) {
      artFetchProc.running = false
      root.verifiedArtUrl = ""
      return
    }

    if (MediaModel.isRasterDataUri(raw)) {
      artFetchProc.running = false
      root.verifiedArtUrl = raw
      return
    }

    // The service hands over its own validated cache-busted artwork.cache URL;
    // trust exactly that copy directly (a second fetch would duplicate work,
    // and the `?t=` buster must reach the popup Images intact or a track
    // change would never repaint the cover art). Any other file:// candidate -
    // e.g. a player's own temp art file like /tmp/.com.google.Chrome.* - still
    // goes through the validating fetch below: Chrome deletes those temps as
    // playback moves on, so displaying them raw flashes "Cannot open" errors.
    if (raw.indexOf("file://" + root.artworkCachePath) === 0) {
      artFetchProc.running = false
      root.verifiedArtUrl = raw
      return
    }

    // Keep the last good cover visible while validating a new track's artwork.
    // Remote HTTPS or local file: validate & cache with strict byte limits, no
    // redirects, secure mktemp, and magic byte check.
    artFetchProc.running = false
    artFetchProc.command = [
      "bash", "-c",
      "set -euo pipefail; URL=\"$1\"; CACHE_FILE=\"$2\"; CACHE_DIR=\"$(dirname \"$CACHE_FILE\")\"; mkdir -p -m 0700 \"$CACHE_DIR\"; TMP_FILE=$(mktemp -p \"$CACHE_DIR\" artwork.XXXXXX); trap 'rm -f \"${TMP_FILE:-}\"' EXIT; if [[ \"$URL\" =~ ^https:// ]]; then HTTP_CODE=$(curl -sS --max-time 3 --max-filesize 2097152 --proto \"=https\" -w \"%{http_code}\" \"$URL\" -o \"$TMP_FILE\" 2>/dev/null || echo \"000\"); if [[ \"$HTTP_CODE\" != \"200\" ]]; then exit 1; fi; elif [[ \"$URL\" =~ ^file://(/.*) ]] || [[ \"$URL\" =~ ^(/.*) ]]; then FILE_PATH=\"${BASH_REMATCH[1]}\"; FILE_PATH=\"${FILE_PATH%%[?#]*}\"; python3 -c '\nimport os,stat,sys\np=sys.argv[1]\nfd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_CLOEXEC)\nst=os.fstat(fd)\nif not(stat.S_ISREG(st.st_mode) and 4<=st.st_size<=2097152):\n os.close(fd)\n sys.exit(1)\nd=os.read(fd,2097152)\nos.close(fd)\nsys.stdout.buffer.write(d)\n' \"$FILE_PATH\" > \"$TMP_FILE\" 2>/dev/null; else exit 1; fi; MAGIC=$(od -N 12 -A n -t x1 \"$TMP_FILE\" 2>/dev/null | tr -d \" \\n\"); if [[ \"$MAGIC\" =~ ^89504e470d0a1a0a ]] || [[ \"$MAGIC\" =~ ^ffd8 ]] || [[ \"$MAGIC\" =~ ^47494638 ]] || [[ \"$MAGIC\" =~ ^424d ]] || [[ \"$MAGIC\" =~ ^52494646.{8}57454250 ]]; then mv -f \"$TMP_FILE\" \"$CACHE_FILE\"; exit 0; else exit 1; fi",
      "--",
      raw,
      root.artworkCachePath
    ]
    root.artFetchGeneration = root.artGeneration
    artFetchProc.running = true
  }

  Process {
    id: artFetchProc
    onExited: function(exitCode) {
      // Superseded or cancelled while running: this result is stale.
      if (root.artFetchGeneration !== root.artGeneration) return
      if (exitCode === 0) {
        root.verifiedArtUrl = "file://" + root.artworkCachePath + "?t=" + Date.now()
      }
      // On failure, leave the currently shown cover alone instead of pointing at
      // the shared cache file with a fresh buster (which made a failed fetch
      // indistinguishable from a successful one and re-showed the old track).
    }
  }

  readonly property string artworkSource: root.artUrl !== ""
    ? root.artUrl
    : "file://" + root.artworkCachePath
  property string displayedArtworkSource: ""
  property string previousArtworkSource: ""

  onArtUrlChanged: {
    if (root.artUrl === "" || root.artUrl === root.displayedArtworkSource) return
    root.previousArtworkSource = root.displayedArtworkSource || root.artworkSource
    root.displayedArtworkSource = root.artUrl
  }

  property bool popupOpen: false
  // The timer stops while the popup is closed, so the estimator's clock is
  // stale on reopen: reseed from the last known position, otherwise the whole
  // closed interval would be added back in one jump.
  onPopupOpenChanged: if (popupOpen) reseedPositionSync(trackPosition)
  property bool isMinimized: false
  function close() { popupOpen = false }
  property real maxLabelWidth: 220

  function playerKey(player) {
    if (!player) return ""
    if (mediaService && typeof mediaService.playerKey === "function") return mediaService.playerKey(player)
    return MediaModel.playerKey(player)
  }

  function playerCanonicalKey(player) {
    if (!player) return ""
    return MediaModel.playerCanonicalKey(player)
  }

  function runAction(action, targetPlayer) {
    var p = targetPlayer || activePlayer
    if (!p) return
    if (mediaService && typeof mediaService.runAction === "function") {
      mediaService.runAction(action, false, playerKey(p))
      return
    }
    if (action === "playPause") {
      if (typeof p.togglePlaying === "function") p.togglePlaying()
      else if (typeof p.playPause === "function") p.playPause()
      else if (p.isPlaying && typeof p.pause === "function") p.pause()
      else if (typeof p.play === "function") p.play()
    } else if (action === "next" && typeof p.next === "function") {
      p.next()
    } else if (action === "previous" && typeof p.previous === "function") {
      p.previous()
    }
  }

  function selectPlayer(targetPlayer) {
    if (!targetPlayer) return
    var key = playerKey(targetPlayer)
    if (mediaService && typeof mediaService.selectPlayer === "function") {
      mediaService.selectPlayer(key)
    } else {
      if (typeof targetPlayer.play === "function") {
        targetPlayer.play()
      } else if (typeof targetPlayer.togglePlaying === "function") {
        targetPlayer.togglePlaying()
      }
    }
  }

  function sourceName(player) {
    return MediaModel.sourceName(player)
  }

  function sourceIcon(player) {
    return MediaModel.sourceIcon(player)
  }

  // The real app logo from the icon theme (original, multicolour artwork -
  // the four-colour Chrome ball, the green Spotify circle, ...) for the
  // source tiles. Tries the player's desktop entry first, then known icon
  // names per source. Returns "" when nothing resolves so tiles fall back
  // to the brand-coloured glyph.
  function appIconSource(player) {
    if (!player) return ""

    var entry = String(player.desktopEntry || "").trim()
    if (entry.length > 0) {
      var direct = Quickshell.iconPath(entry, true)
      if (direct.length > 0) return direct
    }

    var guesses = {
      "Spotify": ["spotify"],
      "YouTube": ["youtube", "google-youtube"],
      "Twitch": ["twitch"],
      "VLC": ["vlc"],
      "Firefox": ["firefox", "firefox-esr"],
      "Chrome": ["google-chrome", "google-chrome-stable", "chromium"],
      // Brave ships its hicolor icons as "brave-desktop" (see
      // brave-browser.desktop Icon=); there is no icon named "brave".
      "Brave": ["brave-desktop", "brave-browser", "brave"],
      "Edge": ["microsoft-edge", "microsoft-edge-stable"],
      "SoundCloud": ["soundcloud"],
      "Netflix": ["netflix"],
      "Discord": ["discord"],
      "MPV": ["mpv", "io.mpv.Mpv"]
    }
    var names = guesses[MediaModel.sourceName(player)] || []
    for (var i = 0; i < names.length; i++) {
      var p = Quickshell.iconPath(names[i], true)
      if (p.length > 0) return p
    }
    return ""
  }

  visible: true
  implicitWidth: pill.width + Style.space(8)
  implicitHeight: barSize

  Behavior on implicitWidth {
    NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
  }

  // Bar Pill Capsule - Dynamic Continuous Flow Audio Visualizer
  BorderSurface {
    id: pill
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    height: Math.min(parent.height - Style.space(6), Style.space(28))
    width: root.isMinimized
      ? height
      : (root.showText ? (flowRow.implicitWidth + Style.space(16)) : Style.space(110))
    radius: height / 2
    clip: true
    color: clickArea.containsMouse ? Util.alpha(root.bar ? root.bar.barForeground : Color.foreground, 0.05) : "transparent"
    borderSpec: Border.none()

    Behavior on width {
      NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
    }
    Behavior on color {
      ColorAnimation { duration: 180 }
    }

    // Dynamic Multi-Mode Continuous Audio Visualizer Canvas
    Canvas {
      id: waveCanvas
      anchors.fill: parent
      anchors.margins: Style.space(2)
      visible: !root.isMinimized

      property real phase: 0

      // Phase speed scales with root.currentEnergy instead of running on a fixed
      // wall-clock loop: previously phase advanced a full cycle every 2200ms
      // regardless of what was playing, so only the wave's amplitude reacted to
      // real audio - the motion itself always looked like the same repeating
      // loop no matter how loud or quiet the track got (reported: "moving in a
      // short loop", not in sync with the sound). Baseline rate matches the old
      // fixed 2200ms/cycle; energy scales it from ~0.4x (quiet/idle ambient
      // drift, motion never freezes abruptly) up to ~2x (loud) so a real beat
      // drop visibly speeds the motion up, not just its amplitude.
      FrameAnimation {
        id: phaseDriver
        running: root.isPlaying
        readonly property real baseRate: (Math.PI * 2) / 2.2

        onTriggered: {
          if (frameTime <= 0 || frameTime > 1) return
          var speed = baseRate * (0.4 + root.currentEnergy * 1.6)
          var next = waveCanvas.phase + speed * frameTime
          waveCanvas.phase = next >= Math.PI * 2 ? next - Math.PI * 2 : next
        }
      }

      onPhaseChanged: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        if (width <= 0 || height <= 0) return

        var midY = height / 2
        var energy = root.currentEnergy
        var mode = root.visualizerMode

        // Multi-frequency rhythm & beat intensity physics
        var bassPulse = Math.pow(Math.abs(Math.sin(phase * 2.5)), 3) * energy
        var melodySwell = (0.5 + 0.5 * Math.sin(phase * 0.35)) * energy
        var intensity = 0.2 + (bassPulse * 0.5 + melodySwell * 0.3) * energy

        // Color flow: every mode paints through a horizontal palette gradient
        // whose phase scrolls with the same music clock as the shapes (phase),
        // so colors ripple through the visualizer instead of a flat monochrome
        // wash. Ties scroll speed to the existing energy-scaled phase rate, so
        // it never runs while paused and slows on quiet passages.
        var flowPhase = phase * 0.35
        var dimAlpha = energy > 0.4 ? 1.0 : 0.4
        function buildFlow(offset, alpha) {
          var g = ctx.createLinearGradient(0, 0, width, 0)
          for (var k = 0; k <= 40; k++)
            g.addColorStop(k / 40, root.flowPaletteColor(k / 40 * 2 - flowPhase + (offset || 0), alpha))
          return g
        }

        if (mode === "wave") {
          // 1. TRIPLE HARMONIC REACTIVE OCEAN WAVE
          var amp = height * (0.06 + energy * (0.22 + intensity * 0.15))

          ctx.lineWidth = 1.2 + bassPulse * 0.8
          ctx.strokeStyle = buildFlow(0, dimAlpha)
          ctx.beginPath()
          for (var x = 0; x <= width; x += 3) {
            var k = (x / width) * Math.PI * 4
            var y = midY + Math.sin(k + phase * (0.8 + energy * 0.4)) * Math.cos(k * 0.5 + phase * 0.6) * amp
            if (x === 0) ctx.moveTo(x, y)
            else ctx.lineTo(x, y)
          }
          ctx.stroke()

          // Companion wave: draws whenever anything at all is audible (the
          // envelope already keeps it subtle in quiet passages), paints the
          // palette offset in the OPPOSITE direction so at any x-position its
          // hue never matches the main wave, and stays clearly readable
          // against it (near-full palette brightness). Offset +2.5 at 60%
          // alpha was effectively invisible - half the loop resembles the
          // main wave's hues and read as "only one wave".
          if (energy > 0.05) {
            ctx.lineWidth = 1.0 + bassPulse * 0.5
            ctx.strokeStyle = buildFlow(-2.5, dimAlpha * 0.85)
            ctx.beginPath()
            for (var x2 = 0; x2 <= width; x2 += 3) {
              var k2 = (x2 / width) * Math.PI * 3
              var y2 = midY + Math.sin(k2 - phase * 1.2) * (amp * 0.65)
              if (x2 === 0) ctx.moveTo(x2, y2)
              else ctx.lineTo(x2, y2)
            }
            ctx.stroke()
          }

          // Third (finest) wave: a fast, small ripple that runs one quarter
          // of the palette loop away from BOTH other waves' offsets (0 and
          // -2.5), so three clearly distinct color streams cross and layer.
          // It drifts opposite the main wave's direction for interleaving
          // motion, and rides the real loudness envelope like the others.
          if (energy > 0.05) {
            ctx.lineWidth = 0.9 + bassPulse * 0.4
            ctx.strokeStyle = buildFlow(1.25, dimAlpha * 0.75)
            ctx.beginPath()
            for (var x3 = 0; x3 <= width; x3 += 3) {
              var k3 = (x3 / width) * Math.PI * 5
              var y3 = midY + Math.sin(k3 + phase * 1.5) * Math.cos(k3 * 0.3 + phase * 0.45) * (amp * 0.45)
              if (x3 === 0) ctx.moveTo(x3, y3)
              else ctx.lineTo(x3, y3)
            }
            ctx.stroke()
          }
        } else if (mode === "bars") {
          // 2. ADAPTIVE FREQUENCY EQUALIZER BARS
          var numBars = root.showText ? 16 : 22
          var barW = (width / numBars) * 0.45
          var gap = (width / numBars) * 0.55
          ctx.fillStyle = buildFlow(0, dimAlpha)
          for (var b = 0; b < numBars; b++) {
            var barFreq = Math.abs(Math.sin(phase * 2.0 + b * 0.75) * Math.cos(phase * 1.2 + b * 0.35))
            var bh = (barFreq * (height * (0.15 + energy * (0.3 + intensity * 0.35))) + 2)
            var bx = b * (barW + gap) + gap / 2
            var by = midY - bh / 2
            ctx.fillRect(bx, by, barW, bh)
          }
        } else if (mode === "dots") {
          // 3. PULSING WAVE MATRIX BEADS
          var numDots = root.showText ? 14 : 18
          var step = width / (numDots + 1)
          ctx.fillStyle = buildFlow(1.5, dimAlpha)
          for (var d = 1; d <= numDots; d++) {
            var dx = d * step
            var dotOsc = Math.sin(phase * 2.0 + d * 0.6)
            var dy = midY + dotOsc * (height * (0.08 + energy * (0.18 + intensity * 0.16)))
            var r = (1.5 + (bassPulse * 1.0) + (energy * 0.8))
            ctx.beginPath()
            ctx.arc(dx, dy, r, 0, Math.PI * 2)
            ctx.fill()
          }
        } else if (mode === "particles") {
          // 4. FLOWING SOUND DUST / SPARKS
          var numParts = root.showText ? 12 : 16
          ctx.fillStyle = buildFlow(0.8, dimAlpha)
          for (var pIdx = 0; pIdx < numParts; pIdx++) {
            var speed = 20 + energy * 20 + bassPulse * 10
            var px = ((pIdx * 28 + (phase / (Math.PI * 2)) * width * (0.6 + energy * 0.6)) % width)
            var py = midY + Math.sin(px * 0.08 + phase + pIdx) * (height * (0.08 + energy * (0.2 + intensity * 0.15)))
            ctx.beginPath()
            ctx.arc(px, py, 1.4 + energy * 0.8 + bassPulse * 0.6, 0, Math.PI * 2)
            ctx.fill()
          }
        } else if (mode === "pulse") {
          // 5. RHYTHMIC BREATHING AUDIO HEARTBEAT
          var pulseScale = 0.25 + energy * (0.35 + intensity * 0.4)
          var grad = ctx.createRadialGradient(width / 2, midY, 2, width / 2, midY, (width / 2) * pulseScale)
          grad.addColorStop(0, root.flowPaletteColor(phase * 0.35 + 1.0, dimAlpha))
          grad.addColorStop(0.55, root.flowPaletteColor(phase * 0.35 + 2.2, dimAlpha * 0.55))
          grad.addColorStop(1, "transparent")
          ctx.fillStyle = grad
          ctx.fillRect(0, 0, width, height)
        }
      }
    }

    // Minimized Mode (Single icon)
    Item {
      anchors.fill: parent
      visible: root.isMinimized

      Text {
        anchors.centerIn: parent
        text: "󰝚"
        textFormat: Text.PlainText
        color: root.isPlaying ? root.visualizerColor : (clickArea.containsMouse ? root.visualizerColor : (root.bar ? root.bar.barForeground : Color.foreground))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        Behavior on color { ColorAnimation { duration: 140 } }
      }
    }

    // Pure Minimalist Visualizer Mode (Source Glyph centered over flow)
    Item {
      anchors.fill: parent
      visible: !root.isMinimized && !root.showText

      Text {
        anchors.centerIn: parent
        text: root.hasMedia ? root.sourceIcon(root.activePlayer) : "󰝚"
        textFormat: Text.PlainText
        color: root.isPlaying ? root.visualizerColor : (root.hasMedia ? (root.bar ? root.bar.barForeground : Color.foreground) : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.4))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        Behavior on color { ColorAnimation { duration: 140 } }
      }
    }

    // Full Expanded Mode (Music icon + Scrolling song name over flow)
    Row {
      id: flowRow
      anchors.centerIn: parent
      spacing: Style.space(7)
      visible: !root.isMinimized && root.showText

      // Music Icon / Source Glyph
      Text {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        text: root.hasMedia ? root.sourceIcon(root.activePlayer) : "󰝚"
        textFormat: Text.PlainText
        color: root.isPlaying ? root.visualizerColor : (root.hasMedia ? (root.bar ? root.bar.barForeground : Color.foreground) : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.4))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }
      }

      // Track Title & Artist with smooth marquee scroll, or idle placeholder
      Item {
        id: scrollClip
        width: root.hasMedia ? Math.min(root.maxLabelWidth, titleRow.implicitWidth) : idleLabel.implicitWidth
        height: Math.max(glyph.implicitHeight, Style.space(16))
        clip: true
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.bar || !root.bar.vertical

        Text {
          id: idleLabel
          visible: !root.hasMedia
          text: "Music"
          textFormat: Text.PlainText
          color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Row {
          id: titleRow
          visible: root.hasMedia
          spacing: Style.space(5)
          anchors.verticalCenter: parent.verticalCenter

          property bool needsScroll: titleRow.implicitWidth > root.maxLabelWidth

          Text {
            id: titleText
            text: root.title
            textFormat: Text.PlainText
            color: root.bar ? root.bar.barForeground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: sepText
            visible: root.artist !== ""
            text: "·"
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: artistText
            visible: root.artist !== ""
            text: root.artist
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          SequentialAnimation on x {
            id: scrollAnim
            running: titleRow.needsScroll && !root.popupOpen && (!root.bar || !root.bar.vertical) && root.hasMedia && !root.isMinimized && root.showText
            loops: Animation.Infinite
            // A stopped animation leaves x at its last animated value. Without
            // this reset, a long title that scrolled and is then replaced by a
            // short one stays shifted left inside the clipping Item and loses
            // its beginning until another long title starts scrolling.
            onRunningChanged: if (!running) titleRow.x = 0

            PauseAnimation { duration: 2500 }
            NumberAnimation {
              to: -(titleRow.implicitWidth - scrollClip.width)
              duration: Math.max(3000, (titleRow.implicitWidth - scrollClip.width) * 35)
              easing.type: Easing.Linear
            }
            PauseAnimation { duration: 2000 }
            NumberAnimation {
              to: 0
              duration: Math.max(1500, (titleRow.implicitWidth - scrollClip.width) * 15)
              easing.type: Easing.InOutQuad
            }
          }
        }

      }
    }
  }

  // Interactive Bar Click Area
  MouseArea {
    id: clickArea
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: pill.width
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) {
        root.runAction("playPause", root.activePlayer)
      } else if (mouse.button === Qt.RightButton) {
        _writeTextGate = true
        root.showText = !root.showText
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
    onWheel: function(wheel) {
      if (!root.activePlayer) return
      if (wheel.angleDelta.y > 0) {
        root.runAction("previous", root.activePlayer)
      } else if (wheel.angleDelta.y < 0) {
        root.runAction("next", root.activePlayer)
      }
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasMedia ? MediaModel.sanitizeText(root.title + (root.artist ? " — " + root.artist : "")) : "Music Player (Right-click: Toggle Text)")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // Dedicated Floating Player & Source Selection Window
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    padding: 0
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight + popup.contentPadding * 2)

    readonly property real contentPadding: Style.spacing.popupPadding
    readonly property real innerRadius: Math.max(0, Style.cornerRadius - Math.max(
      Border.top(borderSpec) || 0, Border.right(borderSpec) || 0,
      Border.bottom(borderSpec) || 0, Border.left(borderSpec) || 0))
    readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
    readonly property color mutedFg: Qt.darker(fg, 1.35)
    readonly property color dimFg: Qt.darker(fg, 1.6)

    // Full-card album-art backdrop, behind every section.
    Rectangle {
      id: popupBackdropFrame
      anchors.fill: parent
      radius: popup.innerRadius
      clip: true
      color: Util.alpha(popup.fg, 0.04)
      z: -1

      Image {
        id: popupBackdrop
        anchors.fill: parent
        source: root.displayedArtworkSource || root.artworkSource
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        sourceSize.width: Math.round(width * Screen.devicePixelRatio)
        sourceSize.height: Math.round(height * Screen.devicePixelRatio)
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.InOutQuad } }
      }

      MultiEffect {
        anchors.fill: popupBackdrop
        source: popupBackdrop
        autoPaddingEnabled: false
        blurEnabled: popupBackdrop.status === Image.Ready
        blur: 1.0
        blurMax: 96
        blurMultiplier: 1.15
        saturation: -0.15
        brightness: -0.1
      }

      // Scrim keeps every section readable over bright cover art.
      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          GradientStop { position: 0.0; color: Util.alpha(Color.background, 0.28) }
          GradientStop { position: 0.45; color: Util.alpha(Color.background, 0.62) }
          GradientStop { position: 1.0; color: Util.alpha(Color.background, 0.9) }
        }
      }
    }

    Column {
      id: column
      anchors.fill: parent
      anchors.margins: popup.contentPadding
      spacing: Style.space(12)

      // Hero section: large centered artwork and metadata over the backdrop.
      BorderSurface {
        id: hero
        width: parent.width
        height: heroColumn.implicitHeight + Style.space(16)
        color: "transparent"
        borderSpec: Border.none()

        Column {
          id: heroColumn
          anchors.centerIn: parent
          width: parent.width - Style.space(24)
          spacing: Style.space(6)

          // Former source badge, kept invisible so the gap above the cover
          // art stays exactly as before.
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            opacity: 0
            spacing: Style.space(4)

            Text {
              text: root.hasMedia ? root.sourceIcon(root.activePlayer) : "󰝚"
              textFormat: Text.PlainText
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: root.hasMedia ? root.sourceName(root.activePlayer).toUpperCase() : "MUSIC"
              textFormat: Text.PlainText
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Large centered cover art with crossfade between tracks.
          BorderSurface {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(112)
            height: width
            radius: 0
            clip: true
            color: Util.alpha(popup.fg, 0.08)
            borderSpec: Border.none()

            Image {
              id: previousArtwork
              anchors.fill: parent
              anchors.margins: Style.space(1)
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              autoTransform: true
              sourceSize.width: Style.space(224)
              sourceSize.height: Style.space(224)
              source: root.previousArtworkSource
              visible: source !== "" && artwork.opacity < 1
            }

            Image {
              id: artwork
              anchors.fill: parent
              anchors.margins: Style.space(1)
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              autoTransform: true
              sourceSize.width: Style.space(224)
              sourceSize.height: Style.space(224)
              source: root.displayedArtworkSource || root.artworkSource
              opacity: status === Image.Ready ? 1 : 0
              visible: source !== "" && status === Image.Ready
              Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.InOutQuad } }
            }

            Text {
              anchors.centerIn: parent
              visible: artwork.status !== Image.Ready
              text: root.hasMedia ? root.sourceIcon(root.activePlayer) : "󰝚"
              textFormat: Text.PlainText
              color: root.sourceBadgeColor(root.activePlayer)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.displayLarge
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.title || "Nothing playing"
            textFormat: Text.PlainText
            color: popup.fg
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            topPadding: Style.space(2)
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.artist
            textFormat: Text.PlainText
            color: popup.mutedFg
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            visible: text !== ""
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.album
            textFormat: Text.PlainText
            color: popup.dimFg
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            visible: text !== ""
          }
        }
      }

      // Clickable sine-wave track progress and seek control.
      Column {
        width: parent.width
        spacing: Style.space(3)
        visible: root.trackLength > 0

        Item {
          width: parent.width
          height: Style.space(16)
          Text {
            id: elapsedTime
            text: root.formatTime(root.trackPosition)
            anchors.left: parent.left
            color: popup.mutedFg
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            text: "-" + root.formatTime(root.trackLength - root.trackPosition)
            anchors.right: parent.right
            color: popup.dimFg
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Canvas {
          id: seekWaveform
          width: parent.width
          height: Style.space(22)
          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)

            var midY = height / 2
            var amp = Math.max(2, height / 2 - 2)
            var cycles = 3
            var steps = Math.max(64, Math.round(width / 2))
            var progressX = width * root.trackProgress

            // One full sine path across the canvas, stroked from the
            // current origin so the same curve can be drawn twice.
            function traceWave() {
              ctx.beginPath()
              for (var i = 0; i <= steps; i++) {
                var x = width * i / steps
                var y = midY - amp * Math.sin((i / steps) * cycles * 2 * Math.PI)
                if (i === 0) ctx.moveTo(x, y)
                else ctx.lineTo(x, y)
              }
              ctx.stroke()
            }

            ctx.lineWidth = 2
            ctx.lineCap = "round"
            ctx.lineJoin = "round"

            // Unplayed remainder.
            ctx.strokeStyle = Util.alpha(popup.fg, 0.18)
            traceWave()

            // Played portion, clipped to the progress point.
            ctx.save()
            ctx.beginPath()
            ctx.rect(0, 0, progressX, height)
            ctx.clip()
            ctx.strokeStyle = root.visualizerColor
            traceWave()
            ctx.restore()

            // Playhead dot riding the wave.
            var playheadY = midY - amp * Math.sin(root.trackProgress * cycles * 2 * Math.PI)
            ctx.beginPath()
            ctx.arc(progressX, playheadY, 3, 0, 2 * Math.PI)
            ctx.fillStyle = root.visualizerColor
            ctx.fill()
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: function(mouse) {
              root.seekTrack(Math.max(0, Math.min(1, mouse.x / width)))
            }
          }
        }

        Connections {
          target: root
          function onTrackProgressChanged() { seekWaveform.requestPaint() }
        }
      }

      // Transport controls centered in the row; volume is pinned to the left
      // edge (slider popover on hover) and the lyrics button to the right.
      Item {
        id: transportHost
        width: parent.width
        height: transportRow.height

        Row {
          id: transportRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(10)

          TransportButton {
            glyph: "󰒮"
            bordered: false
            enabled: Boolean(root.activePlayer && root.activePlayer.canGoPrevious)
            onActivated: root.runAction("previous", root.activePlayer)
          }

          TransportButton {
            glyph: root.isPlaying ? "󰏤" : "󰐊"
            primary: true
            enabled: Boolean(root.activePlayer && (root.activePlayer.canTogglePlaying || root.activePlayer.canPlay || root.activePlayer.canPause || root.isPlaying))
            onActivated: root.runAction("playPause", root.activePlayer)
          }

          TransportButton {
            glyph: "󰒭"
            bordered: false
            enabled: Boolean(root.activePlayer && root.activePlayer.canGoNext)
            onActivated: root.runAction("next", root.activePlayer)
          }
        }

        // Lyrics opens the synced-lyrics panel; pinned to the right edge
        // to mirror the volume button on the left. Borderless like the
        // other secondary controls.
        TransportButton {
          anchors.right: parent.right
          glyph: ""
          glyphIcon: Qt.resolvedUrl("lyrics-mic.svg")
          bordered: false
          enabled: Boolean(root.activePlayer && root.title)
          onActivated: root.openLyrics()
        }

        // Per-source volume: click toggles mute; hover opens a popover with
        // a liquid-fill capsule - colour rises from the bottom like a vial,
        // the whole capsule is the drag target.
        Item {
          id: volumeButton
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(32)
          height: width
          visible: root.hasVolumeControl

          property bool popoverOpen: false

          // Closing the panel must never leave the popover stuck open.
          Connections {
            target: root
            function onPopupOpenChanged() {
              if (!root.popupOpen) volumeButton.popoverOpen = false
            }
          }

          BorderSurface {
            anchors.fill: parent
            radius: width / 2
            color: volumeMouse.containsMouse ? Style.hoverFillFor(popup.fg, Color.accent) : "transparent"
            borderSpec: Border.none()

            Text {
              anchors.centerIn: parent
              text: root.muted ? "󰝟" : (root.volume > 0.5 ? "󰕾" : (root.volume > 0 ? "󰖀" : "󰕿"))
              textFormat: Text.PlainText
              color: volumeMouse.containsMouse ? Color.accent : popup.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              opacity: root.muted ? 0.6 : 1.0

              Behavior on color { ColorAnimation { duration: 140 } }
            }
          }

          MouseArea {
            id: volumeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: { volumeHideTimer.stop(); volumeButton.popoverOpen = true }
            onExited: volumeHideTimer.start()
            onClicked: root.toggleMute()
          }

          // Liquid level capsule, only on hover. The hide timer bridges the
          // gap crossing between button and popover so it can't flicker shut.
          BorderSurface {
            id: volumePopover
            anchors.bottom: parent.top
            anchors.bottomMargin: Style.space(8)
            // Centre above the button, then pulled slightly left per
            // preference so the vial leans away from the lyric column.
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.horizontalCenterOffset: -Style.space(6)
            width: Style.space(50)
            height: Style.space(150)
            radius: Style.space(10)
            visible: volumeButton.popoverOpen && root.popupOpen
            // No card behind the control - just the floating % + vial.
            color: "transparent"
            borderSpec: Border.none()

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(6)

              Text {
                id: volumePercent
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: Math.round((root.muted ? 0 : root.volume) * 100) + "%"
                textFormat: Text.PlainText
                color: popup.fg
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Item {
                id: volumeSliderWrap
                width: parent.width
                height: parent.height - volumePercent.implicitHeight - parent.spacing

                // Liquid-only vial: the capsule carries no rim, sheen or
                // secondary level - the moving liquid is the only indicator.
                // The whole capsule stays the drag target (bottom = 0%, top =
                // 100%), and the surface ripples so volume reads as fluid.
                Item {
                  id: liquidCapsule
                  anchors.fill: parent

                  // Sub-1% collapses to a true empty state - otherwise a
                  // sliver + wave linger at "zero" and break the look.
                  readonly property real level: {
                    var v = root.muted ? 0 : Math.max(0, Math.min(1, root.volume))
                    return v < 0.01 ? 0 : v
                  }
                  readonly property color liquidColor: root.visualizerColor || Color.accent

                  // The surface is drawn from a smoothed level, so volume
                  // changes pour into place instead of jumping.
                  property real drawnLevel: level

                  Behavior on drawnLevel {
                    enabled: !liquidMouse.draggingVolume
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                  }

                  // Idle ripple phase, plus a short-lived "slosh" that swells
                  // the wave while the level is pouring fast and settles after.
                  property real wavePhase: 0
                  property real slosh: 0

                  Timer {
                    interval: 34
                    repeat: true
                    running: volumePopover.visible && liquidCapsule.drawnLevel > 0.001
                    onTriggered: {
                      liquidCapsule.wavePhase += 0.115
                      liquidCapsule.slosh = Math.max(0, liquidCapsule.slosh * 0.92)
                      liquidBody.requestPaint()
                    }
                  }

                  Connections {
                    target: liquidCapsule
                    function onDrawnLevelChanged() { liquidBody.requestPaint() }
                    function onLiquidColorChanged() { liquidBody.requestPaint() }
                  }

                  Connections {
                    target: liquidCapsule
                    function onLevelChanged() {
                      liquidCapsule.slosh = Math.min(1, liquidCapsule.slosh + Math.abs(liquidCapsule.level - liquidCapsule.drawnLevel) * 26)
                      liquidBody.requestPaint()
                    }
                  }

                  // The empty-vial hint: a bare capsule fill, no rim on top.
                  // It exists so an empty vial still reads as a bar.
                  Rectangle {
                    id: vialSpace
                    anchors.fill: parent
                    radius: width / 2
                    color: liquidMouse.containsMouse ? Util.alpha(popup.fg, 0.14) : Util.alpha(popup.fg, 0.08)

                    Behavior on color { ColorAnimation { duration: 140 } }
                  }

                  // The liquid itself: a canvas so the wave surface can be
                  // clipped to the capsule's curvature - a QML `clip` clamps
                  // to the bounding box and would square the corners off.
                  Canvas {
                    id: liquidBody
                    anchors.fill: parent
                    antialiasing: true

                    onWidthChanged: if (visible) requestPaint()
                    onHeightChanged: if (visible) requestPaint()
                    onVisibleChanged: if (visible) requestPaint()
                    Component.onCompleted: requestPaint()

                    onPaint: {
                      var ctx = getContext("2d")
                      var w = width, h = height
                      if (w < 2 || h < 2) return
                      var r = w / 2

                      ctx.reset()
                      ctx.clearRect(0, 0, w, h)

                      if (liquidCapsule.drawnLevel <= 0.001) return

                      // Round-glass clip: two arcs joined by the straight
                      // sides trace the capsule exactly.
                      ctx.beginPath()
                      ctx.arc(r, r, r, Math.PI, Math.PI * 2)
                      ctx.arc(w - r, h - r, r, 0, Math.PI)
                      ctx.closePath()
                      ctx.clip()

                      // Keep a visible surface at tiny non-zero volumes.
                      var pool = Math.min(Math.max(h * liquidCapsule.drawnLevel, 6), h)
                      var surface = h - pool

                      var amp = 1 + liquidCapsule.slosh * 1.5
                      var phase = liquidCapsule.wavePhase
                      var waveY = function(x) {
                        return surface
                          + amp * 1.2 * Math.sin((x / w) * Math.PI * 2.1 + phase * 2.0)
                          + amp * 0.6 * Math.sin((x / w) * Math.PI * 4.7 + phase * 3.2 + 1.3)
                          + amp * 0.8 * Math.sin(phase * 1.6)
                      }

                      // One continuous body of liquid, no surface line drawn
                      // over it: the silhouette is the level itself.
                      ctx.beginPath()
                      ctx.moveTo(0, waveY(0))
                      var step = Math.max(1.5, w / 24)
                      for (var x = step; x < w; x += step) ctx.lineTo(x, waveY(x))
                      ctx.lineTo(w, waveY(w))
                      ctx.lineTo(w, h)
                      ctx.lineTo(0, h)
                      ctx.closePath()

                      var c = liquidCapsule.liquidColor
                      ctx.fillStyle = "rgba(" + Math.round(c.r * 255) + ","
                        + Math.round(c.g * 255) + ","
                        + Math.round(c.b * 255) + "," + c.a + ")"
                      ctx.fill()
                    }
                  }

                  MouseArea {
                    id: liquidMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    property bool draggingVolume: false

                    // Bottom = 0%, top = 100%. Dragging while muted lifts the
                    // mute first so the fill visibly tracks the pointer.
                    function setFromY(py) {
                      var v = 1 - Math.max(0, Math.min(1, py / height))
                      if (root.muted && v > 0) root.toggleMute()
                      root.setVolume(v)
                    }

                    onPressed: function(mouse) {
                      if (mouse.button !== Qt.LeftButton) return
                      draggingVolume = true
                      setFromY(mouse.y)
                    }
                    onPositionChanged: function(mouse) {
                      if (draggingVolume) setFromY(mouse.y)
                    }
                    onReleased: function(mouse) {
                      if (mouse.button !== Qt.LeftButton) return
                      draggingVolume = false
                      setFromY(mouse.y)
                    }
                    onExited: draggingVolume = false
                    onClicked: function(mouse) {
                      if (mouse.button === Qt.RightButton) root.toggleMute()
                    }
                  }
                }
              }
            }

            // Hover keeper on top: NoButton so slider presses/wheel pass
            // through, but hover anywhere on the popover holds it open.
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
              cursorShape: Qt.PointingHandCursor
              onEntered: volumeHideTimer.stop()
              onExited: volumeHideTimer.start()
              onWheel: function(wheel) { wheel.accepted = false }
            }
          }

          Timer {
            id: volumeHideTimer
            interval: 160
            onTriggered: volumeButton.popoverOpen = false
          }
        }
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      // Source / Player Switcher Section
      Column {
        width: parent.width
        spacing: Style.space(6)

        // Empty state when no players are active
        Text {
          visible: root.sourcePlayers.length === 0
          text: "No active media players found."
          textFormat: Text.PlainText
          color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          anchors.horizontalCenter: parent.horizontalCenter
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
        }

        // Player Source Cards - icon tiles as a single equal-slice row.
        Grid {
          id: sourceGrid
          width: parent.width
          // Grid packs items by row COUNT - its built-in `columns` property -
          // so pinning it to the source count keeps everything on ONE row no
          // matter how many players are active; each source still gets an
          // equal slice of the full width with its logo centred in that slice.
          columns: Math.max(1, root.sourcePlayers.length)
          columnSpacing: 0
          rowSpacing: Style.space(6)

          readonly property real cardWidth: Math.floor(width / columns)
          readonly property real cardHeight: Math.min(48, cardWidth)

          Repeater {
            model: root.sourcePlayers

            Item {
              id: sourceRow
              required property var modelData
              // Icon-only source cards: no tile fill, no border, in any
              // state. The playing source's icon is the one in full colour;
              // every other source sits desaturated grey, brightening to
              // full grey on hover.
              opacity: selected ? 1.0 : (sourceRow.hovered ? 1.0 : 0.9)
              Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

              readonly property var player: modelData
              readonly property bool selected: root.activePlayer && player
                && root.playerCanonicalKey(root.activePlayer) === root.playerCanonicalKey(player)
              readonly property string name: root.sourceName(player)
              readonly property string icon: root.sourceIcon(player)
              readonly property string appIcon: root.appIconSource(player)
              // Icons shrink with the slice so a long row of sources never
              // overlaps (28px until the slice gets tight, 16px floor).
              readonly property real iconExtent: Math.max(16, Math.min(Style.space(28), Math.floor(sourceGrid.cardWidth * 0.62)))
              // The playing source's glyph keeps its brand colour (Spotify
              // green, YouTube red, ...). Every other source falls back to a
              // plain grey glyph - no colour - until it becomes active.
              readonly property color iconColor: {
                var brand = MediaModel.sourceColor(player)
                // Hover colour effect: the hovered source flashes its brand
                // colour (or accent) even when not the active one, then
                // settles back to grey.
                if (brand && (selected || hovered)) return brand
                if (selected) return Color.accent
                var fg = root.bar ? root.bar.foreground : Color.foreground
                return Qt.darker(fg, 1.5)
              }
              readonly property string track: {
                if (!player) return "Active Player"
                var t = player.trackTitle || (player.metadata && player.metadata["xesam:title"]) || ""
                var a = player.trackArtist || (player.metadata && player.metadata["xesam:artist"]) || ""
                if (t) return MediaModel.cleanTitle(t, a)
                return MediaModel.sanitizeText(player.identity || "Active Player")
              }
              readonly property string artistName: {
                if (!player) return ""
                var t = player.trackTitle || (player.metadata && player.metadata["xesam:title"]) || ""
                var a = player.trackArtist || (player.metadata && player.metadata["xesam:artist"]) || ""
                return MediaModel.cleanArtist(a, t, player)
              }
              // Same Repeater-delegate stale-hover issue as the flow-mode buttons above.
              property bool hovered: false

              width: sourceGrid.cardWidth
              height: sourceGrid.cardHeight

              Row {
                anchors.centerIn: parent
                spacing: Style.space(10)

                // Real app logo when the icon theme has one (original,
                // multicolour artwork); otherwise the brand-coloured glyph
                // below. Row skips invisible items, so exactly one shows.
                Image {
                  id: sourceRowAppIcon
                  visible: status === Image.Ready
                  source: sourceRow.appIcon
                  sourceSize.width: Math.round(width * Screen.devicePixelRatio)
                  sourceSize.height: Math.round(height * Screen.devicePixelRatio)
                  fillMode: Image.PreserveAspectFit
                  width: sourceRow.iconExtent
                  height: width

                  // Only the playing source keeps its brand colours; the
                  // others render as grayscale artwork - but hovering any
                  // restore fades its original colours back in, and leaving
                  // fades the grey back over it (140ms colour effect).
                  layer.enabled: !sourceRow.selected
                  layer.effect: MultiEffect {
                    saturation: (sourceRow.selected || sourceRow.hovered) ? 0.0 : -1.0
                    Behavior on saturation {
                      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                    }
                  }
                }

                // Icon-only tile: name, track line and transport glyph are not
                // rendered; hover shows the details as a tooltip instead.
                Text {
                  visible: sourceRowAppIcon.status !== Image.Ready
                  text: sourceRow.icon
                  textFormat: Text.PlainText
                  color: sourceRow.iconColor
                  Behavior on color { ColorAnimation { duration: 140 } }
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Math.max(18, Math.min(Style.font.display, Math.round(sourceRow.iconExtent * 1.15)))
                }
              }

              MouseArea {
                id: sourceCardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: {
                  sourceRow.hovered = true
                  if (root.bar) root.bar.showTooltip(root, sourceRow.name
                    + (sourceRow.track ? " — " + sourceRow.track : ""))
                }
                onExited: {
                  sourceRow.hovered = false
                  if (root.bar) root.bar.hideTooltip(root)
                }
                onClicked: root.selectPlayer(sourceRow.player)
              }
            }
          }
        }
      }
    }
  }
}
