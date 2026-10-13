"use strict";
// Bağlantı kodu ayrıştırma: web ve Mac ile ortak vektörlerin hepsi
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const { PAIR_ALPHABET, PAIR_LENGTH, parsePairCode, pairDisplay } = require("../src/paircode");

const vectors = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "pair-vectors.json"), "utf8"));

test("alfabe ve uzunluk vektörlerle aynı", () => {
  assert.equal(PAIR_ALPHABET, vectors.alphabet);
  assert.equal(PAIR_LENGTH, vectors.length);
});

test("parse: tüm vektörler", () => {
  assert.ok(vectors.parse.length >= 30);
  for (const v of vectors.parse) {
    assert.equal(parsePairCode(v.input), v.code, `girdi: ${JSON.stringify(v.input)}`);
  }
});

test("display: derive vektörleri", () => {
  for (const v of vectors.derive) assert.equal(pairDisplay(v.code), v.display);
});

test("link vektörlerindeki bağlantılardan kod geri okunur", () => {
  for (const v of vectors.link) assert.equal(parsePairCode(v.link), v.code);
});

test("metin olmayan girdi null", () => {
  for (const v of [undefined, null, 42, {}, []]) assert.equal(parsePairCode(v), null);
});

test("bozuk yüzde kodlaması hata fırlatmaz", () => {
  assert.equal(parsePairCode("envanter://baglan?kod=%E0%A4%A"), null);
  assert.equal(parsePairCode("kod=%G1%4"), null);
});
