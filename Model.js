// Pure helpers for the Simple SIP panel. No I/O, no QML objects -- everything
// here is a function of its arguments so it can be reasoned about (and, if it
// ever matters, tested) on its own.
//
// Two inputs arrive from `omarchy-sip`:
//   * event lines  -- baresip's own JSON, one object per line (structured)
//   * status/cmd   -- responses whose `data` field is human prose (unstructured)
// classifyEvent() handles the first; parseReginfo() / parseCallCount() do the
// prose-scraping for the second, so that mess lives in exactly one place.

// baresip colours some status text (print_scode emits green "OK ", red "ERR"),
// and those escapes survive into the command responses relayed from ctrl_dbus.
function stripAnsi(text) {
  return String(text || "").replace(/\x1b\[[0-9;]*[A-Za-z]|\[[0-9;]*m/g, "")
}

// ------------------------------------------------------------------- events

// Map a baresip event object onto the panel's vocabulary. Returns null for
// events the panel does not model (RTCP ticks, SDP exchanges, module noise),
// which keeps the caller free of a long switch.
function classifyEvent(ev) {
  // A command response rather than an event. Only a refusal or failure of a
  // command the panel sent (token "panel") matters here: a successful reply
  // carries nothing the events do not, and other tokens belong to other
  // clients' request/reply round trips, which every client sees broadcast.
  if (ev && ev.response === true) {
    if (ev.ok === false && String(ev.token || "") === "panel")
      return { kind: "commandFailed", error: String(ev.data || "") || "Command failed" }
    return null
  }
  var type = String((ev && ev.type) || "")
  var peer = peerLabel((ev && ev.peeruri) || "")

  switch (type) {
  // -- our own synthetic bridge events
  case "CTRL_CONNECTED":
    return { kind: "ctrl", connected: true }
  case "CTRL_DISCONNECTED":
  case "CTRL_FAILED":
    return { kind: "ctrl", connected: false, error: (ev && ev.reason) || "" }

  // -- a notification was clicked; the daemon cannot open the panel itself
  case "SHOW_PANEL":
    return { kind: "showPanel" }

  // -- the daemon's own options, replayed to every client on connect
  case "OPTIONS":
    return { kind: "options", options: pickOptions(ev) }

  // -- registration
  case "REGISTERING":
    return { kind: "registration", registration: "pending" }
  case "REGISTER_OK":
    return { kind: "registration", registration: "registered", aor: (ev && ev.accountaor) || "" }
  case "REGISTER_FAIL":
    return { kind: "registration", registration: "failed", error: (ev && ev.param) || "Registration failed" }
  case "UNREGISTERING":
    return { kind: "registration", registration: "none" }

  // -- voicemail waiting indication (RFC 3842 message-summary body)
  case "MWI_NOTIFY":
    return { kind: "mwi", mwi: parseMwi((ev && ev.param) || "") }

  // -- a blind transfer we asked for was refused by the far end. Success
  // needs no case of its own: the call simply closes ("Call transfered").
  case "TRANSFER_FAILED":
    return { kind: "transferFailed", error: String((ev && ev.param) || "") }

  // -- calls. `id` lets us ignore events for a call we are not showing.
  case "CALL_INCOMING":
    return { kind: "call", callState: "incoming", peer: peer, callId: (ev && ev.id) || "" }
  case "CALL_OUTGOING":
    return { kind: "call", callState: "outgoing", peer: peer, callId: (ev && ev.id) || "" }
  case "CALL_RINGING":
    return { kind: "call", callState: "ringing", peer: peer, callId: (ev && ev.id) || "" }
  case "CALL_ESTABLISHED":
    return { kind: "call", callState: "active", peer: peer, callId: (ev && ev.id) || "", started: true }
  case "CALL_CLOSED":
    return { kind: "call", callState: "idle", peer: "", callId: "",
             closedReason: String((ev && ev.param) || "") }
  }
  return null
}

// Only the keys the daemon defines, and only booleans -- mirrors
// read_options() in the CLI.
var OPTION_KEYS = ["notifications", "regAlerts", "dnd", "aec"]

function pickOptions(obj) {
  var out = {}
  for (var i = 0; i < OPTION_KEYS.length; i++) {
    var key = OPTION_KEYS[i]
    if (obj && typeof obj[key] === "boolean") out[key] = obj[key]
  }
  return out
}

// Which daemon options differ from what the panel's settings want, as
// [key, value] pairs. `pending` holds writes already sent and not yet
// confirmed by an OPTIONS event, so a slow round trip is not written twice.
// `aec` restarts the daemon, so it is held back while a call is up.
function optionChanges(wanted, current, pending, callIdle) {
  var out = []
  for (var key in wanted) {
    if (typeof current[key] !== "boolean") continue
    if (current[key] === wanted[key]) continue
    if (pending && pending[key] === wanted[key]) continue
    if (key === "aec" && !callIdle) continue
    out.push([key, wanted[key]])
  }
  return out
}

// ------------------------------------------------------- prose from responses

// `reginfo` prints one line per account: the AOR padded to 42 columns, then
// per-registration " OK  <server>" / " ERR <server>" / " zzz <server>".
// An account with regint=0 has no registration client and so prints nothing,
// which is "none" rather than a failure.
function parseReginfo(data, aor) {
  var text = stripAnsi(data)
  var lines = text.split("\n")
  var wanted = String(aor || "")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.indexOf("sip:") < 0) continue
    if (wanted && line.indexOf(wanted) < 0) continue
    if (/\bOK\b/.test(line)) return "registered"
    if (/\bERR\b/.test(line)) return "failed"
    if (/\bzzz\b/.test(line)) return "pending"
    return "none"
  }
  return "unknown"
}

function parseCallCount(data) {
  var match = stripAnsi(data).match(/Active calls \((\d+)\)/)
  return match ? parseInt(match[1], 10) : 0
}

// `listcalls` renders one call_debug block per call, headed by the call's own
// state -- "===== Call debug (INCOMING) =====" for a call that is ringing and
// has not been answered. Events are still the normal way the panel learns a
// call is ringing; this is how a resync recovers one whose event it missed,
// so it returns the peer too (from the block's own peer_uri line, not the
// first one in the document, which may belong to another call).
// Returns null when nothing is ringing.
function parseIncomingCall(data) {
  var blocks = stripAnsi(data).split("===== Call debug (")
  for (var i = 1; i < blocks.length; i++) {
    var block = blocks[i]
    var close = block.indexOf(")")
    if (close < 0) continue
    if (block.substring(0, close).trim() !== "INCOMING") continue
    var match = block.match(/peer_uri:\s*(.*)/)
    return { peer: match ? peerLabel(match[1]) : "" }
  }
  return null
}

// A message-summary body, as the voicemail server sends it:
//   Messages-Waiting: yes
//   Message-Account: sip:*97@pbx.example.com
//   Voice-Message: 2/8 (0/2)
// -> { waiting: true, newCount: 2, oldCount: 8, account: "sip:*97@pbx..." }
// Tolerant of case and missing lines; counts are clamped so a hostile
// server cannot put a nine-digit number in the panel.
function parseMwi(body) {
  var out = { waiting: false, newCount: 0, oldCount: 0, account: "" }
  var lines = String(body || "").split(/\r?\n/)
  for (var i = 0; i < lines.length && i < 64; i++) {
    var m = lines[i].match(/^\s*([A-Za-z-]+)\s*:\s*(.*?)\s*$/)
    if (!m) continue
    var key = m[1].toLowerCase()
    if (key === "messages-waiting") out.waiting = m[2].toLowerCase() === "yes"
    else if (key === "message-account") out.account = m[2].substring(0, 256)
    else if (key === "voice-message") {
      var counts = m[2].match(/^(\d+)\s*\/\s*(\d+)/)
      if (counts) {
        out.newCount = Math.min(999, parseInt(counts[1], 10))
        out.oldCount = Math.min(999, parseInt(counts[2], 10))
      }
    }
  }
  return out
}

// ------------------------------------------------------------------ dialling

// Accept what a person would actually type. A bare extension or phone number
// is completed with the account's domain; anything already URI-shaped is left
// alone so `sips:` and explicit ports survive untouched. A `tel:` URI is just a
// phone number with a scheme, and a phone number may carry the separators
// people write it with -- "+1 (555) 010-0100" -- none of which are dialable.
function normalizeTarget(input, aor) {
  var target = String(input || "").trim().replace(/\s+/g, "")
  if (target === "") return ""
  if (/^tel:/i.test(target)) target = target.substring(4).split(";")[0]
  if (/^sips?:/.test(target)) return target
  if (target.indexOf("@") > 0) return "sip:" + target
  if (/^[+0-9*#().-]+$/.test(target) && /[0-9]/.test(target)) {
    target = target.replace(/[().-]/g, "")
  }
  if (target === "") return ""

  var domain = domainOf(aor)
  if (!domain) return "sip:" + target
  return "sip:" + target + "@" + domain
}

// The daemon's own grammar for a dial or transfer target (see _COMMAND_GRAMMAR
// in bin/omarchy-sip), mirrored here so the panel can refuse a target before
// anything optimistic happens, instead of showing "Calling…" for a command the
// daemon was always going to throw away. The daemon stays the authority.
var TARGET_RE = /^sips?:[A-Za-z0-9._~:\/@%+*#-]{1,250}$/

function validTarget(uri) {
  return TARGET_RE.test(String(uri || ""))
}

// The address of record the setup form saves. People type the server they
// were given -- "pbx.example.com" -- with the extension in the auth field;
// baresip needs sip:user@host, and an account without the user part is
// refused outright and registers nothing. So a bare host borrows the auth
// user as its user part, and a missing scheme is supplied.
function accountUri(input, authUser) {
  var value = String(input || "").trim().replace(/\s+/g, "")
  if (value === "") return ""
  value = value.replace(/^sips?:/i, "")
  var user = String(authUser || "").trim()
  if (value.indexOf("@") < 0 && user !== "") value = user + "@" + value
  return "sip:" + value
}

function domainOf(aor) {
  var value = String(aor || "").replace(/^sips?:/, "")
  var at = value.indexOf("@")
  if (at < 0) return ""
  return value.substring(at + 1).split(";")[0]
}

// "sip:1001@pbx.example.com;transport=tcp" -> "1001@pbx.example.com"
function peerLabel(uri) {
  var value = String(uri || "").trim()
  if (value === "") return ""
  value = value.replace(/^[^<]*</, "").replace(/>.*$/, "")
  value = value.replace(/^sips?:/, "").split(";")[0]
  return value
}

// Just the user part, for the big line in the panel.
function peerShort(uri) {
  var label = peerLabel(uri)
  var at = label.indexOf("@")
  return at > 0 ? label.substring(0, at) : label
}

// ------------------------------------------------------------- presentation

// Live timer: empty until a call actually starts.
function durationText(startedAtMs, nowMs) {
  if (!startedAtMs) return ""
  return formatDuration(Math.floor((nowMs - startedAtMs) / 1000))
}

// mm:ss, or h:mm:ss past the hour.
function formatDuration(totalSeconds) {
  var total = Math.max(0, Math.floor(Number(totalSeconds) || 0))
  var minutes = Math.floor(total / 60)
  var seconds = total % 60
  if (minutes >= 60) {
    var hours = Math.floor(minutes / 60)
    return hours + ":" + pad2(minutes % 60) + ":" + pad2(seconds)
  }
  return pad2(minutes) + ":" + pad2(seconds)
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

// What a DTMF keypad has; mirrors the daemon's sndcode grammar.
function validDigits(digits) {
  return /^[0-9*#A-Da-d]{1,32}$/.test(String(digits || ""))
}

// Fold digits into the command queue: when the last queued command is also
// DTMF and there is room, extend it rather than queue another process --
// someone typing an account number at an IVR types faster than a CLI starts.
// Returns the new queue; never mutates the one given.
function queueDigits(queue, digits) {
  var q = (queue || []).slice()
  var last = q.length ? q[q.length - 1] : null
  if (last && last[0] === "send" && last[1] === "sndcode" && (last[2] + digits).length <= 32) {
    q[q.length - 1] = ["send", "sndcode", last[2] + digits]
  } else {
    q.push(["send", "sndcode", digits])
  }
  return q
}

function isRinging(callState) {
  return callState === "incoming"
}

function inCall(callState) {
  return callState === "active" || callState === "outgoing" || callState === "ringing"
}

// Telephone glyphs from the Nerd Font FontAwesome range -- the bold handset
// stays legible at bar size, where the thinner Material phone variants blur
// together. State is carried by colour and the ringing blink, not by shape,
// except for in-call which gets the filled square so a glance tells you the
// line is busy.
function barGlyph(callState) {
  if (callState === "active") return "\uf098"   // nf-fa-phone_square
  return "\uf095"                             // nf-fa-phone
}

// ---------------------------------------------------------------- call log

// `omarchy-sip history` output: {calls, unseenMissed}. An older CLI printed
// the bare array, which still reads, with nothing unseen.
function parseHistory(parsed) {
  if (Array.isArray(parsed)) return { calls: parsed, unseenMissed: 0 }
  var p = parsed || {}
  var n = parseInt(p.unseenMissed, 10)
  return {
    calls: Array.isArray(p.calls) ? p.calls : [],
    unseenMissed: isFinite(n) && n > 0 ? n : 0
  }
}

// Direction arrows rather than phone glyphs: they read at row size and say
// "out" / "in" without colour. A missed call keeps the inbound arrow (it was
// an inbound call) and is distinguished by the urgent tint plus its meta text,
// so the meaning does not rest on colour alone.
function historyGlyph(entry) {
  return (entry && entry.direction === "out") ? "↗" : "↙"
}

function historyIsMissed(entry) {
  return !!(entry && entry.missed)
}

// What selecting a row dials. The log keeps the peer as baresip reported it,
// and an inbound From URI routinely carries parameters -- `;user=phone` from
// any PSTN gateway -- which the daemon's dial grammar refuses, and rightly:
// they would reach baresip's command line. The address itself is what
// "call them back" means, so that is what is dialled.
function redialTarget(entry) {
  var peer = String((entry && entry.peer) || "")
  var label = peerLabel(peer)
  if (label === "") return ""
  return (/^\s*(?:[^<]*<)?sips:/.test(peer) ? "sips:" : "sip:") + label
}

function historyLabel(entry, contacts) {
  var peer = (entry && entry.peer) || ""
  return contactName(peer, contacts) || peerShort(peer) || "unknown"
}

// ---------------------------------------------------------------- contacts

// The saved name for a peer, matched on the bare address. Falls back to the
// user part alone when exactly one contact has it (and it is not a two-digit
// code), so an extension saved against the PBX's hostname still matches a
// call that arrives from its IP. Mirrors contact_name_for() in the CLI.
function contactName(uri, contacts) {
  var label = peerLabel(uri)
  var list = contacts || []
  if (label === "") return ""
  for (var i = 0; i < list.length; i++) {
    if (peerLabel(list[i].uri) === label) return String(list[i].name || "")
  }
  var user = label.split("@")[0]
  if (user.length < 3) return ""
  var found = ""
  var count = 0
  for (var j = 0; j < list.length; j++) {
    if (peerLabel(list[j].uri).split("@")[0] === user) { found = String(list[j].name || ""); count++ }
  }
  return count === 1 ? found : ""
}

// Contacts matching what is typed in the dial field: a name containing it
// (any word, case-insensitive) or an address whose user part starts with it.
// Names that start with it sort first.
function matchContacts(query, contacts, limit) {
  var q = String(query || "").trim().toLowerCase()
  var list = contacts || []
  if (q === "") return []
  var starts = [], contains = []
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    var name = String(c.name || "").toLowerCase()
    var user = peerShort(c.uri).toLowerCase()
    if (name.indexOf(q) === 0 || user.indexOf(q) === 0) starts.push(c)
    else if (name.indexOf(q) > 0) contains.push(c)
  }
  return starts.concat(contains).slice(0, limit || 5)
}

// "3m ago · 01:12" / "just now · Missed" / "2d ago · No answer"
function historyMeta(entry, nowMs) {
  var e = entry || {}
  var when = relativeTime(e.ts, nowMs)
  var what
  if (e.missed) what = "Missed"
  else if (!e.duration) what = "No answer"
  else what = formatDuration(e.duration)
  return when + " · " + what
}

// Coarse on purpose: a call log wants "when-ish", not a timestamp.
function relativeTime(tsSeconds, nowMs) {
  var ts = Number(tsSeconds || 0)
  if (!ts) return ""
  var seconds = Math.max(0, Math.floor((nowMs - ts * 1000) / 1000))
  if (seconds < 45) return "just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return Math.max(1, minutes) + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 7) return days + "d ago"
  // Deliberately not Qt.locale(): keeping this file free of QML globals is
  // what lets the whole module be exercised from plain node.
  var d = new Date(ts * 1000)
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return d.getDate() + " " + months[d.getMonth()]
}

function heroMeta(state) {
  var s = state || {}
  if (!s.daemonUp) return "Daemon stopped"
  if (!s.configured) return "No account configured"
  var vm = s.newVoicemail > 0 ? " · " + s.newVoicemail + " new voicemail" + (s.newVoicemail === 1 ? "" : "s") : ""
  switch (s.registration) {
  case "registered": return s.aor + vm
  case "pending":    return "Registering…"
  case "failed":     return s.lastError || "Registration failed"
  case "none":       return s.aor + " · not registering"
  }
  return s.aor || "Starting…"
}

function callTitle(state) {
  var s = state || {}
  var title = ""
  switch (s.callState) {
  case "incoming": return "Incoming call"
  case "outgoing": title = "Calling…"; break
  case "ringing":  title = "Ringing…"; break
  case "active":   title = s.onHold ? "On hold" : "In call"; break
  default: return ""
  }
  return s.muted ? title + " · Muted" : title
}
