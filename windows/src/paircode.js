"use strict";
// Bağlantı kodu ayrıştırma: web panelindeki src/lib/pairCode.ts ve Mac'teki PairCode.swift ile birebir aynı kural
// (docs/SYNC.md → Bağlantı kodu). Ortak vektörler: test/fixtures/pair-vectors.json.

/** Kodun harfleri: karışan 0/1/I/L/O yok (31 karakter) */
const PAIR_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";

/** Kodun uzunluğu (tiresiz) */
const PAIR_LENGTH = 16;

/** Yalnızca a–z → A–Z (diğer karakterler olduğu gibi) */
function asciiUpper(s) {
  return s.replace(/[a-z]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 32));
}

/** Yalnızca A–Z → a–z */
function asciiLower(s) {
  return s.replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32));
}

/** Yüzde kodlamasını çözer; bozuk dizi olduğu gibi kalır, geçersiz UTF-8 baytları "�" olur (hata vermez). */
function percentDecode(s) {
  if (!s.includes("%")) return s;
  const bytes = [];
  const enc = new TextEncoder();
  for (let i = 0; i < s.length; ) {
    if (s[i] === "%" && /^[0-9A-Fa-f]{2}$/.test(s.slice(i + 1, i + 3))) {
      bytes.push(parseInt(s.slice(i + 1, i + 3), 16));
      i += 3;
      continue;
    }
    const ch = String.fromCodePoint(s.codePointAt(i) ?? 0);
    for (const b of enc.encode(ch)) bytes.push(b);
    i += ch.length;
  }
  return new TextDecoder("utf-8").decode(new Uint8Array(bytes));
}

// Dört dörtlü grup; arada en çok bir tire ya da boşluk; öncesi ve sonrası harf/rakam olmamalı
const CODE_RE = /(?:^|[^0-9A-Z])([0-9A-Z]{4}(?:[- ]?[0-9A-Z]{4}){3})(?=$|[^0-9A-Z])/g;

function inAlphabet(code) {
  if (code.length !== PAIR_LENGTH) return false;
  for (const ch of code) if (!PAIR_ALPHABET.includes(ch)) return false;
  return true;
}

/**
 * Metinden kodu bulur (tiresiz 16 harf; yoksa null). Mesajın tamamı ya da envanter:// bağlantısı da verilebilir:
 *  1. "kod=" varsa (harf büyüklüğü önemsiz) ilk "kod="dan sonrası, ilk "&", "#" ya da boşluğa kadar alınır; yüzde
 *     kodlaması çözülür.
 *  2. a–z büyük harfe çevrilir.
 *  3. Soldan sağa 4-4-4-4 grupları aranır; tire ve boşluklar atılır, 16 harfi de alfabede olan ilk grup döner.
 *     Reddedilen eşleşmeden sonra arama grubun ikinci harfinden sürer.
 */
function parsePairCode(input) {
  if (typeof input !== "string") return null;
  let s = input;
  const at = asciiLower(s).indexOf("kod=");
  if (at >= 0) {
    const rest = s.slice(at + 4);
    s = percentDecode(/^[^&#\s]*/.exec(rest)?.[0] ?? "");
  }
  s = asciiUpper(s);
  const re = new RegExp(CODE_RE.source, "g");
  let m;
  while ((m = re.exec(s)) !== null) {
    const group = m[1];
    const start = m.index + m[0].length - group.length;
    const code = group.replace(/[- ]/g, "");
    if (inAlphabet(code)) return code;
    re.lastIndex = start + 1;
  }
  return null;
}

/** Ekrandaki biçim: "7KQ2-M9XP-4TRA-HW3D" */
function pairDisplay(code) {
  return code.match(/.{1,4}/g)?.join("-") ?? code;
}

module.exports = { PAIR_ALPHABET, PAIR_LENGTH, parsePairCode, pairDisplay };
