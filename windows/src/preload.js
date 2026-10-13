"use strict";
// Korumalı (sandbox) ön yükleme: sayfaya yalnızca window.envanterDesktop açılır. Genel bir ipc geçidi yoktur;
// tek mesaj, bekleyen değişiklik sayısıdır (ana süreç göndereni ayrıca doğrular).

const { contextBridge, ipcRenderer } = require("electron");

function argValue(name) {
  const prefix = `--${name}=`;
  const arg = process.argv.find((a) => typeof a === "string" && a.startsWith(prefix));
  return arg ? arg.slice(prefix.length) : "";
}

const platform = process.platform === "win32" ? "windows" : process.platform === "darwin" ? "mac" : "linux";
const version = argValue("envanter-version");

let lastCount = -1;

contextBridge.exposeInMainWorld(
  "envanterDesktop",
  Object.freeze({
    platform,
    version,
    /** Gönderilmemiş değişiklik sayısı: pencere kapatılırken uyarı için */
    setPendingCount(n) {
      const count = typeof n === "number" && Number.isFinite(n) ? Math.min(Math.max(Math.floor(n), 0), 1_000_000) : 0;
      if (count === lastCount) return;
      lastCount = count;
      ipcRenderer.send("envanter:pending-count", count);
    },
  }),
);
