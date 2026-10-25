import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons
import "../io.github.elliotalien.tide/MediaModel.js" as MediaModel

BarWidget {
  id: root
  moduleName: "io.github.elliotalien.tide-lyrics"

  property int playerRevision: 0

  // A plugin may only look up its *own* service (shell.qml pluginServiceFor ->
  // pluginOwnsTarget), so this widget cannot read Tide's service object to reuse
  // its source-selection rules. Pick the player locally instead, preferring one
  // that is actually playing and, when nothing plays, one that still carries
  // track metadata - otherwise a stale, metadata-less browser session wins over
  // the paused track the bar is showing.
  // hasTrackMetadata() also counts a bare mpris:artUrl, which a stopped Chrome
  // session keeps pointing at a deleted /tmp file while carrying no title or
  // artist at all - that made it win the paused fallback over the real track.
  // For choosing *which* player to show, only title/artist count.
  function hasTrackText(player) {
    if (!player) return false
    if (player.trackTitle || player.trackArtist) return true
    var meta = player.metadata || ({})
    return Boolean(meta["xesam:title"] || meta["xesam:artist"])
  }

  readonly property var activePlayer: {
    var revision = playerRevision
    var players = Mpris.players ? Mpris.players.values : []
    var fallback = null
    var fallbackWithTrack = null
    for (var i = 0; i < players.length; i++) {
      var player = players[i]
      if (!player || MediaModel.isProxyPlayer(player)) continue
      if (!MediaModel.hasMetadata(player)) continue
      if (player.isPlaying) return player
      if (!fallback) fallback = player
      if (!fallbackWithTrack && hasTrackText(player)) fallbackWithTrack = player
    }
    return fallbackWithTrack || fallback
  }
  property bool lyricsOpen: false
  readonly property bool isPlaying: Boolean(activePlayer && activePlayer.isPlaying)
  readonly property string title: {
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    // Mirror the main widget's cleaned display title so the LRCLIB lookup uses
    // exactly the text the player panel shows (browser/site suffixes stripped).
    return MediaModel.sanitizeText(MediaModel.cleanTitle(t, a) || t || activePlayer.identity || activePlayer.desktopEntry || "")
  }
  readonly property string artist: {
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    return MediaModel.cleanArtist(a, t, activePlayer) || MediaModel.sanitizeText(a)
  }
  readonly property real trackLength: {
    var value = Number(activePlayer && activePlayer.length)
    if (!isFinite(value) || value <= 0) return 0
    return value > 1000000 ? value / 1000000 : value
  }
  property real trackPosition: 0
  readonly property color lyricColor: bar ? bar.barForeground : Color.foreground

  // Local position estimate, fed by MediaModel.samplePosition: if the raw MPRIS
  // sample stops moving while playback is active, the display keeps advancing on
  // the local clock instead of freezing (see the function's doc comment).
  property var positionSync: ({ position: 0, reported: -1, sampleMs: 0 })
  property string positionSyncSignature: ""

  function readMprisPosition() {
    if (!activePlayer) return -1
    var raw = Number(activePlayer.position)
    if (!isFinite(raw) || raw < 0) return -1
    return raw > 1000000 ? raw / 1000000 : raw
  }

  // `at` is the position to keep estimating from; the current raw sample is
  // recorded as comparison baseline only, never as the position itself, so a
  // value left over from a previous track cannot be trusted on the next tick.
  function reseedPositionSync(at) {
    positionSync = { position: Math.max(0, at || 0), reported: readMprisPosition(), sampleMs: Date.now() }
  }

  property string lyricsRequestKey: ""
  property bool ignoreNextExit: false
  property string lyricsStatus: ""
  // Lyric lookup state machine: "get" = exact LRCLIB match, "search" = title
  // candidates tried in order (see MediaModel.lyricsQueryCandidates).
  property string lookupStage: ""
  property var searchCandidates: []
  property var fallbackRecord: null
  property var lyricLines: []
  property var lyricTimes: []
  property var currentLyricWords: []
  property int currentLyricIndex: -1
  property real lyricWordProgress: 0

  visible: lyricsOpen
  implicitWidth: lyricsOpen ? Style.space(300) : 0
  implicitHeight: barSize
  Behavior on implicitWidth { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

  function toggleLyrics() {
    if (!lyricsOpen) noLyricsAutoClose.stop()
    lyricsOpen = !lyricsOpen
  }

  IpcHandler {
    target: "io.github.elliotalien.tide-lyrics"
    function toggle(): string {
      root.broadcast("toggleLyrics")
      return "ok"
    }

    // Diagnostic snapshot for sync debugging:
    //   omarchy-shell io.github.elliotalien.tide-lyrics state
    function state(): string {
      return JSON.stringify({
        open: root.lyricsOpen,
        hasPlayer: !!root.activePlayer,
        player: root.activePlayer ? (root.activePlayer.identity || root.activePlayer.desktopEntry || "") : "",
        title: root.title,
        artist: root.artist,
        position: root.trackPosition,
        length: root.trackLength,
        isPlaying: root.isPlaying,
        lineCount: root.lyricLines.length,
        timed: root.lyricTimes.length === root.lyricLines.length && root.lyricLines.length > 0,
        firstLineTime: root.lyricTimes.length > 0 ? root.lyricTimes[0] : -1,
        index: root.currentLyricIndex,
        status: root.lyricsStatus
      })
    }
  }

  Instantiator {
    model: Mpris.players
    delegate: Connections {
      required property var modelData
      target: modelData
      function onIsPlayingChanged() { root.playerRevision++ }
      function onMetadataChanged() { root.playerRevision++ }
      function onTrackTitleChanged() { root.playerRevision++ }
      function onTrackArtistChanged() { root.playerRevision++ }
    }
  }

  Process {
    id: lyricsProcess
    stdout: StdioCollector {
      id: lyricsOutput
      waitForEnd: true
    }
  }

  function beginCurl(url) {
    // Process.running = false only terminates the old curl; it still emits
    // exited, and that stale exit (with its old body) would otherwise be
    // attributed to this new request. Ignore exactly that one exit.
    if (lyricsProcess.running) {
      root.ignoreNextExit = true
      lyricsProcess.running = false
    }
    // LRCLIB answers anonymous-looking clients with HTTP 503 "server is busy"
    // mid-chain (observed live), which silently aborted the whole lookup.
    // A descriptive User-Agent plus bounded retries of transient 5xx rides
    // through it; plain 404s (no such track) are still fail-fast.
    lyricsProcess.command = [
      "curl", "-fsSL", "--max-time", "8", "--proto", "=https",
      // Bound the response body like the artwork fetch does: the plugins
      // parse whatever arrives before rendering anything.
      "--max-filesize", "2097152",
      "-A", "Tide-lyrics/1.0 (Omarchy shell bar widget)",
      "--retry", "2", "--retry-delay", "1", "--retry-max-time", "12",
      url
    ]
    lyricsProcess.running = true
  }

  // Stage 1: exact artist+title match. One request, and when the artist is a
  // real artist name it is usually the right recording.
  function beginExactLookup() {
    root.lookupStage = "get"
    beginCurl("https://lrclib.net/api/get?artist_name=" + encodeURIComponent(root.artist)
      + "&track_name=" + encodeURIComponent(root.title))
  }

  // Stage 2+: progressively simpler forms of the same title (parentheses
  // stripped, doubled suffixes collapsed, core after the artist dash). As the
  // last resort, the stage-1 record is still shown rather than nothing.
  function beginSearchLookup() {
    var next = root.searchCandidates.length > 0 ? root.searchCandidates.shift() : ""
    if (next) {
      root.lookupStage = "search"
      beginCurl("https://lrclib.net/api/search?track_name=" + encodeURIComponent(next))
      return
    }
    if (root.fallbackRecord) {
      var record = root.fallbackRecord
      root.fallbackRecord = null
      root.applyLyricRecord(record)
      return
    }
    root.lyricsStatus = "Lyrics are unavailable for this track."
    noLyricsAutoClose.restart()
  }

  // LRCLIB carries several versions of the same song (album, video, live,
  // karaoke) whose lengths differ by up to minutes; picking the wrong one
  // throws the lyrics dozens of seconds off - the classic "sync issue". Rank
  // candidates by distance from the playing track's length, preferring entries
  // that actually carry timestamps over plain text.
  function bestLyricRecord(records) {
    if (!records || records.length === 0) return null
    var best = null
    var bestScore = null
    for (var i = 0; i < records.length; i++) {
      var record = records[i]
      if (!record) continue
      var hasSynced = String(record.syncedLyrics || "").trim() !== ""
      var hasPlain = String(record.plainLyrics || "").trim() !== ""
      if (!hasSynced && !hasPlain) continue
      var duration = Number(record.duration)
      var delta = (root.trackLength > 0 && isFinite(duration) && duration > 0)
        ? Math.abs(duration - root.trackLength) : 600
      // Tiers: a same-length recording beats a differently-cut one even when
      // the other carries timestamps - lyrics timed for a different cut of the
      // song play visibly out of sync, which is worse than untimed lyrics for
      // the right cut. Within a tier, shorter distance wins.
      var score
      if (delta <= 15) score = hasSynced ? delta : 500 + delta
      else score = (hasSynced ? 1000 : 1500) + Math.min(delta, 600)
      // Same artist name (channel-style spellings included) is a strong
      // tie-breaker between unrelated songs of near-identical length.
      if (MediaModel.artistNamesMatch(record.artistName, root.artist)) score -= 250
      if (bestScore === null || score < bestScore) {
        bestScore = score
        best = record
      }
    }
    return best
  }

  function applyLyricRecord(record) {
    var synced = String(record.syncedLyrics || "").trim()
    root.lyricLines = []
    root.lyricTimes = []
    root.currentLyricWords = []
    root.currentLyricIndex = -1
    root.lyricWordProgress = 0
    if (synced) {
      var timestampPattern = /^\s*\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]/
      var entries = []
      synced.split(/\r?\n/).forEach(function(line) {
        // A line may carry several timestamps ("[00:10.00][00:40.00]chorus").
        // The old parser only read the first tag and kept the second inside the
        // displayed text, so a repeated chorus never highlighted.
        var rest = line
        var times = []
        var match = rest.match(timestampPattern)
        while (match) {
          var fraction = match[3] ? Number("0." + match[3]) : 0
          times.push(Number(match[1]) * 60 + Number(match[2]) + fraction)
          rest = rest.substring(match[0].length)
          match = rest.match(timestampPattern)
        }
        var text = rest.trim()
        if (times.length === 0 || !text) return
        for (var i = 0; i < times.length; i++) entries.push({ time: times[i], text: text })
      })
      // The parallel arrays must stay in time order: updateLyricIndex stops at
      // the first timestamp past the playhead, so an out-of-order repeat would
      // park the highlight on the wrong line.
      entries.sort(function(a, b) { return a.time - b.time })
      for (var e = 0; e < entries.length; e++) {
        root.lyricTimes.push(entries[e].time)
        root.lyricLines.push(entries[e].text)
      }
    }
    if (root.lyricLines.length === 0) {
      var plain = String(record.plainLyrics || "").trim()
      root.lyricLines = plain ? plain.split(/\r?\n/).filter(function(line) { return line.trim() !== "" }) : []
    }
    root.lyricsStatus = root.lyricLines.length > 0 ? "" : "Lyrics are unavailable for this track."
    if (root.lyricLines.length === 0) noLyricsAutoClose.restart()
    root.updateLyricIndex()
  }

  function loadLyrics(isTrackChange) {
    if (!root.title || !root.activePlayer) {
      // No player: clear everything and fold the bar away. Returning early here
      // used to leave the previous song's lyrics in place, which the timer then
      // rewound to line 1 on screen indefinitely.
      root.lyricLines = []
      root.lyricTimes = []
      root.currentLyricWords = []
      root.currentLyricIndex = -1
      root.lyricWordProgress = 0
      root.lyricsStatus = ""
      root.positionSyncSignature = ""
      root.trackPosition = 0
      noLyricsAutoClose.stop()
      root.lyricsOpen = false
      return
    }
    var requestKey = root.artist + "\n" + root.title
    root.lyricsRequestKey = requestKey
    noLyricsAutoClose.stop()
    root.lyricsStatus = "Loading lyrics..."
    // Restart the position estimate with this lookup. Opening mid-track seeds
    // from the player's real position: the local estimate starts at zero and,
    // for players that never announce Position changes (Chrome), would never
    // catch up to where the song actually is. A real track change still starts
    // from zero so the previous track's frozen end position cannot park the
    // lyrics on the new track's last line.
    var signature = MediaModel.trackSignature(root.activePlayer)
    var sameTrack = signature === root.positionSyncSignature
    var reading = root.readMprisPosition()
    var seed = sameTrack ? (reading >= 0 ? reading : root.trackPosition)
      : (isTrackChange ? 0 : (reading >= 0 ? reading : 0))
    root.positionSyncSignature = signature
    root.reseedPositionSync(seed)
    root.trackPosition = root.positionSync.position
    root.lyricLines = []
    root.lyricTimes = []
    root.currentLyricWords = []
    root.currentLyricIndex = -1
    root.lyricWordProgress = 0
    root.fallbackRecord = null
    root.searchCandidates = MediaModel.lyricsQueryCandidates(root.title)
    root.beginExactLookup()
  }

  onLyricsOpenChanged: if (lyricsOpen) loadLyrics(false)
  onTitleChanged: if (lyricsOpen) loadLyrics(true)
  onArtistChanged: if (lyricsOpen) loadLyrics(true)

  function updateLyricIndex() {
    if (lyricLines.length === 0) return
    var timed = lyricTimes.length === lyricLines.length && lyricTimes.length > 0
    // Timed lyrics carry their own clock and work without a track length; only
    // the plain-lyrics fallback needs to spread lines across the track.
    if (!timed && !(trackLength > 0)) {
      // Plain lyrics and no known duration: nothing to interpolate against, but
      // leaving currentLyricIndex at -1 hides the viewport while lyricsStatus is
      // empty, which showed an empty 300px strip. Show the first line instead.
      if (currentLyricIndex !== 0) {
        currentLyricIndex = 0
        currentLyricWords = String(lyricLines[0] || "").trim().split(/\s+/).filter(function(word) { return word !== "" })
      }
      lyricWordProgress = 0
      return
    }
    var nextIndex = -1
    var progress = 0
    if (timed) {
      for (var i = 0; i < lyricTimes.length; i++) {
        if (trackPosition >= lyricTimes[i]) nextIndex = i
        else break
      }
      nextIndex = Math.max(0, nextIndex)
      var start = lyricTimes[nextIndex]
      // Last line: run to the real track end when known, else assume the line
      // holds for a few seconds instead of refusing to advance.
      var end = nextIndex + 1 < lyricTimes.length ? lyricTimes[nextIndex + 1]
        : (trackLength > start ? trackLength : start + 10)
      progress = end > start ? Math.max(0, Math.min(1, (trackPosition - start) / (end - start))) : 0
    } else {
      nextIndex = Math.min(lyricLines.length - 1, Math.floor((trackPosition / trackLength) * lyricLines.length))
      var lineDuration = trackLength / lyricLines.length
      progress = lineDuration > 0 ? (trackPosition % lineDuration) / lineDuration : 0
    }
    if (nextIndex !== currentLyricIndex) {
      currentLyricIndex = nextIndex
      currentLyricWords = String(lyricLines[nextIndex] || "").trim().split(/\s+/).filter(function(word) { return word !== "" })
    }
    lyricWordProgress = progress
  }

  // No lyrics: show the track's own text for a beat, then fold the bar
  // away instead of parking "Lyrics are unavailable" on screen.
  Timer {
    id: noLyricsAutoClose
    interval: 1600
    onTriggered: root.lyricsOpen = false
  }

  Timer {
    interval: 250
    running: root.lyricsOpen
    repeat: true
    onTriggered: {
      // Track switch: never seed the estimate from the previous track's
      // position, which would park the lyrics on the old track's last line.
      var signature = MediaModel.trackSignature(root.activePlayer)
      if (signature !== root.positionSyncSignature) {
        root.positionSyncSignature = signature
        root.trackPosition = 0
        root.reseedPositionSync(0)
        root.updateLyricIndex()
        return
      }
      var value = MediaModel.samplePosition(root.positionSync, root.readMprisPosition(), root.isPlaying, Date.now())
      if (isFinite(value) && value >= 0)
        root.trackPosition = root.trackLength > 0 ? Math.min(value, root.trackLength) : value
      root.positionSync.position = root.trackPosition
      root.updateLyricIndex()
    }
  }

  onCurrentLyricIndexChanged: {
    lyricText.x = 0
    if (lyricScroll.running) lyricScroll.restart()
  }

  Connections {
    target: lyricsProcess
    function onExited(exitCode) {
      // Exit of a curl this plugin itself cancelled (see beginCurl).
      if (root.ignoreNextExit) {
        root.ignoreNextExit = false
        return
      }
      // A newer lookup replaced this one while curl was still running.
      if (root.lyricsRequestKey !== root.artist + "\n" + root.title) return

      var payload = null
      if (exitCode === 0) {
        try { payload = JSON.parse(lyricsOutput.text || "") }
        catch (error) { payload = null }
      }

      if (root.lookupStage === "get") {
        var record = (payload && typeof payload === "object" && !Array.isArray(payload)) ? payload : null
        var duration = record ? Number(record.duration) : NaN
        var hasText = record && (String(record.syncedLyrics || "").trim() !== ""
          || String(record.plainLyrics || "").trim() !== "")
        // Only take the exact match when its length agrees with the playing
        // track; a mismatched version is kept as a last-resort fallback while
        // the duration-ranked search looks for a better one.
        var aligned = hasText && (root.trackLength <= 0 || !isFinite(duration) || duration <= 0
          || Math.abs(duration - root.trackLength) <= 5)
        if (aligned) { root.applyLyricRecord(record); return }
        if (hasText) root.fallbackRecord = record
        root.beginSearchLookup()
        return
      }

      // Search stage: an array of candidates, ranked by length match.
      var records = Array.isArray(payload) ? payload : []
      var best = root.bestLyricRecord(records)
      if (best) { root.applyLyricRecord(best); return }
      root.beginSearchLookup()
    }
  }

  function lyricMarkup() {
    var words = currentLyricWords || []
    var completed = lyricWordProgress * words.length
    return words.map(function(word, index) {
      var safeWord = String(word).replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/\"/g, "&quot;")
      var color = index < completed ? Util.alpha(Color.accent, 0.3) : Color.accent
      return "<font color=\"" + color + "\">" + safeWord + "</font>"
    }).join(" ")
  }

  Item {
    anchors.fill: parent
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    clip: true

    Item {
      id: lyricViewport
      anchors.fill: parent
      visible: root.lyricsStatus === "" && root.currentLyricIndex >= 0
      opacity: visible ? 1 : 0
      scale: visible ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.InOutQuad } }
      Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.InOutQuad } }

      Text {
        id: lyricText
        x: 0
        height: parent.height
        width: Math.max(parent.width, implicitWidth)
        anchors.verticalCenter: parent.verticalCenter
        text: root.lyricMarkup()
        textFormat: Text.RichText
        horizontalAlignment: Text.AlignLeft
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.NoWrap
        color: root.lyricColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      SequentialAnimation {
        id: lyricScroll
        running: root.lyricsOpen && lyricText.width > lyricViewport.width
        loops: Animation.Infinite

        PauseAnimation { duration: 1100 }
        NumberAnimation {
          target: lyricText
          property: "x"
          to: -(lyricText.width - lyricViewport.width)
          duration: Math.max(1800, (lyricText.width - lyricViewport.width) * 28)
          easing.type: Easing.Linear
        }
        PauseAnimation { duration: 800 }
        NumberAnimation {
          target: lyricText
          property: "x"
          to: 0
          duration: 450
          easing.type: Easing.OutQuad
        }
      }
    }

    Text {
      anchors.fill: parent
      visible: root.lyricsStatus !== ""
      // No lyrics: show the track's own text instead of the error message;
      // the auto-close timer folds the bar away a beat later.
      text: root.lyricsStatus.indexOf("unavailable") !== -1
        ? "No lyrics"
        : (root.lyricsStatus || "Loading lyrics...")
      color: Qt.darker(root.lyricColor, 1.2)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
  }
}
