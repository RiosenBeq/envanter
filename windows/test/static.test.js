"use strict";
// Paket ayarları, çevrimdışı sayfası ve ön yükleme için durağan denetimler
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
const read = (p) => fs.readFileSync(path.join(root, p), "utf8");
const pkg = JSON.parse(read("package.json"));

test("package.json: ad, sürüm, giriş noktası", () => {
  assert.equal(pkg.name, "nextgen-envanter-windows");
  assert.equal(pkg.productName, "NextGen Envanter");
  assert.equal(pkg.version, "2.1.0");
  assert.equal(pkg.main, "src/main.js");
  assert.ok(fs.existsSync(path.join(root, pkg.main)));
});

test("package.json: Electron ve electron-builder tam sürüme sabit", () => {
  // Desteği biten Electron sürümleri güvenlik düzeltmesi almaz (37 ve öncesi); en az 44
  assert.match(pkg.devDependencies.electron, /^\d+\.\d+\.\d+$/);
  assert.ok(Number(pkg.devDependencies.electron.split(".")[0]) >= 44, pkg.devDependencies.electron);
  assert.match(pkg.devDependencies["electron-builder"], /^\d+\.\d+\.\d+$/);
  assert.equal(pkg.dependencies, undefined, "uygulamanın çalışma zamanı bağımlılığı yok");
});

test("package.json: Windows kurulum ayarları", () => {
  const b = pkg.build;
  assert.equal(b.appId, "com.nextgen.envanter");
  assert.equal(b.win.target, "nsis");
  assert.equal(b.win.icon, "build/icon.png");
  assert.equal(b.artifactName, "NextGen-Envanter-Kurulum-${version}.${ext}");
  assert.deepEqual(b.files, ["src/**/*", "build/icon.png", "package.json"]);
  assert.deepEqual(b.protocols, [{ name: "NextGen Envanter", schemes: ["envanter"] }]);
  assert.deepEqual(b.nsis, {
    oneClick: true,
    perMachine: false,
    createDesktopShortcut: true,
    createStartMenuShortcut: true,
    shortcutName: "NextGen Envanter",
    installerLanguages: ["tr_TR"],
    language: "1055",
    include: "build/installer.nsh",
  });
});

test("kaldırıcı: envanter:// ve otomatik başlatma kayıtlarını siler, güncellemede dokunmaz", () => {
  const nsh = read("build/installer.nsh");
  assert.ok(!pkg.build.files.some((f) => f.includes("installer.nsh")), "kurulum betiği uygulama paketine girmemeli");
  const macro = /!macro customUnInstall\n([\s\S]*?)!macroend/.exec(nsh)?.[1];
  assert.ok(macro, "customUnInstall makrosu yok");
  // her şey güncelleme denetiminin içinde
  assert.match(macro, /^\s*; [^\n]*\n\s*\$\{ifNot\} \$\{isUpdated\}\n[\s\S]*\$\{endif\}\s*$/);
  assert.match(macro, /ReadRegStr \$0 HKCU "Software\\Classes\\envanter\\shell\\open\\command" ""/);
  assert.match(macro, /DeleteRegKey HKCU "Software\\Classes\\envanter"/);
  assert.match(macro, /ReadRegStr \$0 HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Run" "\$\{APP_ID\}"/);
  assert.match(macro, /DeleteRegValue HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Run" "\$\{APP_ID\}"/);
  assert.match(macro, /DeleteRegValue HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run" "\$\{APP_ID\}"/);
  // silme yalnızca kayıt bu kurulumu gösteriyorsa
  assert.equal((macro.match(/!insertmacro envanterKurulumunuGosterir \$0 \$1\n\s*\$\{if\} \$1 == 1/g) || []).length, 2);
  assert.match(nsh, /StrCpy \$R9 \$\{VALUE\} \$R8\n\s*\$\{if\} \$R9 == '"\$INSTDIR\\'/);
  // kullanılan yazmaçlar geri yüklenir
  const pushes = [...macro.matchAll(/Push (\$\w+)/g)].map((m) => m[1]);
  const pops = [...macro.matchAll(/Pop (\$\w+)/g)].map((m) => m[1]);
  assert.deepEqual(pops, [...pushes].reverse());
  assert.deepEqual(pushes.sort(), ["$0", "$1", "$R8", "$R9"]);
  // uygulama kimliği main.js'deki AppUserModelId ile aynı (Run değerinin adı)
  assert.match(read("src/main.js"), new RegExp(`const APP_ID = "${pkg.build.appId.replace(/\./g, "\\.")}";`));
});

test("package.json: paketlenmiş uygulamanın Electron sigortaları", () => {
  // file:// ayrıcalığı açık kalır: çevrimdışı sayfası asar içinden file:// ile yüklenir
  assert.deepEqual(pkg.build.electronFuses, {
    runAsNode: false,
    enableNodeOptionsEnvironmentVariable: false,
    enableNodeCliInspectArguments: false,
    onlyLoadAppFromAsar: true,
  });
});

test("ikon en az 512×512 PNG", () => {
  const buf = fs.readFileSync(path.join(root, "build", "icon.png"));
  assert.equal(buf.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
  const width = buf.readUInt32BE(16);
  const height = buf.readUInt32BE(20);
  assert.ok(width >= 512 && height >= 512, `${width}×${height}`);
  assert.equal(width, height);
});

test("çevrimdışı sayfası: Türkçe metinler, uzak kaynak yok", () => {
  const html = read("src/offline.html");
  assert.match(html, /<html lang="tr">/);
  assert.match(html, /Web paneline ulaşılamıyor/);
  assert.match(html, />Yeniden dene</);
  assert.match(html, /const ARALIK = 15;/);
  assert.doesNotMatch(html, /<(script|link|img|iframe)[^>]+(src|href)=/i);
});

test("çevrimdışı sayfası: CSP satır içi betik ve stilin özetlerini içerir", () => {
  const html = read("src/offline.html");
  const csp = /http-equiv="Content-Security-Policy" content="([^"]+)"/.exec(html)?.[1];
  assert.ok(csp, "CSP meta etiketi yok");
  // HTML ayrıştırıcısı CRLF'yi LF'ye çevirir; özet de buna göre (Windows'ta CRLF ile çıkarılmış dosyada da doğru)
  const hash = (s) => `'sha256-${crypto.createHash("sha256").update(s.replace(/\r\n?/g, "\n"), "utf8").digest("base64")}'`;
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  const styles = [...html.matchAll(/<style>([\s\S]*?)<\/style>/g)].map((m) => m[1]);
  assert.equal(scripts.length, 1);
  assert.equal(styles.length, 1);
  assert.match(csp, /default-src 'none'/);
  assert.ok(csp.includes(`script-src ${hash(scripts[0])}`), `betik değişti; CSP'deki özet şu olmalı: ${hash(scripts[0])}`);
  assert.ok(csp.includes(`style-src ${hash(styles[0])}`), `stil değişti; CSP'deki özet şu olmalı: ${hash(styles[0])}`);
  assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval/);
});

test("ön yükleme: yalnızca contextBridge ve ipcRenderer, tek kanal", () => {
  const src = read("src/preload.js");
  assert.match(src, /require\("electron"\)/);
  const requires = [...src.matchAll(/require\("([^"]+)"\)/g)].map((m) => m[1]);
  assert.deepEqual(requires, ["electron"]);
  assert.match(src, /const \{ contextBridge, ipcRenderer \} = require\("electron"\);/);
  assert.deepEqual([...src.matchAll(/ipcRenderer\.(\w+)/g)].map((m) => m[1]), ["send"]);
  assert.match(src, /exposeInMainWorld\(\s*"envanterDesktop"/);
});

test("ana süreç: güvenli pencere ayarları", () => {
  const src = read("src/main.js");
  for (const re of [
    /contextIsolation: true/,
    /sandbox: true/,
    /nodeIntegration: false/,
    /webviewTag: false/,
    /spellcheck: false/,
    /partition: PARTITION/,
    /app\.enableSandbox\(\)/,
    /app\.requestSingleInstanceLock\(\)/,
    /setWindowOpenHandler/,
    /"will-navigate"/,
    /setPermissionRequestHandler/,
    /setPermissionCheckHandler/,
    /"will-prevent-unload"/,
    /"render-process-gone"/,
    /win\.on\("session-end", \(\) => \{\n\s*closeConfirmed = true;\n\s*saveWindowState\(\);/,
  ]) {
    assert.match(src, re);
  }
  assert.doesNotMatch(src, /nodeIntegration: true|contextIsolation: false|webSecurity: false|allowRunningInsecureContent/);
});
