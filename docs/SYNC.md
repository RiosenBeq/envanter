# Web paneli ve bulut eşitleme sözleşmesi

NextGen Envanter iki istemciden yönetilir:

- **Mac uygulaması** (bu depo): personelin günlük kullandığı uygulama. Sayım, satış aktarımı ve vardiya girişi buradan yapılır. Veri yerelde `envanter-verisi.json` olarak tutulur ve arka planda buluta eşitlenir.
- **Web paneli** ([RiosenBeq/envantersite](https://github.com/RiosenBeq/envantersite)): patron ve müdürlerin her yerden kontrol ettiği ve gerektiğinde müdahale ettiği panel. Raporlar, sayım düzeltme, sipariş, personel, maliyetler, kullanıcı yetkileri, şube karşılaştırması ve değişiklik geçmişi buradan yönetilir.

Ortak depolama **Supabase**'dir (Postgres + Auth + Row Level Security). İki istemci de Supabase'e doğrudan, kullanıcının oturumuyla bağlanır. Yetkiyi veritabanındaki RLS kuralları ve `security definer` fonksiyonlar uygular; istemcide gizli anahtar yoktur, yalnızca herkese açık *publishable key* kullanılır.

Bu belge iki istemcinin uyması gereken sözleşmedir. Değişiklik yapılırsa iki taraf birlikte güncellenmelidir.

## 1. Veri modeli

Bir **çalışma alanı** (workspace) bir şube/işletmedir. Verisi `AppData`'nın alanlarına karşılık gelen **belgelere** bölünür:

| Anahtar (`key`) | Gövde (`body`, JSON) | Swift tipi |
| --- | --- | --- |
| `items` | stok kalemleri dizisi | `[Item]` |
| `products` | reçeteli ürünler dizisi | `[Product]` |
| `settings` | ayarlar nesnesi | `AppSettings` |
| `employees` | personel dizisi | `[Employee]` |
| `orders` | satın alma siparişleri dizisi | `[PurchaseOrder]` |
| `day:YYYY-MM-DD` | o günün kaydı | `DayRecord` |

- JSON biçimi Swift `JSONEncoder` çıktısıyla aynıdır (`Persistence.encoder()`): `nil` alanlar yazılmaz, tarihler (`salesImportedAt`) ISO 8601 (`2026-08-01T10:15:00Z`), sayılar ondalık.
- Boşalan gün (`DayRecord.isEmpty` ve kilitli değil) silinir: `deleted = true`, `body = {}`. Katalog belgeleri (`items/products/settings/employees/orders`) silinmez.
- Okurken bilinmeyen alanlar korunmalıdır (ileriki sürüm alanları kaybolmasın). Web istemcisi belgeleri değiştirirken yalnızca bildiği alanlara dokunur.

## 2. Supabase şeması

Tablolar `public` şemasında `envanter_` önekiyle durur. Migration dosyası `envantersite/supabase/migrations/20261009120000_envanter.sql`'dir. Supabase GitHub entegrasyonu bu dosyayı `main`'e birleştirmede `postgres` rolüyle, tek işlem (transaction) içinde otomatik uygular. Dosya idempotenttir; tekrar uygulanması zarar vermez.

```
envanter_workspaces (id uuid PK, name text, created_at, created_by uuid)
envanter_members    (workspace_id uuid FK, user_id uuid FK auth.users, role text, email text, added_at)
                    PK (workspace_id, user_id); role ∈ owner | manager | staff
envanter_invites    (workspace_id uuid FK, email text (küçük harf), role text, invited_by uuid, created_at)
                    PK (workspace_id, email)
envanter_docs       (workspace_id uuid FK, key text, body jsonb, rev bigint, deleted bool,
                     updated_at timestamptz, updated_by uuid, client text)
                    PK (workspace_id, key); index (workspace_id, rev)
envanter_activity   (id bigserial PK, workspace_id uuid, user_id uuid, email text, at timestamptz,
                     client text, key text, summary text); index (workspace_id, id desc)
                    key = belge anahtarı ya da 'members' (patronun üyelik işlemleri: hesap açma,
                    şifre belirleme, davet, yetki değişikliği, şubeden çıkarma; belge değil,
                    client = null)
envanter_rev_seq    belge her yazıldığında rev = nextval (çalışma alanları arasında tekdüze artar)
```

### Roller

| Rol | Okuma | Yazma |
| --- | --- | --- |
| owner (patron) | hepsi | hepsi + kullanıcı/yetki yönetimi (hesap açma, şifre belirleme, davet) + şube adı |
| manager (müdür) | hepsi | tüm belgeler |
| staff (personel) | hepsi | yalnızca `day:*` (sayım, satış, vardiya, not); kapatılmış (kilitli) günü değiştiremez |

**Kapatılmış gün.** Kapatılan (kilitlenen, `"locked": true`) gün envanter geçmişini korur. Personel bir günü kapatabilir, ama sunucudaki güncel hali kilitli olan günü değiştiremez, kilidini açamaz ve silemez. Bunları yalnızca patron ve müdür yapabilir. Kural sunucuda `envanter_put` içinde uygulanır. İstemciler de aynı kuralı arayüzde gösterir: personel için kilitli gün salt okunurdur ve "Kilidi Aç" düğmesi yoktur.

Bir kullanıcı birden çok çalışma alanına (şubeye) üye olabilir. Patron tüm şubelerini tek hesaptan görür ve karşılaştırır.

### RLS

Üyeler kendi çalışma alanlarının `workspaces`, `members`, `docs` ve `activity` satırlarını okuyabilir. `invites` satırlarını yalnızca owner okuyabilir. Hiçbir tabloya doğrudan `insert/update/delete` izni yoktur; tüm yazmalar aşağıdaki RPC'lerle yapılır.

### RPC'ler

Hepsi `security definer` ve `set search_path = public, pg_temp` ile tanımlıdır. Çağıranı `auth.uid()` ile doğrular; yalnızca `authenticated` rolüne açıktır.

- `envanter_create_workspace(p_name text) returns uuid` — Şube açar ve çağıranı owner yapar. Yalnızca hiç şube yokken (ilk kurulum) ya da çağıran en az bir şubede owner ise izin verilir.
- `envanter_my_workspaces() returns table(id uuid, name text, role text)` — Önce `envanter_accept_invites()` çalışır.
- `envanter_accept_invites() returns integer` — Çağıranın e-postasına (`auth.jwt() ->> 'email'`, küçük harf) yapılmış davetleri üyeliğe çevirir ve sayısını döner. `auth.users` ekleme tetikleyicisi de aynı işi yapar. Patronun açtığı ya da şifresini belirlediği hesaplar (`raw_app_meta_data.envanter_managed_by`) davetleri kendiliğinden kabul etmez (e-posta sahipliği kanıtlanmamıştır, şifreyi o patron bilir); başka şubenin patronu böyle bir hesabı yeniden davet ederek (hesap var → doğrudan üye) ekler.
- `envanter_rename_workspace(p_workspace uuid, p_name text)` — Yalnızca owner.
- `envanter_put(p_workspace uuid, p_key text, p_body jsonb, p_base_rev bigint, p_deleted boolean default false, p_client text default null, p_summary text default null) returns table(ok boolean, rev bigint, body jsonb, deleted boolean)`
  - Belge yoksa ve `p_base_rev = 0` ise eklenir.
  - Belge varsa ve `rev = p_base_rev` ise güncellenir (`rev = nextval`).
  - Aksi halde yazılmaz: `ok = false` ve sunucudaki güncel `rev/body/deleted` döner (çakışma).
  - Rol yetkisi yoksa hata verir. Anahtar biçimi ve gövde tipi doğrulanır: `items/products/employees/orders` dizi, `settings` ve `day:*` nesne olmalıdır.
  - Kapatılmış gün: çağıran staff ise ve sunucudaki güncel gövde kilitliyse (`body -> 'locked' = true`, silinmemiş) değişiklik, kilit açma ve silme `42501` "Kapatılmış günü yalnızca müdür veya patron değiştirebilir." ile reddedilir. Aynı gövdeyi yeniden yazmak serbesttir. Bu denetim rev karşılaştırmasından **sonra** yapılır. Eski `p_base_rev` ile yazan istemci önce olağan çakışmayı (kilitli gövdeyle) alır. Bu yüzden `42501` alan istemcinin `base`'i her zaman sunucudaki kilitli haldir. İstemci o anahtar için `base`'i geri yükler ("sunucu kazanır"), kullanıcıya bir kez bildirir ve yeniden denemez. Yeni gün eklemek ve açık günü kapatmak personel için serbesttir. Boolean olmayan `locked` değerleri kilit sayılmaz.
  - Başarılı her yazma `envanter_activity`'e bir satır ekler. Özet metni (`p_summary`) istemci üretir; boşsa "güncellendi" yazılır. Örnek: "09.10.2026 sayımı: 90 Gr kapanış 120 → 110".
- `envanter_invite(p_workspace uuid, p_email text, p_role text)` — Yalnızca owner. Kullanıcı zaten kayıtlıysa doğrudan üye yapılır, değilse davet kaydedilir (kayıt olunca otomatik üye olur). Sonuç olarak `'member' | 'invited'` döner.
- `envanter_cancel_invite(p_workspace uuid, p_email text)` — Yalnızca owner.
- `envanter_set_role(p_workspace uuid, p_user uuid, p_role text)` — Yalnızca owner. Son owner düşürülemez.
- `envanter_remove_member(p_workspace uuid, p_user uuid)` — Yalnızca owner. Son owner silinemez. Rol denetimi her istekte üyeliğe bakar; çıkarılan üyenin erişimi hemen kesilir.
- `envanter_members_list(p_workspace uuid) returns table(user_id uuid, email text, role text, added_at timestamptz, pending boolean, can_set_password boolean)` — Üyeler ve bekleyen davetler. Davetleri yalnızca owner görür. `can_set_password`: çağıran (owner) bu üyenin şifresini `envanter_set_member_password` ile belirleyebilir mi (owner olmayanlar ve davetler için hep `false`).
- `envanter_create_account(p_workspace uuid, p_email text, p_password text, p_role text) returns text` — Yalnızca owner. E-posta gerektirmeden hesap açar (Supabase'in yerleşik e-postası yalnızca organizasyon ekibine ulaşır; özel SMTP yoksa davet/onay e-postası gelmez). E-postayla hesap yoksa e-postası onaylı, verilen şifreli bir hesap açılır (`auth.users` + `auth.identities`), `p_role` ile üye yapılır ve `'created'` döner; e-postası onaylı hesap varsa `envanter_invite` gibi üye yapılır, şifresine dokunulmaz ve `'member'` döner (farklı rolle zaten üyeyse `23505`). Hesap var ama e-postası onaylanmamışsa (kişi kendisi kayıt olmuş, doğrulama e-postası gelmemiş): çağıran şifresini belirleyebiliyorsa (`envanter_set_member_password` kuralları) hesap verilen şifreyle açılır, e-postası onaylanır, üye yapılır ve `'created'` döner; belirleyemiyorsa hiçbir şey değişmez ve `'unconfirmed'` döner. Şifre en az 8 karakter, en fazla 72 bayt (`22023`). Bu e-postaya bu şubede ve çağıranın patronu olduğu şubelerde bekleyen davetler kapanır; başka patronların davetleri beklemede kalır.
- `envanter_set_member_password(p_workspace uuid, p_user uuid, p_password text)` — Yalnızca owner. Üyenin şifresini belirler (eski şifre hemen geçmez), onaylanmamış e-postasını onaylar ve oturumlarını yenilenemez yapar (yenileme jetonları silinir; elde kalan erişim anahtarı süresi dolana kadar, varsayılan 1 saat, geçerlidir; erişimi hemen kesmek için `envanter_remove_member`). Hedef bu şubenin üyesi olmalı (`22023`), çağıranın kendisi olmamalı (`22023`; kendi şifresi `PUT /auth/v1/user` ile değişir), hiçbir şubede owner olmamalı ve üye olduğu her şubenin owner'ı çağıran olmalı (`42501`; başka bir patronun çalışanının hesabını ele geçirmeyi önler).
- Patronun üyelik işlemleri (`envanter_create_account`, `envanter_set_member_password`, `envanter_invite`, `envanter_cancel_invite`, `envanter_set_role`, `envanter_remove_member`) bir şey değiştirdiyse `envanter_activity`'e `key = 'members'` satırı yazar: "Hesap oluşturuldu: x (Personel)", "Hesap açıldı (doğrulanmamış kayıt): x (Personel)", "Mevcut hesap şubeye eklendi: x (Müdür)", "Davet edildi: x (Personel)", "Davetin yetkisi değişti: x (Personel → Müdür)", "Davet iptal edildi: x (Müdür)", "Yetki değişti: x (Müdür → Personel)", "Şubeden çıkarıldı: x (Personel)", "Şifre belirlendi: x; eski şifresi geçersiz, açık oturumları en geç 1 saat içinde kapanır". Şifre hiçbir yere yazılmaz.

### Hata kodları ve sınır durumlar

- Var olmayan belgeye sıfırdan farklı `p_base_rev` ile yazma: `ok = false`, `rev = 0`, `body = null`, `deleted = false` döner.
- Başarılı yazma kaydedilen gövdeyi döner (silinmişse `{}`).
- Yetki hatası: SQLSTATE `42501`, HTTP 403 (oturum yoksa 401). Örnekler: üye değil ("Bu şubeye erişiminiz yok."), personelin katalog yazması ("Personel (staff) yalnızca gün kayıtlarını …"), personelin kapatılmış günü değiştirmesi ("Kapatılmış günü yalnızca müdür veya patron değiştirebilir.").
- Üye değil: `22023`, HTTP 400.
- Son owner kuralı: `P0001`, HTTP 400.
- Var olan üyeyi farklı rolle davet (ya da `envanter_create_account`): `23505`, HTTP 409. Aynı rolle davet `'member'` döner.
- Hesap / şifre: şifre kuralı ve kendi şifresini belirleme `22023` (HTTP 400); owner olmayan çağıran, owner hedef ya da başka patronun şubesinde de çalışan hedef `42501` (HTTP 403).
- `day:*` anahtarları gerçek takvim günü olmalıdır.
- `p_client` 100, `p_summary` 500 karakterle kırpılır.
- Kilitli ama başka verisi olmayan gün silinmez (Mac'teki `isEmpty && !isLocked` kuralı). `salesImportedAt` kesirli saniye içermez (`2026-08-01T10:15:00Z`), çünkü Mac'in ISO 8601 çözücüsü kesirli saniyeyi kabul etmez.

### Okuma ve canlı güncelleme

**Okuma (pull):**
`GET /rest/v1/envanter_docs?workspace_id=eq.W&rev=gt.N&order=rev.asc&select=key,body,rev,deleted,updated_at,updated_by&limit=500`. Satırlar 500'lük sayfalarla okunur ve `N` her sayfada son `rev`'e ilerletilir.

**Canlı güncelleme:** `envanter_docs` ve `envanter_activity` tabloları `supabase_realtime` yayınına eklenir. Web paneli değişiklikleri anında görür. Mac uygulaması 60 saniyede bir ve her değişiklikten birkaç saniye sonra eşitler.

**Mac uygulaması isteği:**
- Giriş: `POST {URL}/auth/v1/token?grant_type=password` (başlık `apikey: <publishable key>`). Yanıttaki `access_token` ve `refresh_token` saklanır. Web paneliyle aynı e-posta ve şifre kullanılır (patronun panelden açtığı hesaplar dahil).
- Yenileme reddedilirse (ör. patron şifre belirledi, kullanıcı şifresini başka yerde değiştirdi) oturum düşmüş sayılır: kullanıcıdan yeniden giriş istenir, bekleyen değişiklikler korunur.
- Sonraki istekler: `apikey` başlığı ve `Authorization: Bearer <access_token>`.
- RPC: `POST {URL}/rest/v1/rpc/<ad>`. Süre dolunca `grant_type=refresh_token` ile yenilenir.

## 3. Eşitleme algoritması (iki istemci için aynı)

İstemci durumu:

- `lastRev`: görülen en büyük `rev`.
- `base[key] = { rev, body }`: o belgenin sunucudan son alınan/yazılan hali.
- `dirty`: yerelde değişmiş, henüz gönderilmemiş anahtarlar.

**Çek (pull).** `rev > lastRev` olan her satır için:
- Anahtar `dirty` değilse sunucu sürümü yerele uygulanır. `deleted` ise yerelden silinir.
- `dirty` ise `merged = merge3(base.body, local, remote)` yerele yazılır, anahtar `dirty` kalır.
- Her iki durumda `base = remote` olur ve `lastRev` ilerletilir.

**Gönder (push).** Her `dirty` anahtar için `envanter_put(key, local, base.rev ?? 0, deleted)` çağrılır:
- `ok`: `base = { rev, body: local }` olur ve anahtar `dirty`'den çıkar.
- Çakışma: `local = merge3(base.body, local, server.body)`, `base = server` olur ve en fazla 3 kez yeniden denenir.
- Kalıcı hata (`42501` yetki, `22023` doğrulama …): anahtar `dirty`'den çıkar, yerel hal `base.body` ile değiştirilir (sunucu kazanır; `base` yoksa yerelden silinir), kullanıcıya bir kez bildirilir. Yeniden denenmez.
- Mac: gün belgesinde `42501` yalnızca `base` kilitliyse (kapatılmış gün) "sunucu kazanır" ile sonuçlanır; sonraki anahtarların gönderimi aynı turda sürer. Kilitsiz gün için `42501` (ör. şubeden çıkarılma) çevrimdışı işi kaybetmemek için yerel veriyi geri almaz: hata gösterilir, anahtar `dirty` kalır. Çakışma sınırı aşılan anahtar da `dirty` kalır, diğer anahtarlar gönderilmeye devam eder.

**Yerel rol denetimi (Mac).** Personel hesabıyla tanım belgelerine (items, products, settings, employees, orders) ya da yerelde kapatılmış bir güne dokunan işlem uygulanmadan bütünüyle reddedilir (web'deki `applyMany` / `dayChangeAllowed` ile aynı). Yarısı gönderilip yarısı sunucuca geri alınan işlem veriyi bozardı (ör. teslim alma: Gelen gider, sipariş açık kalır). Hiç kalem sayılmamış gün kapatılamaz (Gün menüsü ⌘L dahil); personel günü onaydan sonra kapatır, çünkü kilidi yalnızca patron veya müdür açabilir.

**Rol güncellemesi (Mac).** Patronun yetki değişikliği oturumu kapatmaz. Mac şube listesini (`envanter_my_workspaces`) açılıştan sonraki ilk eşitleme turunda, en geç 5 dakikada bir, uygulama öne geldiğinde ve bir yazması yetki yüzünden reddedildiğinde yeniden okur. Rol ya da şube adı değiştiyse turun başında güncellenir: önce eski rolün yazamadığı, `dirty` olmayan ve `base`'den ayrışmış tanım belgeleri `base`'e döner (terfide eski tanımlar gönderilmez), sonra rol ve ad değişir. Bekleyen (`dirty`) değişikliklere dokunulmaz; personele alınan müdürün bekleyen tanım değişikliği gönderimde `42501` ile reddedilir ve sunucudaki hal geri gelir. Şube listede yoksa (şubeden çıkarılma) bir şey değişmez.

**İlk bağlantı (Mac).** Bulut boşsa her şey yüklenir. Yerel veri yalnızca varsayılan (seed) haldeyse buluttan indirilir. İkisi de doluysa kullanıcıya sorulur: "Buluttakini İndir" (yerel yedek alınır) ya da "Bu Mac'tekini Yükle". Personel yüklerken tanım belgelerinde sunucudaki hal geçerli olur; personel Mac'i ayrıca her eşitlemede `dirty` olmayan ve `base`'den ayrışmış tanım belgelerini `base`'e döndürür (rol müdüre yükselince eski tanımlar yerel değişiklik sanılıp gönderilmez).

**Şube değişimi (Mac).** Başka bir şubeyle eşleşmiş Mac'in yerel verisi o şubenindir. Verisi olan şubeye geçişte o şubenin verisi indirilir (yerel yedek alınır). Boş şubeye geçişte hiçbir şey kendiliğinden yüklenmez; sorulur: "Yalnızca tanımları kopyala" (items, products, settings; şube adı yeni şubenin adı olur, günler, personel ve siparişler kopyalanmaz) ya da "Her şeyi kopyala". Vazgeçilirse önceki şubeyle eşitleme sürer.

**Çıkış (Mac).** Çıkış yalnızca oturum anahtarlarını siler; şube eşleşmesi (`base`, `lastRev`, `dirty`, rol) korunur ve eşitleme durur. Aynı sunucuda yeniden girişte (başka hesapla da) aynı şube seçilirse kaldığı yerden devam edilir: `base`'den ayrışan belgeler `dirty` olur ve olağan çek/gönder (merge3) ile gönderilir; arada web panelinde yapılan değişiklikler ezilmez. Eşleşme yalnızca "Bu Mac'i şubeden ayır" ile silinir.

**Kayıt sırası (Mac).** Eşitleme yerel veriyi değiştirdiyse önce veri dosyası, sonra eşitleme durumu (`esitleme.json`) yazılır; veri yazılamazsa durum da yazılmaz. Böylece ilerlemiş `base` diskte eski veriyle kalmaz (yeniden açılışta eski belgeler güncel `base.rev` ile çakışmasız gönderilip web'deki değişikliği ezerdi). Veri ve durum kayıtlarının hepsi aynı seri kuyrukta, arka planda yazılır: arayüz kodlamayı beklemez ve sonradan kuyruğa giren bir durum kaydı, bekleyen veri yazmasının önüne geçemez.

### merge3 (üç yollu birleştirme)

Girdiler JSON değerleridir: `base`, `local`, `remote`. Herhangi biri yok (`undefined`) olabilir.

1. `local == base` → `remote`
2. `remote == base` → `local`
3. `local == remote` → `local`
4. Üçü de **nesne** ise (`base` yoksa `{}` sayılır): anahtarların birleşimi için özyinelemeli `merge3(base[k], local[k], remote[k])`. Sonuç `undefined` ise anahtar yazılmaz.
5. `local` ve `remote` **kimlikli diziler** ise birleştirme kimliğe göre yapılır. Kimlikli dizi: tüm elemanlar `"id"` (ya da `"code"`) metin alanı olan nesnelerdir.
   - Her kimlik için `merge3(base[id], local[id], remote[id])` alınır.
   - Sıra: önce `local` sırası, sonra yalnızca `remote`'ta yeni olanlar `remote` sırasıyla eklenir.
   - Sonucu `undefined` olan eleman (bir tarafta silinmiş, diğerinde değişmemiş) çıkarılır.
6. Diğer her durumda (sayı, metin, kimliksiz dizi, tip farkı) **yerel kazanır** → `local`.

Eşitlik, JSON değerlerinin derin eşitliğidir: sayılar sayı olarak, nesnelerde anahtar sırası önemsiz. Test vektörleri `docs/merge3-vectors.json` dosyasındadır. İki istemci de bu vektörlerin tamamını geçmelidir.

## 4. Hesap motoru eşliği

Web paneli, Mac uygulamasının hesaplarını (fark, fiili tüketim, kayıp, maliyet oranları, personel, sipariş önerisi, fiyat uyarıları) TypeScript'te aynen uygular. Eşlik testle korunur:

```
EnvanterTool demo --data-dir D --date 2026-08-31 --days 35
EnvanterTool metrics --data-dir D --date 2026-08-31 --from 2026-08-01 --to 2026-08-31 > metrics.json
```

`metrics.json` ve demo verisi (`envanter-verisi.json`) web deposunda test fikstürü olarak tutulur. TS motoru aynı sonuçları üretmelidir (±0,01 tolerans). Alanlar için `EnvanterTool metrics` çıktısına bakın.
