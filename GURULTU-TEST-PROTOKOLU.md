# Kafe Gürültüsü Testi — Gürültü Engelleme A/B Protokolü

Bu doküman, OpenWhisper'daki **Ses işleme modu** ayarının ("Gürültü engelleme" /
"Engellemesiz") kafe gibi gürültülü bir ortamda dikte doğruluğunu ve hızını
nasıl etkilediğini ölçmek için adım adım bir test protokolüdür.

## Neden canlı mikrofon testi gerekiyor

Apple'ın voice-processing (VPIO) gürültü engelleme özelliği bir donanım/HAL
giriş birimi olarak çalışır; ses **yakalama anında** işlenir. Zaten
kaydedilmiş bir WAV dosyasına sonradan VPIO uygulamak mümkün değildir. Bu
yüzden "gürültü engellemeli" ile "engellemesiz" karşılaştırması, aynı
gürültüyü hoparlörden çalıp **her iki modda da canlı mikrofonla dikte ederek**
yapılmalıdır. Sabit bir ses dosyası üzerinde simülasyon yaparak sayı üretmek
yanıltıcı olur; bu protokol bunu yapmaz.

## Ön koşullar

1. Uygulamayı derleyip kur:
   ```bash
   ./build.sh
   ```
   (Diğer ajanların yaptığı `[Perf]` log satırları ve gürültü engelleme
   değişiklikleri bu derlemeye dahil olmalı.)

2. Eski log kayıtlarının karışmaması için `/tmp/openwhisper.log` dosyasını
   temizle:
   ```bash
   rm -f /tmp/openwhisper.log
   ```
   Test sırasında bu dosyayı tekrar silme — `scripts/perf-report.sh` tüm
   satırları tek seferde okuyup gruplar; testin tamamını tek log dosyasında
   biriktirmen gerekiyor.

3. Kullandığın mikrofonu belirle (kulaklık mı, dahili mikrofon mu) ve test
   boyunca **değiştirme**. Bkz. aşağıdaki "Mikrofon girişini doğrulama"
   bölümü.

4. Kafe gürültüsü betiklerinin bağımlılığı olan `sox` kurulu olmalı
   (`test-dikte.sh` betiği de aynı bağımlılığı kullanıyor):
   ```bash
   brew install sox
   ```

5. Sistem ses seviyeni (hoparlör çıkışı) test öncesi sabit bir değere ayarla
   ve test boyunca değiştirme. Gürültü seviyesi tutarlılığı buna bağlı.

## Gürültü düzeneği

`scripts/noise-test/` altında iki betik var:

- `generate-cafe-noise.sh [hafif|orta|yogun]` — sentetik kafe gürültüsü
  (kahverengi gürültü uğultusu + iki mırıltı katmanı + hafif tiz doku) üretip
  WAV dosyasına yazar. Gerçek bir kafe kaydı değildir.
- `play-cafe-noise.sh [hafif|orta|yogun]` — bu dosyayı otomatik üretir
  (yoksa) ve Mac'in hoparlöründen kesintisiz döngüde çalar.

Test için ayrı bir terminalde:

```bash
./scripts/noise-test/play-cafe-noise.sh orta
```

Kafeyi taklit eden orta yoğunlukta bir "orta" seviyesiyle başlaman önerilir;
istersen `hafif` veya `yogun` ile tekrarlayabilirsin. Hoparlör sesini,
mikrofonun rahatça gürültüyü yakalayacağı ama tam sağır edici olmayan bir
seviyeye ayarla (ör. gündelik konuşma sesinin biraz üstü).

**Not:** `generate-cafe-noise.sh` çalıştırıldığında `scripts/noise-test/`
klasörüne birkaç MB'lık `.wav` dosyaları yazar. Bu dosyalar üretilen bir ara
çıktıdır, depoya girmez (`.gitignore`'da hariç tutulmuştur) — depoda hazır
bir `.wav` dosyası bulamazsan bu normaldir, `generate-cafe-noise.sh` veya
`play-cafe-noise.sh` çalıştırarak kendin üretmen gerekir.

## A/B test adımları

Aşağıdaki adımları **aynı oturumda, aynı gürültü seviyesinde, aynı mikrofon
ile** uygula. Sıralama önemli: önce tüm "Engellemesiz" tekrarlarını, sonra
tüm "Gürültü engelleme" tekrarlarını yap (moda göre gruplamak, mod
değiştirirken oluşan geçiş gürültüsünü/dikkat dağılmasını azaltır).

1. Gürültüyü başlat: `./scripts/noise-test/play-cafe-noise.sh orta`
2. OpenWhisper → Ayarlar → Ses işleme modunu **Engellemesiz** yap.
3. Aşağıdaki 5 test cümlesinin her birini **5 kez** dikte et (toplam 25
   dikte). Her tekrarda:
   - Fn/Globe'a basılı tutup cümleyi doğal hızında söyle, bırak.
   - Çıkan ham metni (ve varsa Ollama temizlemesinden geçmiş metni) not al —
     aşağıdaki doğruluk tablosuna işleyeceksin.
   - Bir sonraki tekrar için 2-3 saniye bekle (motor durumunun oturması
     için).
4. Ses işleme modunu **Gürültü engelleme** yap.
5. Aynı 5 cümleyi, aynı sırayla, yine 5'er kez dikte et (toplam 25 dikte
   daha).
6. Gürültüyü durdur (Ctrl+C).

**Neden 5 tekrar?** `perf-report.sh` medyan/ortalama hesaplıyor ve `n < 3`
olduğunda güvenilmez olduğunu belirtiyor. 5 tekrar, tek bir yavaş/hızlı
ölçümün (ör. arka planda başka bir işlem, Ollama'nın soğuk başlaması vb.)
sonucu bozmasına karşı makul bir güvenlik payı bırakıyor; aynı zamanda testi
makul bir sürede (~toplam 50 dikte) tutuyor.

### Test cümleleri

Bu cümleler kasıtlı olarak Türkçe konuşma akışı içine İngilizce teknik
terimler karıştırıyor (Android/web geliştirici günlük kullanımına benzer,
`sozluk.txt` içindeki terimlerden seçildi). Her testte birebir aynı
cümleleri, aynı sırayla kullan.

| # | Cümle |
| - | ----- |
| 1 | Şu pull request'te bir merge conflict var, önce main'i rebase edip sonra useEffect içindeki cleanup function'ı düzeltmemiz lazım. |
| 2 | Android tarafında ViewModel'deki coroutine job'ını viewModelScope'a bağlamadığım için Jetpack Compose ekranı re-render olurken crash atıyordu. |
| 3 | Supabase'de yeni bir Edge Function yazıp RLS policy'sini service role ile test ettim, ama rate limit'e takılınca hata döndü. |
| 4 | Next.js App Router'da bu Server Component'i Client Component'e çevirip API route yerine Server Action kullanmayı deneyelim. |
| 5 | OAuth access token'ı refresh token ile yeniliyoruz ama session restore sırasında CI/CD pipeline'daki bir environment variable eksik çıktı. |

## Doğruluk nasıl karşılaştırılır (elle kelime hatası sayımı)

Her tekrar için referans cümleyle çıkan metni karşılaştır ve üç hata türünü
say:

- **Yanlış kelime (substitution):** doğru kelime yerine başka bir kelime
  çıkmış (ör. "rebase" yerine "ribeys").
- **Eksik kelime (deletion):** referansta olan bir kelime çıktıda yok.
- **Fazla kelime (insertion):** çıktıda referansta olmayan bir kelime var.

Noktalama/büyük-küçük harf farklarını (Ollama temizlemesinin normal işi)
hata sayma — sadece kelime/terim doğruluğuna bak. Teknik terimlerin doğru
yazılıp yazılmadığına özellikle dikkat et (bu, sözlük/temizleme
katmanının değil, gürültü altında Whisper'ın tanıma kalitesinin göstergesi).

Tablo şablonu (her mod ve gürültü seviyesi için ayrı doldur):

| Cümle # | Tekrar | Mod | Toplam kelime | Yanlış | Eksik | Fazla | Toplam hata | WER (%) |
| ------- | ------ | --- | -------------- | ------ | ----- | ----- | ------------ | ------- |
| 1 | 1 | Engellemesiz | | | | | | |
| 1 | 2 | Engellemesiz | | | | | | |
| ... | | | | | | | | |
| 1 | 1 | Gürültü engelleme | | | | | | |
| ... | | | | | | | | |

`WER (%) = Toplam hata / Toplam kelime * 100`

Cümle başına ve mod başına ortalama WER'i hesapla, sonra iki modu
karşılaştır.

## Hız nasıl okunur

Test bittikten sonra:

```bash
./scripts/perf-report.sh
```

Bu, `/tmp/openwhisper.log` içindeki tüm `[Perf]` satırlarını okuyup
`ns=on` (Gürültü engelleme) ve `ns=off` (Engellemesiz) grupları için
`engineStart`, `decode`, `total` (ve varsa `llm`) metriklerinin örnek
sayısını, medyanını, ortalamasını ve aradaki farkı (ms ve %) basar. n<3 olan
gruplar için Türkçe bir güvenilirlik uyarısı gösterir.

Farklı bir log dosyasıyla çalışmak istersen:

```bash
./scripts/perf-report.sh /yol/baska-log.log
```

## Mikrofon girişini doğrulama

Test boyunca aynı mikrofonu kullandığından emin olmak için
`/tmp/openwhisper.log` içinde şu satırı ara:

```bash
grep "effective input=" /tmp/openwhisper.log
```

Bu satır, o kayıt için gerçekte kullanılan giriş cihazını (kulaklık/harici
mikrofon mu, dahili Mac mikrofonu mu) gösterir. Her dikte tekrarında aynı
cihazın kullanıldığını doğrula; farklı bir cihaza geçiş varsa o tekrarı
sonuçlardan çıkar.

**Not:** Bu satır, gürültü engelleme özelliğiyle birlikte bugün eklenen
loglama değişikliklerinin bir parçası. Eğer henüz derlenmiş uygulamada bu
satırı bulamazsan (log formatı değişmiş olabilir), alternatif olarak şu
mevcut satırlara bak:

```bash
grep "\[AudioEngine\] Using" /tmp/openwhisper.log
```

`Using input device UID=...` satırı belirli bir cihazın seçildiğini,
`Using system default input` satırı sistem varsayılanının kullanıldığını
gösterir — ikinci durumda, hangi fiziksel cihazın o an sistem varsayılanı
olduğunu macOS Ses ayarlarından ayrıca doğrulaman gerekir.

## Beklenen sonuç ve başarısız sayılır kriterleri

Hedef: kafe gürültüsü altında **Gürültü engelleme** modu, **Engellemesiz**
moda göre belirgin şekilde daha düşük WER vermeli, hız (total süre) ise
kabul edilebilir ölçüde artmalı ya da hiç artmamalı.

Aşağıdaki durumlardan biri gerçekleşirse test **başarısız** sayılır:

- **Doğruluk iyileşmiyor:** Gürültü engelleme modundaki ortalama WER,
  Engellemesiz moddaki ortalama WER'e eşit veya daha kötüyse (gürültü
  engellemenin bariz bir faydası yoksa).
- **Hız belirgin şekilde düşüyor:** `perf-report.sh` çıktısında `total`
  metriğinin medyan farkı `ns=on` lehine (yani süreyi artıracak yönde)
  **+150ms'den fazla veya +%15'ten fazla** ise (hangisi daha büyükse) —
  bu, kullanıcının "hız düşmesin" hedefine aykırıdır.
- **engineStart aşırı artıyor:** `engineStart` medyan farkı `ns=on` için
  Engellemesiz'e göre +100ms'den fazlaysa, kayıt başlatma gecikmesi
  kullanıcı tarafından fark edilir hale gelir.
- **Log/veri eksik:** `perf-report.sh` bir metrik için `n<3` uyarısı
  veriyorsa, o metrik için sonuç güvenilir kabul edilmemeli; test o metrik
  için tekrarlanmalı.

Bu kriterlerden hiçbiri gerçekleşmiyorsa ve Gürültü engelleme modunda WER
belirgin şekilde düşükse (öznel olarak "gürültü modelin işini
zorlaştırmıyor" hissi de dahil), sonuç **başarılı** kabul edilir ve gürültü
engelleme varsayılan olarak açık bırakılabilir.
