import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Phone messages, drawn by the shell so the reply box can sit inside the card.
//
// The server used to raise a desktop notification per message; its reply action
// could only open a separate window, which landed in the middle of the screen.
// Here the card is the notification: tap reply and a text field grows at the
// bottom of the same card, with send and cancel icons.
PanelWindow {
  id: root

  property var bar: null
  readonly property string runtime: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/omarchy-remote"
  readonly property string livePath: runtime + "/notifications-live.json"
  readonly property string tokenPath: runtime + "/token"

  readonly property color foreground: Commons.Color.popups.text
  readonly property color cardColor: Commons.Color.popups.background
  readonly property color muted: Qt.darker(foreground, 1.55)
  readonly property color accent: bar ? bar.urgent : Commons.Color.urgent

  property var items: []
  property string token: ""
  property string replyKey: ""
  property string replyText: ""
  // Address of the running service, read from its state file. The request is
  // made to 127.0.0.1 with curl's --connect-to, so the certificate's
  // IP:127.0.0.1 SAN verifies instead of disabling TLS checks.
  property string stateBind: ""
  property int statePort: 8765

  readonly property int cardWidth: Style.space(380)
  readonly property int gap: Style.space(12)
  readonly property int barTop: bar ? (bar.barSizeFor ? bar.barSizeFor(screen.name) : bar.barSize) : 0

  visible: items.length > 0
  color: "transparent"
  screen: bar && bar.QsWindow && bar.QsWindow.window ? bar.QsWindow.window.screen : null
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "omarchy-remote-messages"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: root.replyKey !== ""
    ? WlrKeyboardFocus.OnDemand
    : WlrKeyboardFocus.None

  anchors {
    top: true
    right: true
    bottom: true
  }
  implicitWidth: cardWidth + gap * 2
  mask: Region { item: deck }

  FileView {
    id: liveFile
    path: root.livePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.items = []
  }

  FileView {
    id: tokenFile
    path: root.tokenPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.token = String(text()).trim()
    onLoadFailed: root.token = ""
  }

  Component.onCompleted: {
    liveFile.reload()
    tokenFile.reload()
    stateFile.reload()
  }

  function parse(raw) {
    try {
      var parsed = JSON.parse(String(raw || "[]"))
      if (!Array.isArray(parsed)) { items = []; return }
      items = parsed.slice(-4).reverse()
      if (replyKey !== "" && !items.some(function (entry) { return entry.key === replyKey })) {
        replyKey = ""
        replyText = ""
      }
    } catch (error) {
      items = []
    }
  }

  function sendAction(kind, key, text) {
    if (!token || !key || !stateBind) return
    var payload = JSON.stringify({ kind: kind, key: key, text: text || "" })
    // Never put the token or the reply text in argv (visible in ps), and never
    // use curl -k: the certificate is pinned by the service's own cert.pem.
    actionProc.environment = {
      OR_TOKEN: token,
      OR_PAYLOAD: payload,
      OR_CERT: runtime + "/cert.pem",
      OR_BIND: stateBind,
      OR_PORT: String(statePort)
    }
    actionProc.command = ["bash", "-c",
      'exec curl -sS --max-time 8 --cacert "$OR_CERT" ' +
      '--connect-to "127.0.0.1:$OR_PORT:$OR_BIND:$OR_PORT" ' +
      '-H "X-Token: $OR_TOKEN" ' +
      '-H "Content-Type: application/json" ' +
      '--data-binary "$OR_PAYLOAD" ' +
      '"https://127.0.0.1:$OR_PORT/api/notify/action"']
    actionProc.running = true
  }

  FileView {
    id: stateFile
    path: root.runtime + "/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var state = JSON.parse(text() || "{}")
        root.stateBind = String(state.bind || "")
        root.statePort = Number(state.port || 8765)
      } catch (error) {
        root.stateBind = ""
        root.statePort = 8765
      }
    }
    onLoadFailed: {
      root.stateBind = ""
      root.statePort = 8765
    }
  }

  Process { id: actionProc }

  function beginReply(item) {
    // Reminders and other non-conversation cards have no reply action.
    if (!item || item.canReply !== true) return
    replyKey = String(item.key)
    replyText = ""
    Qt.callLater(function () { replyField.forceActiveFocus() })
  }

  function finishReply(send) {
    if (send && replyText.trim() !== "") {
      sendAction("reply", replyKey, replyText)
    }
    replyKey = ""
    replyText = ""
  }

  Item {
    id: deck
    width: root.cardWidth
    anchors {
      top: parent.top
      right: parent.right
      topMargin: root.barTop + root.gap
      rightMargin: root.gap
    }
    implicitHeight: column.implicitHeight

    Column {
      id: column
      width: parent.width
      spacing: Style.space(8)

      Repeater {
        model: root.items

        BorderSurface {
          id: card
          required property var modelData
          readonly property bool replying: root.replyKey === String(modelData.key)

          width: column.width
          height: body.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: root.cardColor
          borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(1)))

          Column {
            id: body
            anchors {
              left: parent.left
              right: parent.right
              top: parent.top
              margins: Style.space(12)
            }
            spacing: Style.space(6)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Column {
                width: parent.width - (actions.visible ? actions.width + Style.space(8) : 0)
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: String(card.modelData.title || card.modelData.app || "Phone")
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: String(card.modelData.text || "")
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                  width: parent.width
                }
              }

              Row {
                id: actions
                spacing: Style.space(6)
                // Only draw the actions this notification really supports.
                // A calendar reminder has neither, so it shows no buttons.
                visible: card.modelData.canReply === true || card.modelData.canRead === true

                Button {
                  iconText: "\uF0A9"   // reply arrow
                  foreground: root.foreground
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  tooltipText: "Reply"
                  visible: card.modelData.canReply === true
                  onClicked: root.beginReply(card.modelData)
                }

                Button {
                  iconText: "\uF012C"  // check
                  foreground: root.foreground
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  tooltipText: "Mark read"
                  visible: card.modelData.canRead === true
                  onClicked: root.sendAction("read", String(card.modelData.key), "")
                }
              }
            }

            // The reply box lives inside the card, right under the message.
            Column {
              width: parent.width
              visible: card.replying
              spacing: Style.space(6)

              TextField {
                id: replyField
                width: parent.width
                placeholderText: "Reply…"
                text: root.replyText
                foreground: root.foreground
                onTextChanged: root.replyText = text
                onAccepted: root.finishReply(true)
                Keys.onEscapePressed: root.finishReply(false)
              }

              Row {
                spacing: Style.space(6)
                anchors.right: parent.right

                Button {
                  iconText: "\uF0156"   // close
                  foreground: root.muted
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  tooltipText: "Cancel"
                  onClicked: root.finishReply(false)
                }

                Button {
                  iconText: "\uF048F"   // send
                  foreground: root.foreground
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  tooltipText: "Send"
                  enabled: root.replyText.trim() !== ""
                  opacity: enabled ? 1 : 0.35
                  onClicked: if (root.replyText.trim() !== "") root.finishReply(true)
                }
              }
            }
          }
        }
      }
    }
  }
}
