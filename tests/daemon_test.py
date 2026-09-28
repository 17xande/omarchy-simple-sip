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
check("the Answer button accepts that call, by its id", invoked == ["accept c1"])
alerts.action("call:c1", "reject")
check("the Reject button hangs that call up, by its id", invoked == ["accept c1", "hangup c1"])
alerts.action("call:c1", "default")
check("clicking the notification asks the panel to open", invoked == ["accept c1", "hangup c1", "SHOW"])
invoked.remove("SHOW")
alerts.action("call:zz", "answer")
check("a button for a call that is not ringing does nothing", invoked == ["accept c1", "hangup c1"])

alerts.handle({"type": "CALL_ESTABLISHED", "id": "c1"})
check("answering closes the notification", n.closed == ["call:c1"])
alerts.handle({"type": "CALL_CLOSED", "id": "c1"})
check("an answered call leaves no Missed call behind",
      [s[1] for s in n.sent] == ["Incoming call"])
alerts.action("call:c1", "answer")
check("a button pressed after the call ended does nothing", invoked == ["accept c1", "hangup c1"])

alerts, n, invoked, _, _ = make()
alerts.handle({"type": "CALL_INCOMING", "id": "a b", "peeruri": "sip:1@pbx"})
alerts.action("call:a b", "answer")
check("a call whose id cannot be named on a command line is not acted on blind", invoked == [])

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
with open(os.path.join(cdir, "contacts"), "w") as fh:
    fh.write('# my list\n"Spammer" <sip:spam@evil.example>;access=block\n'
             '"Home" <tel:+15550100>\n"Old name" <sip:1001@pbx>;presence=p2p\n')
check("a blocked caller is not listed as a contact",
      [c["name"] for c in json.loads(contacts().stdout)] == ["Old name"])
contacts("add", "sip:2002@pbx", "--name", "Alice")
kept_text = open(os.path.join(cdir, "contacts")).read()
check("adding a contact keeps baresip's call blocking", '<sip:spam@evil.example>;access=block' in kept_text)
check("...and comments and tel: entries", "# my list" in kept_text and "<tel:+15550100>" in kept_text)
contacts("add", "sip:1001@pbx", "--name", "New name")
check("renaming keeps the line's parameters",
      '"New name" <sip:1001@pbx>;presence=p2p' in open(os.path.join(cdir, "contacts")).read())
r = contacts("remove", "sip:1001@pbx")
check("contacts remove deletes it, and only it",
      r.returncode == 0 and "sip:1001@pbx" not in [c["uri"] for c in json.loads(contacts().stdout)]
      and "access=block" in open(os.path.join(cdir, "contacts")).read())
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
for hostile in ("abc scode=200", "abc\nquit", "abc;x", "", "a" * 300, "abc def", 'a"b', "a=b"):
    sent.clear()
    check(f"a Call-ID of {hostile[:20]!r} is never put on baresip's command line",
          not mod.dnd_reject({"type": "CALL_INCOMING", "id": hostile}, opts, tracker, sent.append)
          and sent == [])
check("...and never falls back to a bare hangup, which could end another call", sent == [])
t2 = mod.CallTracker(dfd, "h2.jsonl")
ev2 = {"type": "CALL_INCOMING", "id": "a b", "peeruri": "sip:9@pbx"}
t2.handle(ev2)
mod.dnd_reject(ev2, opts, t2, sent.append)
t2.handle({"type": "CALL_CLOSED", "id": "a b"})
row2 = json.loads(open(os.path.join(dtmp, "h2.jsonl")).read().strip())
check("a call DND could not turn away is not logged as DND", row2["reason"] != "DND")
sent.clear()
check("RFC 3261 punctuation in a Call-ID is still rejected by id",
      mod.dnd_reject({"type": "CALL_INCOMING", "id": "abc/def(1)@host"}, opts, tracker, sent.append)
      and sent == ["hangup abc/def(1)@host scode=480"])

alerts, n, _, _, options = make(dnd=True)
alerts.handle({"type": "CALL_INCOMING", "id": "q", "peeruri": "sip:1@pbx"}, quiet=True)
alerts.handle({"type": "CALL_CLOSED", "id": "q"})
check("a call turned away under DND is not notified, during or after", n.sent == [])
alerts.handle({"type": "CALL_INCOMING", "id": "r b", "peeruri": "sip:1@pbx"}, quiet=False)
check("one DND could not turn away rings through and is notified", len(n.sent) == 1)

cfg_dir = tempfile.mkdtemp()
orig = mod.CONF_DIR
mod.CONF_DIR = cfg_dir
mod.ensure_config()
check("the generated config allows one call at a time",
      "call_max_calls\t\t1" in open(os.path.join(cfg_dir, "config")).read())
mod.CONF_DIR = orig

# ------------------------------------------------------- echo cancellation

aec_dir = tempfile.mkdtemp()
orig_conf = mod.CONF_DIR
mod.CONF_DIR = aec_dir
afd = mod.conf_fd()
mod.ensure_config()
check("echo cancellation is off by default",
      "webrtc_aec.so" not in open(os.path.join(aec_dir, "config")).read())
mod.write_options(dict(mod.OPTION_DEFAULTS, aec=True), afd)
mod.ensure_config()
cfg = open(os.path.join(aec_dir, "config")).read()
check("turning it on loads webrtc_aec, once", cfg.count("module\t\t\twebrtc_aec.so") == 1)
check("...after the audio device module",
      cfg.index("webrtc_aec.so") > cfg.index("module\t\t\tpulse.so"))
mod.write_options(dict(mod.OPTION_DEFAULTS, aec=False), afd)
mod.ensure_config()
check("turning it off removes it", "webrtc_aec" not in open(os.path.join(aec_dir, "config")).read())
mod.CONF_DIR = orig_conf

# ------------------------------------------------- D-Bus sender binding

from jeepney import DBusAddress, new_signal, new_method_call, new_method_return
from jeepney.low_level import HeaderFields


class FakeSock:
    def __init__(self):
        self.closed = False

    def recv(self, n):
        return b"x"

    def fileno(self):
        return 99


class FakeParser:
    def __init__(self, messages):
        self.messages = list(messages)

    def add_data(self, data):
        pass

    def get_next_message(self):
        return self.messages.pop(0) if self.messages else None


class FakeConn:
    def __init__(self, messages):
        self.sock = FakeSock()
        self.parser = FakeParser(messages)

    def close(self):
        pass


N = DBusAddress(mod.NOTIFY_PATH, bus_name=mod.NOTIFY_NAME, interface=mod.NOTIFY_NAME)


def signal_from(sender, member, signature, body, addr=N):
    msg = new_signal(addr, member, signature, body)
    msg.header.fields[HeaderFields.sender] = sender
    return msg


def notify_reply(sender, serial, nid):
    call = new_method_call(N, "Notify", "s", ("x",))
    call.header.serial = serial
    msg = new_method_return(call, "u", (nid,))
    msg.header.fields[HeaderFields.sender] = sender
    return msg


def notifier(messages, owner=":1.5"):
    nt = mod.Notifier.__new__(mod.Notifier)
    nt.pending, nt.ids, nt.close_on_reply = {}, {}, set()
    nt.owner, nt.on_close = owner, None
    nt.conn = FakeConn(messages)
    return nt


nt = notifier([signal_from(":1.99", "ActionInvoked", "us", (7, "answer"))])
nt.ids["call:A"] = 7
check("an ActionInvoked from anyone but the server is ignored", list(nt.pump()) == [])
nt = notifier([signal_from(":1.5", "ActionInvoked", "us", (7, "answer"))])
nt.ids["call:A"] = 7
check("...and one from the server is acted on", list(nt.pump()) == [("call:A", "answer")])
nt = notifier([signal_from(":1.5", "ActionInvoked", "ss", ("7", "answer"))])
nt.ids["call:A"] = 7
try:
    got = list(nt.pump())
    check("a malformed signal is ignored, not a crash", got == [])
except Exception as exc:
    check(f"a malformed signal is ignored, not a crash ({exc!r})", False)

D = DBusAddress("/org/freedesktop/DBus", bus_name="org.freedesktop.DBus", interface="org.freedesktop.DBus")
nt = notifier([signal_from("org.freedesktop.DBus", "NameOwnerChanged", "sss",
                           (mod.NOTIFY_NAME, ":1.5", ":1.77"), D)])
nt.ids["call:A"] = 7
list(nt.pump())
check("a new notification server means the old ids are forgotten", nt.ids == {} and nt.owner == ":1.77")
nt = notifier([signal_from(":1.66", "NameOwnerChanged", "sss", (mod.NOTIFY_NAME, ":1.5", ":1.66"), D)])
list(nt.pump())
check("...but only when the bus itself says so", nt.owner == ":1.5")

nt = notifier([notify_reply(":1.8", 41, 3)])
nt.ids["call:old"] = 3
nt.pending[41] = "call:new"
list(nt.pump())
check("a Notify answered by a different server resets the ids first",
      nt.ids == {"call:new": 3} and nt.owner == ":1.8")

nt = notifier([notify_reply(":1.5", 1000 + i, i) for i in range(100)])
for i in range(100):
    nt.pending[1000 + i] = f"call:{i}"
list(nt.pump())
check("ids are capped", len(nt.ids) == mod.Notifier.MAX_IDS and "call:99" in nt.ids)

closed_fds = []
nt = notifier([])
nt.on_close = closed_fds.append
nt.close()
check("closing the notifier unregisters its descriptor at once", closed_fds == [99])

B = DBusAddress(mod.DBUS_PATH, bus_name=mod.DBUS_NAME, interface=mod.DBUS_NAME)
bus = mod.BaresipBus.__new__(mod.BaresipBus)
bus.owner, bus.pending = ":1.20", {}
bus.conn = FakeConn([signal_from(":1.66", "event", "sss", ("a", "b", '{"type":"SHOW_PANEL"}'), B),
                     signal_from(":1.20", "event", "sss", ("a", "b", '{"type":"REGISTER_OK"}'), B)])
check("baresip events are taken only from the baresip we started",
      list(bus.pump()) == [("event", '{"type":"REGISTER_OK"}')])

# ------------------------------------------------------ mimeapps.list

H = mod.HANDLER
check("install into an empty file adds the section",
      mod.edit_mimeapps("", True) == "[Default Applications]\n" + "".join(
          f"x-scheme-handler/{x}={H};\n" for x in ("sip", "sips", "tel")))
existing = ("[Added Associations]\ntext/plain=nvim.desktop;\n\n[Default Applications]\n"
            "x-scheme-handler/tel=other.desktop;\ntext/html=firefox.desktop\n")
installed = mod.edit_mimeapps(existing, True)
check("install puts ours first and keeps the old default as a fallback",
      f"x-scheme-handler/tel={H};other.desktop;" in installed)
check("...and leaves every other line alone",
      "text/plain=nvim.desktop;" in installed and "text/html=firefox.desktop" in installed
      and installed.startswith("[Added Associations]"))
check("install twice changes nothing", mod.edit_mimeapps(installed, True) == installed)
removed = mod.edit_mimeapps(installed, False)
check("uninstall removes only ours",
      "x-scheme-handler/tel=other.desktop;" in removed and H not in removed and "text/html" in removed)
check("uninstall with nothing to remove is a no-op", mod.edit_mimeapps(existing, False) == existing)

mh = tempfile.mkdtemp()
os.makedirs(os.path.join(mh, ".config"), 0o755)
os.makedirs(os.path.join(mh, "conf"), 0o700)
secret = os.path.join(mh, "conf", "accounts")
open(secret, "w").write("secret\n")


def handler(*args):
    env = {"HOME": mh, "PATH": "/usr/bin:/bin", "OMARCHY_SIP_CONF": os.path.join(mh, "conf"),
           "XDG_RUNTIME_DIR": mh}
    return subprocess.run([sys.executable, "-I", CLI, "handler", *args], env=env,
                          capture_output=True, timeout=20)


mimeapps = os.path.join(mh, ".config", "mimeapps.list")
os.link(secret, mimeapps + ".new")     # xdg-mime's temp name, planted as a hard link
r = handler("install")
check("handler install writes mimeapps.list itself", r.returncode == 0
      and f"x-scheme-handler/sip={H};" in open(mimeapps).read())
check("...never through a planted hard link", open(secret).read() == "secret\n")
check("...and writes the desktop entry",
      os.path.exists(os.path.join(mh, ".local/share/applications", H)))
r = handler("uninstall")
check("handler uninstall removes the entry and our defaults",
      r.returncode == 0 and H not in open(mimeapps).read()
      and not os.path.exists(os.path.join(mh, ".local/share/applications", H)))
os.unlink(mimeapps)
os.symlink(secret, mimeapps)            # a dotfiles-style symlink
r = handler("install")
check("a symlinked mimeapps.list is not followed or replaced",
      r.returncode != 0 and os.path.islink(mimeapps) and open(secret).read() == "secret\n"
      and b"yourself" in r.stderr)

print("\nall passed" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
