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

  // A text field owns the keyboard whenever one is on screen, so letter
  // shortcuts (a / d / b) only apply in the states that have no input.
  readonly property bool textInputActive: dialRow.visible || setupForm.visible || transferRow.visible

  // ...and when the last one leaves the screen, the keyboard has to come back.
  // Nothing else claims it: dialField takes focus when it appears and no one
  // hands it back when it goes, so a call arriving while the panel was already
  // open left Answer on screen with focus stranded on a hidden field -- no
  // 'a', no cursor keys, no Enter. Only reopening the panel recovered it.
  onTextInputActiveChanged: if (!textInputActive && opened) {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  readonly property var actions: buildActions()
  readonly property var primaryActions: actions.filter(function(a) { return a.section !== "history" })
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
    var rows = [{ id: "setup", label: "Account settings", glyph: "\uf013", section: "primary" }]
    // Recent calls are actions too: they share the cursor model, so Enter on a
    // row redials it and the keyboard behaves the same everywhere.
    for (var i = 0; i < sip.history.length && i < sip.historyLimit; i++) {
      var entry = sip.history[i]
      rows.push({
        id: "redial:" + Model.redialTarget(entry),
        label: Model.historyLabel(entry),
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
    default:
      if (id.indexOf("redial:") === 0 && id.length > 7) sip.dial(id.substring(7))
    }
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
    }
  }

  function doTransfer() {
    if (transferField.text.trim() === "") return
    if (sip.transfer(transferField.text) === "") transferOpen = false
  }

  function placeCall() {
    if (dialText.trim() === "") return
    sip.dial(dialText)
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
      // Freeze cursor navigation while a text field is on screen so typing an
      // extension does not trigger shortcuts.
      blocked: root.textInputActive

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
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
              text: Model.peerShort(sip.peer) || "unknown"
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
                var short = Model.peerShort(sip.peer)
                return full !== short ? full : ""
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
      onEntered: {
        root.cursorActive = true
        root.cursorIndex = actionRow.rowIndex
      }
      onClicked: root.activate(actionRow.action.id)
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
