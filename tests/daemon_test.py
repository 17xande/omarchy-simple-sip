"""Exercise the daemon's decision-making without a bus, a baresip or a shell.

CallAlerts decides what gets notified and what an action button does; it takes
its notifier, options and baresip `invoke` as arguments, so fakes stand in for
all three here.

Run: python3 tests/daemon_test.py
"""
import importlib.machinery, importlib.util, json, os, subprocess, sys, tempfile

spec = importlib.util.spec_from_loader(
    "omarchy_sip",
    importlib.machinery.SourceFileLoader(
        "omarchy_sip", os.path.join(os.path.dirname(__file__), "..", "bin", "omarchy-sip")
    ),
)
mod = importlib.util.module_from_spec(spec)
sys.modules["omarchy_sip"] = mod
spec.loader.exec_module(mod)

fails = 0


def check(label, ok):
    global fails
    fails += 0 if ok else 1
    print(("ok   " if ok else "FAIL ") + label)


class FakeNotifier:
    def __init__(self):
        self.sent = []      # (key, summary, body, kwargs)
        self.closed = []

    def notify(self, key, summary, body, **kwargs):
        self.sent.append((key, summary, body, kwargs))

    def close_key(self, key):
        self.closed.append(key)


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def make(**opts):
    options = dict(mod.OPTION_DEFAULTS)
    options.update(opts)
    notifier, invoked, clock = FakeNotifier(), [], Clock()
    alerts = mod.CallAlerts(notifier, lambda: options, invoked.append, clock,
                            show=lambda: invoked.append("SHOW"))
    return alerts, notifier, invoked, clock, options


# ------------------------------------------------------------ incoming calls

alerts, n, invoked, _, _ = make()
alerts.handle({"type": "CALL_INCOMING", "id": "c1", "peeruri": "sip:1001@pbx;user=phone"})
key, summary, body, kw = n.sent[0]
check("an incoming call is notified once", len(n.sent) == 1 and summary == "Incoming call")
check("...keyed by its call id", key == "call:c1")
check("...naming the caller without URI parameters", body == "1001@pbx")
check("...clickable, and with Answer and Reject buttons",
      kw["actions"] == (("default", "Open"), ("answer", "Answer"), ("reject", "Reject")))
check("...at critical urgency", kw["urgency"] == 2 and kw["category"] == "call.incoming")

alerts.action("call:c1", "answer")
check("the Answer button accepts the call in baresip", invoked == ["accept"])
alerts.action("call:c1", "reject")
check("the Reject button hangs it up", invoked == ["accept", "hangup"])
alerts.action("call:c1", "default")
check("clicking the notification asks the panel to open", invoked == ["accept", "hangup", "SHOW"])
invoked.remove("SHOW")
alerts.action("call:zz", "answer")
check("a button for a call that is not ringing does nothing", invoked == ["accept", "hangup"])

alerts.handle({"type": "CALL_ESTABLISHED", "id": "c1"})
check("answering closes the notification", n.closed == ["call:c1"])
alerts.handle({"type": "CALL_CLOSED", "id": "c1"})
check("an answered call leaves no Missed call behind",
      [s[1] for s in n.sent] == ["Incoming call"])
alerts.action("call:c1", "answer")
check("a button pressed after the call ended does nothing", invoked == ["accept", "hangup"])

alerts, n, _, _, _ = make()
alerts.handle({"type": "CALL_INCOMING", "id": "c2", "peeruri": "sip:2002@pbx"})
alerts.handle({"type": "CALL_CLOSED", "id": "c2", "param": "Call gave up"})
check("a call that ends unanswered becomes Missed call",
      n.sent[-1][1] == "Missed call" and n.sent[-1][0] == "call:c2")
check("...replacing the incoming one rather than adding a second", n.sent[-1][3]["replace"] is True)
check("...at normal urgency, without buttons",
      n.sent[-1][3]["urgency"] == 1 and "actions" not in n.sent[-1][3])

alerts, n, _, _, _ = make()
alerts.handle({"type": "CALL_OUTGOING", "id": "o1", "peeruri": "sip:3003@pbx"})
alerts.handle({"type": "CALL_CLOSED", "id": "o1"})
check("an outgoing call is never notified", n.sent == [] and n.closed == [])

alerts, n, _, _, _ = make(notifications=False)
alerts.handle({"type": "CALL_INCOMING", "id": "c3", "peeruri": "sip:4004@pbx"})
alerts.handle({"type": "CALL_CLOSED", "id": "c3"})
check("with notifications off nothing is sent", n.sent == [])

# ----------------------------------------------------------------- escaping

alerts, n, _, _, _ = make()
alerts.handle({"type": "CALL_INCOMING", "id": "x",
               "peeruri": '"<a href=x>Win</a>" <sip:<b>bold</b>@evil>'})
check("caller text is escaped for a markup-capable server", "<" not in n.sent[0][2] and ">" not in n.sent[0][2])
check("notify_text escapes & < >", mod.notify_text("a<b>&c") == "a&lt;b&gt;&amp;c")
check("notify_text flattens newlines", mod.notify_text("a\nb\r\nc") == "a b c")
check("notify_text clips", len(mod.notify_text("x" * 5000)) <= mod.MAX_NOTIFY_TEXT)

# ------------------------------------------------------------- registration

alerts, n, _, clock, options = make()
alerts.handle({"type": "REGISTER_FAIL", "param": "408 Request Timeout"})
clock.now += 60
alerts.tick()
check("a failure before ever registering is not an alert (a typo, not a loss)", n.sent == [])

alerts.handle({"type": "REGISTER_OK"})
alerts.handle({"type": "REGISTER_FAIL", "param": "408 Request Timeout"})
clock.now += 10
alerts.tick()
check("a loss is not reported before it has lasted", n.sent == [])
clock.now += mod.REG_ALERT_AFTER
alerts.tick()
check("a lasting loss is reported", len(n.sent) == 1 and n.sent[0][0] == "reg")
check("...with the reason", "408 Request Timeout" in n.sent[0][2])
alerts.tick()
check("...once", len(n.sent) == 1)
alerts.handle({"type": "REGISTER_OK"})
check("recovery withdraws it", n.closed == ["reg"])

alerts, n, _, clock, options = make(regAlerts=False)
alerts.handle({"type": "REGISTER_OK"})
alerts.handle({"type": "REGISTER_FAIL"})
clock.now += 120
alerts.tick()
check("with registration alerts off nothing is sent", n.sent == [])


# ----------------------------------------------------------------- contacts

parsed = mod.parse_contacts(
    '# comment\n"Front desk" <sip:1001@pbx.example.com>;presence=p2p\n'
    '<sip:1002@pbx.example.com>\n"Bad" <sip:a@b;x>\n"Evil" <http://x>\n\n'
)
check("contacts parse name and bare address",
      parsed[:2] == [{"name": "Front desk", "uri": "sip:1001@pbx.example.com"},
                     {"name": "", "uri": "sip:1002@pbx.example.com"}])
check("a URI parameter is dropped, not kept", parsed[2] == {"name": "Bad", "uri": "sip:a@b"})
check("a non-sip address is skipped", len(parsed) == 3)
check("contacts are capped",
      len(mod.parse_contacts("".join(f"<sip:{i}@x>\n" for i in range(500)))) == mod.MAX_CONTACTS)
check("a long name is clipped",
      len(mod.parse_contacts('"' + "n" * 1000 + '" <sip:a@b>')[0]["name"]) <= mod.MAX_CONTACT_NAME)

book = [{"name": "Front desk", "uri": "sip:1001@pbx.example.com"},
        {"name": "Mum", "uri": "sip:+15550100@gw.example.com"}]
check("a name is found by address", mod.contact_name_for("sip:1001@pbx.example.com;user=phone", book) == "Front desk")
check("...or by user part alone when unambiguous", mod.contact_name_for("sip:1001@10.0.0.5", book) == "Front desk")
check("...but not for a short one", mod.contact_name_for("sip:12@x", [{"name": "N", "uri": "sip:12@y"}]) == "")
check("...nor an ambiguous one",
      mod.contact_name_for("sip:1001@z", book + [{"name": "Other", "uri": "sip:1001@elsewhere"}]) == "")
check("an unknown caller has no name", mod.contact_name_for("sip:9999@pbx", book) == "")

alerts, n, _, _, _ = make()
alerts.contacts = lambda: [{"name": "<i>Mum</i>", "uri": "sip:+15550100@gw.example.com"}]
alerts.handle({"type": "CALL_INCOMING", "id": "k", "peeruri": "sip:+15550100@gw.example.com"})
check("the notification names a known caller, escaped",
      n.sent[0][2] == "&lt;i&gt;Mum&lt;/i&gt; (+15550100@gw.example.com)")

ctmp = tempfile.mkdtemp()
cdir = os.path.join(ctmp, "c")
os.mkdir(cdir, 0o700)
CLI = os.path.join(os.path.dirname(__file__), "..", "bin", "omarchy-sip")


def contacts(*args):
    env = {"HOME": ctmp, "PATH": "/usr/bin:/bin", "OMARCHY_SIP_CONF": cdir, "XDG_RUNTIME_DIR": ctmp}
    return subprocess.run([sys.executable, "-I", CLI, "contacts", *args], env=env,
                          capture_output=True, timeout=20)


r = contacts("add", "sip:1001@pbx", "--name", "Front desk")
check("contacts add stores a contact", r.returncode == 0
      and json.loads(contacts().stdout) == [{"name": "Front desk", "uri": "sip:1001@pbx"}])
contacts("add", "sip:1001@pbx;user=phone", "--name", "Reception")
check("adding the same address renames rather than duplicates",
      json.loads(contacts().stdout) == [{"name": "Reception", "uri": "sip:1001@pbx"}])
for bad in ('Bob" <sip:evil@x>', "a<b", "a;b"):
    r = contacts("add", "sip:2002@pbx", "--name", bad)
    check(f"a name with {bad!r} is refused", r.returncode != 0)
check("...and nothing was written", len(json.loads(contacts().stdout)) == 1)
check("a non-sip address is refused", contacts("add", "tel:123", "--name", "x").returncode != 0)
r = contacts("remove", "sip:1001@pbx")
check("contacts remove deletes it", r.returncode == 0 and json.loads(contacts().stdout) == [])
check("removing an unknown contact says so", contacts("remove", "sip:1001@pbx").returncode != 0)
check("the contacts file is private", oct(os.stat(os.path.join(cdir, "contacts")).st_mode & 0o777) == "0o600")

# ------------------------------------------------------------ click-to-call

for url, want in (
    ("tel:+1-555-0100;phone-context=example.com", "+15550100"),
    ("tel:+1%20(555)%20010-0100", "+15550100100"),
    ("TEL:1001", "1001"),
    ("sip:1001@pbx.example.com;transport=tcp?Subject=hi", "sip:1001@pbx.example.com"),
    ("sips:bob@x.com", "sips:bob@x.com"),
    ("sip://1001@pbx", "sip:1001@pbx"),
):
    check(f"link {url!r} fills {want!r}", mod.link_target(url) == want)
for url in ("http://evil", "tel:", "tel:12%0aquit", "sip:a@b%0ahangup", "tel:" + "1" * 40,
            "javascript:alert(1)", "sip:a b@c", "", "x" * 600):
    check(f"link {url[:30]!r} is refused", mod.link_target(url) == "")


class Hub:
    def __init__(self):
        self.sent = []

    def broadcast(self, text):
        self.sent.append(json.loads(text))


class Bus:
    def __init__(self):
        self.calls = []

    def invoke(self, line, token):
        self.calls.append(line)


local_seen = []
bus, hub = Bus(), Hub()
mod.dispatch(bus, hub, b'{"command":"prefill","params":"+15550100"}', lambda n, p, t: local_seen.append((n, p)))
check("prefill is answered by the daemon", local_seen == [("prefill", "+15550100")] and bus.calls == [])
local_seen.clear()
for bad in ("sip:a@b;x", "+1 555", "hangup", "123\nquit"):
    mod.dispatch(Bus(), Hub(), json.dumps({"command": "prefill", "params": bad}).encode(),
                 lambda n, p, t: local_seen.append(p))
check("prefill refuses anything that is not a number or dialable address", local_seen == [])

entry = mod.handler_text()
check("the desktop entry runs the CLI with an isolated interpreter",
      f'Exec="{mod.PYTHON}" -I "{mod.SELF}" open %u' in entry)
check("...and claims exactly sip, sips and tel",
      "MimeType=x-scheme-handler/sip;x-scheme-handler/sips;x-scheme-handler/tel;" in entry)
orig_self = mod.SELF
for bad in ('/a"b', "/a$b", "/a%u", "/a`b", "/a\\b"):
    mod.SELF = bad
    try:
        import contextlib, io
        with contextlib.redirect_stderr(io.StringIO()):
            mod.handler_text()
        refused = False
    except SystemExit:
        refused = True
    check(f"a desktop entry is not written for the path {bad!r}", refused)
mod.SELF = orig_self

# ------------------------------------------------------------- do not disturb

dtmp = tempfile.mkdtemp()
dfd = mod.dir_fd_for(dtmp)
tracker = mod.CallTracker(dfd)
sent = []
opts = dict(mod.OPTION_DEFAULTS, dnd=True)
ev = {"type": "CALL_INCOMING", "id": "a84b4c76e66710", "peeruri": "sip:1001@pbx"}
tracker.handle(ev)
check("under DND an incoming call is rejected with 480, by its own id",
      mod.dnd_reject(ev, opts, tracker, sent.append) and sent == ["hangup a84b4c76e66710 scode=480"])
tracker.handle({"type": "CALL_CLOSED", "id": "a84b4c76e66710", "param": "480 Temporarily Unavailable"})
row = json.loads(open(os.path.join(dtmp, mod.HISTORY)).read().strip())
check("...and logged as a miss, reason DND", row["missed"] is True and row["reason"] == "DND")

sent.clear()
check("with DND off nothing is rejected",
      not mod.dnd_reject(ev, dict(mod.OPTION_DEFAULTS), tracker, sent.append) and sent == [])
check("an outgoing call is never rejected",
      not mod.dnd_reject({"type": "CALL_OUTGOING", "id": "x"}, opts, tracker, sent.append) and sent == [])
for hostile in ("abc scode=200", "abc\nquit", "abc;x", "", "a" * 200, "abc def"):
    sent.clear()
    check(f"a Call-ID of {hostile[:20]!r} is never put on baresip's command line",
          not mod.dnd_reject({"type": "CALL_INCOMING", "id": hostile}, opts, tracker, sent.append)
          and sent == [])
check("...and never falls back to a bare hangup, which could end another call", sent == [])

alerts, n, _, _, options = make(dnd=True)
alerts.handle({"type": "CALL_INCOMING", "id": "q", "peeruri": "sip:1@pbx"})
alerts.handle({"type": "CALL_CLOSED", "id": "q"})
check("under DND nothing is notified, during or after", n.sent == [])

print("\nall passed" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
