import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Phone remote: starts the service and shows the pairing QR.
BarWidget {
  id: root
  moduleName: "yhcramo.remote"

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string runtime: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/omarchy-remote"
  readonly property string statePath: runtime + "/state.json"
  readonly property string presencePath: runtime + "/presence.json"
  // The service lives in the plugin directory, so a marketplace install is
  // self-contained. `omarchy plugin add` keeps the executable bit.
  readonly property string bin: Qt.resolvedUrl("omarchy-remote").toString().replace(/^file:\/\//, "")
  readonly property string mirrorBin: Qt.resolvedUrl("omarchy-mirror").toString().replace(/^file:\/\//, "")

  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color muted: Qt.darker(foreground, 1.5)
  readonly property color accent: bar ? bar.urgent : Commons.Color.urgent

  property var service: ({})
  property var presence: ({})
  property bool popupOpen: false
  property bool starting: false
  // Bumped only by the refresh button, so the QR image is re-read on demand.
  property int refreshTick: 0

  readonly property bool running: service.url !== undefined && service.url !== ""
  readonly property bool connected: {
    var last = Number(presence.lastClient || 0)
    return running && last > 0 && (Date.now() / 1000 - last) < 6
  }
  readonly property string qrPath: service.qr || ""
  readonly property string mutePath: runtime + "/notifications-muted"
  property bool notificationsMuted: false
  readonly property string iconText: connected ? String.fromCodePoint(0xF0119) : String.fromCodePoint(0xF0989)

  function refresh() {
    if (!stateReader.running) stateReader.running = true
    if (!presenceReader.running) presenceReader.running = true
    if (!muteReader.running) muteReader.running = true
  }

  // Explicit refresh: re-read the files and make the QR image reload. The poll
  // timer already re-reads the files, so this only adds the visible part.
  function forceRefresh() {
    refreshTick++
    refresh()
  }

  function startService() {
    if (running || starting) return
    starting = true
    starter.running = true
  }

  function stopService() {
    stopper.running = true
  }

  function sendClipboard() {
    if (!running) {
      startService()
      return
    }
    clipper.running = true
  }

  function toggleNotifications() {
    muteProc.running = true
  }

  function toggleMirror() {
    mirrorProc.running = true
  }

  function open() {
    popupOpen = true
    startService()
    refresh()
  }

  function close() {
    popupOpen = false
  }

  function toggle() {
    if (popupOpen) close()
    else open()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  ShellIpc {
    target: "yhcramo.remote"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function mirror(): void { root.toggleMirror() }
    function status(): string {
      return JSON.stringify({ running: root.running, connected: root.connected,
                              url: root.service.url || "", qr: root.qrPath })
    }
  }

  // The service writes state.json, presence.json and the mute marker; it deletes
  // them when it stops. FileView does not report a *deletion*, so the widget read
  // stale data and the stop/refresh buttons looked dead. A tiny reader process is
  // used instead: it always reflects what is on disk right now.
  Process {
    id: stateReader
    command: ["bash", "-c",
      "pid=$(cat \"$1/pid\" 2>/dev/null) || exit 0\n" +
      "[ -n \"$pid\" ] && kill -0 \"$pid\" 2>/dev/null || exit 0\n" +
      "cat \"$2\" 2>/dev/null || true",
      "omarchy-remote-state", root.runtime, root.statePath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") { root.service = ({}); return }
        try { root.service = JSON.parse(raw) } catch (e) { root.service = ({}) }
      }
    }
  }

  Process {
    id: presenceReader
    command: ["bash", "-c",
      "f=\"$1\"; if [ -r \"$f\" ]; then cat \"$f\"; fi",
      "omarchy-remote-presence", root.presencePath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") { root.presence = ({}); return }
        try { root.presence = JSON.parse(raw) } catch (e) { root.presence = ({}) }
      }
    }
  }

  Process {
    id: muteReader
    command: ["bash", "-c", "test -e \"$1\"", "omarchy-remote-mute", root.mutePath]
    onExited: function (code, status) { root.notificationsMuted = (code === 0) }
  }

  // The file watcher stays as a fast hint; the readers do the real work.
  FileView {
    id: stateWatch
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }

  FileView {
    id: presenceWatch
    path: root.presencePath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }

  FileView {
    id: muteWatch
    path: root.mutePath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }

  Process {
    id: starter
    command: [root.bin, "start"]
    onRunningChanged: if (!running) {
      root.starting = false
      settle.restart()
    }
  }

  Process {
    id: stopper
    command: [root.bin, "stop"]
    onRunningChanged: if (!running) settle.restart()
  }

  // Hands this computer's clipboard to the service, which the phone reads.
  Process {
    id: clipper
    command: ["bash", "-c",
      "mkdir -p \"$1\" && tmp=\"$1/.clip.$$\" && timeout 5 wl-paste --no-newline 2>/dev/null | head -c 1000000 > \"$tmp\" && mv -f \"$tmp\" \"$1/clipboard-out.txt\" || rm -f \"$tmp\"",
      "omarchy-remote-clip", root.runtime]
    onRunningChanged: if (!running) settle.restart()
  }

  // Flips the notification-mute marker the service reads.
  Process {
    id: muteProc
    command: ["bash", "-c",
      "f=\"$1/notifications-muted\"; if [ -e \"$f\" ]; then rm -f \"$f\"; else mkdir -p \"$1\" && printf 1 > \"$f\"; fi",
      "omarchy-remote-notify", root.runtime]
    onRunningChanged: if (!running) settle.restart()
  }

  // Mirrors the phone into a window and drives it with this keyboard and mouse.
  Process {
    id: mirrorProc
    command: [root.mirrorBin]
  }

  Timer {
    id: settle
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: poll
    interval: 1500
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconText
    tooltipText: root.connected ? "Phone connected" : "Phone remote"
    active: root.connected
    onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      width: parent.width
      spacing: Style.space(12)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: root.iconText
          color: root.connected ? root.accent : root.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          width: parent.width - Style.space(30)
          spacing: Style.space(2)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            textFormat: Text.PlainText
            text: "Phone remote"
            color: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: !root.running ? "Service stopped" : (root.connected ? "Connected" : "Waiting for pairing")
            color: root.connected ? root.accent : root.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      // QR
      Item {
        width: parent.width
        implicitHeight: Style.space(212)

        Rectangle {
          anchors.fill: parent
          color: "#ffffff"
          radius: Style.space(8)
          visible: root.qrPath !== ""
        }

        Image {
          id: qrImage
          anchors.centerIn: parent
          width: Style.space(196)
          height: Style.space(196)
          source: root.qrPath === "" ? "" : "file://" + root.qrPath + "?v=" + (root.service.started || 0) + "-" + root.refreshTick
          fillMode: Image.PreserveAspectFit
          smooth: false
          cache: false
          visible: root.qrPath !== ""
        }

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.running ? "Preparing QR…" : "Starting service…"
          color: root.muted
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          visible: !root.qrPath
        }
      }

      Text {
        textFormat: Text.PlainText
        text: "Scan the QR with your phone camera. Both devices must be on the same Wi-Fi."
        color: root.muted
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }

      // Kept in the layout when the service stops, so the action row does not
      // jump up under the pointer between a stop and the next start.
      Text {
        textFormat: Text.PlainText
        text: root.running ? (root.service.url || "") : " "
        color: root.muted
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
        width: parent.width
        opacity: root.running ? 1 : 0
      }

      Text {
        textFormat: Text.PlainText
        text: {
          var fp = String(root.service.fingerprint || "")
          if (fp.length < 20) return " "
          return "Fingerprint: " + fp.substring(0, 11) + "…" + fp.slice(-8)
        }
        color: root.muted
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
        opacity: root.running ? 1 : 0
      }

      Item {
        id: actions
        width: parent.width
        implicitHeight: Style.space(48)

        Row {
          id: actionsRow
          anchors.centerIn: parent
          spacing: Style.space(10)
          layoutDirection: Qt.LeftToRight

          GlassIconButton {
            iconSource: Qt.resolvedUrl(root.running ? "icons/stop.svg" : "icons/play.svg")
            tooltip: root.running ? "Stop service" : "Start service"
            onClicked: root.running ? root.stopService() : root.startService()
          }

          GlassIconButton {
            iconSource: Qt.resolvedUrl("icons/refresh.svg")
            tooltip: "Refresh"
            onClicked: root.forceRefresh()
          }

          GlassIconButton {
            iconSource: Qt.resolvedUrl("icons/clipboard.svg")
            tooltip: "Send this computer's clipboard to the phone"
            onClicked: root.sendClipboard()
          }

          GlassIconButton {
            iconSource: Qt.resolvedUrl("icons/mirror.svg")
            tooltip: "Mirror the phone and control it from here"
            onClicked: root.toggleMirror()
          }

          GlassIconButton {
            iconSource: Qt.resolvedUrl(root.notificationsMuted ? "icons/bell-off.svg" : "icons/bell.svg")
            tooltip: root.notificationsMuted ? "Phone notifications are off — click to enable"
                                      : "Phone notifications are on — click to silence"
            active: root.notificationsMuted
            onClicked: root.toggleNotifications()
          }
        }
      }
    }
  }

  // Phone messages, with the reply box inside the card. Lives beside the bar so
  // it can anchor to the top-right corner of the same screen.
  NotifyOverlay {
    id: overlay
    bar: root.bar
  }

  // A glass capsule holding one icon. No label: the icon is the whole control.
  component GlassIconButton: Item {
    id: glass
    property string iconSource: ""
    property string tooltip: ""
    property bool active: false
    signal clicked()

    implicitWidth: Style.space(48)
    implicitHeight: Style.space(48)

    Rectangle {
      id: surface
      anchors.fill: parent
      radius: height * 0.22
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                     glass.active ? 0.20 : (pointer.containsMouse ? 0.14 : 0.07))
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, pointer.containsMouse ? 0.22 : 0.12)

      Behavior on color {
        ColorAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic }
      }
      Behavior on border.color {
        ColorAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic }
      }
    }

    // Specular highlight, the top half of the glass.
    Rectangle {
      anchors.fill: parent
      radius: height * 0.22
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.10) }
        GradientStop { position: 0.60; color: Qt.rgba(1, 1, 1, 0.00) }
      }
    }

    // Tint the white SVG to the bar foreground with a layer effect, the same
    // way Omarchy's own notification thumbnails do. A standalone MultiEffect
    // item is not supported by this Quickshell build.
    Image {
      id: glyph
      anchors.centerIn: parent
      width: Style.space(20)
      height: Style.space(20)
      source: glass.iconSource
      sourceSize.width: 64
      sourceSize.height: 64
      fillMode: Image.PreserveAspectFit
      smooth: true

      layer.enabled: glyph.status === Image.Ready
      layer.effect: MultiEffect {
        colorization: 1.0
        colorizationColor: root.foreground
      }
    }

    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: glass.clicked()
      onEntered: if (root.bar) root.bar.showTooltip(glass, glass.tooltip)
      onExited: if (root.bar) root.bar.hideTooltip(glass)
    }
  }
}
