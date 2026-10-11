# NextGen Envanter

Restoranlar için macOS **envanter yönetimi** uygulaması: stok kalemleri, reçeteler, satış raporu aktarımı, günlük sayım ve fark, sipariş ve ekip. Excel'deki envanter dosyasının (Envanter, KOD, Alımlar, Özet sayfaları ve makroları) yaptığı işi otomatik yapar: ModPos satış raporunu reçetelerle hammaddeye çevirir, günlük sayımla karşılaştırır ve farkı **miktar olarak** (adet / kg) gösterir. Şirket içi kullanım içindir (App Store'da yayınlanmaz).

Uygulama şubedeki bilgisayara kurulur; patron ve müdürler aynı veriyi **web panelinden** ([envantersite](https://github.com/RiosenBeq/envantersite)) her yerden, **anlık** izler. Para hesabı (birim maliyet, food cost, personel maliyeti, prime cost, hedefler) yoktur.

> Ekran görüntülerindeki rakamlar `EnvanterTool demo` ile üretilmiş **örnek verilerdir** ("Burger Yiyelim · Tuzla Marina" demo şubesi).

![Genel Bakış](docs/screenshots/01-overview.png)

## Özellikler

| Ekran | Ne işe yarar |
| --- | --- |
| **Genel Bakış** | İlk açılışta (henüz günlük kayıt yokken) **başlangıç kartı**: web paneline bağlanma, yedekten (ya da eski Excel dosyasından) geri yükleme, stok kalemleri ve reçeteler, ilk satış raporu ve sayım. Seçili günün sayım ilerlemesi, satış raporu durumu, tolerans dışı ve **fazla çıkış** olan kalemler, kritik seviyenin altındakiler ve açık siparişler. Son 30 günün **takip şeridi** (yeşil: sayım tam, fark az · sarı: eksik sayım ya da sayılanların %10'unda fark · kırmızı: sayılanların %20'sinde fark) ve son 14 günün sorunlu kalem grafiği. *Dikkat* listeleri: tolerans dışı farklar, kritik seviyenin altındaki stoklar, açık siparişler ve reçetesi tanımsız satışlar. |
| **Günlük Sayım** | Açılış (önceki günden otomatik), Gelen, Transfer, Kapanış girişi. Satılan/Zayi reçeteden otomatik gelir; Fiili Tüketim ve Fark hesaplanır. Tolerans ve kritik seviyeye göre renkler, *Sayılmayan / Sorunlu* filtresi. Gün notu, sayımı yapan kişi (*Sayan*: ekipten seçilir), **günü kapatma kilidi** (sayım girilmemiş gün kapatılamaz), hareketsiz kalemleri tek tıkla doldurma ve satır bazında hesap dökümü. |
| **Satış Dökümü** | ModPos satırlarını *reçeteli / stok etkisi yok / reçete tanımsız* olarak ayırır. Her satırın stoktan düşürdüğü miktarlar görünür; reçete tek tıkla tanımlanır. |
| **Sipariş** | Öneri = son 7/14/30 günün ortalama tüketimi × istenen gün + kritik seviye − mevcut stok − **siparişte bekleyen**. Mevcut stok, son sayıma sonraki günlerin gelen/transfer ve satışları eklenerek tahmin edilir. Öneriden **satın alma siparişi** oluşturulur; teslim alınınca miktarlar o günün *Gelen* sütununa işlenir. Liste WhatsApp için kopyalanabilir veya Excel'e aktarılabilir. |
| **Raporlar** | *Dönem Özeti:* dönem toplamları (ilk açılış, gelen, net transfer, satılan, zayi, fiili tüketim, fark, **fazla çıkış**) ve kalem bazında günlük fark grafiği (tolerans bandıyla). *Kalem Analizi:* beklenen ve fiili tüketim, günlük fark ve stok seviyesi. |
| **Reçeteler** | Hazır reçeteler; hammadde ekleme/çıkarma, başka üründen kopyalama. |
| **Stok Kalemleri** | Birim, reçete birimi ve katsayı, **kritik seviye**, **tolerans (± adet/kg)**; sıralama ve gizleme. |
| **Ekip** | **Eleman ekleme**, düzenleme, pasif yapma ve silme (ad, görev, telefon, işe giriş/çıkış, not). Sayımı yapan kişi ekipten seçilir. Patron web paneline bağlıyken **Kullanıcılar** bölümünden **hesap oluşturur** (e-posta ya da yalnızca kullanıcı adıyla, geçici şifreyle), yetki değiştirir, şifre belirler ve şubeden çıkarır; hesap bir ekip üyesine bağlanabilir. |
| **Ayarlar ve Veri** | Şube adı, sipariş varsayılanları, **web paneli ile eşitleme** (bkz. aşağıda), otomatik kayıt ve yedekler, yedek dosyası, Excel'e aktarım, **sayım formu** ve eski Excel dosyasından içe aktarım. |
| **Nasıl Kullanılır?** | Başlarken, adım adım günlük iş akışı, notlar ve ipuçları, kısayollar ve aranabilir **terimler sözlüğü**. |

Diğer:
- **Terim açıklamaları:** tolerans, fazla çıkış, fiili tüketim gibi terimlerin yanındaki ⓘ işaretinin üzerine gelince kısa açıklama çıkar, tıklayınca ayrıntılı açıklama açılır.
- **Liquid Glass tasarım:** macOS 26'da Apple'ın yerel Liquid Glass yüzeyleri; macOS 14–15'te aynı yüzeyler buzlu cam malzemesiyle çizilir.
- **Geri al / Yinele** (⌘Z / ⇧⌘Z) tüm veri değişikliklerinde çalışır.
- **Kayıt ve yedek:** Otomatik kayıt yapılır, kayıt durumu yan menüde görünür. Günlük yedekler son 30 günü kapsar ve riskli işlemlerden önce anlık kopya alınır. Dosya bozulursa en son yedekten otomatik dönülür; o da okunamazsa bozuk dosya kenara alınır, üzerine yazılmaz.
- **Satış raporu:** `.xlsx`, `.csv` ve `.txt` (UTF-8, UTF-16, Windows-1254) dosyaları ya da pano kabul edilir; dosya hangi ekranda olursa olsun pencereye sürüklenip bırakılabilir. Raporda *Tutar* sütunu varsa yok sayılır.
- **Excel'e aktarım:** Eski *Alımlar* sayfasıyla aynı sütun düzeni kullanılır (pivot tablolar çalışmaya devam eder). Ek olarak Özet, Günlük Durum, Notlar ve Ekip sayfaları yazılır.

### Kısayollar

| Kısayol | İşlem |
| --- | --- |
| ⌘O / ⌘⇧V | Satış raporu aktar / panodan yapıştır |
| ⌘E | Günü Excel'e aktar |
| ⌘[ / ⌘] / ⌘T | Önceki gün / sonraki gün / bugün |
| ⌘L | Günü kapat / kilidi aç |
| ⌘1 … ⌘8 | Genel Bakış, Günlük Sayım, Satış Dökümü, Sipariş, Raporlar, Reçeteler, Stok Kalemleri, Ekip |
| ⌘, | Ayarlar ve Veri |
| ⌘Z / ⇧⌘Z | Geri al / yinele |

## Ekran görüntüleri

Görüntüler CI'da, uygulama `EnvanterTool demo` ile üretilen örnek veriyle çalıştırılarak otomatik alınır; *İlk açılış* görüntüsü boş bir veri klasörüyle alınır.

| | |
| --- | --- |
| ![Günlük Sayım](docs/screenshots/02-daily.png) **Günlük Sayım** | ![Satış Dökümü](docs/screenshots/03-sales.png) **Satış Dökümü** |
| ![Sipariş](docs/screenshots/04-orders.png) **Sipariş** | ![Raporlar](docs/screenshots/05-reports-summary.png) **Raporlar · Dönem Özeti** |
| ![Kalem Analizi](docs/screenshots/06-reports-item-patates.png) **Raporlar · Kalem Analizi** | ![Reçeteler](docs/screenshots/07-recipes-11101.png) **Reçeteler** |
| ![Stok Kalemleri](docs/screenshots/08-items.png) **Stok Kalemleri** | ![Ekip](docs/screenshots/09-team.png) **Ekip** |
| ![Ayarlar](docs/screenshots/10-backup.png) **Ayarlar ve Veri** | ![Nasıl Kullanılır](docs/screenshots/11-help.png) **Nasıl Kullanılır?** |
| ![İlk açılış](docs/screenshots/12-welcome.png) **İlk açılış (boş veri): başlangıç kartı** | |

## Kurulum (şirket içi)

1. Bir Mac'te (macOS 14+, Xcode 15+ veya Swift 5.9+ araç zinciri) derleyin:
   ```bash
   ./Scripts/build_app.sh          # build/NextGen Envanter.app + build/NextGen-Envanter-2.0.zip
   ./Scripts/build_app.sh --dmg    # ayrıca .dmg
   ```
   Hazır paket, GitHub Actions'taki her başarılı çalışmanın **NextGen-Envanter** artifact'ında da bulunur.
2. `.zip`'i diğer Mac'lere kopyalayın, `NextGen Envanter.app`'i *Uygulamalar* klasörüne taşıyın.
3. Uygulama ad-hoc imzalıdır. İlk açılışta macOS uyarı verirse Finder'da uygulamaya sağ tıklayıp **Aç** deyin ya da:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/NextGen Envanter.app"
   ```

Veriler `~/Library/Application Support/Envanter/` altında tutulur (`envanter-verisi.json` ve `Yedekler/`). Uygulamayı silmek veya güncellemek verilere dokunmaz. Başka bir klasör kullanmak için `ENVANTER_DATA_DIR` ortam değişkeni verilebilir.

**Eski sürümden geçiş:** Eski sürümlerin veri dosyası olduğu gibi açılır. Maliyet, fiyat geçmişi, ücret ve vardiya alanları artık kullanılmaz: bu Mac'teki dosyadan ilk kayıtta düşer (önceki hali `Yedekler/` altındaki günlük yedeklerde kalır), bulutta ise silinmez. Eski "sayım yapanlar" listesi kendiliğinden **Ekip**'e taşınır. Yeni sürümün aldığı yedek eski sürümde açılmayabilir.

## Web paneli ve anlık eşitleme

Mac uygulaması, patron ve müdürlerin kullandığı **web paneliyle** ([envantersite](https://github.com/RiosenBeq/envantersite)) Supabase üzerinden **anlık** eşitlenir.

- **Kim ne kullanır:** Personel günlük işleri (sayım, satış raporu aktarımı, gün notu) bu uygulamada yapar. Patron ve müdürler web panelinden her yerden izler (pano, raporlar, uyarılar, şube karşılaştırması, kimin neyi değiştirdiği, **Mac'in şu an açık olup olmadığı**) ve gerektiğinde müdahale eder (sayım düzeltme, sipariş onayı ve teslim alma, stok kalemleri ve reçeteler, ekip, kullanıcılar ve yetkiler).
- **Anlık:** Mac'te yapılan değişiklik 2 sn içinde gönderilir; web panelinde yapılan değişiklik Mac'e Supabase Realtime ile hemen gelir (bağlantı kurulamazsa 60 sn'de bir eşitlenir). Web panelinde "Mac çevrimiçi" göstergesi Mac açıkken yanar.
- **Bağlanma:** *Ayarlar ve Veri > Web paneli ile eşitleme* kartında web paneli hesabının **e-postası ya da kullanıcı adı** ve şifresiyle **Bağlan**. Hesabı patron *Ekip > Kullanıcılar* bölümünde (Mac) ya da web panelinde *Yönetim → Kullanıcılar* ekranında **Hesap oluştur** ile açar: e-posta gerekmez, kullanıcı adı yeter (ör. "Ayşe Yılmaz" → giriş adı `ayse.yilmaz`). Şifre unutulursa aynı yerde **Şifre belirle** ile yeni geçici şifre verilir. Sunucu adresi ve publishable key uygulamada hazırdır (publishable key herkese açık bir anahtardır; yetkiyi veritabanındaki RLS kuralları uygular). Farklı bir Supabase projesi için *Gelişmiş* bölümünden değiştirilebilir.
  - Hesap birden çok şubeye üyeyse şube seçilir. Hiç şube yoksa (ilk kurulum) işletme adıyla yeni bir şube açılır ve hesap patron olur. Şubeye eklenmemiş bir hesapla bağlanılırsa patronun eklemesi gerektiği söylenir.
  - **İlk bağlantı:** Bulut boşsa bu Mac'teki her şey yüklenir. Bu Mac yalnızca varsayılan reçetelerle duruyorsa buluttaki veri indirilir. İki tarafta da veri varsa sorulur: *Buluttakini İndir* (bu Mac'teki veri önce `Yedekler/bulut-indirme-oncesi-….json` olarak saklanır) ya da *Bu Mac'tekini Yükle* (buluttaki önceki hal `Yedekler/bulut-yukleme-oncesi-….json` olarak saklanır).
  - **Şube değiştirme:** *Şube Değiştir…* ile başka şube seçilir. Şube boşsa sorulur: *Yalnızca Tanımları Kopyala* ya da *Her Şeyi Kopyala*.
- **Roller:** *Patron* her şeyi yönetir (kullanıcılar, yetkiler, şube adı dahil), *Müdür* tüm verileri değiştirir, *Personel* yalnızca günlük kayıtları (sayım, satış, not) değiştirir ve günü kapatabilir. Personel hesabıyla bağlı Mac'te stok kalemleri, reçeteler, ekip, siparişler ve ayarlar salt okunurdur. Rol web panelinde değiştirilirse Mac çıkış yapmadan güncellenir.
- **Kapatılmış gün:** Kapatılmış (kilitli) günü yalnızca patron ve müdür değiştirebilir, kilidini açabilir ya da silebilir; sunucu da personelin bu yazmalarını reddeder.
- **Çakışmalar:** Veri belgelere bölünür (stok kalemleri, reçeteler, ayarlar, ekip, siparişler ve her gün ayrı bir belge). Aynı belge iki yerde değiştirilirse alan bazında birleştirilir: aynı güne farklı kalemlerin sayımı girilirse ikisi de korunur; aynı alan iki yerde değiştirilirse son gönderilen geçerli olur. Mac'in bilmediği alanlar (eski sürümlerin maliyet ve vardiya alanları dahil) kaybolmaz.
- **Değişiklik geçmişi:** Her gönderim web panelindeki geçmişe kısa bir özetle yazılır, ör. "09.10.2026 sayımı: 90 Gr kapanış 120 → 110", "09.10.2026 satış raporu aktarıldı (121 satır)", "Ekip: Ayşe eklendi".
- **Geri al:** ⌘Z yalnızca kendi yaptığınız değişikliğin alanlarını geri alır; arada web panelinden gelen değişiklikler korunur.
- **Oturum ve gizlilik:** Şifre saklanmaz. Oturum anahtarları ve eşitleme durumu veri klasöründeki `esitleme.json` dosyasında yalnızca kullanıcının okuyabileceği izinle (0600) tutulur; yedeklere girmez. *Çıkış Yap* eşitlemeyi durdurur, bu Mac'teki veriyi silmez ve şube eşleşmesini korur. *Çıkış Yap ve Bu Mac'i Şubeden Ayır* eşleşmeyi de siler.
- Otomatik test (`ENVANTER_SELFTEST`) ve ekran görüntüsü (`ENVANTER_SNAPSHOT_DIR`) modlarında eşitleme kapalıdır.

İki istemcinin uyduğu sözleşme (tablolar, roller, RPC'ler, eşitleme algoritması, merge3, anlık bağlantı, kullanıcı adı) [docs/SYNC.md](docs/SYNC.md) dosyasındadır. Eşitleme kodu `Sources/EnvanterCore` altında platformdan bağımsızdır (`CloudSync.swift`, `CloudSyncEngine.swift`, `SupabaseAPI.swift`, `CloudMembersAPI.swift`, `Realtime.swift`, `Accounts.swift`, `Team.swift`, `JSONValue.swift`, `ChangeSummary.swift`); uygulama tarafı `CloudSyncController.swift`, `CloudSyncView.swift` ve `TeamView.swift`'tir.

```bash
swift test --filter CloudSyncTests    # merge3 vektörleri, belge dönüşümü, bellek içi sunucuyla iki istemci, istekler ve oturum yenileme
swift test --filter RealtimeTests     # anlık bağlantı protokolü (sahte soketle)
# Gerçek Supabase bileşenleriyle (envantersite/scripts/local-supabase ortamı çalışırken):
ENVANTER_SUPABASE_TEST_URL=http://127.0.0.1:54321 swift test --filter IntegrationTests
```

## Komut satırı aracı

Paketin içinde `Contents/MacOS/EnvanterTool` olarak gelir (uygulama kapalıyken kullanın):

```bash
EnvanterTool status                                      # veri özeti
EnvanterTool import-excel 01.08.xlsm [--overwrite] [--dry-run]
EnvanterTool export-excel rapor.xlsx [--from 01.08.2026] [--to 31.08.2026]
EnvanterTool orders [--date 09.10.2026] [--days 14] [--cover 3]   # sipariş listesi (metin)
EnvanterTool report [--from 01.08.2026] [--to 31.08.2026]         # envanter raporu: sorunlu kalemler, fazla çıkış, kritik seviye, açık sipariş
EnvanterTool demo --data-dir ~/Desktop/demo [--days 35]           # eğitim için örnek veri
```

Demo veriyle uygulamayı açmak (gerçek veriye dokunmaz):

```bash
ENVANTER_DATA_DIR=~/Desktop/demo "/Applications/NextGen Envanter.app/Contents/MacOS/Envanter"
```

## Hesaplama

- **Fiili Tüketim** = Açılış + Gelen + Gelen Transfer − (Giden Transfer + Kapanış)
- **Fark** = (Satılan + Zayi) − Fiili Tüketim. Negatif fark, satışlara göre fazla stok çıktığını gösterir.
- **Fazla çıkış** = tolerans dışı negatif farkı olan günlerin miktarı (az çıkışlarla mahsup edilmez); tüm ekranlarda aynı tanım.
- **Takip şeridi:** sayılanların en az %20'sinde tolerans dışı fark → kırmızı; en az %10'unda ya da sayım eksikse → sarı; diğer → yeşil.
- **Sipariş önerisi** = ortalama günlük tüketim × gün + kritik seviye − mevcut stok (son sayım + sonraki hareketler) − siparişte bekleyen (adet yukarı tam sayıya, kg 0,1'e yuvarlanır)

## Geliştirme

```
Sources/EnvanterCore   Platformdan bağımsız iş mantığı (motor, ekip, satın alma, eşitleme, anlık bağlantı, Excel/ZIP okuma-yazma, kayıt)
Sources/Envanter       SwiftUI uygulaması (yalnızca macOS; Glass.swift: Liquid Glass yüzeyleri)
Sources/EnvanterTool   Komut satırı aracı
Tests/EnvanterCoreTests
Scripts/               build_app.sh (paket), make_icon.swift (ikon), e2e_cli.sh (komut satırı uçtan uca testi)
```

```bash
swift test                                  # macOS veya Linux (çekirdek testleri)
swift build                                 # macOS'ta uygulama dahil
./Scripts/e2e_cli.sh .build/debug/EnvanterTool
ENVANTER_SELFTEST=1 ".build/debug/Envanter" # uygulama içi sistem testi (geçici klasörde, çıkış kodu 0 = başarılı)
```

CI (`.github/workflows/ci.yml`) şu adımları çalıştırır:
- **Linux:** çekirdek testleri ve komut satırı uçtan uca testi.
- **macOS:** uygulamanın derlenmesi, testler, dağıtım paketi, komut satırı testi ve **uygulama içi sistem testi** (sayım, satış aktarımı, geri al/yinele, tolerans, gün kilidi, ekip, sipariş teslim alma, Excel ve diske kayıt gerçek uygulama durumu üzerinden doğrulanır).
- **Ekran görüntüleri:** demo veriyle macOS'ta otomatik alınır.

## Yol haritası / öneriler

- **Şubeler arası transfer:** Transferin iki şubeye birden işlenmesi.
- **ModPos entegrasyonu:** Raporu elle almak yerine ModPos'un dışa aktarım klasörünü izleyip her sabah otomatik içe aktarma.
- **Fatura okuma:** Tedarikçi faturasının fotoğrafından/PDF'inden kalem ve miktarları okuyup siparişi otomatik teslim alma.
- **iPad / iPhone ile sayım:** Depoda telefonla (barkod/QR ile) sayım yapıp anlık olarak Mac'e ve web paneline aktarma.
- **Hesap güvenliği:** Patron hesapları için iki adımlı doğrulama (Supabase MFA).
- **Bildirimler:** Kritik seviyenin altına düşen kalemler ve fazla çıkış olan günler için günlük e-posta/WhatsApp özeti. `EnvanterTool report` ve `orders` bugün de bir cron/launchd göreviyle kullanılabilir.
- **Yarı mamul reçeteleri:** Soslar ve hazırlıklar için alt reçeteler (reçete içinde reçete).
- **Kod imzalama:** Şirket bir Apple Developer hesabı alırsa uygulama Developer ID ile imzalanıp noter onayından geçirilebilir.
