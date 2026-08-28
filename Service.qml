import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns everything stateful about the SIP account and the current call.
//
// The `omarchy-sip` daemon holds baresip's single control connection; this
// service reads its JSON journal (one object per line) and pushes commands
// back. Call state is driven by *events*, never by polling -- the status
// snapshot exists only to resync after a shell restart, when the last
// registration event may be minutes in the past.
Item {
  id: root

  property var settings: ({})

  // ------------------------------------------------------------------ limits
  //
  // The CLI bounds what it prints, but this side must bound what it retains:
  // StdioCollector holds an entire stream, so anything whose full text we do
  // not actually need is consumed a line at a time and clipped as it arrives.
  readonly property int maxLineChars: 65536    // matches MAX_LINE in the CLI
  readonly property int maxJsonChars: 262144   // a status/history document
  readonly property int maxErrorChars: 240     // what lastError can ever hold

  // Qt.resolvedUrl(".") may or may not carry a trailing slash depending on the
  // loader, so normalise before appending.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/+$/, "")
  readonly property string cli: pluginDir + "/bin/omarchy-sip"

  // ------------------------------------------------------------------ state
  property bool installed: false
  property bool unitActive: false
  property bool daemonUp: false
  property bool configured: false
  property string aor: ""
  // unknown | none | pending | registered | failed
  property string registration: "unknown"
  // idle | incoming | outgoing | ringing | active
  property string callState: "idle"
  property string peer: ""
  property string callId: ""
  property double callStartedAt: 0
  property string lastError: ""
  property string lastClosedReason: ""
  // Recent calls, newest first, as recorded by the daemon.
  property var history: []

  readonly property bool ready: daemonUp && configured && registration === "registered"
  readonly property bool busy: actionProcess.running
  readonly property bool ringing: callState === "incoming"
  readonly property bool onCall: Model.inCall(callState)

  // Bundled for Model.heroMeta so the panel doesn't hand-assemble it.
  readonly property var snapshot: ({
    daemonUp: daemonUp,
    configured: configured,
    registration: registration,
    aor: aor,
    callState: callState,
    lastError: lastError
  })

  signal incomingCall(string peerUri)

  readonly property int statusRefreshSec: intSetting("statusRefreshSec", 60, 10, 600)
  readonly property int historyLimit: intSetting("historyLimit", 5, 0, 20)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    return value === true || value === "true"
  }

  // ---------------------------------------------------------------- commands

  function refresh() {
    refreshHistory()
    if (statusProcess.running) return
    statusProcess.command = [cli, "status"]
    statusProcess.running = true
    statusWatchdog.restart()
  }

  function refreshHistory() {
    if (historyProcess.running || historyLimit === 0) return
    historyProcess.command = [cli, "history", "--limit", String(historyLimit)]
    historyProcess.running = true
    historyWatchdog.restart()
  }

  function run(args) {
    if (actionProcess.running) return
    lastError = ""
    actionProcess.errText = ""
    actionProcess.command = [cli].concat(args)
    actionProcess.running = true
    actionWatchdog.restart()
  }

  // Keeps a bounded prefix of a process's diagnostic output. Called per line,
  // so nothing larger than one line is ever held, let alone the whole stream.
  function appendBounded(buf, line) {
    if (buf.length >= maxErrorChars) return buf
    var text = String(line || "").replace(/\s+/g, " ")
    return (buf === "" ? text : buf + " " + text).substring(0, maxErrorChars)
  }

  function dial(input) {
    var target = Model.normalizeTarget(input, aor)
    if (target === "") return
    // Optimistic: the panel switches to "calling" immediately and the real
    // CALL_OUTGOING / CALL_CLOSED event corrects it a moment later.
    callState = "outgoing"
    peer = Model.peerLabel(target)
    callStartedAt = 0
    run(["dial", target])
  }

  function answer() {
    if (callState !== "incoming") return
    run(["answer"])
  }

  function hangup() {
    if (callState === "idle") return
    run(["hangup"])
  }

  function startDaemon() { run(["start"]) }

  // Password goes over stdin so it never appears in a process listing.
  function setAccount(uri, authUser, displayName, transport, password) {
    if (accountProcess.running) return
    var args = [cli, "account", "set", uri]
    if (authUser) args = args.concat(["--auth-user", authUser])
    if (displayName) args = args.concat(["--display-name", displayName])
    if (transport) args = args.concat(["--transport", transport])
    lastError = ""
    accountProcess.errText = ""
    accountProcess.command = args
    accountProcess.running = true
    accountWatchdog.restart()
    accountProcess.write(String(password || "") + "\n")
    accountProcess.stdinEnabled = false
  }

  // ------------------------------------------------------------------ events

  function handleLine(line) {
    var text = String(line || "")
    // The journal caps its own records, but this listener runs for the whole
    // shell session: refuse an oversized line before it reaches JSON.parse.
    if (text.length > maxLineChars) return
    text = text.trim()
    if (text === "") return
    var event
    try {
      event = JSON.parse(text)
    } catch (e) {
      return   // not ours; the journal only ever holds JSON, so ignore quietly
    }

    var update = Model.classifyEvent(event)
    if (!update) return

    if (update.kind === "ctrl") {
      daemonUp = update.connected
      if (!update.connected) {
        callState = "idle"
        peer = ""
        callId = ""
        callStartedAt = 0
        if (update.error) lastError = update.error
      } else {
        refresh()
      }
      return
    }

    if (update.kind === "registration") {
      registration = update.registration
      if (update.aor) aor = update.aor
      lastError = update.registration === "failed" ? (update.error || "Registration failed") : ""
      return
    }

    if (update.kind === "call") {
      var wasRinging = callState === "incoming"
      callState = update.callState
      if (update.callState === "idle") {
        peer = ""
        callId = ""
        callStartedAt = 0
        lastClosedReason = update.closedReason || ""
        // The daemon writes the log row as it handles this same event, so give
        // it a beat before reading the file back.
        historySettleTimer.restart()
      } else {
        if (update.peer) peer = update.peer
        if (update.callId) callId = update.callId
        if (update.started && callStartedAt === 0) callStartedAt = Date.now()
      }
      if (update.callState === "incoming" && !wasRinging) {
        notifyIncoming(peer)
        root.incomingCall(peer)
      }
    }
  }

  function notifyIncoming(peerUri) {
    if (!boolSetting("ringNotifications", true)) return
    // Critical urgency so it survives Do Not Disturb -- a missed call is worse
    // than an interruption, and the notification is the only cue when the
    // panel is closed.
    Quickshell.execDetached([
      "notify-send", "-u", "critical", "-a", "Simple SIP",
      "-i", "call-start-symbolic",
      "Incoming call", peerUri || "unknown caller"
    ])
  }

  function applyStatus(text) {
    var raw = String(text || "")
    if (raw.length > maxJsonChars) return
    var status
    try {
      status = JSON.parse(raw)
    } catch (e) {
      return
    }
    installed = status.installed === true
    unitActive = status.unitActive === true
    daemonUp = status.daemonUp === true
    configured = status.configured === true
    if (status.aor) aor = String(status.aor)

    // reginfo is authoritative on startup; events take over from there.
    if (status.reginfo && status.reginfo.data !== undefined) {
      registration = Model.parseReginfo(status.reginfo.data, aor)
    } else if (!daemonUp) {
      registration = "unknown"
    }

    // A call that ended while the shell was restarting leaves stale UI state.
    if (status.calls && status.calls.data !== undefined) {
      if (Model.parseCallCount(status.calls.data) === 0 && callState !== "incoming") {
        callState = "idle"
        peer = ""
        callId = ""
        callStartedAt = 0
      }
    }
  }

  // ----------------------------------------------------------------- process

  // Long-lived: a bar widget is loaded for the whole shell session, so this is
  // the always-on listener that makes an inbound call ring even with the panel
  // closed.
  Process {
    id: eventsProcess
    command: [root.cli, "events"]
    running: true
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    onExited: function(exitCode) {
      root.daemonUp = false
      restartTimer.restart()
    }
  }

  // The one place a whole document is needed, so StdioCollector stays -- but
  // the CLI clamps --limit and clips every field, and the watchdog below bounds
  // how long this can run at all.
  Process {
    id: historyProcess
    running: false
    command: []
    stdout: StdioCollector { id: historyOut; waitForEnd: true }
    onExited: function(exitCode) {
      historyWatchdog.stop()
      if (exitCode !== 0) return
      var raw = String(historyOut.text || "[]")
      if (raw.length > root.maxJsonChars) return
      try {
        var parsed = JSON.parse(raw)
        root.history = Array.isArray(parsed) ? parsed : []
      } catch (e) {
        root.history = []
      }
    }
  }

  Timer {
    id: historySettleTimer
    interval: 400
    onTriggered: root.refreshHistory()
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    // No stderr parser: with none set Quickshell discards the stream, which is
    // what we want here -- nothing read it, and collecting it only retained it.
    onExited: function(exitCode) {
      statusWatchdog.stop()
      if (exitCode === 0) root.applyStatus(statusOut.text)
      else root.daemonUp = false
    }
  }

  // Only ever needs an error message, so both streams feed one bounded buffer
  // instead of two StdioCollectors retaining everything the CLI ever printed.
  Process {
    id: actionProcess
    property string errText: ""
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(line) { actionProcess.errText = root.appendBounded(actionProcess.errText, line) }
    }
    stderr: SplitParser {
      onRead: function(line) { actionProcess.errText = root.appendBounded(actionProcess.errText, line) }
    }
    onExited: function(exitCode) {
      actionWatchdog.stop()
      if (exitCode !== 0) {
        root.lastError = elide(actionProcess.errText || "Command failed")
        // The optimistic dial never happened -- fall back to what is real.
        root.refresh()
      }
    }
  }

  Process {
    id: accountProcess
    property string errText: ""
    running: false
    command: []
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { accountProcess.errText = root.appendBounded(accountProcess.errText, line) }
    }
    stderr: SplitParser {
      onRead: function(line) { accountProcess.errText = root.appendBounded(accountProcess.errText, line) }
    }
    onExited: function(exitCode) {
      accountWatchdog.stop()
      if (exitCode !== 0) root.lastError = elide(accountProcess.errText || "Could not save account")
      else root.lastError = ""
      accountProcess.stdinEnabled = true
      // The daemon restarts on an account change; give it a moment to register.
      accountSettleTimer.restart()
    }
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 160 ? value.substring(0, 157) + "…" : value
  }

  // ------------------------------------------------------------- watchdogs
  //
  // Every finite CLI call gets a whole-process deadline. Setting running to
  // false terminates the child, so a helper wedged on a substituted file or a
  // registrar that never answers cannot hold a slot (or its output buffer)
  // open for the rest of the shell session. eventsProcess is deliberately
  // exempt: it is the long-lived listener, and is bounded by the record cap
  // the journal reader enforces instead.
  Timer {
    id: statusWatchdog
    interval: 15000
    onTriggered: if (statusProcess.running) { statusProcess.running = false; root.daemonUp = false }
  }

  Timer {
    id: historyWatchdog
    interval: 10000
    onTriggered: if (historyProcess.running) historyProcess.running = false
  }

  Timer {
    id: actionWatchdog
    interval: 15000
    onTriggered: {
      if (!actionProcess.running) return
      actionProcess.running = false
      root.lastError = "Command timed out"
      root.refresh()
    }
  }

  // An account change restarts the daemon, so this one is allowed to be slower.
  Timer {
    id: accountWatchdog
    interval: 20000
    onTriggered: {
      if (!accountProcess.running) return
      accountProcess.running = false
      root.lastError = "Saving the account timed out"
    }
  }

  // The journal only exists while the daemon runs, so `events` exits whenever
  // the daemon is down. Retry steadily rather than giving up.
  Timer {
    id: restartTimer
    interval: 3000
    onTriggered: {
      eventsProcess.running = true
      root.refresh()
    }
  }

  Timer {
    id: accountSettleTimer
    interval: 2500
    onTriggered: root.refresh()
  }

  // Cheap safety net: events carry the truth, this catches a daemon that died
  // and came back while nothing was happening.
  Timer {
    interval: root.statusRefreshSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()
}
