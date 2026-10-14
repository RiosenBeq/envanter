# NextGen Envanter — Windows uygulaması

Mağaza bilgisayarı Windows ise bu uygulama kullanılır. Web panelini kendi penceresinde açar; sayım, satış aktarma
(ModPos dosyası dahil), sipariş, raporlar, stok kalemleri, reçeteler, ekip, ayarlar ve yönetim ekranlarının hepsi
panelden gelir. Panelde yayınlanan her yenilik uygulamada da görünür; ekranlar için uygulamayı güncellemek gerekmez:
panelin yeni sürümü yayınlanınca pencerenin üstünde **Yeni sürüm hazır · Yenile** çıkar (ya da **Dosya → Yenile**,
Ctrl+R), uygulama gece açık kalmışsa gün dönümünde, gönderilmemiş değişiklik yoksa panel kendiliğinden yenilenir. Gece
yarısı "bugün" açıksa panel yeni güne geçer ("Yeni gün başladı · Dünkü güne dön"). Uygulamanın içindeki tarayıcı motorunun (Electron/Chromium) güvenlik düzeltmeleri için yeni kurulum
dosyası çıktığında üzerine kurulur.

Tarayıcıda açmaya göre farkı:

- Başlat menüsünde ve masaüstünde kendi kısayolu, kendi penceresi ve simgesi vardır; istenirse Windows açılınca başlar.
- Patronun gönderdiği `envanter://` bağlantısına tıklamak uygulamayı bağlantı koduyla açar.
- İnternet kesilince boş sayfa yerine "Web paneline ulaşılamıyor" ekranı çıkar ve bağlantı gelince panel kendiliğinden
  geri açılır.
- Gönderilmemiş değişiklik varken pencere kapatılırsa uyarır.
- Panelde "Windows bilgisayarı" olarak görünür.

## Kurulum

1. GitHub'da **Actions → Windows** iş akışının son başarılı çalışmasını açın ve **Artifacts** bölümünden
   `NextGen-Envanter-Windows` dosyasını indirin (30 gün saklanır). Zip'in içinde
   `NextGen-Envanter-Kurulum-<sürüm>.exe` vardır.
2. Kurulum dosyasını çalıştırın. Dosya imzasız olduğu için Windows SmartScreen "Windows bilgisayarınızı korudu"
   diyebilir: **Ek bilgi → Yine de çalıştır**.
3. Kurulum tek tıklamadır ve yönetici izni istemez (yalnızca bu Windows kullanıcısına kurulur). Başlat menüsüne ve
   masaüstüne "NextGen Envanter" kısayolu eklenir. Kaldırmak için: **Ayarlar → Uygulamalar → NextGen Envanter →
   Kaldır**. Kaldırınca `envanter://` bağlantı kaydı ve "Windows açılınca başlat" kaydı da silinir; `ayarlar.json`
   klasörde kalır.

Yeni sürüm aynı şekilde indirilip üzerine kurulur; bağlantı ve ayarlar korunur.

## Şubeye bağlama (bağlantı kodu)

Kullanıcı adı, şifre ya da sunucu ayarı gerekmez:

1. Patron web panelinde **Yönetim → Kullanıcılar → Bilgisayar Bağla**'ya tıklar ve bir kod alır
   (ör. `7KQ2-M9XP-4TRA-HW3D`).
2. Mağaza bilgisayarında ya patronun gönderdiği "Bu bilgisayardaki uygulamada aç" bağlantısına tıklanır (uygulama kod
   dolu olarak açılır; bağlantı uygulamanın kendi penceresindeki panelden tıklanırsa da aynı pencerede açılır) ya da
   uygulamada **Yardım → Bağlantı koduyla bağlan** seçilip kod yazılır.
3. "Bu bilgisayarı şubeye bağla" ile bağlantı tamamlanır.

Kod tek kullanımlıktır: bilgisayar bağlandığında geçersiz olur. Bilgisayarı şubeden ayırmak için patron listeden
"Bağlantıyı kaldır"ı seçer.

## İnternet kesilince

- Bilgisayarda yapılan ve henüz gönderilmemiş değişiklikler bu bilgisayarda saklanır, internet gelince gönderilir.
- Panel hiç açılamazsa "Web paneline ulaşılamıyor" ekranı nedenini (internet yok, sunucu yanıt vermiyor vb.) gösterir;
  15 saniyede bir ve internet geri geldiği anda kendiliğinden yeniden dener. **Yeniden dene** düğmesi hemen dener.
  Panel, kaldığı sayfadan (bekleyen bağlantı kodu dahil) açılır.
- Gönderilmemiş değişiklik varken pencere kapatılırsa "Gönderilmemiş N değişiklik var…" sorusu çıkar: **Kapat** ya da
  **Vazgeç**. Windows kapanırken ya da oturum kapanırken soru sorulmaz (değişiklikler zaten saklıdır).

## Sayfa çökerse

- Paneli gösteren işlem bir kez çökerse panel hemen yeniden yüklenir; kısa sürede yine çökerse "Web paneline
  ulaşılamıyor" ekranı çıkar ve 15 saniyede bir yeniden denenir.
- O ekran da gösterilemiyorsa (ör. virüs programı ya da Windows kod bütünlüğü denetimi uygulamanın sayfa işlemini
  engelliyorsa) uygulama durmadan yeniden başlatmaz: "Panel bu bilgisayarda gösterilemiyor" uyarısı bir kez çıkar ve
  15 sn, 30 sn, 1 dk … (en çok 5 dk) aralıklarla yeniden denenir. **Yeniden dene** hemen dener. Sayfa bir dakika
  sorunsuz çalışınca sayaç sıfırlanır.

## Windows açılınca başlatma

**Dosya → Windows açılınca başlat** işaretlenince uygulama oturum açıldığında kendiliğinden açılır. İşaret kaldırılınca
bu da kalkar. Kayıt `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` altında `com.nextgen.envanter` adıyla durur
(Görev Yöneticisi → Başlangıç uygulamaları'nda görünür); uygulama kaldırılınca silinir, yeni sürüm üzerine kurulunca
korunur.

## Panel adresini değiştirme

Uygulama varsayılan olarak `https://envantersite-yo9n.vercel.app` adresini açar. Başka bir adres için şu dosya
oluşturulur (Not Defteri ile kaydetmek yeterli) ve uygulama yeniden başlatılır:

`%APPDATA%\NextGen Envanter\ayarlar.json`

```json
{ "panelAdresi": "https://envanter.ornek.com" }
```

- Not Defteri'nde "Farklı kaydet"te dosya türü "Tüm dosyalar" seçilmelidir; ad `ayarlar.json.txt` olmamalıdır.
- Yalnızca `https://` adresleri kabul edilir (`http://` yalnızca `127.0.0.1` ve `localhost` için).
- Dosya bozuksa ya da adres geçersizse uygulama varsayılan adresi kullanır; hata vermez.
- `ENVANTER_PANEL_URL` ortam değişkeni verilirse dosyadan önce gelir.
- Pencerenin boyutu ve konumu aynı klasördeki `pencere.json`'da tutulur (ekran çıkarıldıysa pencere ana ekrana gelir).
  Pencere taşınınca ya da boyutlanınca yarım saniye içinde, Windows kapanırken de hemen kaydedilir; akşam uygulama
  açıkken bilgisayar kapatılsa da ertesi gün aynı yerde açılır.

## Güvenlik

- Pencerede yalnızca panelin kendi adresi açılır. Başka `https://` bağlantılar (ör. WhatsApp), `mailto:` ve `tel:`
  varsayılan tarayıcıda ya da uygulamada açılır; `file:`, `javascript:`, `http://` ve diğer şemalar engellenir. "Yeni
  sekmede aç" istekleri de varsayılan tarayıcıya gider; uygulama ikinci pencere açmaz. Paneldeki `envanter://`
  bağlantıları dışarı gönderilmez, bağlan sayfası aynı pencerede açılır.
- Sayfa `contextIsolation`, korumalı alan (sandbox) ve kapalı `nodeIntegration` ile çalışır. Sayfaya yalnızca
  `window.envanterDesktop` açılır: `platform` (`"windows"`), `version` ve `setPendingCount(n)`.
- İzinlerden yalnızca pano (kod ve satış raporu yapıştırma) ve bildirimler verilir; kamera, mikrofon, konum ve
  cihaz erişimi reddedilir.
- Electron desteği süren bir sürüme sabittir (44.7.0); desteği biten sürümler Chromium güvenlik düzeltmesi almaz.
  Uygulama kendini güncellemez: yeni Electron sürümüyle çıkan kurulum dosyası üzerine kurulur.
- Paketlenmiş uygulamada Electron sigortaları kapalıdır: `ELECTRON_RUN_AS_NODE`, `NODE_OPTIONS`, `--inspect` çalışmaz;
  uygulama kodu yalnızca `app.asar`'dan yüklenir. (`file://` ayrıcalığı açık kalır: çevrimdışı ekranı asar içinden
  `file://` ile açılır.)

## Geliştirme

Node 22.12 ya da üstü gerekir. Komutlar `windows/` klasöründe çalıştırılır:

```sh
npm ci                                              # bağımlılıklar
npx install-electron --no                           # Electron ikili dosyası (Electron 44'ten beri ayrı iner)
npm start                                           # uygulamayı geliştirme kipinde aç (varsayılan panel)
ENVANTER_PANEL_URL=http://127.0.0.1:3000 npm start  # yerel paneli aç
npm test                                            # birim testleri (node --test)
xvfb-run -a node test/smoke.mjs                     # Electron duman testi (Linux)
npm run dist                                        # Windows kurulum dosyası → dist/
```

- `npm test`: panel adresi ve `ayarlar.json`, pencere konumu, `envanter://` bağlantıları, gezinme kuralı, bağlantı
  kodu (ortak vektörlerin hepsi), paket ayarları ve çevrimdışı sayfasının CSP özetleri. Not: Node 22'de
  `node --test test/` klasörü dosya sanıp hata verdiği için betik `node --test "test/*.test.js"` kullanır.
- `test/fixtures/pair-vectors.json`, Mac çekirdeğindeki (`Tests/EnvanterCoreTests/Fixtures/`) ve web panelindeki
  (`test/fixtures/`) dosyayla bayt bayt aynıdır; kod ayrıştırma kuralı `src/paircode.js`'tedir.
- Duman testi uygulamayı gerçek Electron ile sahte bir panele karşı açar ve şunları dener: pencere ayarları,
  `window.envanterDesktop`, Türkçe menü, dış bağlantılar, izinler, paneldeki ve ikinci örneğe verilen bağlantı kodu,
  çevrimdışı ekranı ve kendiliğinden dönüş, kapatma uyarısı, `ayarlar.json`, pencere konumunun hatırlanması
  (taşıyınca ve Windows kapanırken), "Vazgeç" denen bağlantının unutulması, art arda çökmede bekleyerek yeniden
  deneme. Kapanmayan uygulama 10 sn sonra sonlandırılır; test takılmaz. Playwright'ın
  `_electron` sürücüsünü kullanır; tarayıcı indirmez. root olarak çalışırken `--no-sandbox` kendiliğinden eklenir.
  `ENVANTER_USER_DATA` ortam değişkeni uygulamanın veri klasörünü değiştirir (testler kendi geçici klasörünü kullanır).
- `npm run dist` Windows'ta çalıştırılır (CI: `.github/workflows/windows.yml`, `windows-latest`). Linux'ta kurulum
  dosyasının NSIS adımı Wine ister; `npx electron-builder --win nsis --x64 --publish never
  -c.win.signAndEditExecutable=false` yalnızca `dist/win-unpacked/` klasörünü üretir.
- `build/installer.nsh` kaldırıcıya eklenir (`nsis.include`): bu kurulumu gösteren `envanter://` ve otomatik başlatma
  kayıtlarını siler; güncellemede (`--updated`) hiçbir şeye dokunmaz.
- Geliştirme kipinde (`npm start`) "Windows açılınca başlat" ayrı bir kayıt (`com.nextgen.envanter.gelistirme`,
  electron.exe + uygulama klasörü) kullanır; kurulu uygulamanın kaydını değiştirmez.
- Kurulum dosyası imzasızdır. İmza sertifikası alınırsa electron-builder'ın `CSC_LINK` / `CSC_KEY_PASSWORD` ortam
  değişkenleriyle imzalanabilir; SmartScreen uyarısı da o zaman kalkar.

Dosyalar: `src/main.js` (pencere, menü, bağlantılar, çevrimdışı ekranı, kapatma uyarısı), `src/preload.js`
(`window.envanterDesktop`), `src/config.js` (panel adresi, pencere konumu), `src/links.js` (`envanter://` ve gezinme
kuralı), `src/paircode.js` (bağlantı kodu), `src/offline.html` (çevrimdışı ekranı), `build/icon.png` (Mac ikonuyla
aynı tasarım, 512×512), `build/installer.nsh` (kaldırıcı temizliği).
