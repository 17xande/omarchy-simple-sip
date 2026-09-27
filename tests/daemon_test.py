"""Exercise the daemon's decision-making without a bus, a baresip or a shell.

CallAlerts decides what gets notified and what an action button does; it takes
its notifier, options and baresip `invoke` as arguments, so fakes stand in for
all three here.

Run: python3 tests/daemon_test.py
"""
import importlib.machinery, importlib.util, os, sys

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


print("\nall passed" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
