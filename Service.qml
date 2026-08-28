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
  }

  function refreshHistory() {
    if (historyProcess.running || historyLimit === 0) return
    historyProcess.command = [cli, "history", "--limit", String(historyLimit)]
    historyProcess.running = true
  }

  function run(args) {
    if (actionProcess.running) return
    lastError = ""
    actionProcess.command = [cli].concat(args)
    actionProcess.running = true
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
    accountProcess.command = args
    accountProcess.running = true
    accountProcess.write(String(password || "") + "\n")
    accountProcess.stdinEnabled = false
  }

  // ------------------------------------------------------------------ events

  function handleLine(line) {
    var text = String(line || "").trim()
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
    var status
    try {
      status = JSON.parse(String(text || ""))
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

  Process {
    id: historyProcess
    running: false
    command: []
    stdout: StdioCollector { id: historyOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        root.history = JSON.parse(String(historyOut.text || "[]"))
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
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyStatus(statusOut.text)
      else root.daemonUp = false
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = elide(actionErr.text || actionOut.text || "Command failed")
        // The optimistic dial never happened -- fall back to what is real.
        root.refresh()
      }
    }
  }

  Process {
    id: accountProcess
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector { id: accountOut; waitForEnd: true }
    stderr: StdioCollector { id: accountErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = elide(accountErr.text || accountOut.text || "Could not save account")
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
