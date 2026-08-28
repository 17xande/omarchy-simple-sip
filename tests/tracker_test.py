"""Exercise CallTracker's outcomes without needing real calls.

Run: python3 tests/tracker_test.py
"""
import importlib.machinery, importlib.util, json, os, sys, tempfile

spec = importlib.util.spec_from_loader(
    "omarchy_sip",
    importlib.machinery.SourceFileLoader(
        "omarchy_sip", os.path.join(os.path.dirname(__file__), "..", "bin", "omarchy-sip")
    ),
)
mod = importlib.util.module_from_spec(spec)
sys.modules["omarchy_sip"] = mod
spec.loader.exec_module(mod)

tmp = tempfile.mkdtemp()
path = os.path.join(tmp, "history.jsonl")
t = mod.CallTracker(path)

# 1. outbound, answered
t.handle({"type": "CALL_OUTGOING", "id": "a", "peeruri": "sip:1001@pbx"})
t.handle({"type": "CALL_ESTABLISHED", "id": "a"})
t.handle({"type": "CALL_CLOSED", "id": "a", "param": "Normal clearing"})

# 2. inbound, answered
t.handle({"type": "CALL_INCOMING", "id": "b", "peeruri": "sip:2002@pbx"})
t.handle({"type": "CALL_ESTABLISHED", "id": "b"})
t.handle({"type": "CALL_CLOSED", "id": "b", "param": "Normal clearing"})

# 3. inbound, never answered -> missed
t.handle({"type": "CALL_INCOMING", "id": "c", "peeruri": "sip:3003@pbx"})
t.handle({"type": "CALL_CLOSED", "id": "c", "param": "Call gave up"})

# 4. outbound, never answered -> NOT missed (we gave up, nobody missed us)
t.handle({"type": "CALL_OUTGOING", "id": "d", "peeruri": "sip:4004@pbx"})
t.handle({"type": "CALL_CLOSED", "id": "d", "param": "Busy Here"})

# 5. interleaved calls must not cross-contaminate
t.handle({"type": "CALL_INCOMING", "id": "e", "peeruri": "sip:5005@pbx"})
t.handle({"type": "CALL_OUTGOING", "id": "f", "peeruri": "sip:6006@pbx"})
t.handle({"type": "CALL_ESTABLISHED", "id": "f"})
t.handle({"type": "CALL_CLOSED", "id": "e", "param": "Call gave up"})   # e missed
t.handle({"type": "CALL_CLOSED", "id": "f", "param": "Normal clearing"})  # f answered

# 6. an event for an unknown call id must not crash or record
t.handle({"type": "CALL_CLOSED", "id": "zzz", "param": "stray"})

rows = [json.loads(l) for l in open(path)]
got = [(r["peer"].split("@")[0].replace("sip:", ""), r["direction"], r["missed"]) for r in rows]
want = [
    ("1001", "out", False),
    ("2002", "in", False),
    ("3003", "in", True),
    ("4004", "out", False),
    ("5005", "in", True),
    ("6006", "out", False),
]
fails = 0
for g, w in zip(got, want):
    ok = g == w
    fails += 0 if ok else 1
    print(("ok   " if ok else "FAIL ") + f"{w[0]}: {g}")
if len(got) != len(want):
    fails += 1
    print(f"FAIL row count: got {len(got)}, want {len(want)}")

# 7. the file must stay capped at the limit
small = mod.CallTracker(os.path.join(tmp, "cap.jsonl"), limit=3)
for i in range(10):
    small.handle({"type": "CALL_OUTGOING", "id": str(i), "peeruri": f"sip:{i}@pbx"})
    small.handle({"type": "CALL_CLOSED", "id": str(i)})
capped = open(os.path.join(tmp, "cap.jsonl")).read().strip().split("\n")
ok = len(capped) == 3 and json.loads(capped[-1])["peer"] == "sip:9@pbx"
fails += 0 if ok else 1
print(("ok   " if ok else "FAIL ") + f"cap: {len(capped)} rows, newest kept")

# 8. history file must be private -- it is a record of who you called
mode = oct(os.stat(path).st_mode & 0o777)
ok = mode == "0o600"
fails += 0 if ok else 1
print(("ok   " if ok else "FAIL ") + f"perms: {mode}")

print("\nall passed" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
