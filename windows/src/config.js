"use strict";
// Ayarlar: panel adresi (ortam değişkeni → ayarlar.json → varsayılan), pencere konumu (pencere.json), otomatik başlatma.
// Electron'a bağlı değildir; birim testleri doğrudan çağırır. Bozuk dosya hiçbir zaman hata fırlatmaz.

const fs = require("node:fs");
const path = require("node:path");

const DEFAULT_PANEL_URL = "https://envantersite-yo9n.vercel.app";
const SETTINGS_FILE = "ayarlar.json";
const WINDOW_FILE = "pencere.json";

// http yalnızca bu bilgisayardaki geliştirme sunucusu için
const LOCAL_HOSTS = new Set(["127.0.0.1", "localhost"]);

const WINDOW_DEFAULTS = Object.freeze({ width: 1360, height: 900, minWidth: 1000, minHeight: 680 });

/** Geçerli panel adresini sondaki "/" olmadan döndürür; geçersizse null. */
function normalizePanelUrl(raw) {
  if (typeof raw !== "string") return null;
  const text = raw.trim();
  if (!text) return null;
  let u;
  try {
    u = new URL(text);
  } catch {
    return null;
  }
  if (u.protocol === "http:") {
    if (!LOCAL_HOSTS.has(u.hostname)) return null;
  } else if (u.protocol !== "https:") {
    return null;
  }
  if (u.username || u.password) return null;
  return u.origin + u.pathname.replace(/\/+$/, "");
}

/** JSON dosyasını okur; yoksa, bozuksa ya da nesne değilse null (Not Defteri'nin BOM'u da sorun olmaz). */
function readJsonFile(file) {
  try {
    const text = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "");
    const value = JSON.parse(text);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

/** JSON dosyasını yarım kalmadan yazar (geçici dosya + yeniden adlandırma); hata yutulur. */
function writeJsonFile(file, value) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n", "utf8");
    fs.renameSync(tmp, file);
    return true;
  } catch {
    return false;
  }
}

/**
 * Panel adresi: ENVANTER_PANEL_URL → <userData>/ayarlar.json içindeki "panelAdresi" → varsayılan.
 * Geçersiz değer atlanır ve sıradakine geçilir.
 */
function resolvePanelUrl({ env = process.env, userDataDir, readFile = readJsonFile } = {}) {
  const fromEnv = normalizePanelUrl(env?.ENVANTER_PANEL_URL);
  if (fromEnv) return { url: fromEnv, source: "env" };
  if (userDataDir) {
    const settings = readFile(path.join(userDataDir, SETTINGS_FILE));
    const fromFile = normalizePanelUrl(settings?.panelAdresi);
    if (fromFile) return { url: fromFile, source: "file" };
  }
  return { url: DEFAULT_PANEL_URL, source: "default" };
}

function isFiniteNumber(v) {
  return typeof v === "number" && Number.isFinite(v);
}

function isRect(r) {
  return !!r && isFiniteNumber(r.x) && isFiniteNumber(r.y) && r.width > 0 && r.height > 0;
}

function overlap(a, b) {
  const w = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
  return w > 0 && h > 0 ? { width: w, height: h } : null;
}

function clamp(v, lo, hi) {
  return Math.min(Math.max(v, lo), Math.max(lo, hi));
}

/**
 * Kaydedilmiş pencere durumunu ekranlara göre düzeltir. Pencere hiçbir ekranda en az 160×100 px görünmüyorsa
 * (ör. ikinci ekran çıkarıldıysa) konum bırakılır ve pencere ortalanır; görünüyorsa ekranın içine kaydırılır.
 * workAreas: screen.getAllDisplays().map(d => d.workArea), ilki ana ekran.
 */
function sanitizeWindowState(saved, workAreas, d = WINDOW_DEFAULTS) {
  const areas = Array.isArray(workAreas) ? workAreas.filter(isRect) : [];
  const s = saved && typeof saved === "object" ? saved : {};
  let width = d.width;
  let height = d.height;
  if (isFiniteNumber(s.width) && isFiniteNumber(s.height)) {
    width = Math.max(d.minWidth, Math.round(s.width));
    height = Math.max(d.minHeight, Math.round(s.height));
  }
  const out = { width, height, maximized: s.maximized === true };

  let area = null;
  if (isFiniteNumber(s.x) && isFiniteNumber(s.y)) {
    const rect = { x: Math.round(s.x), y: Math.round(s.y), width, height };
    let best = 0;
    for (const a of areas) {
      const o = overlap(rect, a);
      if (o && o.width >= 160 && o.height >= 100 && o.width * o.height > best) {
        best = o.width * o.height;
        area = a;
      }
    }
    if (area) {
      out.width = clamp(width, d.minWidth, area.width);
      out.height = clamp(height, d.minHeight, area.height);
      out.x = clamp(rect.x, area.x, area.x + area.width - out.width);
      out.y = clamp(rect.y, area.y, area.y + area.height - out.height);
      return out;
    }
  }
  const primary = areas[0];
  if (primary) {
    out.width = clamp(width, d.minWidth, primary.width);
    out.height = clamp(height, d.minHeight, primary.height);
  }
  return out;
}

/**
 * "Windows açılınca başlat" kaydının seçenekleri (app.setLoginItemSettings).
 * Kurulu uygulama: Electron'un varsayılanları (kayıt adı uygulama kimliği, yol uygulamanın exe'si).
 * Geliştirme ("electron ."): ayrı kayıt adı, electron.exe ve uygulama klasörü. Böylece kurulu uygulamanın kaydı
 * ezilmez ve oturum açılınca uygulamasız boş Electron penceresi açılmaz.
 */
function loginItemOptions({ appId, defaultApp, execPath, appPath }) {
  if (!defaultApp) return {};
  // Windows argümanları tırnaklamaz; klasör adında boşluk olabilir
  return { name: `${appId}.gelistirme`, path: execPath, args: [`"${appPath}"`] };
}

/** app.getLoginItemSettings() sonucundan menüdeki işaretin durumu. Ayrı adlı kayıt launchItems'ta adıyla aranır. */
function loginItemEnabled(settings, options = {}) {
  if (!settings || typeof settings !== "object") return false;
  if (options.name && Array.isArray(settings.launchItems)) {
    return settings.launchItems.some((item) => item?.name === options.name);
  }
  return settings.openAtLogin === true;
}

module.exports = {
  DEFAULT_PANEL_URL,
  SETTINGS_FILE,
  WINDOW_FILE,
  WINDOW_DEFAULTS,
  normalizePanelUrl,
  readJsonFile,
  writeJsonFile,
  resolvePanelUrl,
  sanitizeWindowState,
  loginItemOptions,
  loginItemEnabled,
};
