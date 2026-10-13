"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { deepLinkTarget, findDeepLink, navigationPolicy, isDeepLink } = require("../src/links");

const PANEL = "https://envantersite-yo9n.vercel.app";

test("deepLinkTarget: kodlu bağlantı /baglan#kod=<görünen kod> olur", () => {
  const want = `${PANEL}/baglan#kod=7KQ2-M9XP-4TRA-HW3D`;
  for (const raw of [
    "envanter://baglan?kod=7KQ2-M9XP-4TRA-HW3D",
    "envanter://baglan/?kod=7kq2m9xp4trahw3d",
    "ENVANTER://BAGLAN?KOD=7KQ2-M9XP-4TRA-HW3D",
    "envanter:baglan?kod=7KQ2-M9XP-4TRA-HW3D",
    "envanter:///baglan?kod=7KQ2%2DM9XP%2D4TRA%2DHW3D",
    "  envanter://baglan?kod=7KQ2-M9XP-4TRA-HW3D&sunucu=https%3A%2F%2Fabc.supabase.co&anahtar=sb_publishable_x  ",
    "envanter://baglan#kod=7KQ2-M9XP-4TRA-HW3D",
  ]) {
    assert.equal(deepLinkTarget(raw, PANEL), want, raw);
  }
});

test("deepLinkTarget: geçersiz kod ya da bilinmeyen yol → kodsuz /baglan", () => {
  for (const raw of [
    "envanter://baglan",
    "envanter://baglan?kod=",
    "envanter://baglan?kod=7KQ2-M9XP-4TRA-HW1D",
    "envanter://baglan?kod=&x=7KQ2-M9XP-4TRA-HW3D",
    "envanter://ayarlar?kod=7KQ2-M9XP-4TRA-HW3D",
    "envanter://",
    "envanter:",
  ]) {
    assert.equal(deepLinkTarget(raw, PANEL), `${PANEL}/baglan`, raw);
  }
});

test("deepLinkTarget: envanter: olmayan adres null", () => {
  for (const raw of ["https://x.example/baglan?kod=7KQ2-M9XP-4TRA-HW3D", "7KQ2-M9XP-4TRA-HW3D", "", null, undefined, 5]) {
    assert.equal(deepLinkTarget(raw, PANEL), null);
  }
});

test("deepLinkTarget: yerel panel adresiyle", () => {
  assert.equal(
    deepLinkTarget("envanter://baglan?kod=ZZ23YX98WVUT7654", "http://127.0.0.1:3124"),
    "http://127.0.0.1:3124/baglan#kod=ZZ23-YX98-WVUT-7654",
  );
});

test("findDeepLink: argv içindeki ilk envanter: argümanı", () => {
  assert.equal(findDeepLink(["C:\\Program\\NextGen Envanter.exe", "--allow-file-access", "envanter://baglan?kod=A", "envanter://b"]), "envanter://baglan?kod=A");
  assert.equal(findDeepLink(["electron", ".", "ENVANTER:baglan"]), "ENVANTER:baglan");
  assert.equal(findDeepLink(["electron", "."]), null);
  assert.equal(findDeepLink(undefined), null);
  assert.equal(findDeepLink([null, 3, {}]), null);
  assert.equal(isDeepLink(" envanter://x"), true);
  assert.equal(isDeepLink("https://envanter.example"), false);
});

test("navigationPolicy: panel içi", () => {
  assert.equal(navigationPolicy(`${PANEL}/`, PANEL), "inside");
  assert.equal(navigationPolicy(`${PANEL}/baglan#kod=X`, PANEL), "inside");
  assert.equal(navigationPolicy(`${PANEL}/sayim?gun=2026-10-13`, PANEL), "inside");
  assert.equal(navigationPolicy("http://127.0.0.1:3124/raporlar", "http://127.0.0.1:3124"), "inside");
});

test("navigationPolicy: dış bağlantılar varsayılan uygulamada", () => {
  for (const url of [
    "https://wa.me/?text=merhaba",
    "https://wa.me/905551112233",
    "https://supabase.com/dashboard",
    "mailto:destek@example.com",
    "tel:+905551112233",
    "https://envantersite-yo9n.vercel.app.example.com/",
  ]) {
    assert.equal(navigationPolicy(url, PANEL), "external", url);
  }
});

test("navigationPolicy: geri kalan her şey engellenir", () => {
  for (const url of [
    "file:///C:/Windows/System32/drivers/etc/hosts",
    "javascript:alert(1)",
    "data:text/html,<b>x</b>",
    "http://envantersite-yo9n.vercel.app/",
    "http://example.com/",
    "ftp://example.com/",
    "ms-settings:privacy",
    "envanter://baglan",
    "about:blank",
    "https://kullanici:sifre@example.com/",
    "bozuk adres",
    "",
  ]) {
    assert.equal(navigationPolicy(url, PANEL), "block", url);
  }
});
