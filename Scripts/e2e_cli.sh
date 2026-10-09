#!/bin/bash
# EnvanterTool uçtan uca testi: demo kur → durum/rapor/sipariş → Excel'e aktar → başka klasöre geri al.
#   ./Scripts/e2e_cli.sh <EnvanterTool yolu>
set -euo pipefail
TOOL="${1:?EnvanterTool yolu gerekli}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "✗ $*"; exit 1; }
ok() { echo "✓ $*"; }
expect() { grep -q -- "$2" <<<"$1" || fail "$3 (beklenen: $2)"; ok "$3"; }

END="2026-08-31"

# 1) Demo veri: --data-dir zorunlu, dolu klasöre yazmaz
if "$TOOL" demo >/dev/null 2>&1; then fail "demo --data-dir olmadan çalışmamalı"; else ok "demo --data-dir olmadan reddedildi"; fi
"$TOOL" demo --data-dir "$WORK/demo" --date "$END" --days 35 >/dev/null
if "$TOOL" demo --data-dir "$WORK/demo" >/dev/null 2>&1; then fail "dolu klasöre demo yazılmamalı"; else ok "dolu klasöre demo yazılmadı"; fi

# 2) Durum ve rapor
out=$("$TOOL" status --data-dir "$WORK/demo")
expect "$out" "Kayıtlı gün: 35" "status: 35 gün"
expect "$out" "Burger Yiyelim · Tuzla Marina" "status: şube adı"
out=$("$TOOL" report --data-dir "$WORK/demo" --from 01.08.2026 --to 31.08.2026)
expect "$out" "Satış tutarı" "report: satış tutarı"
expect "$out" "Personel" "report: personel satırı"
expect "$out" "Prime cost" "report: prime cost satırı"
expect "$out" "Fiyat artışı" "report: fiyat artışı uyarısı"
expect "$out" "Açık sipariş        : 1" "report: açık sipariş"

# 3) Sipariş listesi
out=$("$TOOL" orders --data-dir "$WORK/demo" --date "$END")
expect "$out" "Sipariş listesi – 31.08.2026" "orders: başlık"
expect "$out" "• " "orders: en az bir kalem"

# 4) Excel'e aktar
"$TOOL" export-excel "$WORK/rapor.xlsx" --data-dir "$WORK/demo" --from 01.08.2026 --to "$END" >/dev/null
[ -s "$WORK/rapor.xlsx" ] || fail "Excel dosyası oluşmadı"
head -c 2 "$WORK/rapor.xlsx" | grep -q "PK" || fail "Excel dosyası zip değil"
ok "export-excel: geçerli .xlsx"

# 5) Aktarılan Excel'i boş bir klasöre geri al (Alımlar sayfası → geçmiş günler)
out=$("$TOOL" import-excel "$WORK/rapor.xlsx" --data-dir "$WORK/yeni" --dry-run)
expect "$out" "Geçmiş günler: 31" "import-excel --dry-run: 31 gün bulundu"
expect "$out" "hiçbir şey yazılmadı" "import-excel --dry-run: yazmadı"
[ ! -f "$WORK/yeni/envanter-verisi.json" ] || fail "dry-run veri dosyası oluşturmamalı"
out=$("$TOOL" import-excel "$WORK/rapor.xlsx" --data-dir "$WORK/yeni")
expect "$out" "31 yeni gün" "import-excel: 31 gün aktarıldı"
out=$("$TOOL" import-excel "$WORK/rapor.xlsx" --data-dir "$WORK/yeni")
expect "$out" "31 atlanan" "import-excel: tekrarında veri olan günlere dokunmadı"
out=$("$TOOL" status --data-dir "$WORK/yeni")
expect "$out" "Kayıtlı gün: 31" "status: geri alınan veri"

# 6) Bozuk veri: üzerine yazılmaz, hata koduyla çıkar
mkdir -p "$WORK/bozuk" && echo "{bozuk" > "$WORK/bozuk/envanter-verisi.json"
if "$TOOL" status --data-dir "$WORK/bozuk" >/dev/null 2>&1; then fail "bozuk veride hata vermeli"; else ok "bozuk veride hata kodu"; fi
ls "$WORK/bozuk" | grep -q "^bozuk-" || fail "bozuk dosya kenara alınmalı"
ok "bozuk dosya kenara alındı"

echo "Tüm komut satırı testleri geçti."
