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
  // The address being saved as a contact, or "" when the form is closed.
  property string contactUri: ""

  readonly property var suggestions: dialRow.visible
    ? Model.matchContacts(dialText, sip.contacts, 5) : []

  // Whether any text field on screen is on screen at all (for handing the
  // keyboard back when the last one goes), and whether one has the keyboard
  // now (for keeping navigation and shortcuts out of the way of typing).
  // They differ after Down from the dial field: it stays on screen while the
  // cursor walks the rows under it.
  readonly property bool textInputActive: dialRow.visible || setupForm.visible
                                          || transferRow.visible || contactRow.visible
  readonly property bool fieldFocused: dialField.activeFocus || transferField.activeFocus
                                       || contactField.activeFocus || uriField.activeFocus
                                       || authField.activeFocus || displayField.activeFocus
                                       || passwordField.activeFocus || transportField.popupOpen

  // ...and when the last one leaves the screen, the keyboard has to come back.
  // Nothing else claims it: dialField takes focus when it appears and no one
  // hands it back when it goes, so a call arriving while the panel was already
  // open left Answer on screen with focus stranded on a hidden field -- no
  // 'a', no cursor keys, no Enter. Only reopening the panel recovered it.
  onTextInputActiveChanged: if (!textInputActive && opened) {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // The contact form closing strands focus on a hidden field just as the
  // others do, but the dial field may still be on screen to take it.
  onContactUriChanged: if (contactUri === "" && opened) {
    Qt.callLater(function() {
      if (dialField.visible) dialField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  readonly property var actions: buildActions()
  readonly property var suggestActions: actions.filter(function(a) { return a.section === "suggest" })
  readonly property var primaryActions: actions.filter(function(a) { return a.section === "primary" })
  readonly property var historyActions: actions.filter(function(a) { return a.section === "history" })

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
    if (setupForm.visible) return []
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
    var rows = []
    // Contacts matching what is typed, first, right under the field.
    for (var k = 0; k < suggestions.length; k++) {
      rows.push({ id: "call:" + suggestions[k].uri, label: suggestions[k].name || Model.peerShort(suggestions[k].uri),
                  meta: Model.peerLabel(suggestions[k].uri), glyph: "\uf095",
                  contactUri: suggestions[k].uri, section: "suggest" })
    }
    if (sip.voicemailTarget !== "") {
      rows.push({ id: "voicemail", label: "Voicemail", glyph: "\uf0e0", hint: "v",
                  meta: sip.mwi.newCount > 0 ? sip.mwi.newCount + " new" : "",
                  urgent: sip.mwi.newCount > 0, section: "primary" })
    }
    rows.push({ id: "setup", label: "Account settings", glyph: "\uf013", section: "primary" })
    // Recent calls are actions too: they share the cursor model, so Enter on a
    // row redials it and the keyboard behaves the same everywhere.
    for (var i = 0; i < sip.history.length && i < sip.historyLimit; i++) {
      var entry = sip.history[i]
      rows.push({
        id: "redial:" + Model.redialTarget(entry),
        label: Model.historyLabel(entry, sip.contacts),
        contactUri: Model.redialTarget(entry),
        glyph: Model.historyGlyph(entry),
        meta: Model.historyMeta(entry, clock.now),
        urgent: Model.historyIsMissed(entry),
        section: "history"
      })
    }
    return rows
  }

  function activate(id) {
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
    default:
      if (id.indexOf("redial:") === 0 && id.length > 7) sip.dial(id.substring(7))
      else if (id.indexOf("call:") === 0 && id.length > 5) { dialText = ""; sip.dial(id.substring(5)) }
    }
  }

  // "Save as contact" for a row's address; an existing contact is renamed,
  // and saving an empty name removes it.
  function openContact(uri) {
    if (!uri) return
    contactUri = uri
    contactField.text = Model.contactName(uri, sip.contacts)
    Qt.callLater(function() { contactField.forceActiveFocus(); contactField.selectAll() })
  }

  function saveContact() {
    if (contactUri === "") return
    if (sip.saveContact(contactUri, contactField.text)) contactUri = ""
  }

  function cursorAction() {
    if (!cursorActive || actions.length === 0) return null
    return actions[Math.min(cursorIndex, actions.length - 1)]
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
    passwordField.text = ""
  }

  onSetupOpenChanged: if (setupOpen) {
    setupTouched = false
    fillSetupForm()
    sip.loadAccount()
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
      if (sip.callState !== "idle") root.contactUri = ""
    }
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

    // Ringing is the one thing worth interrupting for: surface the panel so
    // Answer is one click away rather than buried behind the bar icon.
    onIncomingCall: function(peerUri) {
      if (root.isLeader && sip.boolSetting("autoOpenOnIncoming", true)) root.summonHere()
    }
    onShowRequested: if (root.isLeader) root.summonHere()
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
    function status(): string {
      return sip.callState + " " + (sip.peer || "-") + " " + sip.registration
    }
  }

  function ipcResult(reason) {
    return reason ? "refused: " + reason : "ok"
  }

  // ------------------------------------------------------------- bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: Model.barGlyph(sip.callState)
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Freeze cursor navigation while a text field has the keyboard, so
      // typing an extension does not trigger shortcuts.
      blocked: root.fieldFocused

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        // Up from the first row goes back to the dial field it came from.
        if (dy < 0 && root.cursorIndex === 0 && dialRow.visible) {
          root.cursorActive = false
          dialField.forceActiveFocus()
          return
        }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: {
        if (root.cursorActive && root.actions.length > 0) {
          root.activate(root.actions[Math.min(root.cursorIndex, root.actions.length - 1)].id)
        }
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t || "").toLowerCase()
        if (key === "a" && sip.callState === "incoming") sip.answer()
        else if ((key === "d" || key === "r") && sip.callState === "incoming") sip.hangup()
        // h j k l and x never arrive here: PanelKeyCatcher takes them for
        // navigation and delete. Hence p for hold and n for the keypad.
        else if (key === "b" && sip.onCall) sip.hangup()
        else if (key === "m" && sip.onCall) sip.toggleMute()
        else if (key === "p" && sip.callState === "active") sip.toggleHold()
        else if (key === "n" && sip.callState === "active") root.keypadOpen = !root.keypadOpen
        else if (key === "t" && sip.callState === "active") root.transferOpen = true
        else if (sip.callState === "active" && Model.validDigits(t)) sip.sendDigits(t)
        else if (key === "s") root.setupOpen = !root.setupOpen
        else if (key === "v" && sip.callState === "idle" && sip.voicemailTarget !== "") sip.dial(sip.voicemailTarget)
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
                text: Model.barGlyph(sip.callState)
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
              text: Model.contactName(sip.peer, sip.contacts) || Model.peerShort(sip.peer) || "unknown"
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
                var big = Model.contactName(sip.peer, sip.contacts) || Model.peerShort(sip.peer)
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

          // ---------- keypad ----------
          Grid {
            id: keypad
            visible: root.keypadOpen && sip.callState === "active"
            columns: 3
            spacing: Style.space(6)
            anchors.horizontalCenter: parent.horizontalCenter

            Repeater {
              model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
              PanelActionButton {
                required property string modelData
                iconText: modelData
                tooltipText: "Send " + modelData
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.heading
                size: Style.space(40)
                bordered: true
                onClicked: sip.sendDigits(modelData)
              }
            }
          }

          // ---------- dial ----------
          RowLayout {
            id: dialRow
            visible: sip.daemonUp && sip.configured && !sip.onCall
                     && sip.callState !== "incoming" && !setupForm.visible
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
              onAccepted: root.placeCall()
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
              iconText: "\uf095"
              tooltipText: "Call"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.dialText.trim() !== "" && !sip.busy
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.placeCall()
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

          // ---------- call log ----------
          PanelSectionHeader {
            visible: root.historyActions.length > 0
            text: "RECENT CALLS"
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

          // ---------- save as contact ----------
          Column {
            id: contactRow
            visible: root.contactUri !== "" && sip.callState === "idle"
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Save " + Model.peerLabel(root.contactUri) + " as"
                    + (Model.contactName(root.contactUri, sip.contacts) !== "" ? " (empty removes it)" : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: contactField
                Layout.fillWidth: true
                placeholderText: "Name"
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                maximumLength: 128
                onAccepted: root.saveContact()
                Keys.onEscapePressed: root.contactUri = ""
              }

              PanelActionButton {
                iconText: "\uf234"
                tooltipText: "Save contact"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.saveContact()
              }
            }
          }

          // ---------- account setup ----------
          PanelSeparator {
            visible: setupForm.visible
            foreground: root.foreground
          }

          Column {
            id: setupForm
            visible: !sip.configured || root.setupOpen
            width: parent.width
            spacing: Style.space(8)

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
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onAccepted: root.saveAccount()
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
              onChanged: function(v) { transportField.value = v; root.setupTouched = true }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: "Save"
                enabled: uriField.text.trim() !== ""
                onClicked: root.saveAccount()
              }

              Button {
                text: "Cancel"
                visible: sip.configured
                onClicked: root.setupOpen = false
              }
            }
          }
        }
      }
    }
  }

  function saveAccount() {
    var uri = Model.accountUri(uriField.text, authField.text)
    if (uri === "") return
    // A save already in flight refuses this one; keep the form (and the typed
    // password) on screen rather than silently dropping it.
    if (!sip.setAccount(uri, authField.text.trim(), displayField.text.trim(),
                        transportField.value, passwordField.text))
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
    running: root.opened && sip.callState === "active"
    repeat: true
    onTriggered: now = Date.now()
    onRunningChanged: if (running) now = Date.now()
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
      onEntered: {
        root.cursorActive = true
        root.cursorIndex = actionRow.rowIndex
      }
      // Right-click on a call or contact row saves (or renames) the contact.
      onClicked: function(mouse) {
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

      Text {
        textFormat: Text.PlainText
        text: actionRow.action ? actionRow.action.glyph : ""
        color: actionRow.tint
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
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
