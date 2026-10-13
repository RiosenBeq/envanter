"use strict";
// envanter:// bağlantıları ve pencere içi gezinme kuralı. Electron'a bağlı değildir; birim testleri doğrudan çağırır.

const { parsePairCode, pairDisplay } = require("./paircode");

const SCHEME_RE = /^envanter:/i;

function isDeepLink(value) {
  return typeof value === "string" && SCHEME_RE.test(value.trim());
}

/**
 * envanter:// bağlantısının panelde açılacağı adres.
 *  - "envanter://baglan?kod=7KQ2-M9XP-4TRA-HW3D" (ya da "envanter:baglan?...", harf büyüklüğü ve sondaki "/" önemsiz)
 *    → "<panel>/baglan#kod=7KQ2-M9XP-4TRA-HW3D". Kod adreste değil "#" sonrasında: sunucuya gitmez, kayıtlara girmez.
 *  - Kod geçersizse ya da yol tanınmıyorsa → "<panel>/baglan" (kod yazma ekranı).
 *  - envanter: olmayan adres → null.
 */
function deepLinkTarget(rawUrl, panelUrl) {
  if (!isDeepLink(rawUrl)) return null;
  const raw = rawUrl.trim();
  const base = `${panelUrl}/baglan`;
  const route = raw
    .slice("envanter:".length)
    .replace(/^\/+/, "")
    .split(/[?#]/, 1)[0]
    .replace(/\/+$/, "")
    .toLowerCase();
  if (route !== "baglan") return base;
  const code = parsePairCode(raw);
  return code ? `${base}#kod=${pairDisplay(code)}` : base;
}

/** Komut satırındaki ilk envanter: bağlantısı (Windows bağlantıyı uygulamaya argüman olarak verir); yoksa null. */
function findDeepLink(argv) {
  if (!Array.isArray(argv)) return null;
  for (const arg of argv) if (isDeepLink(arg)) return arg.trim();
  return null;
}

const EXTERNAL_PROTOCOLS = new Set(["https:", "mailto:", "tel:"]);

/**
 * Pencerede açılmak istenen adres için karar:
 *  "inside"   panelin kendi adresi (aynı köken) → pencerede açılır
 *  "external" başka https:// (ör. https://wa.me/...), mailto:, tel: → varsayılan tarayıcı/uygulama açar
 *  "block"    geri kalan her şey (file:, javascript:, data:, http://, bilinmeyen şemalar, bozuk adres)
 */
function navigationPolicy(targetUrl, panelUrl) {
  let target;
  try {
    target = new URL(String(targetUrl));
  } catch {
    return "block";
  }
  let panelOrigin = null;
  try {
    panelOrigin = new URL(String(panelUrl)).origin;
  } catch {
    panelOrigin = null;
  }
  if (panelOrigin && panelOrigin !== "null" && target.origin === panelOrigin) return "inside";
  if (!EXTERNAL_PROTOCOLS.has(target.protocol)) return "block";
  if (target.username || target.password) return "block";
  return "external";
}

module.exports = { isDeepLink, deepLinkTarget, findDeepLink, navigationPolicy };
