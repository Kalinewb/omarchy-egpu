import QtQuick
import "common"
import "views"
import "common/Palette.js" as Palette
import "common/Notices.js" as NoticeRules

// eGPU's declared notch integration (plan-gui.md §7.2; notch:SURFACE-HOSTING.md
// §1-§5). manifest.json names this file as `entryPoints.surface` with
// `surface.contract: 1`. Omarchy ignores both; the notch loads this file once,
// and only when it is the bar and has accepted the integration. With no
// notch it is never loaded, and the standalone widget is all there is.
//
// It exists once however many monitors there are, so it owns the costs: the
// one StatusSource (a FileView on status.json, which the plugin's own Service
// keeps fresh), the one HealthSource and the one Engine pool. The panel the
// notch creates per screen (NotchPanel.qml) is handed all three.
//
// It does not: register IPC (the widget owns kalinewb.egpu), draw anything of
// its own outside the notch, or write under the plugins folder.
//
// Activities: plug-in and safe-to-unplug (and a yank, as a warning) become a
// transient claim (§7.5) under one key, so a new one replaces the last in
// place. The claim's answer is kept in `lastAnswer`; until G7 adds the
// Service's notifications nothing is suppressed on it, and warnings never are.
Item {
  id: root

  // The notch sets this. Until it does, there is no notch.
  property var surfaceHost: null

  // ------------------------------------------------------------- available
  //
  // Declined, honestly, on a machine with no Thunderbolt/USB4 domain and no
  // eGPU on the PCI bus (an OCuLink card still counts): there is nothing for
  // the notch to show (notch:SURFACE-HOSTING.md:132-134, 158). The status
  // says so in `bolt.domain`; `bolt.daemon` alone cannot, because boltd being
  // down reads the same. Before the first status, and from an engine that
  // predates the field, the answer is yes: a notch panel that says "no eGPU"
  // is honest, a notch that never offers the plugin is not.
  //
  // The notch reads this as the file finishes loading (and again only when
  // something else makes it look), so the status file is read synchronously
  // (StatusSource.blockLoading). docs/notch-requests.md asks for a re-read
  // on change.
  readonly property bool available: {
    var s = source.status
    if (!s || !s.bolt || s.bolt.domain !== false) return true
    return !!(s.pci && s.pci.present)
  }
  // Additive and not read by the notch today: it shows its own words for any
  // `available: false` ("Not available right now"). docs/notch-requests.md.
  readonly property string unavailableReason: root.available ? "" : "This machine has no Thunderbolt or USB4 port."

  // ------------------------------------------------------------ the panel
  property Component panel: Component {
    NotchPanel {
      status: root.status
      engine: engineRunner
      health: healthSource
      statusNote: root.statusNote
      noticeTitle: root.noticeTitle
    }
  }

  // ------------------------------------------------------------ activities
  //
  // One named row, a Glance showing the notice. The notch lists the names it
  // was given but draws its own glyph-and-title row for every claim today, so
  // this is declared for when it draws named views (docs/notch-requests.md).
  property var activityViews: ({ "egpu": root.noticeRow })
  property Component noticeRow: Component {
    Glance {
      status: root.status
      engine: engineRunner
      theme: root.theme
      active: true
      statusNote: root.statusNote
      noticeTitle: root.noticeTitle
    }
  }

  // ----------------------------------------------------------------- state

  // Where the plugin is checked out, from where this file was loaded.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url).replace(/\/+$/, "")
  }

  readonly property var status: source.status
  readonly property string statusNote: source.outcomeText
  readonly property string noticeTitle: notices.live ? notices.notice.title : ""
  // Sizes are the notch's own default unit (1) here: the row has no Style
  // scale to follow that the notch itself would not apply.
  readonly property var theme: Palette.fromHost(root.surfaceHost, {})

  // The answer to the last claim: "shown", "queued", "declined:<reason>", or
  // "no-host" with no notch. Never a reason to drop a warning.
  property string lastAnswer: ""
  property var lastClaim: null

  Engine {
    id: engineRunner
    pluginDir: root.pluginDir
  }

  StatusSource {
    id: source
    engine: engineRunner
    blockLoading: true
    onEvent: function (record) { notices.take(record) }
  }

  // Setup's rows, read only while a panel holds it open (each NotchPanel
  // calls hold() in open() and release() in close()).
  HealthSource {
    id: healthSource
    engine: engineRunner
    status: root.status
  }

  Notices {
    id: notices
    status: root.status
    canConnect: engineRunner.can("device connect")
    onRaised: function (notice) { root.claim(notice) }
  }

  function claim(notice) {
    var c = NoticeRules.claimFor(notice)
    root.lastClaim = c
    if (!root.surfaceHost || typeof root.surfaceHost.claim !== "function") { root.lastAnswer = "no-host"; return root.lastAnswer }
    root.lastAnswer = String(root.surfaceHost.claim(c))
    return root.lastAnswer
  }

  // Our notice goes when its time does, rather than waiting on the notch's
  // own clock, which starts only when it is shown.
  Connections {
    target: notices
    function onLiveChanged() {
      if (!notices.live && root.surfaceHost && typeof root.surfaceHost.release === "function")
        root.surfaceHost.release(NoticeRules.KEY)
    }
  }
}
