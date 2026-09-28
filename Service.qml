import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import "Model.js" as Model

// Owns everything stateful about the SIP account and the current call.
//
// The `omarchy-sip` daemon holds baresip's control connection; this service
// reads its event stream (one JSON object per line, via `omarchy-sip events`)
// and pushes commands back. Call state is driven by *events*, never by polling -- the status
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

  // This instance's reply token, so the daemon's refusal of somebody else's
  // command (another panel copy, a script) is never taken for this one's.
  readonly property string panelToken: "panel-" + Math.random().toString(36).substring(2, 12)

  // Qt.resolvedUrl(".") may or may not carry a trailing slash depending on the
  // loader, so normalise before appending.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/+$/, "")
  readonly property string cli: pluginDir + "/bin/omarchy-sip"

  // Every child this file launches gets an explicit, minimal environment
  // rather than the shell's. `bin/omarchy-sip` is `#!/usr/bin/python3 -I`, so
  // the interpreter is absolute and isolated already, but the loader still
  // reads LD_PRELOAD/LD_LIBRARY_PATH from whatever omarchy-shell happens to
  // have inherited, and a writable PATH entry would decide which `systemctl`
  // the CLI finds. `clearEnvironment: true` plus these keys is the whole
  // surface: HOME and XDG_RUNTIME_DIR locate the config and runtime
  // directories, DBUS_SESSION_BUS_ADDRESS lets `systemctl --user` reach the
  // user manager, LANG, the plugin's own OMARCHY_SIP_* overrides below, and a
  // PATH that is fixed rather than inherited.
  readonly property string cleanPath: "/usr/local/bin:/usr/bin:/bin"

  // The OMARCHY_SIP_* keys are this plugin's own documented overrides and have
  // to be forwarded: the daemon runs under `systemd --user`, which still sees
  // them, so dropping them here would leave the panel reading
  // ~/.config/omarchy-sip while the daemon reads OMARCHY_SIP_CONF -- the panel
  // would report "no account", write credentials to the wrong directory, and
  // restart a daemon that never sees them. They select configuration, not code:
  // the directory they name is still pinned and ownership-checked like any
  // other, so forwarding them costs nothing the execution-trust rule protects.
  function cleanEnv() {
    var env = { "PATH": cleanPath }
    var keys = ["HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "LANG",
                "OMARCHY_SIP_CONF", "OMARCHY_SIP_LISTEN", "OMARCHY_SIP_INTERFACE"]
    for (var i = 0; i < keys.length; i++) {
      var value = Quickshell.env(keys[i])
      if (value) env[keys[i]] = String(value)
    }
    return env
  }

  // Events and commands both go through the CLI as a subprocess rather than a
  // QML Socket connected to the control path directly. Two things Quickshell
  // does not give QML a way to do itself: SplitParser has no byte ceiling, so
  // a peer that never sends a newline grows its buffer in this long-lived
  // shell process without bound; and a plain `path` string is resolved fresh
  // on connect, so it does not benefit from the pinned-descriptor resolution
  // the daemon uses for everything else. `read_lines()` in the CLI already
  // enforces MAX_LINE per record before anything is printed, and it resolves
  // the socket through the same pinned runtime-directory descriptor the
  // daemon itself walks -- so routing through it closes both gaps at once,
  // at the cost of one always-running child process instead of none.

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
  // Tracked here, not reported: baresip emits no event for either. Both
  // belong to the current call and are cleared whenever it changes.
  property bool muted: false
  property bool onHold: false
  // DTMF sent during this call, for the panel to echo back (last 24 only).
  property string sentDigits: ""
  // The last optimistic mute/hold change, so a refusal can put it back.
  property var pendingToggle: null
  // Which of the two sources spoke last. A status snapshot is a request/reply
  // round trip, so its answer can predate a call event that arrived while it
  // was in flight -- comparing these is what keeps applyStatus from clearing a
  // call that started after it asked.
  property double lastCallEventAt: 0
  property double statusRequestedAt: 0
  // When the panel last sent a dial. A refusal that arrives with no call event
  // after this is the refusal of that dial, so the optimistic "Calling…" goes.
  property double dialSentAt: 0
  // Recent calls, newest first, as recorded by the daemon.
  property var history: []
  // Missed calls logged since the panel was last opened, over the whole log.
  property int unseenMissed: 0
  // Saved contacts, [{name, uri}], as `omarchy-sip contacts` lists them.
  property var contacts: []

  // The last voicemail summary the server sent (see Model.parseMwi).
  property var mwi: ({ waiting: false, newCount: 0, oldCount: 0, account: "" })
  property bool markSeenPending: false
  // The stored account as `account show` reports it -- everything the setup
  // form edits except the password, of which only hasPassword is known.
  property var accountDetails: ({})
  // The daemon's own options (options.json), as last reported by it.
  property var daemonOptions: ({})
  // Set by the panel on exactly one copy of the widget, so a multi-monitor
  // bar does not write the same option once per monitor.
  property bool optionSync: false
  // Also leader-only: pausing media once, not once per monitor.
  property bool mediaControl: false
  // Players this service paused for the current call, by D-Bus name, so only
  // those are resumed -- never something the person paused themselves.
  property var pausedPlayers: []
  property var pendingOptions: ({})
  // Do Not Disturb as the panel should show it: a toggle still on its way to
  // the daemon counts, so the row flips at once.
  readonly property bool dnd: typeof pendingOptions.dnd === "boolean" ? pendingOptions.dnd
                                                                      : daemonOptions.dnd === true

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
    lastError: lastError,
    muted: muted,
    onHold: onHold,
    newVoicemail: mwi.newCount
  })

  signal incomingCall(string peerUri)
  // A notification was clicked. The panel decides which copy opens.
  signal showRequested()
  // A sip:/tel: link was opened: the panel fills its dial field with this.
  signal prefillRequested(string target)

  readonly property int statusRefreshSec: intSetting("statusRefreshSec", 60, 10, 600)
  readonly property int historyLimit: intSetting("historyLimit", 5, 0, 20)

  // Backoff for respawning the `events` subprocess while the daemon is
  // unreachable -- each retry is a Python interpreter start, not a syscall.
  readonly property int eventsRetryMinMs: 3000
  readonly property int eventsRetryMaxMs: 30000
  property int eventsRetryMs: eventsRetryMinMs

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function stringSetting(name, fallback, maxLength) {
    return String(setting(name, fallback)).trim().substring(0, maxLength)
  }

  // Where "Call voicemail" goes: the configured number, or the account the
  // voicemail server itself named. Empty when neither is known.
  readonly property string voicemailTarget:
    Model.voicemailTarget(stringSetting("voicemailNumber", "", 64), mwi.account, aor)

  // A saved name for a peer, matched as Model.contactName allows.
  function nameFor(uri) { return Model.contactName(uri, contacts, aor) }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    return value === true || value === "true"
  }

  // ---------------------------------------------------------------- commands

  function refresh() {
    refreshHistory()
    if (statusProcess.running) return
    statusRequestedAt = Date.now()
    statusProcess.command = [cli, "status"]
    statusProcess.running = true
    statusWatchdog.restart()
  }

  // Runs even with historyLimit 0: the list may be hidden, but the missed-call
  // count still drives the bar badge.
  function refreshHistory() {
    if (historyProcess.running) return
    var args = [cli, "history", "--limit", String(historyLimit)]
    if (markSeenPending) args.push("--mark-seen")
    markSeenPending = false
    historyProcess.command = args
    historyProcess.running = true
    historyWatchdog.restart()
  }

  // Opening the panel is looking at the log.
  function markHistorySeen() {
    markSeenPending = true
    if (historyProcess.running) return   // picked up by the next refresh
    refreshHistory()
  }

  // Commands run one CLI process at a time, in order. One that arrives while
  // another is in flight waits its turn rather than being dropped: an answer
  // pressed a moment after a dial, or a hangup pressed twice, has to happen.
  // The queue is bounded so a stuck daemon cannot make it grow without limit;
  // returns false only when it is full, so a caller that needs to know whether
  // its command will go out (dial's optimistic UI) can resync instead.
  readonly property int maxQueuedCommands: 32
  property var commandQueue: []

  function run(args) {
    if (actionProcess.running) {
      if (commandQueue.length >= maxQueuedCommands) return false
      commandQueue = commandQueue.concat([args])
      return true
    }
    startAction(args)
    return true
  }

  function startAction(args) {
    lastError = ""
    actionProcess.errText = ""
    actionProcess.command = [cli].concat(args)
    actionProcess.running = true
    actionWatchdog.restart()
  }

  // What the panel's settings say the daemon's options should be. dnd is not
  // here: it is toggled at run time and lives only in the daemon.
  function wantedOptions() {
    return {
      notifications: boolSetting("ringNotifications", true),
      regAlerts: boolSetting("registrationAlerts", true),
      aec: boolSetting("echoCancellation", false)
    }
  }

  function syncOptions() {
    if (!optionSync || !daemonUp) return
    var changes = Model.optionChanges(wantedOptions(), daemonOptions, pendingOptions,
                                      callState === "idle")
    for (var i = 0; i < changes.length; i++) setOption(changes[i][0], changes[i][1])
  }

  function setOption(key, value) {
    var pending = Object.assign({}, pendingOptions)
    pending[key] = value
    pendingOptions = pending
    // Not queued means not happening: drop the pending value, or the panel
    // would show (and act on) a setting the daemon never got.
    if (!run(["option", "set", key, value ? "on" : "off"])) {
      var undo = Object.assign({}, pendingOptions)
      delete undo[key]
      pendingOptions = undo
    }
  }

  function toggleDnd() {
    if (typeof daemonOptions.dnd !== "boolean") return "the daemon has not reported its options yet"
    setOption("dnd", !dnd)
    return ""
  }

  onSettingsChanged: syncOptions()
  // The form fills from these; an account set or cleared elsewhere (the CLI,
  // another panel copy) must not leave the old details on screen.
  onConfiguredChanged: loadAccount()
  onOptionSyncChanged: syncOptions()

  function drainQueue() {
    if (actionProcess.running || commandQueue.length === 0) return
    var next = commandQueue[0]
    commandQueue = commandQueue.slice(1)
    startAction(next)
  }

  // `omarchy-sip send` -- fire-and-forget, one line down the control socket --
  // as a short subprocess rather than a direct QML Socket write. The CLI
  // resolves the socket through the daemon's own pinned directory descriptor
  // instead of a bare path string, and the existing action watchdog and
  // bounded error buffer come for free.
  // `--` before the command: a parameter is often caller-chosen -- a
  // Call-ID may begin with "-" -- and must never be read as an option.
  function command(name, params) {
    var args = ["send", "--token=" + panelToken, "--", name]
    return run(params ? args.concat([params]) : args)
  }

  // Keeps a bounded prefix of a process's diagnostic output. Called per line,
  // so nothing larger than one line is ever held, let alone the whole stream.
  function appendBounded(buf, line) {
    if (buf.length >= maxErrorChars) return buf
    var text = String(line || "").replace(/\s+/g, " ")
    return (buf === "" ? text : buf + " " + text).substring(0, maxErrorChars)
  }

  // dial/answer/hangup return "" when the command went out, or why it did
  // not -- which the IpcHandler hands back instead of an unconditional "ok".
  function dial(input) {
    if (onCall || callState === "incoming") return "a call is already in progress"
    var target = Model.normalizeTarget(input, aor)
    if (target === "") return "nothing to dial"
    // Refuse here what the daemon would refuse there. Its refusal does come
    // back (see "commandFailed" below), but only after the panel has already
    // said "Calling…" -- checking first means it never says it.
    if (!Model.validTarget(target)) {
      lastError = elide("Can't dial " + target)
      return "not a dialable address: " + target
    }
    // Optimistic: the panel switches to "calling" immediately and the real
    // CALL_OUTGOING / CALL_CLOSED event corrects it a moment later.
    dialSentAt = Date.now()
    callState = "outgoing"
    peer = Model.peerLabel(target)
    callStartedAt = 0
    if (!command("dial", target)) {
      refresh()
      return "too many commands queued"
    }
    return ""
  }

  // Mirrors dial(): a caller that fires while another action is still in
  // flight (a double press on answer/hangup, or two calls to the IpcHandler
  // back to back) must not have its command silently dropped with the UI
  // left showing a call state that no longer matches what actually happened.
  // Name the call when its id is known and nameable, so the command can only
  // ever reach the call on screen; baresip's "current call" otherwise.
  function callParam() {
    return Model.validCallId(callId) ? callId : ""
  }

  function answer() {
    if (callState !== "incoming") return "no call is ringing"
    if (!command("accept", callParam())) { refresh(); return "too many commands queued" }
    return ""
  }

  function hangup() {
    if (callState === "idle") return "no call in progress"
    if (!command("hangup", callParam())) { refresh(); return "too many commands queued" }
    return ""
  }

  // Optimistic, like dial(): the row flips at once, and a refusal from the
  // daemon (see "commandFailed") flips it back.
  function toggleMute() {
    if (!onCall) return "no call in progress"
    var next = !muted
    pendingToggle = { kind: "mute", previous: muted }
    toggleTimer.restart()
    muted = next
    if (!command("mute", next ? "yes" : "no")) { muted = !next; return "too many commands queued" }
    return ""
  }

  function toggleHold() {
    if (callState !== "active") return "no answered call to hold"
    var next = !onHold
    pendingToggle = { kind: "hold", previous: onHold }
    toggleTimer.restart()
    onHold = next
    if (!command(next ? "hold" : "resume", callParam())) { onHold = !next; return "too many commands queued" }
    return ""
  }

  // Blind transfer: hand the current call to someone else and drop out. The
  // far end is asked (REFER); if it agrees the call closes like any other,
  // and if not a TRANSFER_FAILED event says why.
  function transfer(input) {
    if (!onCall) return "no call in progress"
    var target = Model.normalizeTarget(input, aor)
    if (target === "") return "nothing to transfer to"
    if (!Model.validTarget(target)) {
      lastError = elide("Can't transfer to " + target)
      return "not a dialable address: " + target
    }
    if (!command("transfer", target)) return "too many commands queued"
    return ""
  }

  function pauseMedia() {
    if (!mediaControl || !boolSetting("pauseMediaOnCall", true)) return
    var players = Mpris.players ? Mpris.players.values : []
    var paused = pausedPlayers.slice()
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (p && p.isPlaying && p.canPause) {
        p.pause()
        paused.push(p.dbusName + "\n" + p.identity)
      }
    }
    pausedPlayers = paused
  }

  function resumeMedia() {
    if (pausedPlayers.length === 0) return
    var players = Mpris.players ? Mpris.players.values : []
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      // Same bus name *and* identity: a player that quit during the call and
      // had its name taken by another is not the one that was paused.
      if (p && pausedPlayers.indexOf(p.dbusName + "\n" + p.identity) >= 0 && !p.isPlaying && p.canPlay) p.play()
    }
    pausedPlayers = []
  }

  // Idle -> anything is a call starting (ringing or dialling); anything ->
  // idle is it ending, answered or not.
  property string previousCallState: "idle"
  onCallStateChanged: {
    if (previousCallState === "idle" && callState !== "idle") pauseMedia()
    else if (callState === "idle") resumeMedia()
    previousCallState = callState
  }

  function redial() {
    var target = Model.lastOutbound(history)
    if (target === "") return "no outgoing call to redial"
    return dial(target)
  }

  function resetCallControls() {
    muted = false
    onHold = false
    pendingToggle = null
    sentDigits = ""
  }

  function sendDigits(digits) {
    var d = String(digits || "")
    if (callState !== "active") return "no answered call"
    if (!Model.validDigits(d)) return "not keypad digits: " + d
    if (actionProcess.running) {
      if (commandQueue.length >= maxQueuedCommands) return "too many commands queued"
      commandQueue = Model.queueDigits(commandQueue, d, panelToken)
    } else {
      startAction(["send", "--token=" + panelToken, "--", "sndcode", d])
    }
    sentDigits = (sentDigits + d).slice(-24)
    return ""
  }

  function startDaemon() { run(["start"]) }

  function loadContacts() { return runContacts([cli, "contacts"]) }

  // An empty name removes the contact. Both answer with the new list, so the
  // panel never shows a contact the CLI refused to store.
  function saveContact(uri, name) {
    var target = Model.redialTarget({ peer: uri })
    if (target === "") return false
    var n = String(name || "").trim()
    return runContacts(n === "" ? [cli, "contacts", "remove", target]
                                : [cli, "contacts", "add", target, "--name=" + n])
  }

  function runContacts(args) {
    if (contactsProcess.running) return false
    contactsProcess.errText = ""
    contactsProcess.command = args
    contactsProcess.running = true
    contactsWatchdog.restart()
    return true
  }

  function loadAccount() {
    if (accountShowProcess.running) return
    accountShowProcess.command = [cli, "account", "show"]
    accountShowProcess.running = true
    accountShowWatchdog.restart()
  }

  // Password goes over stdin so it never appears in a process listing.
  // Returns false if a save is already in flight, so the caller knows not to
  // clear the form -- dropping the typed password on the floor is worse than
  // making the user press Save again.
  //
  // Always --merge: the form never shows the stored password, so a blank one
  // means "unchanged", and the CLI keeps it (and outbound/regint, which the
  // form does not edit) rather than saving an account with no password.
  // Auth user and display name are always passed, so clearing either field
  // does clear it.
  function setAccount(uri, authUser, displayName, transport, password) {
    if (accountProcess.running) return false
    // `--opt=value` forms: a value that starts with "-" is then still a value,
    // not an option argparse refuses (after the form has already closed).
    var args = [cli, "account", "set", "--merge",
                "--auth-user=" + String(authUser || ""),
                "--display-name=" + String(displayName || "")]
    if (transport) args.push("--transport=" + transport)
    args.push("--", uri)
    lastError = ""
    accountProcess.errText = ""
    accountProcess.command = args
    accountProcess.running = true
    accountWatchdog.restart()
    accountProcess.write(String(password || "") + "\n")
    accountProcess.stdinEnabled = false
    return true
  }

  // ------------------------------------------------------------------ events

  function handleLine(line) {
    var text = String(line || "")
    // The CLI caps its own records, but this listener runs for the whole
    // shell session: refuse an oversized line before it reaches JSON.parse.
    if (text.length > maxLineChars) return
    text = text.trim()
    if (text === "") return
    var event
    try {
      event = JSON.parse(text)
    } catch (e) {
      return   // not ours; the stream only ever carries JSON, so ignore quietly
    }

    var update = Model.classifyEvent(event, panelToken)
    if (!update) return

    // `send` is fire-and-forget, so its process exits 0 whether or not the
    // daemon accepted the command; the verdict arrives here, as a response
    // with the panel's token. Without this a refused dial left "Calling…"
    // on screen until the next periodic resync.
    if (update.kind === "commandFailed") {
      lastError = elide(update.error)
      if (pendingToggle) {
        if (pendingToggle.kind === "mute") muted = pendingToggle.previous
        else onHold = pendingToggle.previous
        pendingToggle = null
      }
      if (callState === "outgoing" && lastCallEventAt < dialSentAt) {
        callState = "idle"
        peer = ""
        callId = ""
        callStartedAt = 0
      }
      return
    }

    if (update.kind === "ctrl") {
      daemonUp = update.connected
      if (update.connected) {
        eventsRetryMs = eventsRetryMinMs   // a real connection means the daemon is back
      }
      if (!update.connected) {
        callState = "idle"
        peer = ""
        callId = ""
        callStartedAt = 0
        if (update.error) lastError = elide(update.error)
      } else {
        refresh()
      }
      return
    }

    if (update.kind === "mwi") {
      mwi = update.mwi
      return
    }

    if (update.kind === "transferFailed") {
      lastError = elide("Transfer failed" + (update.error ? ": " + update.error : ""))
      return
    }

    if (update.kind === "prefill") {
      root.prefillRequested(update.target)
      return
    }

    if (update.kind === "showPanel") {
      root.showRequested()
      return
    }

    if (update.kind === "options") {
      daemonOptions = update.options
      pendingOptions = ({})
      syncOptions()
      return
    }

    if (update.kind === "registration") {
      registration = update.registration
      if (update.aor) aor = update.aor
      lastError = update.registration === "failed" ? elide(update.error || "Registration failed") : ""
      return
    }

    // A call the daemon turned away under Do Not Disturb is never sent here,
    // so nothing needs filtering on the panel's (possibly stale) idea of it.
    //
    // One call at a time: while a call is up, events naming another call are
    // not about the one on screen. (The daemon refuses a second call; this
    // keeps a stray one from rewriting what the panel shows.)
    if (update.kind === "call" && callState !== "idle" && update.callId && callId
        && update.callId !== callId) return

    if (update.kind === "call") {
      lastCallEventAt = Date.now()
      var wasRinging = callState === "incoming"
      // A different call, or none: its mute and hold state are not ours.
      if (update.callState === "idle" || update.callState === "incoming"
          || (update.callId && callId && update.callId !== callId)) resetCallControls()
      callState = update.callState
      if (update.callState === "idle") {
        Qt.callLater(syncOptions)   // anything held back for the call
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
      if (update.callState === "incoming" && !wasRinging) announceIncoming()
    }
  }

  // Ringing is the one state the panel must never miss, so both the event
  // stream and a status resync funnel through here. The notification itself
  // is the daemon's job now (see CallAlerts in the CLI): it is sent once, has
  // Answer/Reject buttons, and works while the shell is restarting.
  function announceIncoming() {
    root.incomingCall(peer)
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
    if (status.options && typeof status.options === "object") {
      daemonOptions = Model.pickOptions(status.options)
      syncOptions()
    }

    // reginfo is authoritative on startup; events take over from there.
    if (status.reginfo && status.reginfo.data !== undefined) {
      registration = Model.parseReginfo(status.reginfo.data, aor)
    } else if (!daemonUp) {
      registration = "unknown"
    }

    // Events carry the truth; this is the resync that repairs what they missed.
    if (status.calls && status.calls.data !== undefined) {
      var incoming = Model.parseIncomingCall(status.calls.data)
      if (incoming && callState !== "incoming") {
        // A call is ringing right now and no CALL_INCOMING ever reached us --
        // the listener was between reconnects. Adopt it: without this the
        // panel offers no Answer for the whole life of the call, and no
        // poll can ever recover it.
        callState = "incoming"
        peer = incoming.peer
        callId = ""
        callStartedAt = 0
        announceIncoming()
      } else if (Model.parseCallCount(status.calls.data) === 0
                 && (callState !== "incoming" || statusRequestedAt > lastCallEventAt)) {
        // A call that ended while the shell was restarting leaves stale UI
        // state. Clearing a ringing call is only safe when this snapshot was
        // asked for after the last call event we saw -- otherwise it is a
        // reply that predates a call which is still coming up.
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
  // closed. `omarchy-sip events` connects to the control socket and prints one
  // bounded, newline-terminated JSON line per record (or nothing at all for an
  // oversized one) -- see read_lines() in the CLI -- so SplitParser here only
  // ever sees data our own bounded reader already produced.
  Process {
    id: eventsProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.cleanEnv()
    stdinEnabled: false
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    onRunningChanged: if (running) root.refresh()
    onExited: function(exitCode) {
      root.daemonUp = false
      // Each retry is a Python interpreter start, not a syscall the way the
      // old raw-socket reconnect was, so a daemon that stays down (not
      // installed yet, stopped for troubleshooting) must not keep spawning
      // one every few seconds indefinitely. Back off, capped, and reset the
      // moment a connection actually succeeds -- see the "ctrl" branch above.
      eventsRetryMs = Math.min(eventsRetryMs * 2, eventsRetryMaxMs)
      eventsRestartTimer.interval = eventsRetryMs
      eventsRestartTimer.restart()
    }
  }

  function startEvents() {
    if (eventsProcess.running) return
    eventsProcess.command = [cli, "events"]
    eventsProcess.running = true
  }

  // The socket only exists while the daemon runs, and `events` exits as soon
  // as it does (or immediately, if nothing is listening yet). Retry with
  // backoff rather than hammering a spawn every 3s for as long as it is down.
  Timer {
    id: eventsRestartTimer
    interval: eventsRetryMinMs
    onTriggered: root.startEvents()
  }

  // The one place a whole document is needed, so StdioCollector stays -- but
  // the CLI clamps --limit and clips every field, and the watchdog below bounds
  // how long this can run at all.
  Process {
    id: historyProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.cleanEnv()
    stdout: StdioCollector { id: historyOut; waitForEnd: true }
    onExited: function(exitCode) {
      historyWatchdog.stop()
      if (exitCode !== 0) return
      var raw = String(historyOut.text || "[]")
      if (raw.length > root.maxJsonChars) return
      try {
        var parsed = Model.parseHistory(JSON.parse(raw))
        root.history = parsed.calls
        root.unseenMissed = parsed.unseenMissed
      } catch (e) {
        root.history = []
      }
      if (root.markSeenPending) Qt.callLater(root.refreshHistory)
    }
  }

  // A refusal arrives within a round trip; after this, the change stuck.
  Timer {
    id: toggleTimer
    interval: 5000
    onTriggered: root.pendingToggle = null
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
    clearEnvironment: true
    environment: root.cleanEnv()
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
    clearEnvironment: true
    environment: root.cleanEnv()
    stdout: SplitParser {
      onRead: function(line) { actionProcess.errText = root.appendBounded(actionProcess.errText, line) }
    }
    stderr: SplitParser {
      onRead: function(line) { actionProcess.errText = root.appendBounded(actionProcess.errText, line) }
    }
    onExited: function(exitCode) {
      actionWatchdog.stop()
      if (exitCode !== 0) {
        // Whatever was pending did not happen (an `option set`, say); the
        // daemon's next OPTIONS record is the truth again.
        root.pendingOptions = ({})
        root.lastError = elide(actionProcess.errText || "Command failed")
        // The optimistic dial never happened -- fall back to what is real.
        root.refresh()
      }
      // Deferred: starting the next child from inside this one's exit
      // handler would reassign `command` on a Process still tearing down.
      Qt.callLater(root.drainQueue)
    }
  }

  Process {
    id: accountProcess
    property string errText: ""
    running: false
    command: []
    clearEnvironment: true
    environment: root.cleanEnv()
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
      root.loadAccount()
      // The daemon restarts on an account change; give it a moment to register.
      accountSettleTimer.restart()
    }
  }

  // The contact list is a whole document, so StdioCollector -- bounded by the
  // CLI's own caps (200 entries, clipped names) and by maxJsonChars here.
  Process {
    id: contactsProcess
    property string errText: ""
    running: false
    command: []
    clearEnvironment: true
    environment: root.cleanEnv()
    stdout: StdioCollector { id: contactsOut; waitForEnd: true }
    stderr: SplitParser {
      onRead: function(line) { contactsProcess.errText = root.appendBounded(contactsProcess.errText, line) }
    }
    onExited: function(exitCode) {
      contactsWatchdog.stop()
      if (exitCode !== 0) {
        root.lastError = root.elide(contactsProcess.errText || "Could not save the contact")
        return
      }
      var raw = String(contactsOut.text || "[]")
      if (raw.length > root.maxJsonChars) return
      try {
        var parsed = JSON.parse(raw)
        if (Array.isArray(parsed)) root.contacts = parsed
      } catch (e) {}
    }
  }

  Timer {
    id: contactsWatchdog
    interval: 10000
    onTriggered: if (contactsProcess.running) contactsProcess.running = false
  }

  Process {
    id: accountShowProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.cleanEnv()
    stdout: StdioCollector { id: accountShowOut; waitForEnd: true }
    onExited: function(exitCode) {
      accountShowWatchdog.stop()
      if (exitCode !== 0) return
      var raw = String(accountShowOut.text || "")
      if (raw.length > root.maxJsonChars) return
      try {
        var parsed = JSON.parse(raw)
        if (parsed && typeof parsed === "object") root.accountDetails = parsed
      } catch (e) {}
    }
  }

  Timer {
    id: accountShowWatchdog
    interval: 10000
    onTriggered: if (accountShowProcess.running) accountShowProcess.running = false
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
  // open for the rest of the shell session. The control socket is deliberately
  // exempt: it is the long-lived listener, and is bounded instead by the
  // per-record cap the daemon and handleLine both enforce.
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
      Qt.callLater(root.drainQueue)
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

  Component.onCompleted: {
    startEvents()
    refresh()
    loadAccount()
    loadContacts()
  }
}
