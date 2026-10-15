// Electron duman testi: uygulamayı sahte bir panelle gerçekten açar ve davranışları uçtan uca dener.
// Çalıştırma (Linux): xvfb-run -a node test/smoke.mjs    — Chromium indirmez; Playwright'ın _electron sürücüsü yeter.
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const require = createRequire(import.meta.url);
const { _electron } = require("playwright");
const electronPath = require("electron");

const appDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const pkg = JSON.parse(fs.readFileSync(path.join(appDir, "package.json"), "utf8"));
// root olarak (konteyner) Chromium korumalı alanı açılamaz
const sandboxArgs = process.getuid?.() === 0 || process.env.ELECTRON_NO_SANDBOX === "1" ? ["--no-sandbox"] : [];
const userData = fs.mkdtempSync(path.join(os.tmpdir(), "envanter-smoke-"));

const HOME_PAGE = `<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Sahte panel</title></head><body>
<h1 id="sayfa">ana</h1>
<a id="dis" href="https://example.com/disari">dış bağlantı</a>
<a id="yeni" href="https://wa.me/905551112233" target="_blank">WhatsApp</a>
<a id="dosya" href="file:///etc/hostname">dosya</a>
<a id="http" href="#" onclick="window.open('http://example.org/engelli'); return false">http</a>
<a id="uygulama" href="envanter://baglan?kod=7kq2-m9xp-4tra-hw3d&amp;sunucu=https%3A%2F%2Fabc.supabase.co&amp;anahtar=x">Bu bilgisayardaki uygulamada aç</a>
<a id="uygulama-yeni" href="envanter://baglan?kod=ZZ23-YX98-WVUT-7654" target="_blank">yeni sekmede</a>
</body></html>`;

const BAGLAN_PAGE = `<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>Bağlan</title></head><body>
<h1 id="sayfa">baglan</h1><p id="kod"></p><p id="yukleme"></p>
<script>
document.getElementById("kod").textContent = location.hash;
document.getElementById("yukleme").textContent = String(performance.timeOrigin);
</script></body></html>`;

let server = null;
let port = 0;
let base = "";

function startServer() {
  const s = http.createServer((req, res) => {
    const { pathname } = new URL(req.url, "http://yerel");
    const body = pathname === "/" ? HOME_PAGE : pathname === "/baglan" ? BAGLAN_PAGE : null;
    if (body === null) {
      res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
      res.end("yok");
      return;
    }
    res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    res.end(body);
  });
  return new Promise((resolve, reject) => {
    s.once("error", reject);
    s.listen(port, "127.0.0.1", () => {
      server = s;
      port = s.address().port;
      base = `http://127.0.0.1:${port}`;
      resolve();
    });
  });
}

async function stopServer() {
  if (!server) return;
  const s = server;
  server = null;
  s.closeAllConnections();
  await new Promise((resolve) => s.close(() => resolve()));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** p, ms içinde sonuçlanmazsa hata (yanıt vermeyen bir çağrı testi takmasın) */
function withTimeout(p, ms, what = "yanıt") {
  let timer;
  return Promise.race([
    p,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${what} ${ms} ms içinde gelmedi`)), ms);
    }),
  ]).finally(() => clearTimeout(timer));
}

async function waitFor(fn, { timeout = 10_000, interval = 100, what = "koşul" } = {}) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    try {
      last = await withTimeout(Promise.resolve().then(fn), Math.max(end - Date.now(), 1));
      if (last) return last;
    } catch (e) {
      last = e;
    }
    await sleep(interval);
  }
  throw new Error(`zaman aşımı: ${what} (son değer: ${last instanceof Error ? last.message : JSON.stringify(last)})`);
}

const results = [];
async function check(name, fn) {
  const started = Date.now();
  try {
    await fn();
    results.push({ name, ok: true });
    console.log(`  ok    ${name} (${Date.now() - started} ms)`);
  } catch (e) {
    results.push({ name, ok: false });
    console.log(`  HATA  ${name}\n        ${String(e?.stack || e).split("\n").slice(0, 12).join("\n        ")}`);
  }
}

const processes = new WeakMap();

async function launch(extraArgs = [], { panelEnv = true } = {}) {
  const env = { ...process.env, ENVANTER_USER_DATA: userData };
  if (panelEnv) env.ENVANTER_PANEL_URL = base;
  else delete env.ENVANTER_PANEL_URL;
  const app = await _electron.launch({ executablePath: electronPath, args: [...sandboxArgs, appDir, ...extraArgs], env, timeout: 30_000 });
  // kapandıktan sonra app.process() kullanılamaz; süreç baştan alınır
  processes.set(app, app.process());
  const stdout = [];
  app.process().stdout?.on("data", (d) => stdout.push(String(d)));
  const win = await app.firstWindow();
  // beforeunload soruları Electron'da will-prevent-unload'a gider; Playwright kendisi yanıtlamaya kalkmasın
  win.on("dialog", () => {});
  return { app, win, stdout };
}

/** Uygulamayı kapatır; pencere kapanmayı reddederse (ör. kapatma uyarısı bozulduysa) test takılmaz, süreç öldürülür. */
async function closeApp(app) {
  const proc = processes.get(app);
  const exited = () => proc.exitCode !== null || proc.signalCode !== null;
  if (exited()) return;
  const gone = new Promise((resolve) => proc.once("exit", resolve));
  await Promise.race([app.close().catch(() => {}), gone, sleep(10_000)]);
  if (exited()) return;
  console.log("  (uygulama 10 sn'de kapanmadı; süreç sonlandırılıyor)");
  proc.kill("SIGKILL");
  await Promise.race([gone, sleep(5_000)]);
}

/** Uygulama açıkken ikinci bir örneği bağlantıyla başlatır (Windows'un bağlantı tıklamasında yaptığı gibi). */
function runSecondInstance(link) {
  return new Promise((resolve, reject) => {
    const child = spawn(electronPath, [...sandboxArgs, appDir, link], {
      env: { ...process.env, ENVANTER_USER_DATA: userData, ENVANTER_PANEL_URL: base },
      stdio: "ignore",
    });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("ikinci örnek kapanmadı"));
    }, 20_000);
    child.once("error", reject);
    child.once("exit", (code) => {
      clearTimeout(timer);
      resolve(code);
    });
  });
}

// Engellenen gezinmeden sonra Playwright'ın tıklaması gezinmenin bitmesini bekleyip takılır; tıklama sayfada yapılır
const clickInPage = (win, id) => win.evaluate((i) => document.getElementById(i).click(), id);

const mainUrl = (app) => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0]?.webContents.getURL() ?? null);
// Çökme denetimlerinde Playwright sayfası çökmüş sayılabilir; sayfa içeriği ana süreçten okunur
const pageText = (app, id) =>
  app.evaluate(({ BrowserWindow }, i) => {
    const wc = BrowserWindow.getAllWindows()[0]?.webContents;
    if (!wc || wc.isCrashed() || wc.isLoading()) return null;
    const js = wc.executeJavaScript(`document.getElementById(${JSON.stringify(i)})?.textContent ?? null`).catch(() => null);
    return Promise.race([js, new Promise((r) => setTimeout(() => r(null), 1000))]);
  }, id);
const readJson = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
};
const windowCount = (app) => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length);
const countLines = (stdout, prefix) => stdout.join("").split("\n").filter((l) => l.startsWith(prefix)).length;
const countQuestions = (stdout) => countLines(stdout, "SORU:");

/** Yerel diyalogları kaydedip seçilen cevabı döndüren sahte showMessageBoxSync. */
async function stubDialog(app, answer) {
  await app.evaluate(({ dialog }, a) => {
    globalThis.__cevap = a;
    globalThis.__sorular = globalThis.__sorular ?? [];
    dialog.showMessageBoxSync = (...args) => {
      const o = args.length > 1 ? args[1] : args[0];
      const q = { message: o.message, detail: o.detail, buttons: o.buttons };
      globalThis.__sorular.push(q);
      console.log(`SORU:${JSON.stringify(q)}`);
      return globalThis.__cevap;
    };
  }, answer);
}

async function main() {
  await startServer();
  console.log(`Sahte panel: ${base} · Electron ${require("electron/package.json").version} · veri: ${userData}`);

  // ---------------------------------------------------------------- 1. açılış
  const first = await launch();
  const { app, win } = first;
  try {
    await check("pencere açılır ve paneli yükler", async () => {
      await waitFor(async () => (await mainUrl(app)) === `${base}/`, { what: "ana sayfa" });
      await win.waitForSelector("#sayfa");
      assert.equal(await win.textContent("#sayfa"), "ana");
      await waitFor(() => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isVisible()), { what: "pencere görünür" });
    });

    await check("pencere ayarları güvenli (contextIsolation, sandbox, nodeIntegration kapalı)", async () => {
      const info = await app.evaluate(({ BrowserWindow, screen }) => {
        const w = BrowserWindow.getAllWindows()[0];
        const p = w.webContents.getLastWebPreferences();
        return {
          title: w.getTitle(),
          size: w.getSize(),
          min: w.getMinimumSize(),
          contextIsolation: p.contextIsolation,
          sandbox: p.sandbox,
          nodeIntegration: p.nodeIntegration,
          webviewTag: p.webviewTag,
          workArea: screen.getPrimaryDisplay().workArea,
        };
      });
      assert.equal(info.title, "Sahte panel");
      assert.deepEqual(info.min, [1000, 680]);
      // varsayılan 1360×900; küçük ekranda ekrana sığdırılır (xvfb-run varsayılanı 1280×1024)
      assert.deepEqual(info.size, [Math.min(1360, info.workArea.width), Math.min(900, info.workArea.height)]);
      assert.equal(info.contextIsolation, true);
      assert.equal(info.sandbox, true);
      assert.equal(info.nodeIntegration, false);
      assert.equal(info.webviewTag, false);
      assert.equal(await win.evaluate(() => typeof require + "/" + typeof process + "/" + typeof module), "undefined/undefined/undefined");
    });

    await check("window.envanterDesktop: platform, sürüm, yalnızca setPendingCount", async () => {
      const d = await win.evaluate(() => {
        const e = window.envanterDesktop;
        return { platform: e.platform, version: e.version, keys: Object.keys(e), frozen: Object.isFrozen(e), fn: typeof e.setPendingCount };
      });
      assert.equal(d.platform, "linux");
      assert.equal(d.version, pkg.version);
      assert.deepEqual(d.keys.sort(), ["platform", "setPendingCount", "version"]);
      assert.equal(d.frozen, true);
      assert.equal(d.fn, "function");
    });

    await check("kullanıcı aracısına uygulama adı ve sürümü eklenir", async () => {
      const ua = await win.evaluate(() => navigator.userAgent);
      assert.ok(ua.endsWith(` NextGenEnvanter/${pkg.version} (Linux)`), ua);
    });

    await check("Türkçe menü", async () => {
      const menu = await app.evaluate(({ Menu }) =>
        Menu.getApplicationMenu().items.map((i) => ({ label: i.label, items: i.submenu.items.filter((s) => s.type !== "separator").map((s) => s.label) })),
      );
      assert.deepEqual(
        menu.map((m) => m.label),
        ["Dosya", "Düzen", "Görünüm", "Yardım"],
      );
      assert.deepEqual(menu[0].items, ["Yenile", "Panel adresini tarayıcıda aç", "Çıkış"]);
      assert.deepEqual(menu[1].items, ["Geri al", "Yinele", "Kes", "Kopyala", "Yapıştır", "Tümünü seç"]);
      assert.deepEqual(menu[2].items, ["Yakınlaştır", "Uzaklaştır", "Gerçek boyut", "Tam ekran", "Geliştirici araçları"]);
      assert.deepEqual(menu[3].items, ["Bağlantı koduyla bağlan", "Sürüm bilgisi"]);
    });

    await check("dış bağlantılar pencerede açılmaz, varsayılan tarayıcıya gider", async () => {
      await app.evaluate(({ shell }) => {
        globalThis.__acilan = [];
        shell.openExternal = async (url) => {
          globalThis.__acilan.push(url);
        };
      });
      const opened = () => app.evaluate(() => globalThis.__acilan);
      await clickInPage(win, "dis");
      await waitFor(async () => (await opened()).length === 1, { what: "dış bağlantı" });
      await clickInPage(win, "yeni");
      await waitFor(async () => (await opened()).length === 2, { what: "yeni sekme bağlantısı" });
      await clickInPage(win, "dosya");
      await clickInPage(win, "http");
      await sleep(700);
      assert.deepEqual(await opened(), ["https://example.com/disari", "https://wa.me/905551112233"]);
      assert.equal(await mainUrl(app), `${base}/`);
      assert.equal(await windowCount(app), 1);
    });

    await check("izinler: bildirim ve pano izinli, konum/kamera/mikrofon reddedilir", async () => {
      assert.equal(await win.evaluate(() => Notification.requestPermission()), "granted");
      const geo = await win.evaluate(
        () => new Promise((r) => navigator.geolocation.getCurrentPosition(() => r("izin verildi"), (e) => r(e.code), { timeout: 5000 })),
      );
      assert.equal(geo, 1); // PERMISSION_DENIED
      // Kamera/mikrofon kararı doğrudan izin denetiminden okunur (xvfb'de aygıt olmadığından getUserMedia her durumda
      // NotFoundError verir; izin verilse bile fark edilmez)
      const state = (name) => win.evaluate((n) => navigator.permissions.query({ name: n }).then((s) => s.state), name);
      assert.equal(await state("camera"), "denied");
      assert.equal(await state("microphone"), "denied");
      assert.equal(await state("geolocation"), "denied");
      assert.equal(await state("clipboard-write"), "granted");
    });

    await check("paneldeki envanter:// bağlantısı (“Bu bilgisayardaki uygulamada aç”) bağlan sayfasını bu pencerede açar", async () => {
      await clickInPage(win, "uygulama");
      await waitFor(async () => (await mainUrl(app)) === `${base}/baglan#kod=7KQ2-M9XP-4TRA-HW3D`, { what: "bağlan sayfası" });
      await waitFor(async () => (await pageText(app, "kod")) === "#kod=7KQ2-M9XP-4TRA-HW3D", { what: "sayfa kodu okudu" });
      // "yeni sekmede" istenen bağlantı da yeni pencere ya da tarayıcı açmadan aynı pencerede
      await app.evaluate(({ BrowserWindow }, u) => BrowserWindow.getAllWindows()[0].loadURL(u), `${base}/`);
      await win.waitForSelector("#uygulama-yeni");
      await clickInPage(win, "uygulama-yeni");
      await waitFor(async () => (await mainUrl(app)) === `${base}/baglan#kod=ZZ23-YX98-WVUT-7654`, { what: "yeni sekme bağlantısı" });
      assert.equal(await windowCount(app), 1);
      assert.ok(!(await app.evaluate(() => globalThis.__acilan)).some((u) => u.startsWith("envanter:")), "tarayıcıya gönderilmemeli");
      // sonraki denetimler ana sayfadan başlar
      await app.evaluate(({ BrowserWindow }, u) => BrowserWindow.getAllWindows()[0].loadURL(u), `${base}/`);
      await waitFor(async () => (await mainUrl(app)) === `${base}/`, { what: "ana sayfaya dönüş" });
      await win.waitForSelector("#sayfa");
    });

    // ---------------------------------------------------------------- 2. envanter:// bağlantıları
    await check("ikinci örneğe verilen bağlantı /baglan#kod=7KQ2-M9XP-4TRA-HW3D açar", async () => {
      const code = await runSecondInstance("envanter://baglan?kod=7kq2-m9xp-4tra-hw3d&sunucu=https%3A%2F%2Fabc.supabase.co&anahtar=x");
      assert.equal(code, 0);
      await waitFor(async () => (await mainUrl(app)) === `${base}/baglan#kod=7KQ2-M9XP-4TRA-HW3D`, { what: "bağlan sayfası" });
      await win.waitForSelector("#kod");
      assert.equal(await win.textContent("#kod"), "#kod=7KQ2-M9XP-4TRA-HW3D");
      assert.equal(await windowCount(app), 1);
    });

    await check("bağlan sayfası açıkken gelen yeni kod sayfayı baştan yükler", async () => {
      const before = await win.textContent("#yukleme");
      assert.equal(await runSecondInstance("envanter:baglan?KOD=zz23yx98wvut7654"), 0);
      await waitFor(async () => (await mainUrl(app)) === `${base}/baglan#kod=ZZ23-YX98-WVUT-7654`, { what: "yeni kod" });
      await waitFor(async () => (await win.textContent("#kod")) === "#kod=ZZ23-YX98-WVUT-7654", { what: "sayfa yeni kodu okudu" });
      assert.notEqual(await win.textContent("#yukleme"), before);
    });

    await check("geçersiz kodlu bağlantı kodsuz /baglan açar", async () => {
      assert.equal(await runSecondInstance("envanter://baglan?kod=7KQ2-M9XP-4TRA-HW1D"), 0);
      await waitFor(async () => (await mainUrl(app)) === `${base}/baglan`, { what: "kodsuz bağlan" });
      await waitFor(async () => (await win.textContent("#kod")) === "", { what: "kod boş" });
    });

    await check("menü: Bağlantı koduyla bağlan, Panel adresini tarayıcıda aç, Sürüm bilgisi", async () => {
      const before = await win.textContent("#yukleme");
      const click = (menu, label) =>
        app.evaluate(({ Menu }, [m, l]) => Menu.getApplicationMenu().items.find((i) => i.label === m).submenu.items.find((i) => i.label === l).click(), [menu, label]);
      await click("Yardım", "Bağlantı koduyla bağlan");
      await waitFor(async () => (await win.textContent("#yukleme").catch(() => before)) !== before, { what: "bağlan sayfası yeniden yüklendi" });
      assert.equal(await mainUrl(app), `${base}/baglan`);
      await click("Dosya", "Panel adresini tarayıcıda aç");
      await waitFor(async () => (await app.evaluate(() => globalThis.__acilan)).includes(`${base}/`), { what: "tarayıcıda açılan panel" });
      await app.evaluate(({ dialog }) => {
        dialog.showMessageBox = async (...args) => {
          globalThis.__surum = args.length > 1 ? args[1] : args[0];
          return { response: 0, checkboxChecked: false };
        };
      });
      await click("Yardım", "Sürüm bilgisi");
      const about = await waitFor(() => app.evaluate(() => globalThis.__surum), { what: "sürüm penceresi" });
      assert.equal(about.message, `NextGen Envanter ${pkg.version}`);
      const [adres, surum] = about.detail.split("\n");
      assert.equal(adres, `Panel adresi: ${base}`);
      assert.ok(surum.startsWith(`Electron ${require("electron/package.json").version} · Chromium `), surum);
    });

    // ---------------------------------------------------------------- 3. çevrimdışı
    await check("sunucu kapanınca yenileme çevrimdışı sayfasını gösterir", async () => {
      await stopServer();
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].webContents.reload());
      await waitFor(async () => (await mainUrl(app))?.startsWith("file:"), { what: "çevrimdışı sayfası" });
      const url = new URL(await mainUrl(app));
      assert.ok(url.pathname.endsWith("/offline.html"), url.pathname);
      assert.equal(url.searchParams.get("hedef"), `${base}/baglan`);
      await win.waitForSelector("#dene");
      assert.equal(await win.textContent("h1"), "Web paneline ulaşılamıyor");
      assert.equal(await win.textContent("#dene"), "Yeniden dene");
      assert.equal(await win.textContent("#neden"), "Sunucu şu anda yanıt vermiyor.");
      assert.equal(await win.textContent("#adres"), `127.0.0.1:${port}`);
      // CSP özetleri doğru: satır içi betik çalışıyor (geri sayım) ve stil uygulanıyor
      await waitFor(async () => /saniye sonra kendiliğinden yeniden denenecek/.test(await win.textContent("#durum")), { what: "geri sayım" });
      assert.equal(await win.evaluate(() => getComputedStyle(document.getElementById("dene")).borderTopLeftRadius), "4px");
    });

    await check("sunucu geri gelince panel kendiliğinden açılır (15 sn'de bir deneme)", async () => {
      await sleep(1500);
      await startServer();
      await waitFor(async () => (await mainUrl(app)) === `${base}/baglan`, { timeout: 25_000, interval: 250, what: "otomatik dönüş" });
      await win.waitForSelector("#sayfa");
    });

    await check("“Yeniden dene” düğmesi hemen dener", async () => {
      await stopServer();
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].webContents.reload());
      await waitFor(async () => (await mainUrl(app))?.startsWith("file:"), { what: "çevrimdışı sayfası" });
      await win.waitForSelector("#dene");
      await win.click("#dene");
      await waitFor(async () => (await win.textContent("#neden")) === "Hâlâ ulaşılamıyor.", { what: "hâlâ ulaşılamıyor" });
      await startServer();
      await win.click("#dene");
      await waitFor(async () => (await mainUrl(app)) === `${base}/baglan`, { timeout: 5000, what: "düğmeyle dönüş" });
    });

    await check("Dosya → Yenile çevrimdışı sayfasındayken paneli yeniden dener", async () => {
      await stopServer();
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].webContents.reload());
      await waitFor(async () => (await mainUrl(app))?.startsWith("file:"), { what: "çevrimdışı sayfası" });
      await startServer();
      await app.evaluate(({ Menu }) => Menu.getApplicationMenu().items[0].submenu.items[0].click());
      await waitFor(async () => (await mainUrl(app)) === `${base}/baglan`, { timeout: 5000, what: "menüyle dönüş" });
    });

    // ---------------------------------------------------------------- 4. kapatma uyarısı
    await check("bekleyen değişiklik varken kapatma soru sorar; “Vazgeç” kapatmaz", async () => {
      await win.waitForSelector("#sayfa");
      await stubDialog(app, 1);
      await win.evaluate(() => window.envanterDesktop.setPendingCount(3));
      await sleep(300);
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].close());
      await sleep(800);
      assert.equal(await windowCount(app), 1);
      const qs = await app.evaluate(() => globalThis.__sorular);
      assert.equal(qs.length, 1);
      assert.equal(qs[0].message, "Gönderilmemiş 3 değişiklik var.");
      assert.equal(qs[0].detail, "Değişiklikler bu bilgisayarda saklanır ve internet gelince gönderilir. Yine de kapatılsın mı?");
      assert.deepEqual(qs[0].buttons, ["Kapat", "Vazgeç"]);
    });

    await check("sayfanın kendi beforeunload'u varken de “Vazgeç” kapatmaz", async () => {
      // sayfanın kapanmayı durdurduğu her an kaydedilir (uygulamanın kendi dinleyicisinin yanında)
      await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()[0].webContents.on("will-prevent-unload", () => console.log("SAYFA-DURDURDU")),
      );
      await win.click("#sayfa"); // beforeunload için kullanıcı etkileşimi gerekir
      await win.evaluate(() =>
        window.addEventListener("beforeunload", (e) => {
          e.preventDefault();
          e.returnValue = "";
        }),
      );
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].close());
      await sleep(1000);
      assert.equal(await windowCount(app), 1);
      assert.equal((await app.evaluate(() => globalThis.__sorular)).length, 2);
    });

    await check("sayı 0 iken sayfanın beforeunload'u yine soruya dönüşür (will-prevent-unload)", async () => {
      await win.evaluate(() => window.envanterDesktop.setPendingCount(0));
      await sleep(300);
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].close());
      await waitFor(async () => (await app.evaluate(() => globalThis.__sorular)).length === 3, { what: "üçüncü soru" });
      await sleep(500);
      assert.equal(await windowCount(app), 1);
      const qs = await app.evaluate(() => globalThis.__sorular);
      assert.equal(qs[2].message, "Gönderilmemiş değişiklikler olabilir.");
      assert.deepEqual(qs[2].buttons, ["Kapat", "Vazgeç"]);
      assert.equal(countLines(first.stdout, "SAYFA-DURDURDU"), 1);
    });

    await check("“Kapat” seçilince pencere kapanır; sayfa da durdursa ikinci soru sorulmaz", async () => {
      await win.evaluate(() => window.envanterDesktop.setPendingCount(2));
      await sleep(300);
      // sonraki açılışta geri gelecek boyut
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setBounds({ x: 40, y: 30, width: 1111, height: 777 }));
      await sleep(300);
      await stubDialog(app, 0);
      const closed = app.waitForEvent("close", { timeout: 15_000 });
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].close());
      await closed;
      assert.equal(countQuestions(first.stdout), 4);
      assert.equal(countLines(first.stdout, "SAYFA-DURDURDU"), 2, "sayfanın beforeunload'u bu kapanışta da çalışmalıydı");
    });
  } finally {
    await closeApp(app);
  }

  // ---------------------------------------------------------------- 5. yeniden açılış
  // ikinci açılış ortam değişkeni olmadan: panel adresi ayarlar.json'dan (Not Defteri BOM'u ile) okunur
  fs.writeFileSync(path.join(userData, "ayarlar.json"), "\uFEFF" + JSON.stringify({ panelAdresi: `${base}/` }));
  const second = await launch(["envanter://baglan?kod=AB2C-D3EF-4GH5-JK6M"], { panelEnv: false });
  try {
    await check("ilk açılışta komut satırındaki bağlantı açılır (ayarlar.json adresiyle)", async () => {
      await waitFor(async () => (await mainUrl(second.app)) === `${base}/baglan#kod=AB2C-D3EF-4GH5-JK6M`, { what: "ilk açılış bağlantısı" });
      await second.win.waitForSelector("#kod");
      assert.equal(await second.win.textContent("#kod"), "#kod=AB2C-D3EF-4GH5-JK6M");
    });

    await check("pencere boyutu ve konumu hatırlanır (pencere.json)", async () => {
      const saved = JSON.parse(fs.readFileSync(path.join(userData, "pencere.json"), "utf8"));
      assert.equal(saved.width, 1111);
      assert.equal(saved.height, 777);
      const b = await second.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].getBounds());
      assert.equal(b.width, 1111);
      assert.equal(b.height, 777);
      assert.equal(b.x, 40);
      assert.equal(b.y, 30);
    });

    await check("pencere taşınınca/boyutlanınca durum kısa süre içinde kaydedilir (kapatmayı beklemeden)", async () => {
      const file = path.join(userData, "pencere.json");
      await second.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setBounds({ x: 70, y: 60, width: 1200, height: 720 }));
      const saved = await waitFor(
        () => {
          const s = readJson(file);
          return s?.x === 70 && s.y === 60 && s.width === 1200 && s.height === 720 ? s : null;
        },
        { timeout: 5000, what: "pencere.json güncellendi" },
      );
      assert.equal(saved.maximized, false);
    });

    await check("bekleyen değişiklik yokken soru sorulmadan kapanır", async () => {
      await stubDialog(second.app, 1);
      const closed = second.app.waitForEvent("close", { timeout: 15_000 });
      await second.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].close());
      await closed;
      assert.equal(countQuestions(second.stdout), 0);
    });
  } finally {
    await closeApp(second.app);
  }

  // ---------------------------------------------------------------- 6. çökme ve Windows'un kapanması
  const third = await launch();
  try {
    await waitFor(async () => (await mainUrl(third.app)) === `${base}/`, { what: "üçüncü açılış" });
    await third.win.waitForSelector("#sayfa");

    const blockUnload = async () => {
      await third.win.click("#sayfa"); // beforeunload için kullanıcı etkileşimi
      await third.win.evaluate(() =>
        window.addEventListener("beforeunload", (e) => {
          e.preventDefault();
          e.returnValue = "";
        }),
      );
    };

    await check("bekleyen değişiklik varken paneldeki envanter:// bağlantısı tek soru sorar", async () => {
      await stubDialog(third.app, 0);
      await third.win.evaluate(() => window.envanterDesktop.setPendingCount(2));
      await blockUnload();
      await clickInPage(third.win, "uygulama");
      await waitFor(async () => (await mainUrl(third.app)) === `${base}/baglan#kod=7KQ2-M9XP-4TRA-HW3D`, { what: "bağlan sayfası" });
      await sleep(500);
      assert.equal(countQuestions(third.stdout), 1, "tıklama ve bağlan sayfasının yüklenmesi için ayrı ayrı sorulmamalı");
      const [q] = await third.app.evaluate(() => globalThis.__sorular);
      assert.equal(q.message, "Gönderilmemiş 2 değişiklik var.");
      assert.deepEqual(q.buttons, ["Çık", "Vazgeç"]);
      await third.app.evaluate(({ BrowserWindow }, u) => BrowserWindow.getAllWindows()[0].loadURL(u), `${base}/`);
      await waitFor(async () => (await mainUrl(third.app)) === `${base}/`, { what: "ana sayfaya dönüş" });
      await third.win.waitForSelector("#sayfa");
    });

    await check("“Vazgeç” denen bağlantı unutulur: sonraki çökmede açık sayfa yeniden yüklenir", async () => {
      await stubDialog(third.app, 1);
      await blockUnload();
      const before = countQuestions(third.stdout);
      assert.equal(await runSecondInstance("envanter://baglan?kod=AB2C-D3EF-4GH5-JK6M"), 0);
      await waitFor(async () => countQuestions(third.stdout) === before + 1, { what: "çıkış sorusu" });
      const q = (await third.app.evaluate(() => globalThis.__sorular)).at(-1);
      assert.deepEqual(q.buttons, ["Çık", "Vazgeç"]);
      await sleep(500);
      assert.equal(await mainUrl(third.app), `${base}/`);
      await third.app.evaluate(({ BrowserWindow }) => {
        const wc = BrowserWindow.getAllWindows()[0].webContents;
        globalThis.__yuklenen = [];
        wc.on("did-navigate", (_e, url) => globalThis.__yuklenen.push(url));
        wc.forcefullyCrashRenderer();
      });
      await waitFor(async () => (await pageText(third.app, "sayfa")) === "ana", { what: "çökmeden sonra yeniden yükleme" });
      assert.deepEqual(await third.app.evaluate(() => globalThis.__yuklenen), [`${base}/`]);
    });

    await check("her sayfa çökerse sıkı döngü yok: bekleyip yeniden dener, bir kez uyarır", async () => {
      await third.app.evaluate(({ BrowserWindow, dialog }) => {
        const wc = BrowserWindow.getAllWindows()[0].webContents;
        globalThis.__cokme = 0;
        globalThis.__yuklenen = [];
        globalThis.__bildirim = [];
        wc.on("render-process-gone", () => globalThis.__cokme++);
        dialog.showMessageBox = (...args) => {
          const o = args.length > 1 ? args[1] : args[0];
          return new Promise((resolve) => globalThis.__bildirim.push({ o, resolve }));
        };
        // her sayfa (çevrimdışı sayfası dahil) açılır açılmaz çöker
        globalThis.__cokert = () =>
          setTimeout(() => {
            if (!wc.isDestroyed() && !wc.isCrashed()) wc.forcefullyCrashRenderer();
          }, 50);
        wc.on("dom-ready", globalThis.__cokert);
        wc.reload();
      });
      const notices = () => third.app.evaluate(() => globalThis.__bildirim.map(({ o }) => ({ message: o.message, detail: o.detail, buttons: o.buttons })));
      await waitFor(async () => (await notices()).length === 1, { what: "uyarı" });
      const crashes = await third.app.evaluate(() => globalThis.__cokme);
      const loads = (await third.app.evaluate(() => globalThis.__yuklenen)).length;
      assert.ok(crashes >= 2 && crashes <= 3, `çökme sayısı ${crashes}`);
      // bekleme süresince yeni yükleme ve çökme olmaz
      await sleep(4000);
      assert.equal(await third.app.evaluate(() => globalThis.__cokme), crashes);
      assert.equal((await third.app.evaluate(() => globalThis.__yuklenen)).length, loads);
      const [n] = await notices();
      assert.equal(n.message, "Panel bu bilgisayarda gösterilemiyor.");
      assert.match(n.detail, /^Sayfayı gösteren işlem art arda kapandı \(.+\)\.\n15 saniye sonra kendiliğinden yeniden denenecek/);
      assert.deepEqual(n.buttons, ["Yeniden dene", "Tamam"]);
      // sorun giderildi; kullanıcı "Yeniden dene"ye basar
      await third.app.evaluate(({ BrowserWindow }) => {
        BrowserWindow.getAllWindows()[0].webContents.off("dom-ready", globalThis.__cokert);
        globalThis.__bildirim[0].resolve({ response: 0, checkboxChecked: false });
      });
      await waitFor(async () => (await pageText(third.app, "sayfa")) === "ana", { what: "yeniden denemeyle dönüş" });
      assert.equal(await mainUrl(third.app), `${base}/`);
      assert.equal((await notices()).length, 1);
    });

    await check("Windows kapanırken (session-end) pencere durumu hemen yazılır", async () => {
      const file = path.join(userData, "pencere.json");
      // "close" gelmeden süreç sonlanır: kayıt gecikmeli kaydı beklemeden olay içinde yazılmalı
      await third.app.evaluate(({ BrowserWindow }) => {
        const w = BrowserWindow.getAllWindows()[0];
        w.setBounds({ x: 90, y: 80, width: 1150, height: 700 });
        w.emit("session-end");
      });
      const s = readJson(file);
      assert.deepEqual(s && { x: s.x, y: s.y, width: s.width, height: s.height }, { x: 90, y: 80, width: 1150, height: 700 });
    });
  } finally {
    await closeApp(third.app);
  }
}

try {
  await main();
} catch (e) {
  results.push({ name: "duman testi yarıda kaldı", ok: false });
  console.log(`  HATA  ${e?.stack || e}`);
} finally {
  await stopServer();
  fs.rmSync(userData, { recursive: true, force: true });
}

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} denetim geçti${failed.length ? ` · başarısız: ${failed.map((f) => f.name).join(", ")}` : ""}`);
process.exit(failed.length ? 1 : 0);
