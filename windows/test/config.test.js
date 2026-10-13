"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {
  DEFAULT_PANEL_URL,
  WINDOW_DEFAULTS,
  normalizePanelUrl,
  readJsonFile,
  writeJsonFile,
  resolvePanelUrl,
  sanitizeWindowState,
  loginItemOptions,
  loginItemEnabled,
} = require("../src/config");

// Testlerin açtığı geçici klasörler sonda silinir (her çalıştırmada %TEMP% dolmasın)
const tempDirs = [];
function tempDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "envanter-ayar-"));
  tempDirs.push(dir);
  return dir;
}
test.after(() => {
  for (const dir of tempDirs.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
});

test("varsayılan panel adresi", () => {
  assert.equal(DEFAULT_PANEL_URL, "https://envantersite-yo9n.vercel.app");
});

test("normalizePanelUrl: geçerli adresler, sondaki / atılır", () => {
  assert.equal(normalizePanelUrl("https://envanter.example.com/"), "https://envanter.example.com");
  assert.equal(normalizePanelUrl("  https://Envanter.Example.com//  "), "https://envanter.example.com");
  assert.equal(normalizePanelUrl("https://example.com/panel/"), "https://example.com/panel");
  assert.equal(normalizePanelUrl("https://example.com:8443"), "https://example.com:8443");
  assert.equal(normalizePanelUrl("http://127.0.0.1:3124/"), "http://127.0.0.1:3124");
  assert.equal(normalizePanelUrl("http://localhost:3000"), "http://localhost:3000");
  assert.equal(normalizePanelUrl("https://example.com/?a=1#b"), "https://example.com");
});

test("normalizePanelUrl: geçersiz adresler null", () => {
  for (const raw of [
    "http://example.com",
    "http://192.168.1.5:3000",
    "ftp://example.com",
    "file:///C:/panel/index.html",
    "javascript:alert(1)",
    "example.com",
    "https://kullanici:sifre@example.com",
    "",
    "   ",
    null,
    undefined,
    42,
    { url: "https://example.com" },
  ]) {
    assert.equal(normalizePanelUrl(raw), null, JSON.stringify(raw));
  }
});

test("resolvePanelUrl: ortam değişkeni → ayarlar.json → varsayılan", () => {
  const dir = tempDir();
  fs.writeFileSync(path.join(dir, "ayarlar.json"), JSON.stringify({ panelAdresi: "https://dosya.example.com/" }));
  assert.deepEqual(resolvePanelUrl({ env: { ENVANTER_PANEL_URL: "http://127.0.0.1:9/" }, userDataDir: dir }), {
    url: "http://127.0.0.1:9",
    source: "env",
  });
  assert.deepEqual(resolvePanelUrl({ env: {}, userDataDir: dir }), { url: "https://dosya.example.com", source: "file" });
  // geçersiz ortam değişkeni atlanır
  assert.deepEqual(resolvePanelUrl({ env: { ENVANTER_PANEL_URL: "http://kotu.example.com" }, userDataDir: dir }), {
    url: "https://dosya.example.com",
    source: "file",
  });
  assert.deepEqual(resolvePanelUrl({ env: {}, userDataDir: tempDir() }), { url: DEFAULT_PANEL_URL, source: "default" });
  assert.deepEqual(resolvePanelUrl({ env: {} }), { url: DEFAULT_PANEL_URL, source: "default" });
});

test("resolvePanelUrl: bozuk ya da geçersiz ayarlar.json hata fırlatmaz, varsayılana döner", () => {
  for (const content of [
    "{bozuk",
    "",
    "null",
    "[]",
    '"https://x.example.com"',
    JSON.stringify({ panelAdresi: "http://uzak.example.com" }),
    JSON.stringify({ panelAdresi: 7 }),
    JSON.stringify({ baskaAyar: true }),
  ]) {
    const dir = tempDir();
    fs.writeFileSync(path.join(dir, "ayarlar.json"), content);
    assert.deepEqual(resolvePanelUrl({ env: {}, userDataDir: dir }), { url: DEFAULT_PANEL_URL, source: "default" }, content);
  }
  // ayarlar.json bir klasörse
  const dir = tempDir();
  fs.mkdirSync(path.join(dir, "ayarlar.json"));
  assert.equal(resolvePanelUrl({ env: {}, userDataDir: dir }).source, "default");
});

test("ayarlar.json: Not Defteri'nin UTF-8 BOM'u sorun olmaz", () => {
  const dir = tempDir();
  fs.writeFileSync(path.join(dir, "ayarlar.json"), "\uFEFF" + JSON.stringify({ panelAdresi: "https://bom.example.com" }), "utf8");
  assert.deepEqual(resolvePanelUrl({ env: {}, userDataDir: dir }), { url: "https://bom.example.com", source: "file" });
});

test("readJsonFile / writeJsonFile", () => {
  const dir = tempDir();
  const file = path.join(dir, "alt", "pencere.json");
  assert.equal(readJsonFile(file), null);
  assert.equal(writeJsonFile(file, { width: 1200 }), true);
  assert.deepEqual(readJsonFile(file), { width: 1200 });
  assert.deepEqual(fs.readdirSync(path.dirname(file)), ["pencere.json"]);
  // yazılamayan yer: hata yutulur
  fs.writeFileSync(path.join(dir, "dosya"), "x");
  assert.equal(writeJsonFile(path.join(dir, "dosya", "pencere.json"), {}), false);
});

const SCREEN = { x: 0, y: 0, width: 1920, height: 1040 };
const SECOND = { x: 1920, y: 0, width: 1280, height: 984 };

test("pencere: kayıt yoksa varsayılan boyut, konum yok (ortalanır)", () => {
  assert.deepEqual(sanitizeWindowState(null, [SCREEN]), { width: 1360, height: 900, maximized: false });
  assert.deepEqual(sanitizeWindowState("bozuk", [SCREEN]), { width: 1360, height: 900, maximized: false });
  assert.deepEqual(sanitizeWindowState(undefined, []), { width: 1360, height: 900, maximized: false });
});

test("pencere: kayıtlı konum ve boyut korunur", () => {
  assert.deepEqual(sanitizeWindowState({ x: 100, y: 50, width: 1200, height: 800, maximized: true }, [SCREEN]), {
    x: 100,
    y: 50,
    width: 1200,
    height: 800,
    maximized: true,
  });
  assert.deepEqual(sanitizeWindowState({ x: 2000, y: 20, width: 1100, height: 700 }, [SCREEN, SECOND]), {
    x: 2000,
    y: 20,
    width: 1100,
    height: 700,
    maximized: false,
  });
});

test("pencere: en küçük boyutun altına inmez, ekrandan büyükse sığdırılır", () => {
  const small = sanitizeWindowState({ x: 10, y: 10, width: 300, height: 200 }, [SCREEN]);
  assert.equal(small.width, WINDOW_DEFAULTS.minWidth);
  assert.equal(small.height, WINDOW_DEFAULTS.minHeight);
  const big = sanitizeWindowState({ x: -50, y: -30, width: 4000, height: 3000 }, [SCREEN]);
  assert.deepEqual(big, { x: 0, y: 0, width: 1920, height: 1040, maximized: false });
});

test("pencere: çıkarılmış ikinci ekrandaki konum bırakılır", () => {
  const s = sanitizeWindowState({ x: 2100, y: 100, width: 1200, height: 800 }, [SCREEN]);
  assert.deepEqual(s, { width: 1200, height: 800, maximized: false });
});

test("pencere: kısmen taşan pencere ekrana kaydırılır", () => {
  const s = sanitizeWindowState({ x: 1700, y: 900, width: 1200, height: 800 }, [SCREEN]);
  assert.deepEqual(s, { x: 720, y: 240, width: 1200, height: 800, maximized: false });
});

test("pencere: küçük ekranda boyut ekrana sığar", () => {
  const laptop = { x: 0, y: 0, width: 1280, height: 680 };
  assert.deepEqual(sanitizeWindowState(null, [laptop]), { width: 1280, height: 680, maximized: false });
});

test("pencere: sayı olmayan değerler yok sayılır", () => {
  assert.deepEqual(sanitizeWindowState({ x: "1", y: null, width: NaN, height: Infinity, maximized: "evet" }, [SCREEN]), {
    width: 1360,
    height: 900,
    maximized: false,
  });
});

test("otomatik başlatma: kurulu uygulama Electron varsayılanlarını kullanır", () => {
  const o = loginItemOptions({ appId: "com.nextgen.envanter", defaultApp: false, execPath: "C:\\Uygulama\\NextGen Envanter.exe", appPath: "x" });
  assert.deepEqual(o, {});
  assert.equal(loginItemEnabled({ openAtLogin: true, launchItems: [] }, o), true);
  assert.equal(loginItemEnabled({ openAtLogin: false }, o), false);
});

test("otomatik başlatma: geliştirmede ayrı kayıt adı, electron.exe + tırnaklı uygulama klasörü", () => {
  const o = loginItemOptions({
    appId: "com.nextgen.envanter",
    defaultApp: true,
    execPath: "C:\\dev\\node_modules\\electron\\dist\\electron.exe",
    appPath: "C:\\Kod Klasörü\\envanter\\windows",
  });
  assert.deepEqual(o, {
    name: "com.nextgen.envanter.gelistirme",
    path: "C:\\dev\\node_modules\\electron\\dist\\electron.exe",
    args: ['"C:\\Kod Klasörü\\envanter\\windows"'],
  });
  assert.notEqual(o.name, "com.nextgen.envanter", "kurulu uygulamanın kaydının adı kullanılmamalı");
  // işaret, kurulu uygulamanın kaydına (openAtLogin) değil geliştirme kaydına bakar
  assert.equal(loginItemEnabled({ openAtLogin: true, launchItems: [{ name: "com.nextgen.envanter" }] }, o), false);
  assert.equal(loginItemEnabled({ openAtLogin: false, launchItems: [{ name: "com.nextgen.envanter.gelistirme" }] }, o), true);
  // launchItems yoksa (macOS) openAtLogin
  assert.equal(loginItemEnabled({ openAtLogin: true }, o), true);
  assert.equal(loginItemEnabled(null, o), false);
});
