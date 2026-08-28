# Simple SIP

A minimal SIP softphone for the Omarchy bar. One account, one call at a time:
register, dial out, answer what comes in. [baresip](https://github.com/baresip/baresip)
does all the SIP, RTP and audio work.

![Simple SIP panel](preview.png)

```
  registered, idle            ringing (blinking, urgent colour)
  in a call                   dimmed: no account / daemon stopped
```

## Requirements

- `baresip` — `sudo pacman -S baresip` (in the official Arch repos)
- PipeWire's PulseAudio interface (`pipewire-pulse`), which Omarchy ships by default
- `python3` for the control helper (stdlib only, no pip packages)

## Install

```bash
omarchy plugin add https://github.com/<you>/omarchy-simple-sip --enable
~/.config/omarchy/plugins/io.github.17xande.simple-sip/bin/omarchy-sip install
```

`install` generates the baresip config, writes a `systemd --user` unit and starts it.
The daemon holds the SIP registration continuously, so calls arrive even when the
panel is closed and across shell restarts.

Then set your account — either in the panel (the setup form appears until an account
exists) or from a terminal, which keeps the password out of your shell history:

![Account setup](docs/account-setup.png)

```bash
read -rs PASSWORD
printf '%s' "$PASSWORD" | omarchy-sip account set sip:you@pbx.example.com \
    --auth-user you --transport tls
unset PASSWORD
```

## Using it

| Action | Panel | Keyboard | IPC |
|---|---|---|---|
| Call | type an extension or `sip:user@host`, press Enter | — | `omarchy-shell io.github.17xande.simple-sip dial sip:1001@pbx` |
| Answer | click **Answer** | `a` | `omarchy-shell io.github.17xande.simple-sip answer` |
| Reject / hang up | click **Reject** / **Hang up** | `d` / `b` | `omarchy-shell io.github.17xande.simple-sip hangup` |
| Account settings | click the gear row | `s` | — |

A bare extension or phone number is completed with your account's domain, so `1001`
dials `sip:1001@pbx.example.com`. Incoming calls raise a critical-urgency
notification and (by default) open the panel.

### Recent calls

The panel keeps a short log of calls made, received and missed. An inbound call that
never reached "established" is a **miss** (shown in the urgent colour); an outbound one
that was never picked up is just "No answer". Selecting a row redials it, with the
mouse or the keyboard.

The log is written by the daemon, not the panel, so a call that starts and ends while
the shell is restarting is still recorded. It lives in
`~/.config/omarchy-sip/history.jsonl` (mode `0600`, last 50 calls), and
`historyLimit: 0` in the widget settings hides the section entirely.

### Keybindings

Omarchy plugins cannot ship keybindings — the manifest has no such field, and
installing a plugin never writes to your Hyprland config. Add what you want to
`~/.config/hypr/bindings.conf`:

```
bindd = SUPER SHIFT, T, SIP dialer, exec, omarchy-shell io.github.17xande.simple-sip toggle
bindd = SUPER, F9, Answer SIP call, exec, omarchy-shell io.github.17xande.simple-sip answer
bindd = SUPER SHIFT, F9, Hang up SIP call, exec, omarchy-shell io.github.17xande.simple-sip hangup
```

`SUPER+SHIFT+T` is unbound in a default Omarchy install. Note that `SUPER+SHIFT+P`
is **not** free — Omarchy binds it to Google Photos.

## How it works

baresip's `ctrl_tcp` module accepts **only one** control connection — its connect
handler drops any existing client when a new one arrives. So a single daemon owns
that socket and everything else goes through two files:

```
$XDG_RUNTIME_DIR/omarchy-sip/cmd      FIFO   -- one JSON command per line, in
$XDG_RUNTIME_DIR/omarchy-sip/events   file   -- one JSON object per line, out
```

Both baresip events and command responses land in the journal, so any number of
readers can tail it and see the whole picture. The panel drives its state from
*events* (structured); the `status` snapshot exists only to resync after a shell
restart, when the last registration event may be minutes old.

```
Panel.qml ──┬─ Process: omarchy-sip events ──── tails the journal
            └─ Process: omarchy-sip dial/answer/hangup ── writes the FIFO
                                    │
                          omarchy-sip daemon ── owns the one ctrl_tcp connection
                                    │
                                 baresip ── SIP / RTP / audio
```

`Model.js` holds every pure function (event mapping, URI completion, duration
formatting, and the one place that scrapes baresip's prose output). `Service.qml`
owns state and processes. `Panel.qml` is a view with no call state of its own.

**Swapping the engine.** The QML only ever calls
`omarchy-sip {events,status,dial,answer,hangup,account}` with JSON in and out.
Replacing baresip with something else means reimplementing that contract; the QML
does not change.

## CLI

```
omarchy-sip install | uninstall            set up or remove the user service
omarchy-sip start | stop | restart         control the daemon
omarchy-sip status                         JSON: unit, account and baresip state
omarchy-sip events                         stream the JSON event journal
omarchy-sip dial <uri> | answer | hangup   call control
omarchy-sip send <cmd> [params]            any baresip command, fire-and-forget
omarchy-sip cmd  <cmd> [params]            ... and print the response
omarchy-sip history [--limit N]            recent calls as JSON
omarchy-sip account show | set | clear     account management
```

`send`/`cmd` reach every baresip command, which is handy for things the panel does
not surface: `omarchy-sip cmd callstat`, `omarchy-sip cmd reginfo`,
`omarchy-sip cmd listcalls`.

Environment overrides: `OMARCHY_SIP_CONF` (config dir, default
`~/.config/omarchy-sip`) and `OMARCHY_SIP_LISTEN` (SIP bind address, default
`0.0.0.0:0` — set a fixed port only if your PBX requires one).

## Security notes

- Credentials live in `~/.config/omarchy-sip/accounts`, mode `0600`. baresip's
  accounts format is `;`-delimited, so a password containing `;` is rejected rather
  than silently truncated.
- Passwords are passed to the CLI on **stdin**, never as an argument, so they never
  appear in a process listing.
- `ctrl_tcp` has no authentication. It binds `127.0.0.1` only — but that still means
  any local process can place calls through the daemon. The daemon refuses to start
  if that port is already held, rather than adopting somebody else's baresip.
- Like all Omarchy plugins, this runs unsandboxed inside the long-lived
  `omarchy-shell` process, with your user's permissions.

### Files and descriptors

Both directories the plugin owns — `~/.config/omarchy-sip` and
`$XDG_RUNTIME_DIR/omarchy-sip` — are created at mode `0700` and then *pinned*: a
symlink, a non-directory, or a directory belonging to another user in either place
is a hard error, not something to write into.

Every persistent object (the command FIFO, the event journal, `history.jsonl`, the
accounts and config files, baresip's log) is opened with `O_NOFOLLOW | O_NONBLOCK`
and then validated with `fstat` **on the descriptor that will actually be used**, for
both file type and owner. Checking the descriptor rather than the pathname is what
makes the check unraceable, and `O_NONBLOCK` is what stops a FIFO substituted for a
regular file from parking a helper inside `open()`. `write_fifo` therefore fails
immediately — rather than hanging the panel — when there is no daemon reading.

Nothing is read without a ceiling: whole-file reads cap at 1 MiB, one journal record
or FIFO command at 64 KiB, one history field at 512 bytes, and baresip's prose replies
at 8 KiB before they are spliced into `omarchy-sip status`. An oversized record is
dropped and noted in the journal instead of buffered.

### Processes

The QML side consumes each helper's diagnostic output a line at a time into a
240-character buffer, instead of retaining whole streams, and every finite CLI call
has a whole-process deadline (10–20 s) after which the child is terminated. The
`omarchy-sip events` listener is the one long-lived process, so it is bounded by the
record cap in the journal reader rather than by a deadline.

### Privileges

The plugin never invokes `sudo` and never calls a package manager. `pacman -S baresip`
in [Requirements](#requirements) is an instruction for you to run. `systemctl` is only
ever called as `systemctl --user` and only ever names this plugin's own unit,
`omarchy-sip.service`.

## Not in this version

- No mute — baresip's `menu` module exposes no mute command, so it would mean
  muting the system input device instead of just the call.
- No DTMF keypad, no multiple accounts, no call transfer or hold.
- Direct IP-to-IP calls need a reachable interface; baresip refuses loopback
  destinations with `no laddr for 127.0.0.1`.

## Troubleshooting

```bash
systemctl --user status omarchy-sip      # is the daemon up?
omarchy-sip status                       # what does it think is going on?
omarchy-sip events                       # watch calls happen live
cat $XDG_RUNTIME_DIR/omarchy-sip/baresip.log
qs log -p /usr/share/omarchy/shell --tail 100    # QML errors
```

If the daemon refuses to start with *"control port already in use"*, another
baresip is holding `127.0.0.1:44510`; the daemon deliberately will not adopt it.

## Hacking on it

`.qml` edits hot-reload. **`Model.js` edits do not** — the QML engine caches JS
imports for the life of the shell process, and neither `omarchy-shell shell
rescanPlugins` nor disabling/re-enabling the plugin clears them. Run
`omarchy-restart-shell` after touching `Model.js` (not `omarchy-refresh-shell`,
which also resets `shell.json` to defaults).

`Model.js` is deliberately free of QML objects, so its logic can be exercised
straight from node:

```bash
node -e 'const s=require("fs").readFileSync("Model.js","utf8");const M={};
new Function("exports",s+"\nObject.assign(exports,{normalizeTarget,parseReginfo});")(M);
console.log(M.normalizeTarget("1001","sip:you@pbx.example.com"));'
```

### Tests

```bash
./tests/run
```

Three dependency-free suites: `tests/model_test.js` covers every pure function in
`Model.js` (event mapping, URI completion, the registration-status scraping, relative
times), `tests/tracker_test.py` covers the call log's made / received / missed
classification, interleaved calls, the size cap and file permissions, and
`tests/io_test.py` covers the file/descriptor discipline described under
[Security notes](#files-and-descriptors) — each case swaps a symlink, a FIFO or an
oversized record in for something the plugin expects to own, and asserts it fails or
clips rather than following, blocking, or buffering without limit.

`qmllint` cannot resolve the shell's `Panel` type and exits 255 with no output on
this plugin *and* on the first-party ones, so it is not a useful gate here.

## License

MIT
