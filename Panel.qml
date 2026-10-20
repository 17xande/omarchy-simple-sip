import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Simple SIP -- bar widget + panel. One account, one call at a time.
//
// The panel is a view over Service.qml's state; it holds no call state of its
// own. Which controls are on screen is decided entirely by the service:
// no daemon -> Start, no account -> setup form, ringing -> Answer/Reject,
// on a call -> timer + Hang up, otherwise -> dial field.
Panel {
  id: root
  moduleName: "io.github.17xande.simple-sip"
  ipcTarget: "io.github.17xande.simple-sip"
  manageIpc: false

  // Host-injected, capability-scoped to this plugin's own lifecycle. Its
  // summon/toggle route through the bar to the copy on the focused monitor.
  property var shell: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Keyboard cursor over whichever action rows are currently visible.
  property bool cursorActive: false
  property int cursorIndex: 0
  property bool setupOpen: false
  property string dialText: ""
  // Set once the person edits the setup form, so account details that arrive
  // late (the `account show` round trip) never overwrite what they typed.
  property bool setupTouched: false
  property bool keypadOpen: false
  property bool transferOpen: false
  // The dial keypad under the dial field. Remembered for the shell session
  // only: like the panel itself, it starts from the same place every time.
  property bool dialPadOpen: false
  // Which screen the idle panel shows: "main", "contacts" or "history". Only
  // reachable with no call ringing or up; a call forces it back to "main" so
  // Answer and Hang up are never hidden behind a list.
  property string view: "main"
  property string contactQuery: ""
  // The contact form is open. `contactOriginal` is the address the contact is
  // saved under now ("" for a new one), which is what an edit replaces.
  property bool contactOpen: false
  property string contactOriginal: ""
  property string contactError: ""
  // What the next press confirms, for a few seconds: "delete:<uri>" or
  // "clear" (the call log). Any cursor move, or the clock, takes it back.
  property string armed: ""
  // The setup form's codec switches (ids, see Model.CODEC_CHOICES), what the
  // account has stored now, and whether that is a list written by hand.
  property var codecsOn: Model.DEFAULT_CODECS.slice()
  property string codecsStored: Model.codecArg(Model.DEFAULT_CODECS)
  property bool codecsCustom: false
  // What the outbound and STUN fields were filled from, and whether the person
  // has touched each: a field is only sent when they have and it differs.
  property string outboundStored: ""
  property string stunStored: ""
  property bool outboundEdited: false
  property bool stunEdited: false
  property bool codecsEdited: false
  // End of the quiet window after an auto-open; see Model.typingGuard.
  property double typingGuardUntil: 0
  readonly property int typingQuietMs: 1500
  property double lastPrefillAt: 0
  property string lastPrefill: ""
  // What the contact form's fields held when it opened, to tell edits from not.
  property string contactBaseName: ""
  property string contactBaseNumber: ""
  readonly property int prefillIntervalMs: 3000

  // True when this key must be swallowed because the panel opened by itself
  // under someone's typing; also extends the window.
  function guardKey() {
    var g = Model.typingGuard(Date.now(), typingGuardUntil, typingQuietMs)
    typingGuardUntil = g.until
    return g.swallow
  }

  readonly property var suggestions: dialRow.visible
    ? Model.matchContacts(dialText, sip.contacts, 5) : []

  // Whether any text field on screen is on screen at all (for handing the
  // keyboard back when the last one goes), and whether one has the keyboard
  // now (for keeping navigation and shortcuts out of the way of typing).
  // They differ after Down from the dial field: it stays on screen while the
  // cursor walks the rows under it.
  readonly property bool textInputActive: dialRow.visible || setupForm.visible
                                          || transferRow.visible || contactForm.visible
                                          || contactsSearchRow.visible
  readonly property bool fieldFocused: dialField.activeFocus || transferField.activeFocus
                                       || contactsSearch.activeFocus || formFocused
                                       || contactNameField.activeFocus || contactNumberField.activeFocus
                                       || uriField.activeFocus
                                       || authField.activeFocus || displayField.activeFocus
                                       || passwordField.activeFocus || transportField.popupOpen
                                       || outboundField.activeFocus || stunField.activeFocus

  // Focus anywhere inside one of the two forms, whatever it is: a switch, a
  // button, the dropdown's trigger. The key catcher takes Tab, Space, Enter and
  // Escape before any of them could, so it must stand aside for all of them,
  // not only for the text fields -- which is also what lets Tab walk the form.
  readonly property bool formFocused: {
    var win = setupForm.Window.window
    var item = win ? win.activeFocusItem : null
    return item !== null && (within(item, setupForm) || within(item, contactForm))
  }

  function within(item, ancestor) {
    for (var p = item; p; p = p.parent) if (p === ancestor) return true
    return false
  }

  // A form is taller than the panel; keep the control that has focus in view.
  function revealFocus() {
    var win = setupForm.Window.window
    var item = win ? win.activeFocusItem : null
    if (!item || !(within(item, setupForm) || within(item, contactForm))) return
    var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
    var bottom = top + item.height
    var margin = Style.space(8)
    if (top - margin < panelFlick.contentY) panelFlick.contentY = Math.max(0, top - margin)
    else if (bottom + margin > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = Math.min(Math.max(0, panelFlick.contentHeight - panelFlick.height),
                                     bottom + margin - panelFlick.height)
  }

  // ...and when the last one leaves the screen, the keyboard has to come back.
  // Nothing else claims it: dialField takes focus when it appears and no one
  // hands it back when it goes, so a call arriving while the panel was already
  // open left Answer on screen with focus stranded on a hidden field -- no
  // 'a', no cursor keys, no Enter. Only reopening the panel recovered it.
  onTextInputActiveChanged: if (!textInputActive && opened) {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // The contact form closing strands focus on a hidden field just as the
  // others do, but the search or dial field may still be on screen to take it.
  onContactOpenChanged: {
    disarm()
    if (!contactOpen && opened) giveFocusBack()
  }

  function giveFocusBack() {
    Qt.callLater(function() {
      if (contactsSearch.visible) contactsSearch.forceActiveFocus()
      else if (dialField.visible) dialField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  // Arrival on a screen: its search field takes the keyboard, a list without
  // one starts with the cursor on its first row, and a confirmation pending
  // on the last screen is not carried to this one.
  onViewChanged: {
    disarm()
    contactQuery = ""
    cursorActive = view === "history"
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    if (opened) giveFocusBack()
  }

  onCursorIndexChanged: disarm()

  function disarm() {
    armed = ""
    armTimer.stop()
  }

  function arm(what) {
    armed = what
    armTimer.restart()
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: column
  }

  onActionsChanged: pointerGate.reset()

  Timer {
    id: armTimer
    interval: 3000
    onTriggered: root.armed = ""
  }

  // The screens are only there when nothing else is: the account is up, no
  // call, and neither form open.
  readonly property bool idleScreen: sip.daemonUp && sip.configured && sip.callState === "idle"
                                     && !setupForm.visible && !contactForm.visible
  readonly property bool contactsShown: view === "contacts" && idleScreen
  readonly property var shownContacts: Model.filterContacts(contactQuery, sip.contacts)
  // More calls in the log than the main screen lists (all of them, when it
  // lists none): the way into the whole log.
  readonly property bool moreCalls: sip.history.length > sip.historyLimit
  readonly property bool mainIdle: idleScreen && view === "main"

  // Said under the list when there is nothing in it.
  readonly property string emptyText: {
    if (contactsShown && shownContacts.length === 0)
      return sip.contacts.length === 0 ? "No contacts yet — save one from Recent calls or add one"
                                        : "No contact matches"
    if (view === "history" && idleScreen && sip.history.length === 0) return "No calls yet"
    return ""
  }

  readonly property var actions: buildActions()
  readonly property var suggestActions: actions.filter(function(a) { return a.section === "suggest" })
  readonly property var primaryActions: actions.filter(function(a) { return a.section === "primary" })
  readonly property var historyActions: actions.filter(function(a) { return a.section === "history" })
  readonly property var moreActions: actions.filter(function(a) { return a.section === "more" })

  // Cursor indices are assigned here, once, so the two Repeaters below can
  // render different sections while sharing a single keyboard cursor.
  function buildActions() {
    var built = buildRows()
    for (var i = 0; i < built.length; i++) {
      built[i].index = i
      if (!built[i].section) built[i].section = "primary"
    }
    return built
  }

  function buildRows() {
    // Account settings stay reachable while the daemon is down: an account
    // baresip refuses is one reason it might be, and this is where it is fixed.
    if (!sip.daemonUp) return setupForm.visible
      ? [{ id: "start", label: "Start SIP daemon", glyph: "\uf04b" }]
      : [{ id: "start", label: "Start SIP daemon", glyph: "\uf04b" },
         { id: "setup", label: "Account settings", glyph: "\uf013" }]
    // A call is answered, hung up and muted whatever form was open: those rows
    // come before the forms, which a call closes (see onCallStateChanged).
    if (sip.callState === "incoming") return [
      { id: "answer", label: "Answer", glyph: "\uf095" },
      { id: "reject", label: "Reject", glyph: "\uf00d" }
    ]
    if (sip.onCall) {
      var inCall = [{ id: "mute", label: sip.muted ? "Unmute" : "Mute",
                      glyph: sip.muted ? "\uf131" : "\uf130", hint: "m" }]
      if (sip.callState === "active") {
        inCall.push({ id: "hold", label: sip.onHold ? "Resume" : "Hold",
                      glyph: sip.onHold ? "\uf04b" : "\uf04c", hint: "p" })
        // nf-md-dialpad (U+F061C), outside the BMP, so spelt as its pair.
        inCall.push({ id: "keypad", label: keypadOpen ? "Hide keypad" : "Keypad",
                      glyph: "\udb81\ude1c", hint: "n" })
        inCall.push({ id: "transfer", label: "Transfer…", glyph: "\uf064", hint: "t" })
      }
      inCall.push({ id: "hangup", label: "Hang up", glyph: "\uf00d", hint: "b" })
      return inCall
    }
    if (setupForm.visible) return []
    if (contactForm.visible) return []
    var rows = []
    if (view === "contacts") return contactRows(rows)
    if (view === "history") return historyRows(rows)
    // Contacts matching what is typed, first, right under the field.
    for (var k = 0; k < suggestions.length; k++) {
      rows.push({ id: "call:" + suggestions[k].uri, label: suggestions[k].name || Model.peerShort(suggestions[k].uri),
                  meta: Model.peerLabel(suggestions[k].uri), glyph: "\uf095",
                  contactUri: suggestions[k].uri, section: "suggest" })
    }
    if (sip.voicemailTarget !== "") {
      // The meta names where it dials, so the number is never a surprise.
      rows.push({ id: "voicemail", label: "Voicemail", glyph: "\uf0e0", hint: "v",
                  meta: (sip.mwi.newCount > 0 ? sip.mwi.newCount + " new · " : "")
                        + Model.peerShort(Model.normalizeTarget(sip.voicemailTarget, sip.aor)),
                  urgent: sip.mwi.newCount > 0, section: "primary" })
    }
    rows.push({ id: "dnd", label: "Do not disturb", glyph: "\uf1f6", hint: "q",
                meta: sip.dnd ? "On — calls go to voicemail" : "", urgent: sip.dnd, section: "primary" })
    // nf-fa-address_book
    rows.push({ id: "contacts", label: "Contacts", glyph: "\uf2b9", hint: "o",
                meta: sip.contacts.length > 0 ? sip.contacts.length + " saved" : "", section: "primary" })
    rows.push({ id: "setup", label: "Account settings", glyph: "\uf013", section: "primary" })
    // Recent calls are actions too: they share the cursor model, so Enter on a
    // row redials it and the keyboard behaves the same everywhere.
    for (var i = 0; i < sip.history.length && i < sip.historyLimit; i++) rows.push(callRow(sip.history[i]))
    // nf-fa-history
    if (moreCalls) rows.push({ id: "all-calls", label: "All calls", glyph: "\uf1da", hint: "y",
                               meta: sip.history.length + " calls", section: "more" })
    return rows
  }

  function callRow(entry) {
    return {
      id: "redial:" + Model.redialTarget(entry),
      label: Model.historyLabel(entry, sip.contacts, sip.aor),
      contactUri: Model.redialTarget(entry),
      glyph: Model.historyGlyph(entry),
      meta: Model.historyMeta(entry, clock.now),
      urgent: Model.historyIsMissed(entry),
      section: "history"
    }
  }

  // The contacts screen: a way to add one, then everybody the search matches.
  // The delete confirmation lives in the row's own meta, where the eye already is.
  function contactRows(rows) {
    // nf-fa-user_plus
    rows.push({ id: "contact-new", label: "New contact", glyph: "\uf234", section: "primary" })
    for (var i = 0; i < shownContacts.length; i++) {
      var c = shownContacts[i]
      var sure = armed === "delete:" + c.uri
      rows.push({ id: "contact:" + c.uri, label: c.name || Model.peerShort(c.uri),
                  meta: sure ? "Press x again to delete" : Model.peerLabel(c.uri), urgent: sure,
                  glyph: "\uf095", contactUri: c.uri, saved: true, section: "history" })
    }
    return rows
  }

  // The whole call log, then the one destructive row, which takes two presses.
  function historyRows(rows) {
    for (var i = 0; i < sip.history.length; i++) rows.push(callRow(sip.history[i]))
    if (sip.history.length > 0) {
      var sure = armed === "clear"
      // nf-fa-trash
      rows.push({ id: "clear-history", glyph: "\uf1f8", urgent: true, section: "more",
                  label: sure ? "Clear all " + sip.history.length + " calls? Press again" : "Clear history" })
    }
    return rows
  }

  function activate(id) {
    if (id !== "clear-history") disarm()
    switch (id) {
    case "start":  sip.startDaemon(); break
    case "answer": sip.answer(); break
    case "reject": sip.hangup(); break
    case "hangup": sip.hangup(); break
    case "mute":   sip.toggleMute(); break
    case "hold":   sip.toggleHold(); break
    case "keypad": keypadOpen = !keypadOpen; break
    case "transfer": transferOpen = true; break
    case "setup":  setupOpen = true; break
    case "voicemail": sip.dial(sip.voicemailTarget); break
    case "dnd":    sip.toggleDnd(); break
    case "contacts": view = "contacts"; break
    case "all-calls": view = "history"; break
    case "contact-new": openContact(""); break
    case "clear-history":
      if (armed === "clear") { disarm(); sip.clearHistory() }
      else arm("clear")
      break
    default:
      if (id.indexOf("redial:") === 0 && id.length > 7) sip.dial(id.substring(7))
      else if (id.indexOf("call:") === 0 && id.length > 5) { dialText = ""; sip.dial(id.substring(5)) }
      else if (id.indexOf("contact:") === 0 && id.length > 8) { view = "main"; sip.dial(id.substring(8)) }
    }
  }

  // x or Delete on a saved contact: the first press asks, the second (within a
  // few seconds, with the cursor where it was) deletes.
  function requestDelete() {
    var a = cursorAction()
    if (!contactsShown || !a || !a.saved) return
    if (armed === "delete:" + a.contactUri) { disarm(); sip.deleteContact(a.contactUri) }
    else arm("delete:" + a.contactUri)
  }

  // Keys on the contacts screen: a search is what is typed there, except e and
  // c on a contact, which edit it.
  function contactsKey(t, key) {
    var a = cursorAction()
    if ((key === "e" || key === "c") && a && a.saved) { openContact(a.contactUri); return }
    if (t.length === 1 && t >= " " && t !== "\x7f") {
      contactQuery = contactQuery + t
      cursorActive = false
      contactsSearch.forceActiveFocus()
    }
  }

  // The contact saved under exactly this address, or null. Exactly: a name
  // lent to a caller by extension (Model.contactName) is not a contact to edit.
  function savedContact(uri) {
    var target = Model.redialTarget({ peer: uri })
    for (var i = 0; i < sip.contacts.length; i++) if (sip.contacts[i].uri === target) return sip.contacts[i]
    return null
  }

  // The contact form, for a row's address ("" for a new contact). A saved
  // contact is edited -- name and address, replaced in one step -- and an empty
  // name removes it.
  function openContact(uri) {
    var saved = uri ? savedContact(uri) : null
    contactOriginal = saved ? saved.uri : ""
    contactError = ""
    contactNameField.text = saved ? saved.name : ""
    contactNumberField.text = uri || ""
    contactBaseName = contactNameField.text
    contactBaseNumber = contactNumberField.text
    contactOpen = true
    Qt.callLater(function() { contactNameField.forceActiveFocus(); contactNameField.selectAll() })
  }

  function contactDirty() {
    return contactNameField.text !== contactBaseName || contactNumberField.text !== contactBaseNumber
  }

  function saveContact() {
    if (!contactOpen) return
    var r = Model.contactForm(contactNameField.text, contactNumberField.text, sip.aor,
                              contactOriginal, sip.contacts)
    if (r.error !== "") { contactError = r.error; return }
    if (sip.saveContact(r.uri, r.name, contactOriginal)) contactOpen = false
    else contactError = "Still saving the last change — try again"
  }

  // The form's Delete asks first, like the row's x: a second press within a few
  // seconds deletes.
  function deleteOpenContact() {
    if (contactOriginal === "") return
    if (armed !== "form-delete") { arm("form-delete"); return }
    disarm()
    if (sip.deleteContact(contactOriginal)) contactOpen = false
  }

  function cursorAction() {
    if (!cursorActive || actions.length === 0) return null
    return actions[Math.min(cursorIndex, actions.length - 1)]
  }

  // Down from a field: onto the rows under it.
  function intoRows() {
    if (actions.length === 0) return
    cursorIndex = 0
    cursorActive = true
    keyCatcher.forceActiveFocus()
  }

  function moveCursor(dy) {
    cursorActive = true
    if (actions.length === 0) return
    cursorIndex = Math.max(0, Math.min(actions.length - 1, cursorIndex + dy))
  }

  function close() {
    root.controller.hide()
    setupOpen = false
  }

  // The bar builds one copy of this widget per monitor, each with its own
  // Service. Anything that must happen once -- opening the panel for a call,
  // pausing media, syncing settings to the daemon -- is done by the first
  // copy only. Falls back to "yes" when the host offers no way to tell.
  readonly property bool isLeader: {
    if (!bar || typeof bar.moduleWidgets !== "function") return true
    var items = bar.moduleWidgets(moduleName)
    return items.length === 0 || items[0] === root
  }

  // Open on the focused monitor rather than whichever copy happened to run
  // this. The shell facade picks the copy; without it, open this one.
  function summonHere() {
    if (shell && typeof shell.summon === "function" && shell.summon(moduleName, "")) return
    root.open()
  }

  function toggleHere() {
    if (shell && typeof shell.toggle === "function") { shell.toggle(moduleName, ""); return }
    root.toggle()
  }

  // Opening the form shows the account as it is, so changing one field does
  // not silently reset the others -- the transport used to reappear as udp.
  function fillSetupForm() {
    if (setupTouched) return
    var d = sip.accountDetails || {}
    uriField.text = String(d.aor || "")
    authField.text = String(d.authUser || "")
    displayField.text = String(d.displayName || "")
    transportField.value = ["udp", "tcp", "tls"].indexOf(d.transport) >= 0 ? d.transport : "udp"
    outboundStored = String(d.outbound || "")
    stunStored = String(d.stun || "")
    outboundField.text = outboundStored
    stunField.text = stunStored
    codecsOn = Model.codecIds(d)
    codecsStored = Model.codecArg(codecsOn)
    codecsCustom = d.codecsCustom === true
    passwordField.text = ""
  }

  onSetupOpenChanged: {
    if (setupOpen) {
      view = "main"
      setupTouched = false
      outboundEdited = false
      stunEdited = false
      codecsEdited = false
      fillSetupForm()
      sip.loadAccount()
    } else {
      passwordField.text = ""   // a cancelled form keeps no password around
    }
  }

  Connections {
    target: sip
    function onAccountDetailsChanged() { if (setupForm.visible) root.fillSetupForm() }
    // A call missed while the panel is open has been seen.
    function onUnseenMissedChanged() { if (root.opened && sip.unseenMissed > 0) sip.markHistorySeen() }
    function onCallStateChanged() {
      if (sip.callState !== "active") {
        root.keypadOpen = false
        root.transferOpen = false
      }
      if (sip.callState !== "idle") {
        root.contactOpen = false
        root.setupOpen = false
        root.view = "main"
      }
    }
    function onDaemonUpChanged() { if (!sip.daemonUp) root.view = "main" }
  }

  // The panel scrolls to whatever form control has the keyboard.
  Connections {
    target: setupForm.Window.window
    ignoreUnknownSignals: true
    function onActiveFocusItemChanged() { root.revealFocus() }
  }

  function doTransfer() {
    if (transferField.text.trim() === "") return
    if (sip.transfer(transferField.text) === "") transferOpen = false
  }

  // Typing a name and pressing Enter calls the best match; anything that
  // looks like an address or a number is dialled as typed.
  function placeCall() {
    var text = dialText.trim()
    if (text === "") return
    var byName = suggestions.length > 0 && /[A-Za-z]/.test(text)
                 && text.indexOf("@") < 0 && !/^(sips?|tel):/i.test(text)
    sip.dial(byName ? suggestions[0].uri : text)
    dialText = ""
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    // Always the main screen, and never a form left over from last time.
    view = "main"
    contactOpen = false
    disarm()
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    // The clock only ticks during a call, so stamp it on open to keep the
    // call log's relative times honest.
    clock.now = Date.now()
    sip.markHistorySeen()
    sip.refresh()
    Qt.callLater(function() {
      if (dialField.visible) dialField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  Service {
    id: sip
    settings: root.settings
    optionSync: root.isLeader
    mediaControl: root.isLeader

    // Ringing is the one thing worth interrupting for: surface the panel so
    // Answer is one click away rather than buried behind the bar icon.
    onIncomingCall: function(peerUri) {
      // Armed on every ring, auto-open or not: a panel already open while
      // someone types into its dial or contact field hands the keyboard to
      // Answer/Reject the moment the field disappears. Every copy arms it;
      // the one that opens is the focused monitor's.
      root.typingGuardUntil = Date.now() + root.typingQuietMs
      if (root.isLeader && sip.boolSetting("autoOpenOnIncoming", true)) root.summonHere()
    }
    onShowRequested: if (root.isLeader) root.summonHere()
    // A clicked link fills the dial field and opens the panel; the person
    // presses Enter. It never dials by itself -- a web page must not be able
    // to place a call. Every copy fills its own field, since the copy that
    // opens is the one on the focused monitor, not necessarily this one.
    //
    // The link picks the moment, so: at most one every few seconds, never
    // over something the person is typing, and the same quiet-keyboard guard
    // as an auto-open -- the panel takes the keyboard, and whatever they were
    // typing elsewhere, Enter included, must not land in a field holding
    // someone else's number.
    onPrefillRequested: function(target) {
      if (sip.callState !== "idle") return
      var now = Date.now()
      if (now - root.lastPrefillAt < root.prefillIntervalMs) return
      if (dialField.activeFocus && root.dialText.trim() !== "") return
      // Never over a number the person typed, in a field that is not even on
      // screen now (only what a link put there last may be replaced) ...
      if (root.dialText.trim() !== "" && root.dialText !== root.lastPrefill) return
      // ... nor over a contact form they have been editing. An untouched one
      // is closed, and a screen is left, so the filled field is what they see.
      if (root.contactOpen && root.contactDirty()) return
      root.contactOpen = false
      root.view = "main"
      root.lastPrefillAt = now
      root.lastPrefill = target
      root.dialText = target
      root.cursorActive = false
      root.typingGuardUntil = now + root.typingQuietMs
      if (root.isLeader) root.summonHere()
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.summonHere() }
    function close(): void { root.close() }
    function show(): void { root.summonHere() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggleHere() }
    function dial(uri: string): string { return root.ipcResult(sip.dial(uri)) }
    function answer(): string { return root.ipcResult(sip.answer()) }
    function hangup(): string { return root.ipcResult(sip.hangup()) }
    function mute(): string { return root.ipcResult(sip.toggleMute()) }
    function hold(): string { return root.ipcResult(sip.toggleHold()) }
    function dtmf(digits: string): string { return root.ipcResult(sip.sendDigits(digits)) }
    function transfer(uri: string): string { return root.ipcResult(sip.transfer(uri)) }
    function redial(): string { return root.ipcResult(sip.redial()) }
    function dnd(): string {
      var reason = sip.toggleDnd()
      return reason ? "refused: " + reason : (sip.dnd ? "on" : "off")
    }
    function status(): string {
      return sip.callState + " " + (sip.peer || "-") + " " + sip.registration
    }
  }

  function ipcResult(reason) {
    return reason ? "refused: " + reason : "ok"
  }

  // ------------------------------------------------------------- bar button

  // The call timer beside the icon, when asked for, on a horizontal bar.
  readonly property bool timerOnBar: sip.callState === "active" && !button.vertical
                                     && sip.boolSetting("showCallTimer", false)
  readonly property string callDuration: Model.durationText(sip.callStartedAt, clock.now)

  TextMetrics {
    id: timerMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    text: root.callDuration || "00:00"
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fixedWidth: root.timerOnBar ? slotSize + Math.ceil(timerMetrics.advanceWidth) + Style.space(4)
                                : (vertical ? -1 : slotSize)
    tooltipText: Model.barTooltip({
      daemonUp: sip.daemonUp, configured: sip.configured, registration: sip.registration,
      aor: sip.aor, lastError: sip.lastError, callState: sip.callState,
      peerName: sip.nameFor(sip.peer) || Model.peerShort(sip.peer),
      duration: root.callDuration, muted: sip.muted, onHold: sip.onHold, dnd: sip.dnd,
      unseenMissed: sip.unseenMissed, newVoicemail: sip.mwi.newCount
    })
    iconComponent: Component {
      Item {
        // Timer text to the right of the glyph; the glyph moves left by half
        // its width so the pair stays centred on the widened button.
        Text {
          textFormat: Text.PlainText
          visible: root.timerOnBar
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: glyph.right
          anchors.leftMargin: Style.space(4)
          text: root.callDuration
          color: root.barForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          id: glyph
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.horizontalCenterOffset: root.timerOnBar
            ? -Math.ceil((timerMetrics.advanceWidth + Style.space(4)) / 2) : 0
          text: Model.barGlyph(sip.callState, sip.dnd)
          color: sip.ringing ? (root.bar ? root.bar.urgent : Color.urgent)
                             : (sip.onCall || sip.ready ? root.barForeground
                                                        : Qt.darker(root.barForeground, 1.55))
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon

          // Only while ringing -- a permanently animated bar icon is noise.
          SequentialAnimation on opacity {
            running: sip.ringing
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 500; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutQuad }
          }
          onVisibleChanged: if (!sip.ringing) opacity = 1.0
        }

        // Missed calls since the panel was last opened. A dot, not a count:
        // at bar size a digit is noise, and the panel has the list.
        Rectangle {
          visible: sip.unseenMissed > 0 && !sip.onCall && !sip.ringing
                   && sip.boolSetting("missedCallBadge", true)
          width: Math.max(4, Math.round(Style.font.icon * 0.38))
          height: width
          radius: width / 2
          color: root.bar ? root.bar.urgent : Color.urgent
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: Math.round(parent.width * 0.12)
          anchors.topMargin: Math.round(parent.height * 0.14)
        }
      }
    }
    onPressed: function(buttonCode) {
      // A click meant to open the panel can land just as a call rings; it
      // must not answer or reject it. Inside the guard it only toggles.
      if (buttonCode !== Qt.LeftButton && root.guardKey()) { root.toggle(); return }
      if (buttonCode === Qt.MiddleButton && sip.callState === "incoming") sip.answer()
      else if (buttonCode === Qt.RightButton && sip.onCall) sip.hangup()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Freeze cursor navigation while a text field has the keyboard, so
      // typing an extension does not trigger shortcuts.
      blocked: root.fieldFocused

      onMoveRequested: function(dx, dy) {
        if (root.guardKey()) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        // Up from the first row goes back to the dial or search field it came from.
        if (dy < 0 && root.cursorIndex === 0 && (dialRow.visible || root.contactsShown)) {
          root.cursorActive = false
          if (dialRow.visible) dialField.forceActiveFocus()
          else contactsSearch.forceActiveFocus()
          return
        }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: {
        if (root.guardKey()) return
        if (root.cursorActive && root.actions.length > 0) {
          root.activate(root.actions[Math.min(root.cursorIndex, root.actions.length - 1)].id)
        }
      }
      // Escape goes back a step: out of a form, then out of a screen, and only
      // from the main one does it close the panel.
      onCloseRequested: {
        if (root.contactOpen) root.contactOpen = false
        else if (root.view !== "main") root.view = "main"
        else root.close()
      }
      onDeleteRequested: {
        if (root.guardKey()) return
        root.requestDelete()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.guardKey()) return
        var key = String(t || "").toLowerCase()
        if (root.contactsShown) { root.contactsKey(String(t || ""), key); return }
        if (key === "a" && sip.callState === "incoming") sip.answer()
        else if ((key === "d" || key === "r") && sip.callState === "incoming") sip.hangup()
        // h j k l and x never arrive here: PanelKeyCatcher takes them for
        // navigation and delete. Hence p for hold and n for the keypad.
        else if (key === "b" && sip.onCall) sip.hangup()
        else if (key === "m" && sip.onCall) sip.toggleMute()
        else if (key === "p" && sip.callState === "active") sip.toggleHold()
        else if (key === "n" && sip.callState === "active") root.keypadOpen = !root.keypadOpen
        else if (key === "t" && sip.callState === "active") root.transferOpen = true
        else if (sip.callState === "active" && Model.isKeypadKey(t)) sip.sendDigits(t)
        else if (key === "s" && sip.callState === "idle") root.setupOpen = !root.setupOpen
        else if (key === "q" && !sip.onCall && sip.callState !== "incoming") sip.toggleDnd()
        else if (key === "v" && sip.callState === "idle" && sip.voicemailTarget !== "") sip.dial(sip.voicemailTarget)
        else if (key === "o" && root.mainIdle) root.view = "contacts"
        else if (key === "y" && root.mainIdle && root.moreCalls) root.view = "history"
        else if (key === "n" && root.mainIdle) root.dialPadOpen = !root.dialPadOpen
        else if (key === "c" && root.cursorAction() && root.cursorAction().contactUri)
          root.openContact(root.cursorAction().contactUri)
        // Anything dialable typed while the cursor is on the rows goes back
        // into the dial field, as if it had never left.
        else if (dialRow.visible && /^[0-9+*#]$/.test(t)) {
          root.dialText = root.dialText + t
          root.cursorActive = false
          dialField.forceActiveFocus()
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- hero ----------
          PanelHero {
            id: hero
            width: parent.width
            title: "SIP"
            meta: Model.heroMeta(sip.snapshot)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: sip.ready || sip.onCall ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.barGlyph(sip.callState, sip.dnd)
                color: sip.ringing ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- error / last outcome ----------
          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: sip.lastError !== "" ? sip.lastError
                                       : (sip.callState === "idle" && sip.lastClosedReason !== ""
                                          ? "Last call: " + sip.lastClosedReason : "")
            color: sip.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------- contact form ----------
          // Modal, like the account form: while it is open there are no rows and
          // no dial field. It sits here, under the error line, so it is on
          // screen whichever row it was opened from.
          Column {
            id: contactForm
            visible: root.contactOpen && sip.callState === "idle"
            width: parent.width
            spacing: Style.space(6)
            Keys.onEscapePressed: root.contactOpen = false

            PanelSectionHeader {
              text: root.contactOriginal !== "" ? "EDIT CONTACT" : "NEW CONTACT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: contactNameField
              width: parent.width
              placeholderText: "Name"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              maximumLength: 128
              onTextEdited: root.contactError = ""
              onAccepted: if (!root.guardKey()) root.saveContact()
              Keys.onPressed: function(event) {
                if (Date.now() < root.typingGuardUntil) { root.guardKey(); event.accepted = true }
              }
              Keys.onEscapePressed: root.contactOpen = false
            }

            TextField {
              id: contactNumberField
              width: parent.width
              placeholderText: "Extension, number or sip:user@host"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              maximumLength: 256
              onTextEdited: root.contactError = ""
              onAccepted: if (!root.guardKey()) root.saveContact()
              Keys.onPressed: function(event) {
                if (Date.now() < root.typingGuardUntil) { root.guardKey(); event.accepted = true }
              }
              Keys.onEscapePressed: root.contactOpen = false
            }

            Text {
              textFormat: Text.PlainText
              visible: root.contactError !== ""
              width: parent.width
              text: root.contactError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: "Save"
                focusable: true
                onClicked: if (!root.guardKey()) root.saveContact()
              }

              Button {
                text: "Cancel"
                focusable: true
                onClicked: root.contactOpen = false
              }

              Button {
                text: root.armed === "form-delete" ? "Press again to delete" : "Delete"
                foreground: root.armed === "form-delete" ? root.urgent : root.foreground
                focusable: true
                visible: root.contactOriginal !== ""
                onClicked: if (!root.guardKey()) root.deleteOpenContact()
              }
            }
          }

          // ---------- live call ----------
          Column {
            id: callBlock
            visible: sip.onCall || sip.callState === "incoming"
            width: parent.width
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: Model.callTitle(sip.snapshot)
              color: sip.ringing ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: sip.nameFor(sip.peer) || Model.peerShort(sip.peer) || "unknown"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: {
                var full = Model.peerLabel(sip.peer)
                var big = sip.nameFor(sip.peer) || Model.peerShort(sip.peer)
                return full !== big ? full : ""
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: sip.callState === "active"
              text: Model.durationText(sip.callStartedAt, clock.now)
                    + (sip.codec !== "" ? " · " + sip.codec : "")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: sip.callState === "active" && sip.sentDigits !== ""
              text: "Sent: " + sip.sentDigits
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideLeft
            }
          }

          // ---------- transfer ----------
          RowLayout {
            id: transferRow
            visible: root.transferOpen && sip.callState === "active"
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: transferField
              Layout.fillWidth: true
              placeholderText: "Transfer to extension or sip:user@host"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onAccepted: root.doTransfer()
              Keys.onEscapePressed: root.transferOpen = false
              onVisibleChanged: {
                if (visible) Qt.callLater(forceActiveFocus)
                else text = ""
              }
            }

            PanelActionButton {
              iconText: "\uf064"
              tooltipText: "Transfer"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: transferField.text.trim() !== ""
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.doTransfer()
            }
          }

          // ---------- dial ----------
          RowLayout {
            id: dialRow
            visible: sip.daemonUp && sip.configured && !sip.onCall
                     && sip.callState !== "incoming" && !setupForm.visible
                     && !contactForm.visible && root.view === "main"
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: dialField
              Layout.fillWidth: true
              placeholderText: "Extension or sip:user@host"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: root.dialText
              enabled: !sip.busy

              onTextChanged: if (text !== root.dialText) root.dialText = text
              // The key catcher stands aside while a field has focus, so the
              // guard is applied here too: no typing, and above all no Enter,
              // until the keyboard has been quiet.
              onAccepted: if (!root.guardKey()) root.placeCall()
              Keys.onPressed: function(event) {
                if (Date.now() < root.typingGuardUntil) { root.guardKey(); event.accepted = true }
              }
              Keys.onDownPressed: {
                if (root.actions.length === 0) return
                root.cursorIndex = 0
                root.cursorActive = true
                keyCatcher.forceActiveFocus()
              }
              Keys.onEscapePressed: root.close()
              onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
            }

            PanelActionButton {
              // nf-md-dialpad (U+F061C), as in the call's own keypad row.
              iconText: "\udb81\ude1c"
              tooltipText: root.dialPadOpen ? "Hide keypad" : "Keypad"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: root.dialPadOpen
              Layout.alignment: Qt.AlignVCenter
              onClicked: {
                if (root.guardKey()) return
                root.dialPadOpen = !root.dialPadOpen
                dialField.forceActiveFocus()
              }
            }

            PanelActionButton {
              iconText: "\uf095"
              tooltipText: "Call"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.dialText.trim() !== "" && !sip.busy
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.placeCall()
            }
          }

          // ---------- dial keypad ----------
          // Each button adds its digit to what is typed and leaves the keyboard
          // in the dial field. It dials nothing: Enter or the Call button does.
          DigitPad {
            id: dialPad
            verb: "Type "
            visible: root.dialPadOpen && dialRow.visible
            anchors.horizontalCenter: parent.horizontalCenter
            onPressed: function(digit) {
              if (root.guardKey()) return
              root.dialText = root.dialText + digit
              dialField.forceActiveFocus()
            }
          }

          // ---------- contacts search ----------
          RowLayout {
            id: contactsSearchRow
            visible: root.contactsShown
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: contactsSearch
              Layout.fillWidth: true
              placeholderText: "Search contacts"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              maximumLength: 128
              text: root.contactQuery

              onTextChanged: if (text !== root.contactQuery) root.contactQuery = text
              // Guarded like the dial field: the catcher stands aside while a
              // field has focus, so nothing typed under a self-opened panel
              // may land here, Enter least of all.
              onAccepted: if (!root.guardKey()) root.intoRows()
              Keys.onPressed: function(event) {
                if (Date.now() < root.typingGuardUntil) { root.guardKey(); event.accepted = true }
              }
              Keys.onDownPressed: root.intoRows()
              Keys.onEscapePressed: root.view = "main"
              onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
            }
          }

          // ---------- contact suggestions ----------
          Column {
            id: suggestColumn
            visible: root.suggestActions.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.suggestActions
              ActionRow {
                required property var modelData
                width: suggestColumn.width
                action: modelData
              }
            }
          }

          // ---------- action rows ----------
          Column {
            id: actionColumn
            visible: root.primaryActions.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.primaryActions
              ActionRow {
                required property var modelData
                width: actionColumn.width
                action: modelData
              }
            }
          }

          // ---------- keypad ----------
          // Below the in-call rows, not above them: opened above, it pushed
          // Hang up out of view.
          DigitPad {
            id: keypad
            visible: root.keypadOpen && sip.callState === "active"
            anchors.horizontalCenter: parent.horizontalCenter
            onPressed: function(digit) { sip.sendDigits(digit) }
          }

          // ---------- call log ----------
          PanelSectionHeader {
            visible: root.historyActions.length > 0
            text: root.view === "contacts" ? "CONTACTS"
                  : (root.view === "history" ? "CALL HISTORY" : "RECENT CALLS")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            id: historyColumn
            visible: root.historyActions.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.historyActions
              ActionRow {
                required property var modelData
                width: historyColumn.width
                action: modelData
              }
            }
          }

          // After the list: the row that opens the whole call log, or the one
          // that clears it.
          Column {
            id: moreColumn
            visible: root.moreActions.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.moreActions
              ActionRow {
                required property var modelData
                width: moreColumn.width
                action: modelData
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.emptyText !== ""
            width: parent.width
            text: root.emptyText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------- account setup ----------
          PanelSeparator {
            visible: setupForm.visible
            foreground: root.foreground
          }

          Column {
            id: setupForm
            visible: (!sip.configured || root.setupOpen) && sip.callState === "idle"
            width: parent.width
            spacing: Style.space(8)
            // Whatever has the keyboard in the form -- a switch, a button, the
            // dropdown -- passes Escape up to here.
            Keys.onEscapePressed: root.setupOpen = false

            PanelSectionHeader {
              text: sip.configured ? "CHANGE ACCOUNT" : "SET UP ACCOUNT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Credentials are written to ~/.config/omarchy-sip/accounts (0600)."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            TextField {
              id: uriField
              width: parent.width
              placeholderText: "sip:1001@pbx.example.com"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextEdited: root.setupTouched = true
              Keys.onEscapePressed: root.setupOpen = false
            }

            TextField {
              id: authField
              width: parent.width
              placeholderText: "Auth username (optional)"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextEdited: root.setupTouched = true
              Keys.onEscapePressed: root.setupOpen = false
            }

            TextField {
              id: displayField
              width: parent.width
              placeholderText: "Display name (optional)"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextEdited: root.setupTouched = true
              Keys.onEscapePressed: root.setupOpen = false
            }

            TextField {
              id: passwordField
              width: parent.width
              placeholderText: sip.accountDetails && sip.accountDetails.hasPassword
                               ? "Password (blank keeps the current one)" : "Password"
              password: true
              onTextEdited: root.setupTouched = true
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onAccepted: if (!root.guardKey()) root.saveAccount()
              Keys.onEscapePressed: root.setupOpen = false
            }

            Dropdown {
              id: transportField
              width: parent.width
              label: "Transport"
              value: "udp"
              options: ["udp", "tcp", "tls"]
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(v) {
                if (root.guardKey()) return
                transportField.value = v
                root.setupTouched = true
              }
            }

            TextField {
              id: outboundField
              width: parent.width
              placeholderText: "Outbound proxy (optional)"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              maximumLength: 256
              onTextEdited: { root.setupTouched = true; root.outboundEdited = true }
              onAccepted: if (!root.guardKey()) root.saveAccount()
              Keys.onPressed: function(event) {
                if (Date.now() < root.typingGuardUntil) { root.guardKey(); event.accepted = true }
              }
              Keys.onEscapePressed: root.setupOpen = false
            }

            TextField {
              id: stunField
              width: parent.width
              placeholderText: "STUN server (optional)"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              maximumLength: 256
              onTextEdited: { root.setupTouched = true; root.stunEdited = true }
              onAccepted: if (!root.guardKey()) root.saveAccount()
              Keys.onPressed: function(event) {
                if (Date.now() < root.typingGuardUntil) { root.guardKey(); event.accepted = true }
              }
              Keys.onEscapePressed: root.setupOpen = false
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "A proxy looks like sip:proxy.example.com, a STUN server like stun.example.com:3478."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSectionHeader {
              text: "AUDIO CODECS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // A list somebody wrote by hand has things these switches cannot
            // show, so it is left alone -- and not sent back on save.
            Text {
              textFormat: Text.PlainText
              visible: root.codecsCustom
              width: parent.width
              text: "Custom codec list — edit ~/.config/omarchy-sip/accounts by hand"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              visible: !root.codecsCustom
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: Model.CODEC_CHOICES
                Toggle {
                  required property var modelData
                  width: parent.width
                  label: modelData.label
                  checked: root.codecsOn.indexOf(modelData.id) >= 0
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: {
                    if (root.guardKey()) return
                    root.codecsOn = Model.toggleCodec(root.codecsOn, modelData.id)
                    root.setupTouched = true
                    root.codecsEdited = true
                  }
                }
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: "Save"
                focusable: true
                enabled: uriField.text.trim() !== ""
                onClicked: if (!root.guardKey()) root.saveAccount()
              }

              Button {
                text: "Cancel"
                focusable: true
                visible: sip.configured
                onClicked: if (!root.guardKey()) root.setupOpen = false
              }
            }
          }
        }
      }
    }
  }

  function saveAccount() {
    // A save restarts the daemon, which would drop the call.
    if (sip.callState !== "idle") return
    var uri = Model.accountUri(uriField.text, authField.text)
    if (uri === "") return
    // Only what the person changed is sent beyond the basics: a proxy, STUN
    // server or codec list that was already there -- written by hand, say, in a
    // form this one cannot show, or not yet loaded into it when they typed --
    // is never sent back as blank. A field counts as changed when it was edited
    // and now differs from what it was filled from.
    var extra = {}
    if (outboundEdited && outboundField.text.trim() !== outboundStored) extra.outbound = outboundField.text.trim()
    if (stunEdited && stunField.text.trim() !== stunStored) extra.stun = stunField.text.trim()
    if (codecsEdited && !codecsCustom && Model.codecArg(codecsOn) !== codecsStored) extra.codecs = Model.codecArg(codecsOn)
    // A save already in flight refuses this one; keep the form (and the typed
    // password) on screen rather than silently dropping it.
    if (!sip.setAccount(uri, authField.text.trim(), displayField.text.trim(),
                        transportField.value, passwordField.text, extra))
      return
    // Never keep the password in a live QML property.
    passwordField.text = ""
    setupOpen = false
  }

  // Drives the in-call timer; stopped otherwise so an idle panel costs nothing.
  Timer {
    id: clock
    property double now: Date.now()
    interval: 1000
    running: sip.callState === "active" && (root.opened || root.timerOnBar || button.tooltipHovered)
    repeat: true
    onTriggered: now = Date.now()
    onRunningChanged: if (running) now = Date.now()
  }

  // The 3x4 telephone keypad, for the call's tones and for the dial field.
  component DigitPad: Grid {
    id: pad
    property string verb: "Send "
    signal pressed(string digit)
    columns: 3
    spacing: Style.space(6)

    Repeater {
      model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
      PanelActionButton {
        required property string modelData
        iconText: modelData
        tooltipText: pad.verb + modelData
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.heading
        size: Style.space(40)
        bordered: true
        onClicked: pad.pressed(modelData)
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property var action: null
    readonly property int rowIndex: action && action.index !== undefined ? action.index : -1

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    // Destructive actions and missed calls carry the urgent colour; everything
    // else is plain foreground.
    readonly property color tint: {
      if (!action) return root.foreground
      if (action.id === "reject" || action.id === "hangup" || action.urgent) return root.urgent
      return root.foreground
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      // Only a pointer that is really moving selects a row. Rows are rebuilt
      // under a resting pointer -- arming a delete does it -- and the enter
      // that follows is not the person pointing, so it must not move the
      // cursor (which would take the confirmation back).
      onPositionChanged: function(mouse) {
        if (!root.pointerGate.moved(actionRow, mouse)) return
        root.cursorActive = true
        root.cursorIndex = actionRow.rowIndex
      }
      // Right-click on a call or contact row saves (or renames) the contact.
      onClicked: function(mouse) {
        // A row under a resting pointer becomes Answer or Reject when a call
        // arrives; a click meant for the old row must not answer it.
        if (root.guardKey()) return
        if (mouse.button === Qt.RightButton) {
          if (actionRow.action.contactUri) root.openContact(actionRow.action.contactUri)
          return
        }
        root.activate(actionRow.action.id)
      }
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      // A fixed-width cell, so labels line up whatever the glyph's width.
      Text {
        textFormat: Text.PlainText
        text: actionRow.action ? actionRow.action.glyph : ""
        color: actionRow.tint
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        horizontalAlignment: Text.AlignHCenter
        Layout.preferredWidth: Math.ceil(Style.font.icon * 1.3)
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.action ? actionRow.action.label : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: text !== ""
          text: actionRow.action && actionRow.action.meta ? actionRow.action.meta : ""
          color: actionRow.action && actionRow.action.urgent ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
