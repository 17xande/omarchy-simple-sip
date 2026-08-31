"""Exercise the file/descriptor discipline the daemon and CLI depend on.

Every case here is a substitution attack in miniature: swap a symlink, a FIFO,
an intermediate directory or a hard link in for something the plugin expects to
own, and check that it fails, clips, or lands on the pinned object instead of
following, blocking, or buffering without limit.

Run: python3 tests/io_test.py
"""
import contextlib, importlib.machinery, importlib.util, io, os, socket, stat, sys, tempfile, time

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


# ------------------------------------------------------------------- pin_dir

os.mkdir(path("real"), 0o700)
os.symlink(path("real"), path("link"))
check("pin_dir refuses a symlinked leaf", dies(mod.pin_dir, path("link")))

os.mkdir(path("chain"), 0o755)
os.mkdir(path("chain/mid"), 0o755)
os.mkdir(path("chain/mid/leaf"), 0o700)
os.symlink(path("chain/mid"), path("chain/vialink"))
check("pin_dir refuses a symlinked intermediate component",
      dies(mod.pin_dir, path("chain/vialink/leaf")))

os.mkdir(path("loose"), 0o755)
os.close(mod.pin_dir(path("loose")))
check("pin_dir tightens a group/other-readable leaf",
      stat.S_IMODE(os.stat(path("loose")).st_mode) == 0o700)

os.close(mod.pin_dir(path("fresh/nested")))
check("pin_dir creates a missing leaf at 0700",
      stat.S_IMODE(os.stat(path("fresh/nested")).st_mode) == 0o700)

# A directory we merely drop a file into -- ~/.config/systemd/user -- is not
# ours to re-mode. Forcing 0755 on it would silently widen a user who keeps
# their unit directory private, on every `status` poll.
os.mkdir(path("borrowed"), 0o700)
os.close(mod.pin_dir(path("borrowed"), 0o755, owned=False))
check("pin_dir leaves an unowned existing leaf's mode alone",
      stat.S_IMODE(os.stat(path("borrowed")).st_mode) == 0o700)

os.close(mod.pin_dir(path("borrowed2"), 0o755, owned=False))
check("pin_dir still creates a missing unowned leaf at its mode",
      stat.S_IMODE(os.stat(path("borrowed2")).st_mode) == 0o755)

mod.write_private("notadir", "", mod.dir_fd_for(path("real")))
check("pin_dir refuses a plain file", dies(mod.pin_dir, path("real/notadir")))


# ------------------------- the finding: same-UID intermediate component swap

# a/b/c pinned, then `b` replaced wholesale by an attacker-controlled directory
# holding a decoy. A pinned descriptor must keep resolving to the real leaf.
os.makedirs(path("swap/b/c"), 0o700)
pinned = mod.pin_dir(path("swap/b/c"))
mod.write_private("accounts", "real-secret\n", pinned)
real_ino = os.stat(path("swap/b/c/accounts")).st_ino

os.makedirs(path("evil/c"), 0o700)
with open(path("evil/c/accounts"), "w") as fh:
    fh.write("decoy\n")
os.rename(path("swap/b"), path("swap/b-old"))
os.rename(path("evil"), path("swap/b"))

got = mod.read_bounded("accounts", pinned)
check("pinned dir survives an intermediate component swap", got == "real-secret\n")
check("swapped-in decoy is never read", "decoy" not in got)
check("reads still land on the original inode",
      os.fstat(mod.open_checked("accounts", os.O_RDONLY, dir_fd=pinned)).st_ino == real_ino)

# ...and the leaf itself being replaced changes nothing for a held descriptor.
os.rename(path("swap/b/c"), path("swap/b/c-gone"))
os.mkdir(path("swap/b/c"), 0o700)
with open(path("swap/b/c/accounts"), "w") as fh:
    fh.write("decoy2\n")
check("pinned dir survives the leaf directory being replaced",
      mod.read_bounded("accounts", pinned) == "real-secret\n")
os.close(pinned)


# -------------------------------------------------------- open_checked reads

conf = mod.dir_fd_for(path("conf"))
mod.write_private("plain", "hello\n", conf)
os.symlink(path("conf/plain"), path("conf/plain.link"))

try:
    os.close(mod.open_checked("plain.link", os.O_RDONLY, dir_fd=conf))
    check("open_checked refuses a symlink", False)
except OSError:
    check("open_checked refuses a symlink", True)

check("read_bounded returns nothing for a symlink",
      mod.read_bounded("plain.link", conf) == "")
check("read_bounded reads a real file", mod.read_bounded("plain", conf) == "hello\n")

# A FIFO standing in for a regular file must fail fast, never park us in open().
os.mkfifo(path("conf/fifo-as-file"), 0o600)
started = time.monotonic()
got = mod.read_bounded("fifo-as-file", conf)
check("read_bounded refuses a FIFO without blocking",
      got == "" and time.monotonic() - started < 1.0)

mod.write_private("big", "x" * 5000, conf)
check("read_bounded stops at its limit", len(mod.read_bounded("big", conf, 100)) == 100)


# ------------------------------------------------- replace, never truncate

mod.write_private("secret", "shh", conf)
check("write_private creates a 0600 file",
      stat.S_IMODE(os.stat(path("conf/secret")).st_mode) == 0o600)

os.chmod(path("conf/secret"), 0o644)
mod.write_private("secret", "shh again", conf)
check("write_private narrows a widened mode back to 0600",
      stat.S_IMODE(os.stat(path("conf/secret")).st_mode) == 0o600)

# O_NOFOLLOW stops a symlink but not a same-owner HARD LINK. Truncating in
# place would push the new password into a file somebody else already holds.
mod.write_private("creds", "old-password\n", conf)
os.link(path("conf/creds"), path("conf/creds.planted"))
mod.write_private("creds", "new-password\n", conf)
check("hard link keeps the old bytes (replace, not truncate)",
      open(path("conf/creds.planted")).read() == "old-password\n")
check("the real file has the new bytes",
      open(path("conf/creds")).read() == "new-password\n")
check("planted link count drops back to 1",
      os.stat(path("conf/creds.planted")).st_nlink == 1)

# A symlink planted at the destination is replaced, and its target untouched.
mod.write_private("target", "untouched\n", conf)
os.symlink(path("conf/target"), path("conf/dest"))
mod.write_private("dest", "written\n", conf)
check("symlink at the destination is replaced, not written through",
      not os.path.islink(path("conf/dest"))
      and open(path("conf/target")).read() == "untouched\n"
      and open(path("conf/dest")).read() == "written\n")


# -------------------------------------------------------------- record bounds

hist = mod.dir_fd_for(path("hist"))
oversized = '{"peer":"' + "y" * (mod.MAX_LINE + 10) + '"}'
mod.write_private(mod.HISTORY, oversized + '\n{"ts":1,"direction":"in","peer":"sip:1@pbx"}\n', hist)
check("read_lines drops an oversized record", len(mod.CallTracker(hist).read_lines()) == 1)

record = mod.history_record({
    "ts": 1, "direction": "in", "peer": "sip:" + "z" * 10000,
    "missed": True, "duration": 10 ** 12, "reason": "w" * 10000,
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


def feeds(data):
    try:
        list(mod.NetstringDecoder().feed(data))
    except ValueError:
        return True
    return False


check("NetstringDecoder rejects an oversized declared length",
      feeds(b"%d:" % (mod.MAX_LINE + 1)))
check("NetstringDecoder rejects a colon-less flood", feeds(b"1" * 64))
check("NetstringDecoder rejects a non-numeric length", feeds(b"abc:xx,"))


# ------------------------------------------------------------- socket bounds

a, b = socket.socketpair()
b.sendall(b'{"a":1}\n' + b"z" * (mod.MAX_LINE + 10) + b'\n{"a":2}\n')
b.close()
lines = list(mod.read_lines(a, time.monotonic() + 2))
a.close()
check("stream drops an oversized record and resynchronises",
      lines == ['{"a":1}', '{"a":2}'])

# A client that never sends a newline must not grow the daemon's buffer.
srv_dir = mod.dir_fd_for(path("run"))
hub = mod.ControlHub(srv_dir)
check("control socket is created 0600",
      stat.S_IMODE(os.stat(path("run/control")).st_mode) == 0o600)
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.connect(f"/proc/self/fd/{srv_dir}/control")
conn = hub.accept()
client.sendall(b"x" * (mod.MAX_LINE + 4096))
time.sleep(0.05)
hub.read_commands(conn)
check("a newline-less client cannot grow the daemon buffer",
      len(hub.clients[conn]["buf"]) <= mod.MAX_LINE)
client.sendall(b"tail\n" + b'{"command":"ok"}\n')
time.sleep(0.05)
check("the stream resynchronises at the next newline",
      hub.read_commands(conn) == [b'{"command":"ok"}'])
client.close()
hub.close()
check("closing the hub removes the socket", not os.path.exists(path("run/control")))


# ------------------------------------------------------- connect, don't hang

mod.RUN_DIR = path("empty-run")
mod._DIR_FDS.pop(mod.RUN_DIR, None)
started = time.monotonic()
check("daemon_up is false with nothing listening", mod.daemon_up() is False)
check("connect_control fails fast rather than hanging",
      dies(mod.connect_control) and time.monotonic() - started < 2.0)

print("\nall passed" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
