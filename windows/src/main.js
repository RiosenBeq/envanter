"use strict";
// NextGen Envanter — mağaza bilgisayarı uygulaması (Windows): web panelini kendi penceresinde açar.
// Tek pencere, tek örnek; envanter:// bağlantıları, çevrimdışı sayfası, kapatma uyarısı, Türkçe menü.

const path = require("node:path");
const { app, BrowserWindow, Menu, dialog, ipcMain, nativeTheme, screen, session, shell } = require("electron");
const config = require("./config");
const { deepLinkTarget, findDeepLink, isDeepLink, navigationPolicy } = require("./links");

const PROTOCOL = "envanter";
const APP_ID = "com.nextgen.envanter";
const PARTITION = "persist:envanter";
const PENDING_CHANNEL = "envanter:pending-count";
const OFFLINE_PAGE = path.join(__dirname, "offline.html");
const ICON = path.join(__dirname, "..", "build", "icon.png");

// Panelin pano (kod, satış raporu yapıştırma) ve bildirim izinleri; geri kalan her istek reddedilir
const ALLOWED_PERMISSIONS = new Set(["clipboard-sanitized-write", "clipboard-read", "notifications"]);

const PLATFORM = process.platform === "win32" ? "windows" : process.platform === "darwin" ? "mac" : "linux";
const PLATFORM_LABEL = { windows: "Windows", mac: "Mac", linux: "Linux" }[PLATFORM];

// Görüntüleme süreci çökmeleri: art arda çökmede sıkı yeniden yükleme döngüsü yerine artan bekleme
const CRASH_RETRY_FIRST = 15_000;
const CRASH_RETRY_MAX = 5 * 60_000;
const CRASH_STABLE_AFTER = 60_000;
const CRASH_TOO_FAST = 5_000;
// Süreç hiç başlatılamıyor (Windows'ta virüs programı ya da kod bütünlüğü engeli): her sayfa aynı sonuca varır
const CANNOT_START = new Set(["launch-failed", "integrity-failure"]);
const CRASH_REASONS = {
  crashed: "çöktü",
  oom: "bellek yetmedi",
  killed: "sonlandırıldı",
  "abnormal-exit": "beklenmedik biçimde kapandı",
  "launch-failed": "başlatılamadı",
  "integrity-failure": "Windows kod bütünlüğü denetimi engelledi",
  "memory-eviction": "bellek için kapatıldı",
};

const WINDOW_SAVE_DELAY = 500;

// Testler ve geliştirme için ayrı veri klasörü (tek örnek kilidi de bu klasöre bağlıdır)
if (process.env.ENVANTER_USER_DATA) app.setPath("userData", path.resolve(process.env.ENVANTER_USER_DATA));

// Tüm görüntüleme süreçleri korumalı alanda; --no-sandbox açıkça verilmişse (root olarak çalışan Linux testleri) dokunulmaz
if (!app.commandLine.hasSwitch("no-sandbox")) app.enableSandbox();

if (!app.requestSingleInstanceLock()) {
  // Uygulama zaten açık: argümanlar (envanter:// bağlantısı) açık olana "second-instance" ile gider
  app.quit();
} else {
  start();
}

function stripHash(url) {
  const i = typeof url === "string" ? url.indexOf("#") : -1;
  return i >= 0 ? url.slice(0, i) : url || "";
}

function clampCount(n) {
  return typeof n === "number" && Number.isFinite(n) ? Math.min(Math.max(Math.floor(n), 0), 1_000_000) : 0;
}

function start() {
  const version = app.getVersion();
  const statePath = path.join(app.getPath("userData"), config.WINDOW_FILE);
  const panelUrl = config.resolvePanelUrl({ userDataDir: app.getPath("userData") }).url;
  const panelHome = `${panelUrl}/`;

  /** @type {BrowserWindow | null} */
  let win = null;
  // Açılması istenen son panel adresi (bekleyen bağlantı kodu dahil); çevrimdışı sayfası buna döner
  let intendedUrl = deepLinkTarget(findDeepLink(process.argv), panelUrl) ?? panelHome;
  let pendingCount = 0;
  let closeConfirmed = false;
  let closingNow = false;
  // Kullanıcı sayfadan çıkmayı az önce onayladı; aynı tıklamanın envanter:// yüklemesi yeniden sormasın
  let leaveConfirmedAt = 0;
  let skipLeavePrompt = false;
  // Pencerede son istenen/açılan sayfa türü: "panel" ya da "offline" (çökme döngüsünü tanımak için)
  let shownKind = "panel";
  // Art arda çökme serisi
  let crashStreak = 0;
  let crashBackoffs = 0;
  let lastCrashAt = 0;
  let crashRetryTimer = null;
  let crashStableTimer = null;
  let crashNoticeShown = false;

  const isPanel = (url) => navigationPolicy(url, panelUrl) === "inside";
  const alive = () => !!win && !win.isDestroyed();
  // "Windows açılınca başlat" kaydı; geliştirmede kurulu uygulamanın kaydına dokunmaz
  const loginItem = config.loginItemOptions({
    appId: APP_ID,
    defaultApp: !!process.defaultApp,
    execPath: process.execPath,
    appPath: app.getAppPath(),
  });

  registerProtocol();
  if (PLATFORM === "windows") app.setAppUserModelId(APP_ID);

  app.on("second-instance", (_event, argv) => {
    focusWindow();
    const link = findDeepLink(argv);
    if (link) openDeepLink(link);
  });
  // macOS bağlantıları bu olayla gelir (Windows'ta argv)
  app.on("open-url", (event, url) => {
    event.preventDefault();
    openDeepLink(url);
  });
  app.on("window-all-closed", () => app.quit());
  app.on("web-contents-created", (_event, contents) => harden(contents));

  ipcMain.on(PENDING_CHANNEL, (event, n) => {
    if (!alive() || event.sender !== win.webContents) return;
    const frame = event.senderFrame;
    if (!frame || frame.parent || !isPanel(frame.url)) return;
    pendingCount = clampCount(n);
  });

  app.whenReady().then(() => {
    setupSession();
    Menu.setApplicationMenu(buildMenu());
    createWindow();
  });

  function registerProtocol() {
    // Linux'ta .desktop dosyası gerekir; geliştirme ortamının ayarlarını değiştirmemek için atlanır
    if (process.platform === "linux") return;
    if (process.defaultApp) {
      // "electron ." ile geliştirme: Windows bağlantıyı uygulama klasörüyle birlikte açsın
      if (process.argv.length >= 2) app.setAsDefaultProtocolClient(PROTOCOL, process.execPath, [path.resolve(process.argv[1])]);
    } else {
      app.setAsDefaultProtocolClient(PROTOCOL);
    }
  }

  function setupSession() {
    const ses = session.fromPartition(PARTITION);
    ses.setUserAgent(`${ses.getUserAgent()} NextGenEnvanter/${version} (${PLATFORM_LABEL})`);
    ses.setPermissionRequestHandler((_wc, permission, callback, details) => {
      callback(ALLOWED_PERMISSIONS.has(permission) && isPanel(details?.requestingUrl));
    });
    ses.setPermissionCheckHandler((_wc, permission, requestingOrigin) => {
      return ALLOWED_PERMISSIONS.has(permission) && isPanel(requestingOrigin);
    });
    ses.setDevicePermissionHandler(() => false);
  }

  /** Her web içeriği için: yeni pencere yok, webview yok, gezinme kurala bağlı. */
  function harden(contents) {
    contents.on("will-attach-webview", (event) => event.preventDefault());
    // Panel "yeni sekmede aç" dediğinde (ör. kurulum SQL dosyası, WhatsApp) varsayılan tarayıcı açılır; pencere çoğalmaz
    contents.setWindowOpenHandler(({ url }) => {
      if (isDeepLink(url)) openDeepLinkSoon(url);
      else if (navigationPolicy(url, panelUrl) !== "block") openExternal(url);
      return { action: "deny" };
    });
    contents.on("will-navigate", (event, legacyUrl) => {
      const url = event.url || legacyUrl;
      // Paneldeki "Bu bilgisayardaki uygulamada aç" (envanter://): zaten uygulamadayız, bağlan sayfası burada açılır
      if (isDeepLink(url)) {
        event.preventDefault();
        openDeepLinkSoon(url, Date.now() - leaveConfirmedAt < 2000);
        return;
      }
      const policy = navigationPolicy(url, panelUrl);
      if (policy === "inside") return;
      event.preventDefault();
      if (policy === "external") openExternal(url);
    });
  }

  function openExternal(url) {
    Promise.resolve()
      .then(() => shell.openExternal(url))
      .catch(() => {});
  }

  function windowState() {
    const primary = screen.getPrimaryDisplay();
    const areas = [primary, ...screen.getAllDisplays().filter((d) => d.id !== primary.id)].map((d) => d.workArea);
    return config.sanitizeWindowState(config.readJsonFile(statePath), areas);
  }

  // Simge durumundayken isMaximized güvenilmez; son bilinen durum kullanılır
  let wasMaximized = false;
  let saveTimer = null;

  function saveWindowState() {
    clearTimeout(saveTimer);
    saveTimer = null;
    if (!alive()) return;
    const b = win.getNormalBounds();
    const maximized = win.isMinimized() ? wasMaximized : win.isMaximized();
    config.writeJsonFile(statePath, { x: b.x, y: b.y, width: b.width, height: b.height, maximized });
  }

  /** Taşıma/boyutlandırmadan kısa süre sonra kaydeder: zorla kapatmada (ör. görev yöneticisi) da durum kalır. */
  function saveWindowStateSoon() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(saveWindowState, WINDOW_SAVE_DELAY);
  }

  function createWindow() {
    const state = windowState();
    const { WINDOW_DEFAULTS: d } = config;
    win = new BrowserWindow({
      ...("x" in state ? { x: state.x, y: state.y } : { center: true }),
      width: state.width,
      height: state.height,
      minWidth: d.minWidth,
      minHeight: d.minHeight,
      title: "NextGen Envanter",
      icon: ICON,
      show: false,
      backgroundColor: nativeTheme.shouldUseDarkColors ? "#0f0f11" : "#f5f5f3",
      webPreferences: {
        preload: path.join(__dirname, "preload.js"),
        contextIsolation: true,
        sandbox: true,
        nodeIntegration: false,
        nodeIntegrationInSubFrames: false,
        webviewTag: false,
        spellcheck: false,
        partition: PARTITION,
        additionalArguments: [`--envanter-version=${version}`],
      },
    });

    wasMaximized = state.maximized;
    let shown = false;
    const show = () => {
      if (shown || !alive()) return;
      shown = true;
      if (state.maximized) win.maximize();
      win.show();
    };
    win.once("ready-to-show", show);
    // Panel yavaş açılırsa boş ekran beklenmesin
    setTimeout(show, 4000);

    const wc = win.webContents;

    wc.on("did-navigate", (_event, url) => {
      pendingCount = 0;
      closingNow = false;
      skipLeavePrompt = false;
      shownKind = url.startsWith("file:") ? "offline" : "panel";
      if (isPanel(url)) intendedUrl = url;
    });
    wc.on("did-navigate-in-page", (_event, url, isMainFrame) => {
      if (isMainFrame && isPanel(url)) intendedUrl = url;
    });
    wc.on("did-fail-load", (_event, errorCode, _description, validatedURL, isMainFrame) => {
      if (isMainFrame) skipLeavePrompt = false;
      // -3: başka bir gezinme bunu kesti (hata değil)
      if (!isMainFrame || errorCode === -3 || !isPanel(validatedURL)) return;
      if (stripHash(validatedURL) !== stripHash(intendedUrl)) intendedUrl = validatedURL;
      setImmediate(() => showOffline(errorCode));
    });
    wc.on("did-finish-load", () => {
      clearTimeout(crashStableTimer);
      // Sayfa bir dakika çökmeden çalışırsa çökme serisi biter
      if (crashStreak > 0) crashStableTimer = setTimeout(resetCrashStreak, CRASH_STABLE_AFTER);
    });
    wc.on("render-process-gone", (_event, details) => {
      if (details.reason === "clean-exit" || !alive()) return;
      onRendererGone(details.reason, show);
    });

    // Sayfa beforeunload ile kapanmayı durdurursa Electron soru sormaz; soruyu burada biz sorarız
    wc.on("will-prevent-unload", (event) => {
      const kind = closingNow ? "close" : "leave";
      closingNow = false;
      if (kind === "leave" && skipLeavePrompt) {
        skipLeavePrompt = false;
        event.preventDefault();
        return;
      }
      if (closeConfirmed || confirmLeave(pendingCount, kind)) {
        if (kind === "close") closeConfirmed = true;
        else leaveConfirmedAt = Date.now();
        event.preventDefault();
        return;
      }
      // Vazgeç: gezinme iptal; çökme/çevrimdışı dönüşü vazgeçilen adrese değil açık sayfaya gitsin
      const current = wc.getURL();
      if (kind === "leave" && isPanel(current)) intendedUrl = current;
    });

    for (const name of ["resize", "move", "maximize", "unmaximize"]) win.on(name, saveWindowStateSoon);
    win.on("maximize", () => (wasMaximized = true));
    win.on("unmaximize", () => (wasMaximized = false));

    win.on("close", (event) => {
      saveWindowState();
      if (closeConfirmed) return;
      if (pendingCount > 0) {
        if (!confirmLeave(pendingCount, "close")) {
          event.preventDefault();
          return;
        }
        closeConfirmed = true;
        return;
      }
      closingNow = true;
    });
    // Windows kapanıyor ya da oturum kapanıyor: "close" gelmeden süreç sonlanır. Pencere durumu hemen yazılır;
    // soru sorup kapanmayı bekletme (değişiklikler zaten saklı)
    win.on("session-end", () => {
      closeConfirmed = true;
      saveWindowState();
    });
    win.on("closed", () => {
      clearTimeout(saveTimer);
      clearTimeout(crashRetryTimer);
      clearTimeout(crashStableTimer);
      win = null;
    });

    loadPanel(intendedUrl);
  }

  function focusWindow() {
    if (!alive()) return;
    if (win.isMinimized()) win.restore();
    win.show();
    win.focus();
  }

  function openDeepLink(link) {
    const target = deepLinkTarget(link, panelUrl);
    if (!target) return;
    if (!alive()) {
      intendedUrl = target;
      return;
    }
    focusWindow();
    loadPanel(target);
  }

  // Gezinme olayının içinden yeni yükleme başlatılmaz; olay bitince. leaveConfirmed: çıkma sorusu bu tıklama için
  // zaten soruldu ve onaylandı (bağlan sayfası yüklenirken ikinci kez sorulmaz)
  function openDeepLinkSoon(link, leaveConfirmed = false) {
    setImmediate(() => {
      skipLeavePrompt = leaveConfirmed;
      openDeepLink(link);
    });
  }

  function loadPanel(url) {
    if (!alive()) return;
    clearTimeout(crashRetryTimer);
    crashRetryTimer = null;
    intendedUrl = url;
    shownKind = "panel";
    const wc = win.webContents;
    const sameDocument = url.includes("#") && stripHash(wc.getURL()) === stripHash(url);
    const loading = wc.loadURL(url);
    loading
      .then(() => {
        // Yalnızca "#" sonrası değiştiyse sayfa yenilenmez; bağlantı kodunu okuyabilmesi için baştan yüklenir
        if (sameDocument && alive() && wc.getURL() === url) wc.reload();
      })
      .catch(() => {}); // hata did-fail-load ile işlenir
  }

  function showOffline(errorCode) {
    if (!alive()) return;
    shownKind = "offline";
    win.loadFile(OFFLINE_PAGE, { query: { hedef: intendedUrl, kod: String(errorCode) } }).catch(() => {});
  }

  function onOfflinePage() {
    return alive() && win.webContents.getURL().startsWith("file:");
  }

  function reloadPanel() {
    if (!alive()) return;
    if (onOfflinePage()) loadPanel(intendedUrl);
    else win.webContents.reload();
  }

  function resetCrashStreak() {
    crashStreak = 0;
    crashBackoffs = 0;
    crashNoticeShown = false;
  }

  /**
   * Görüntüleme süreci çöktü. İlk çökmede panel hemen yeniden yüklenir; ikincide çevrimdışı sayfası gösterilir
   * (kendi 15 sn'lik denemesiyle). Çevrimdışı sayfası da çöküyorsa, süreç hiç başlatılamıyorsa ya da çökmeler çok
   * sık geliyorsa artan aralıkla (15 sn, 30 sn, 1 dk … en çok 5 dk) yeniden denenir ve bir kez uyarı gösterilir.
   */
  function onRendererGone(reason, show) {
    const now = Date.now();
    clearTimeout(crashStableTimer);
    clearTimeout(crashRetryTimer);
    crashRetryTimer = null;
    crashStreak += 1;
    const tooFast = crashStreak >= 3 && now - lastCrashAt < CRASH_TOO_FAST;
    lastCrashAt = now;
    const offlineCrashed = shownKind === "offline" && crashStreak > 1;
    const stuck = CANNOT_START.has(reason) || offlineCrashed || tooFast || crashBackoffs > 0;
    if (!stuck && crashStreak === 1) return loadPanel(intendedUrl);
    if (!stuck) return showOffline(0);
    const delay = Math.min(CRASH_RETRY_FIRST * 2 ** crashBackoffs, CRASH_RETRY_MAX);
    crashBackoffs += 1;
    crashRetryTimer = setTimeout(() => loadPanel(intendedUrl), delay);
    show();
    showCrashNotice(reason, delay);
  }

  function showCrashNotice(reason, delay) {
    if (crashNoticeShown || !alive()) return;
    crashNoticeShown = true;
    const why = CRASH_REASONS[reason] ?? "kapandı";
    const options = {
      type: "error",
      title: "NextGen Envanter",
      message: "Panel bu bilgisayarda gösterilemiyor.",
      detail: [
        `Sayfayı gösteren işlem art arda kapandı (${why}).`,
        `${Math.round(delay / 1000)} saniye sonra kendiliğinden yeniden denenecek; aralık giderek uzar.`,
        "Sorun sürerse bilgisayarı yeniden başlatın; virüs programı NextGen Envanter'i engelliyorsa izin verin.",
      ].join("\n"),
      buttons: ["Yeniden dene", "Tamam"],
      defaultId: 0,
      cancelId: 1,
      noLink: true,
    };
    dialog
      .showMessageBox(win, options)
      .then(({ response }) => {
        if (response === 0 && alive()) loadPanel(intendedUrl);
      })
      .catch(() => {});
  }

  /** Gönderilmemiş değişiklik varken kapatma/ayrılma sorusu; true: devam et */
  function confirmLeave(count, kind) {
    const message = count > 0 ? `Gönderilmemiş ${count} değişiklik var.` : "Gönderilmemiş değişiklikler olabilir.";
    const question = kind === "close" ? "Yine de kapatılsın mı?" : "Sayfadan yine de çıkılsın mı?";
    const options = {
      type: "warning",
      title: "NextGen Envanter",
      message,
      detail: `Değişiklikler bu bilgisayarda saklanır ve internet gelince gönderilir. ${question}`,
      buttons: [kind === "close" ? "Kapat" : "Çık", "Vazgeç"],
      defaultId: 1,
      cancelId: 1,
      noLink: true,
    };
    const choice = alive() ? dialog.showMessageBoxSync(win, options) : dialog.showMessageBoxSync(options);
    return choice === 0;
  }

  function showAbout() {
    const options = {
      type: "info",
      title: "Sürüm bilgisi",
      message: `NextGen Envanter ${version}`,
      detail: [
        `Panel adresi: ${panelUrl}`,
        `Electron ${process.versions.electron} · Chromium ${process.versions.chrome}`,
      ].join("\n"),
      buttons: ["Tamam"],
      noLink: true,
    };
    if (alive()) dialog.showMessageBox(win, options).catch(() => {});
    else dialog.showMessageBox(options).catch(() => {});
  }

  function buildMenu() {
    const sep = { type: "separator" };
    const autoStart =
      PLATFORM === "linux"
        ? []
        : [
            sep,
            {
              label: `${PLATFORM_LABEL} açılınca başlat`,
              type: "checkbox",
              checked: config.loginItemEnabled(
                app.getLoginItemSettings(loginItem.path ? { path: loginItem.path, args: loginItem.args } : undefined),
                loginItem,
              ),
              click: (item) => app.setLoginItemSettings({ ...loginItem, openAtLogin: item.checked }),
            },
          ];
    const template = [
      ...(PLATFORM === "mac" ? [{ role: "appMenu" }] : []),
      {
        label: "Dosya",
        submenu: [
          { label: "Yenile", accelerator: "CmdOrCtrl+R", click: reloadPanel },
          { label: "Panel adresini tarayıcıda aç", click: () => openExternal(panelHome) },
          ...autoStart,
          sep,
          { label: "Çıkış", role: "quit" },
        ],
      },
      {
        label: "Düzen",
        submenu: [
          { label: "Geri al", role: "undo" },
          { label: "Yinele", role: "redo" },
          sep,
          { label: "Kes", role: "cut" },
          { label: "Kopyala", role: "copy" },
          { label: "Yapıştır", role: "paste" },
          sep,
          { label: "Tümünü seç", role: "selectAll" },
        ],
      },
      {
        label: "Görünüm",
        submenu: [
          { label: "Yakınlaştır", role: "zoomIn" },
          { label: "Uzaklaştır", role: "zoomOut" },
          { label: "Gerçek boyut", role: "resetZoom" },
          sep,
          { label: "Tam ekran", role: "togglefullscreen" },
          ...(app.isPackaged ? [] : [sep, { label: "Geliştirici araçları", role: "toggleDevTools" }]),
        ],
      },
      {
        label: "Yardım",
        submenu: [
          { label: "Bağlantı koduyla bağlan", click: () => (focusWindow(), loadPanel(`${panelUrl}/baglan`)) },
          sep,
          { label: "Sürüm bilgisi", click: showAbout },
        ],
      },
    ];
    return Menu.buildFromTemplate(template);
  }
}
