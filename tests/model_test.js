// Harness for Model.js's pure functions.  Run: node tests/model_test.js
// Model.js deliberately holds no QML objects, which is what makes this possible.
const fs = require("fs");
const src = fs.readFileSync(require("path").join(__dirname, "..", "Model.js"), "utf8");
const M = {};
new Function("exports", src + "\nObject.assign(exports,{stripAnsi,classifyEvent,validTarget,parseReginfo,parseCallCount,parseIncomingCall,normalizeTarget,accountUri,peerLabel,peerShort,durationText,formatDuration,barGlyph,heroMeta,callTitle,domainOf,historyGlyph,redialTarget,historyLabel,historyIsMissed,historyMeta,relativeTime});")(M);

let fails = 0;
const ESC = String.fromCharCode(27);
const t = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) fails++;
  console.log((ok ? "ok   " : "FAIL ") + name + "  => " + JSON.stringify(got));
};

t("normalize bare ext", M.normalizeTarget("1001", "sip:alex@pbx.example.com"), "sip:1001@pbx.example.com");
t("normalize user@host", M.normalizeTarget("bob@other.net", "sip:a@x.com"), "sip:bob@other.net");
t("normalize full uri", M.normalizeTarget("sip:bob@x.com:5080", "sip:a@y"), "sip:bob@x.com:5080");
t("normalize sips", M.normalizeTarget("sips:b@x", "sip:a@y"), "sips:b@x");
t("normalize spaces", M.normalizeTarget(" 07700 900 123 ", "sip:a@pbx"), "sip:07700900123@pbx");
t("normalize empty", M.normalizeTarget("   ", "sip:a@pbx"), "");
t("normalize no account", M.normalizeTarget("1001", ""), "sip:1001");

t("normalize tel uri", M.normalizeTarget("tel:+1-555-0100;phone-context=example.com", "sip:a@pbx"), "sip:+15550100@pbx");
t("normalize phone separators", M.normalizeTarget("+1 (555) 010-0100", "sip:a@pbx"), "sip:+15550100100@pbx");
t("normalize keeps dots in a username", M.normalizeTarget("john.doe", "sip:a@pbx"), "sip:john.doe@pbx");
t("normalize keeps a feature code", M.normalizeTarget("*43", "sip:a@pbx"), "sip:*43@pbx");

t("validTarget plain", M.validTarget("sip:1001@pbx.example.com"), true);
t("validTarget port", M.validTarget("sip:b@x.com:5080"), true);
t("validTarget feature code", M.validTarget("sip:*43@pbx"), true);
t("validTarget refuses uri params", M.validTarget("sip:bob@host;transport=tcp"), false);
t("validTarget refuses a quote", M.validTarget('sip:a@b"x'), false);
t("validTarget refuses no scheme", M.validTarget("a@b"), false);
t("validTarget refuses overlong", M.validTarget("sip:" + "a".repeat(251)), false);
t("typed params are refused before dialling",
  M.validTarget(M.normalizeTarget("sip:bob@host;transport=tcp", "sip:a@pbx")), false);

t("classify refusal of a panel command",
  M.classifyEvent({ response: true, ok: false, data: "command not permitted", token: "panel" }),
  { kind: "commandFailed", error: "command not permitted" });
t("classify refusal with no text", M.classifyEvent({ response: true, ok: false, token: "panel" }),
  { kind: "commandFailed", error: "Command failed" });
t("classify ignores a successful reply", M.classifyEvent({ response: true, ok: true, data: "", token: "panel" }), null);
t("classify ignores another client's refusal",
  M.classifyEvent({ response: true, ok: false, data: "x", token: "req-123" }), null);

t("accountUri full", M.accountUri("sip:1001@pbx.example.com", "1001"), "sip:1001@pbx.example.com");
t("accountUri adds scheme", M.accountUri("1001@pbx", ""), "sip:1001@pbx");
t("accountUri bare host borrows the auth user", M.accountUri("pbx.example.com", "3077"), "sip:3077@pbx.example.com");
t("accountUri sip:host borrows the auth user", M.accountUri("sip:pbx.example.com", "3077"), "sip:3077@pbx.example.com");
t("accountUri bare host with no auth user is left for the CLI to refuse", M.accountUri("pbx", ""), "sip:pbx");
t("accountUri empty", M.accountUri("  ", "x"), "");
t("peerLabel params", M.peerLabel("sip:bob@192.168.22.10:5080;transport=udp"), "bob@192.168.22.10:5080");
t("peerLabel angle", M.peerLabel('"Bob" <sip:bob@x.com>'), "bob@x.com");
t("peerShort", M.peerShort("sip:1001@pbx"), "1001");
t("domainOf", M.domainOf("sip:alex@pbx.example.com"), "pbx.example.com");

t("reginfo OK", M.parseReginfo("\n--- User Agents (1) ---\nsip:a@x.com                OK  sip:x.com\n", "sip:a@x.com"), "registered");
t("reginfo ERR", M.parseReginfo("sip:a@x.com   ERR sip:x.com", "sip:a@x.com"), "failed");
t("reginfo zzz", M.parseReginfo("sip:a@x.com   zzz sip:x.com", "sip:a@x.com"), "pending");
t("reginfo ansi OK", M.parseReginfo("sip:a@x.com   " + ESC + "[32mOK " + ESC + "[;m sip:x.com", "sip:a@x.com"), "registered");
t("reginfo bare-bracket ansi", M.parseReginfo("sip:a@x.com   [32mOK [;m sip:x.com", "sip:a@x.com"), "registered");
t("reginfo no reg client", M.parseReginfo("\n--- User Agents (1) ---\n0 - sip:a@x.com          \n\n", "sip:a@x.com"), "none");
t("reginfo empty", M.parseReginfo("\n--- User Agents (0) ---\n\n", "sip:a@x.com"), "unknown");
t("reginfo expires form", M.parseReginfo("sip:a@x.com   OK  sip:x.com Expires 300s", "sip:a@x.com"), "registered");

t("callcount 2", M.parseCallCount("\n--- Active calls (2) ---\n"), 2);
t("callcount 0", M.parseCallCount("\n(no active calls)\n"), 0);

// listcalls renders one call_debug block per call, headed by that call's state.
const RINGING = [
  "", "User-Agent: 3077@pbx", "--- Active calls (1) ---",
  "  ===== Call debug (INCOMING) =====",
  " local_uri: 3077 <sip:3077@pbx>",
  ' peer_uri:  "Bob" <sip:27126578500@197.234.132.106>',
  " af=AF_INET id=bfe5ab9c6e3ed168",
  " direction: Incoming", "",
].join("\n");
t("incoming from listcalls", M.parseIncomingCall(RINGING), { peer: "27126578500@197.234.132.106" });
t("incoming none when idle", M.parseIncomingCall("\n--- Active calls (0) ---\n"), null);
t("incoming ignores an established call",
  M.parseIncomingCall("--- Active calls (1) ---\n  ===== Call debug (ESTABLISHED) =====\n peer_uri:  <sip:b@x>\n"), null);
t("incoming ignores an outgoing call",
  M.parseIncomingCall("  ===== Call debug (OUTGOING) =====\n peer_uri:  <sip:b@x>\n"), null);
t("incoming takes the ringing call's own peer, not the first in the document",
  M.parseIncomingCall("  ===== Call debug (ESTABLISHED) =====\n peer_uri:  <sip:first@x>\n"
                    + "  ===== Call debug (INCOMING) =====\n peer_uri:  <sip:second@x>\n"),
  { peer: "second@x" });
t("incoming with no peer_uri still reports the ring",
  M.parseIncomingCall("  ===== Call debug (INCOMING) =====\n"), { peer: "" });

t("classify incoming", M.classifyEvent({ type: "CALL_INCOMING", peeruri: "sip:bob@x", id: "a1" }),
  { kind: "call", callState: "incoming", peer: "bob@x", callId: "a1" });
t("classify rtcp ignored", M.classifyEvent({ type: "CALL_RTCP" }), null);
t("classify sdp ignored", M.classifyEvent({ type: "CALL_LOCAL_SDP" }), null);
t("classify closed", M.classifyEvent({ type: "CALL_CLOSED", param: "Rejected by user" }),
  { kind: "call", callState: "idle", peer: "", callId: "", closedReason: "Rejected by user" });
t("classify reg ok", M.classifyEvent({ type: "REGISTER_OK", accountaor: "sip:a@x" }),
  { kind: "registration", registration: "registered", aor: "sip:a@x" });
t("classify ctrl up", M.classifyEvent({ type: "CTRL_CONNECTED" }), { kind: "ctrl", connected: true });

t("duration 95s", M.durationText(1000, 1000 + 95000), "01:35");
t("duration hours", M.durationText(1, 1 + 3725000), "1:02:05");
t("duration unset", M.durationText(0, 5000), "");

t("glyph idle is a phone", M.barGlyph("idle"), "\uf095");
t("glyph in-call is filled", M.barGlyph("active"), "\uf098");
t("glyph ringing is a phone", M.barGlyph("incoming"), "\uf095");
t("hero no daemon", M.heroMeta({ daemonUp: false }), "Daemon stopped");
t("hero no account", M.heroMeta({ daemonUp: true, configured: false }), "No account configured");
t("hero registered", M.heroMeta({ daemonUp: true, configured: true, registration: "registered", aor: "sip:a@x" }), "sip:a@x");

const NOW = 1787900000000;
const mk = (o) => Object.assign({ ts: NOW / 1000, direction: "out", peer: "sip:1001@pbx", missed: false, duration: 0 }, o);
t("hist glyph out", M.historyGlyph(mk({})), "\u2197");
t("hist glyph in", M.historyGlyph(mk({ direction: "in" })), "\u2199");
t("redial strips uri params", M.redialTarget(mk({ peer: "sip:+15550100@gw.example.com;user=phone" })), "sip:+15550100@gw.example.com");
t("redial target is dialable", M.validTarget(M.redialTarget(mk({ peer: "sip:+15550100@gw;user=phone" }))), true);
t("redial keeps sips", M.redialTarget(mk({ peer: "sips:bob@x.com;transport=tls" })), "sips:bob@x.com");
t("redial display name form", M.redialTarget(mk({ peer: '"Bob" <sip:bob@x.com;user=phone>' })), "sip:bob@x.com");
t("redial empty", M.redialTarget(mk({ peer: "" })), "");
t("hist label", M.historyLabel(mk({ peer: "sip:1001@pbx.example.com" })), "1001");
t("hist label empty", M.historyLabel(mk({ peer: "" })), "unknown");
t("hist missed", M.historyIsMissed(mk({ missed: true })), true);
t("meta answered", M.historyMeta(mk({ duration: 72 }), NOW), "just now \u00b7 01:12");
t("meta missed", M.historyMeta(mk({ direction: "in", missed: true }), NOW), "just now \u00b7 Missed");
t("meta no answer", M.historyMeta(mk({ duration: 0 }), NOW), "just now \u00b7 No answer");
t("rel just now", M.relativeTime(NOW / 1000, NOW), "just now");
t("rel minutes", M.relativeTime(NOW / 1000 - 300, NOW), "5m ago");
t("rel hours", M.relativeTime(NOW / 1000 - 7200, NOW), "2h ago");
t("rel days", M.relativeTime(NOW / 1000 - 86400 * 3, NOW), "3d ago");
t("rel old is a date", /^\d{1,2} [A-Z][a-z]{2}$/.test(M.relativeTime(NOW / 1000 - 86400 * 30, NOW)), true);
t("rel unset", M.relativeTime(0, NOW), "");
t("fmt duration 0", M.formatDuration(0), "00:00");
t("fmt duration 72", M.formatDuration(72), "01:12");
t("fmt duration 3725", M.formatDuration(3725), "1:02:05");

console.log(fails === 0 ? "\nall passed" : `\n${fails} FAILED`);
process.exit(fails ? 1 : 0);
