// Harness for Model.js's pure functions.  Run: node tests/model_test.js
// Model.js deliberately holds no QML objects, which is what makes this possible.
const fs = require("fs");
const src = fs.readFileSync(require("path").join(__dirname, "..", "Model.js"), "utf8");
const M = {};
new Function("exports", src + "\nObject.assign(exports,{stripAnsi,classifyEvent,validCallId,typingGuard,isKeypadKey,parseMwi,validDigits,queueDigits,optionChanges,pickOptions,validTarget,parseReginfo,parseCallCount,parseIncomingCall,normalizeTarget,accountUri,peerLabel,peerShort,durationText,formatDuration,barGlyph,heroMeta,barTooltip,lastOutbound,callTitle,domainOf,historyGlyph,parseHistory,voicemailTarget,tipLine,contactName,matchContacts,redialTarget,historyLabel,historyIsMissed,historyMeta,relativeTime});")(M);

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
t("accountUri bare host borrows the auth user", M.accountUri("pbx.example.com", "1001"), "sip:1001@pbx.example.com");
t("accountUri sip:host borrows the auth user", M.accountUri("sip:pbx.example.com", "1001"), "sip:1001@pbx.example.com");
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
  "", "User-Agent: 1001@pbx", "--- Active calls (1) ---",
  "  ===== Call debug (INCOMING) =====",
  " local_uri: 1001 <sip:1001@pbx>",
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
t("classify closed keeps the call id", M.classifyEvent({ type: "CALL_CLOSED", id: "c9", param: "x" }).callId, "c9");
t("classify reg ok", M.classifyEvent({ type: "REGISTER_OK", accountaor: "sip:a@x" }),
  { kind: "registration", registration: "registered", aor: "sip:a@x" });
t("classify ctrl up", M.classifyEvent({ type: "CTRL_CONNECTED" }), { kind: "ctrl", connected: true });

t("classify options keeps only known booleans",
  M.classifyEvent({ type: "OPTIONS", dnd: true, notifications: false, aec: "yes", other: true }),
  { kind: "options", options: { notifications: false, dnd: true } });
t("optionChanges finds a difference", M.optionChanges({ notifications: false }, { notifications: true }, {}, true),
  [["notifications", false]]);
t("optionChanges nothing when equal", M.optionChanges({ notifications: true }, { notifications: true }, {}, true), []);
t("optionChanges skips a write already pending",
  M.optionChanges({ notifications: false }, { notifications: true }, { notifications: false }, true), []);
t("optionChanges holds aec back during a call", M.optionChanges({ aec: true }, { aec: false }, {}, false), []);
t("optionChanges applies aec when idle", M.optionChanges({ aec: true }, { aec: false }, {}, true), [["aec", true]]);
t("optionChanges ignores a key the daemon has not reported", M.optionChanges({ aec: true }, {}, {}, true), []);

t("classify show panel", M.classifyEvent({ type: "SHOW_PANEL" }), { kind: "showPanel" });
t("title in call", M.callTitle({ callState: "active" }), "In call");
t("title on hold", M.callTitle({ callState: "active", onHold: true }), "On hold");
t("title muted", M.callTitle({ callState: "active", muted: true }), "In call \u00b7 Muted");
t("title muted while calling", M.callTitle({ callState: "outgoing", muted: true }), "Calling\u2026 \u00b7 Muted");
t("title incoming ignores stale mute", M.callTitle({ callState: "incoming", muted: true }), "Incoming call");
t("title idle", M.callTitle({ callState: "idle" }), "");
t("digits valid", M.validDigits("0123456789*#"), true);
t("digits refuse a letter", M.validDigits("1e"), false);
t("digits refuse a separator", M.validDigits("1;2"), false);
t("digits refuse empty", M.validDigits(""), false);
const TK = "--token=panel-x";
const DD = "--";
t("queueDigits starts a command", M.queueDigits([], "1", "panel-x"), [["send", TK, DD, "sndcode", "1"]]);
t("queueDigits extends queued DTMF", M.queueDigits([["send", TK, DD, "sndcode", "12"]], "3", "panel-x"), [["send", TK, DD, "sndcode", "123"]]);
t("queueDigits does not extend another command",
  M.queueDigits([["send", TK, DD, "hangup"]], "1", "panel-x"), [["send", TK, DD, "hangup"], ["send", TK, DD, "sndcode", "1"]]);
t("queueDigits stops at the grammar's limit",
  M.queueDigits([["send", TK, DD, "sndcode", "1".repeat(32)]], "2", "panel-x").length, 2);
const q0 = [["send", TK, DD, "sndcode", "1"]]; M.queueDigits(q0, "2", "panel-x");
t("queueDigits leaves its input alone", q0, [["send", TK, DD, "sndcode", "1"]]);
t("classify transfer failure", M.classifyEvent({ type: "TRANSFER_FAILED", param: "603 Decline" }),
  { kind: "transferFailed", error: "603 Decline" });
t("mwi waiting", M.parseMwi("Messages-Waiting: yes\r\nMessage-Account: sip:*97@pbx.example.com\r\nVoice-Message: 2/8 (0/2)\r\n"),
  { waiting: true, newCount: 2, oldCount: 8, account: "sip:*97@pbx.example.com" });
t("mwi none", M.parseMwi("Messages-Waiting: no\r\nVoice-Message: 0/3\r\n"),
  { waiting: false, newCount: 0, oldCount: 3, account: "" });
t("mwi case and spacing", M.parseMwi("messages-waiting:YES\nvoice-message : 1 / 0"),
  { waiting: true, newCount: 1, oldCount: 0, account: "" });
t("mwi clamps counts", M.parseMwi("Voice-Message: 123456789/5").newCount, 999);
t("mwi empty", M.parseMwi(""), { waiting: false, newCount: 0, oldCount: 0, account: "" });
t("classify mwi", M.classifyEvent({ type: "MWI_NOTIFY", param: "Messages-Waiting: yes\r\nVoice-Message: 1/0" }),
  { kind: "mwi", mwi: { waiting: true, newCount: 1, oldCount: 0, account: "" } });
t("hero with voicemail", M.heroMeta({ daemonUp: true, configured: true, registration: "registered", aor: "sip:a@x", newVoicemail: 2 }),
  "sip:a@x \u00b7 2 new voicemails");
t("hero with one voicemail", M.heroMeta({ daemonUp: true, configured: true, registration: "registered", aor: "sip:a@x", newVoicemail: 1 }),
  "sip:a@x \u00b7 1 new voicemail");
const BOOK = [
  { name: "Front desk", uri: "sip:1001@pbx.example.com" },
  { name: "Mum", uri: "sip:+15550100@gw.example.com" },
  { name: "Desk two", uri: "sip:1002@pbx.example.com" },
];
t("contactName by address", M.contactName("sip:1001@pbx.example.com;user=phone", BOOK), "Front desk");
t("contactName display-name form", M.contactName('"x" <sip:+15550100@gw.example.com>', BOOK), "Mum");
t("contactName never lends a name to a caller at an IP literal", M.contactName("sip:1001@203.0.113.9", BOOK, "sip:me@pbx.example.com"), "");
t("contactName by unique user part from the account's domain",
  M.contactName("sip:1001@pbx.example.com:5060", [{ name: "N", uri: "sip:1001@pbxname" }], "sip:me@pbx.example.com"), "N");
t("contactName never lends a name to another domain's caller",
  M.contactName("sip:1001@attacker.example", BOOK, "sip:me@pbx.example.com"), "");
t("contactName not for a short user part", M.contactName("sip:10@x", [{ name: "N", uri: "sip:10@y" }]), "");
t("contactName not when ambiguous",
  M.contactName("sip:1001@pbx.example.com", [{ name: "A", uri: "sip:1001@a" }, { name: "B", uri: "sip:1001@b" }], "sip:me@pbx.example.com"), "");
t("contactName unknown", M.contactName("sip:9@x", BOOK), "");
t("contactName no book", M.contactName("sip:1001@pbx.example.com", undefined), "");
t("hist label uses contact", M.historyLabel({ peer: "sip:1001@pbx.example.com" }, BOOK), "Front desk");
t("matchContacts by name prefix", M.matchContacts("mu", BOOK, 5).map(c => c.name), ["Mum"]);
t("matchContacts by number prefix", M.matchContacts("100", BOOK, 5).map(c => c.name), ["Front desk", "Desk two"]);
t("matchContacts name start before contains", M.matchContacts("desk", BOOK, 5).map(c => c.name), ["Desk two", "Front desk"]);
t("matchContacts limit", M.matchContacts("1", BOOK, 1).length, 1);
t("matchContacts empty query", M.matchContacts(" ", BOOK, 5), []);
t("classify prefill number", M.classifyEvent({ type: "PREFILL", target: "+15550100" }), { kind: "prefill", target: "+15550100" });
t("classify prefill address", M.classifyEvent({ type: "PREFILL", target: "sip:a@b" }), { kind: "prefill", target: "sip:a@b" });
t("classify prefill refuses junk", M.classifyEvent({ type: "PREFILL", target: "sip:a@b;x" }), null);
t("glyph dnd idle is a bell-slash", M.barGlyph("idle", true), "\uf1f6");
t("glyph dnd does not hide a call", M.barGlyph("active", true), "\uf098");
t("meta missed under dnd", M.historyMeta({ ts: 1787900000, direction: "in", missed: true, reason: "DND" }, 1787900000000),
  "just now \u00b7 Missed \u00b7 DND");
t("tooltip registered", M.barTooltip({ daemonUp: true, configured: true, registration: "registered", aor: "sip:1001@pbx", callState: "idle" }),
  "SIP \u00b7 1001@pbx");
t("tooltip in call", M.barTooltip({ daemonUp: true, configured: true, callState: "active", peerName: "Mum", duration: "01:05", muted: true }),
  "In call with Mum \u00b7 01:05 \u00b7 muted");
t("tooltip extras", M.barTooltip({ daemonUp: true, configured: true, registration: "registered", aor: "sip:a@b", callState: "idle",
  dnd: true, unseenMissed: 2, newVoicemail: 1 }), "SIP \u00b7 a@b\nDo not disturb\n2 missed calls\n1 new voicemail");
t("tooltip daemon down", M.barTooltip({ daemonUp: false }), "SIP daemon stopped");
t("tooltip failed", M.barTooltip({ daemonUp: true, configured: true, registration: "failed", lastError: "403", callState: "idle" }),
  "SIP \u00b7 registration failed: 403");
t("lastOutbound", M.lastOutbound([{ direction: "in", peer: "sip:a@b" }, { direction: "out", peer: "sip:c@d;user=phone" }]), "sip:c@d");
t("lastOutbound none", M.lastOutbound([{ direction: "in", peer: "sip:a@b" }]), "");
t("guard swallows a key inside the window and extends it", M.typingGuard(1000, 1500, 1500), { swallow: true, until: 2500 });
t("guard lets a key through after quiet", M.typingGuard(2000, 1500, 1500), { swallow: false, until: 1500 });
t("guard unarmed", M.typingGuard(5, 0, 1500), { swallow: false, until: 0 });
t("keypad keys", ["0", "9", "*", "#"].every(M.isKeypadKey), true);
t("letters are not keypad keys", ["a", "A", "d", "12", ""].some(M.isKeypadKey), false);
t("call id plain", M.validCallId("a84b4c76e66710@pbx.example.com"), true);
t("call id rfc punctuation", M.validCallId("abc/def(1)<x>{y}?[z]"), true);
t("call id refuses space", M.validCallId("abc scode=200"), false);
t("call id refuses =", M.validCallId("a=b"), false);
t("call id refuses ;", M.validCallId("a;b"), false);
t("call id refuses quote", M.validCallId('a"b'), false);
t("call id refuses backslash", M.validCallId("a\\b"), false);
t("call id refuses newline", M.validCallId("ab\n"), false);
t("call id refuses empty", M.validCallId(""), false);
t("voicemail configured wins", M.voicemailTarget("*97", "sip:+1900@evil.example", "sip:me@pbx.example.com"), "*97");
t("voicemail server account on our domain", M.voicemailTarget("", "sip:*97@pbx.example.com", "sip:me@pbx.example.com"), "sip:*97@pbx.example.com");
t("voicemail server account elsewhere is refused", M.voicemailTarget("", "sip:+19005550100@evil.example", "sip:me@pbx.example.com"), "");
t("voicemail undialable account is refused", M.voicemailTarget("", "sip:*97@pbx.example.com;x=1", "sip:me@pbx.example.com"), "");
t("voicemail nothing", M.voicemailTarget("", "", "sip:me@pbx.example.com"), "");
t("tooltip lines are clipped", M.tipLine("x".repeat(5000)).length, 120);
t("classify refusal of another panel's command",
  M.classifyEvent({ response: true, ok: false, data: "x", token: "panel-aaaa" }, "panel-bbbb"), null);
t("classify refusal of this panel's command",
  M.classifyEvent({ response: true, ok: false, data: "x", token: "panel-aaaa" }, "panel-aaaa"), { kind: "commandFailed", error: "x" });
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
t("parseHistory object", M.parseHistory({ calls: [{ peer: "a" }], unseenMissed: 2 }), { calls: [{ peer: "a" }], unseenMissed: 2 });
t("parseHistory legacy array", M.parseHistory([{ peer: "a" }]), { calls: [{ peer: "a" }], unseenMissed: 0 });
t("parseHistory junk", M.parseHistory({ calls: "x", unseenMissed: "lots" }), { calls: [], unseenMissed: 0 });
t("parseHistory negative", M.parseHistory({ calls: [], unseenMissed: -3 }), { calls: [], unseenMissed: 0 });
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
