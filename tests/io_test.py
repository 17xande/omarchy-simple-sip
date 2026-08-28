"""Exercise the file/descriptor discipline the daemon and CLI depend on.

Every case here is a substitution attack in miniature: swap a symlink, a FIFO
or an oversized file in for something the plugin expects to own, and check that
it fails or clips instead of following, blocking, or buffering without limit.

Run: python3 tests/io_test.py
"""
import contextlib, importlib.machinery, importlib.util, io, os, stat, sys, tempfile, time

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
fails = 0


def check(label, ok):
    global fails
    fails += 0 if ok else 1
    print(("ok   " if ok else "FAIL ") + label)


def dies(fn, *args, **kwargs):
    """True when fn() exits via die() -- stderr swallowed, it is expected."""
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            fn(*args, **kwargs)
    except SystemExit:
        return True
    return False


def path(name):
    return os.path.join(tmp, name)


# --------------------------------------------------------------- secure_dir

os.mkdir(path("real"), 0o700)
os.symlink(path("real"), path("link"))
check("secure_dir rejects a symlinked directory", dies(mod.secure_dir, path("link")))

os.mkdir(path("loose"), 0o755)
mod.secure_dir(path("loose"))
check("secure_dir tightens a group/other-readable dir",
      stat.S_IMODE(os.stat(path("loose")).st_mode) == 0o700)

mod.secure_dir(path("fresh/nested"))
check("secure_dir creates a missing dir at 0700",
      stat.S_IMODE(os.stat(path("fresh/nested")).st_mode) == 0o700)

mod.write_private(path("notadir"), "")
check("secure_dir rejects a plain file", dies(mod.secure_dir, path("notadir")))


# -------------------------------------------------------- open_checked reads

with open(path("plain"), "w") as fh:
    fh.write("hello\n")
os.symlink(path("plain"), path("plain.link"))

try:
    fd = mod.open_checked(path("plain.link"), os.O_RDONLY)
    os.close(fd)
    check("open_checked refuses a symlink", False)
except OSError:
    check("open_checked refuses a symlink", True)

check("read_bounded returns nothing for a symlink", mod.read_bounded(path("plain.link")) == "")
check("read_bounded reads a real file", mod.read_bounded(path("plain")) == "hello\n")

# A FIFO standing in for a regular file must fail fast, never park us in open().
os.mkfifo(path("fifo-as-file"), 0o600)
started = time.monotonic()
got = mod.read_bounded(path("fifo-as-file"))
check("read_bounded refuses a FIFO without blocking",
      got == "" and time.monotonic() - started < 1.0)

with open(path("big"), "w") as fh:
    fh.write("x" * 5000)
check("read_bounded stops at its limit", len(mod.read_bounded(path("big"), 100)) == 100)


# ------------------------------------------------------------ write_file mode

mod.write_private(path("secret"), "shh")
check("write_private creates a 0600 file",
      stat.S_IMODE(os.stat(path("secret")).st_mode) == 0o600)

os.chmod(path("secret"), 0o644)
mod.write_private(path("secret"), "shh again")
check("write_private narrows a widened mode back to 0600",
      stat.S_IMODE(os.stat(path("secret")).st_mode) == 0o600)

try:
    mod.write_private(path("plain.link"), "via symlink")
    check("write_private refuses to follow a symlink", False)
except OSError:
    check("write_private refuses to follow a symlink",
          mod.read_bounded(path("plain")) == "hello\n")


# -------------------------------------------------------------- record bounds

hist = path("history.jsonl")
oversized = '{"peer":"' + "y" * (mod.MAX_LINE + 10) + '"}'
mod.write_private(hist, oversized + '\n{"ts":1,"direction":"in","peer":"sip:1@pbx"}\n')
lines = mod.CallTracker(hist).read_lines()
check("read_lines drops an oversized record", len(lines) == 1)

record = mod.history_record({
    "ts": 1,
    "direction": "in",
    "peer": "sip:" + "z" * 10000,
    "missed": True,
    "duration": 10 ** 12,
    "reason": "w" * 10000,
})
check("history_record clips overlong fields",
      len(record["peer"]) == mod.MAX_FIELD and len(record["reason"]) == mod.MAX_FIELD)
check("history_record clamps an absurd duration", record["duration"] == 7 * 86400)

reply = mod.clip_reply({"data": "d" * (mod.MAX_REPLY_CHARS * 2), "ok": True})
check("clip_reply caps baresip prose",
      len(reply["data"]) == mod.MAX_REPLY_CHARS and reply["ok"] is True)
check("clip_reply passes a non-dict through as None", mod.clip_reply("nope") is None)


# ------------------------------------------------------------ netstring bounds

payload = b'{"event":true}'
decoded = list(mod.NetstringDecoder().feed(b"%d:%s," % (len(payload), payload)))
check("NetstringDecoder round-trips a normal payload", decoded == [payload])


def feeds(data, limit=None):
    dec = mod.NetstringDecoder() if limit is None else mod.NetstringDecoder(limit)
    try:
        list(dec.feed(data))
    except ValueError:
        return True
    return False


check("NetstringDecoder rejects an oversized declared length",
      feeds(b"%d:" % (mod.MAX_LINE + 1)))
check("NetstringDecoder rejects a colon-less flood", feeds(b"1" * 64))
check("NetstringDecoder rejects a non-numeric length", feeds(b"abc:xx,"))


# ------------------------------------------------------------------- follow

def drained(target, seconds=0.4, **kwargs):
    """Collect whatever follow() yields within a short deadline."""
    stream = mod.follow(target, deadline=time.monotonic() + seconds, **kwargs)
    try:
        return list(stream)
    finally:
        stream.close()


journal = path("events")
mod.write_private(journal, '{"a":1}\n{"a":2}\n')
check("follow reads existing records from the start",
      drained(journal, from_start=True) == ['{"a":1}', '{"a":2}'])

check("follow starts at EOF by default", drained(journal) == [])

mod.write_private(journal, "z" * (mod.MAX_LINE + 10) + '\n{"a":3}\n')
check("follow drops an oversized record and keeps the next",
      drained(journal, from_start=True) == ['{"a":3}'])

try:
    drained(path("plain.link"), from_start=True)
    check("follow refuses a symlinked journal", False)
except OSError:
    check("follow refuses a symlinked journal", True)

started = time.monotonic()
drained(journal, seconds=0.3)
check("follow honours its deadline instead of waiting forever",
      time.monotonic() - started < 2.0)


# ---------------------------------------------------------- write_fifo timing

mod.FIFO = path("cmd")
os.mkfifo(mod.FIFO, 0o600)
started = time.monotonic()
died = dies(mod.write_fifo, "ping")
check("write_fifo fails fast with no reader on the other end",
      died and time.monotonic() - started < 1.0)

os.unlink(mod.FIFO)
mod.write_private(mod.FIFO, "")
check("write_fifo refuses a regular file in place of the FIFO",
      dies(mod.write_fifo, "ping"))
check("daemon_up is false when the FIFO is not a FIFO", mod.daemon_up() is False)

print("\nall passed" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
