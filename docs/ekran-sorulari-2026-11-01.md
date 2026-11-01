# Ekran soruları — 1 Kasım 2026

Komut yönlendirmesinden sonra kalan gösterme sözcüklü sorular `ScreenQuestion` üzerinden işlenir. Ürün adı pencere başlığı, seçili metin, Safari bağlamı ve erişilebilir sayfa metninden çıkarılır. Belirlenemezse pencere sessizce yakalanır. Bulutta `qwen3-vl-30b`, yerelde kurulu `gemma4:e2b-it-qat`, tanımlama başarısızsa `gemma4:e4b-it-qat` kullanılır. Görüntü istekleri `reasoning_effort` göndermez; bunun mevcut düzeltmesi artık ortak, test edilebilir istek oluşturucusunda korunur. Simgeye basma da aynı bulut modelini seçer.

Ürün yorumları/dayanıklılığı, diğer fiyatlar ve satıcı güvenilirliği için üç Exa sorgusu eşzamanlı hazırlanır. Mağaza bilinmiyorsa mağaza sorgusu yapılmaz; anahtar yoksa veya arama başarısızsa bu eksik kanıt olarak belirtilir. Exa'ya yalnızca ürün/satıcı adı ve sabit arama sözcükleri gönderilir. Ürün sonuçlarında tam adla eşleşmeyen başlıklar ve açık ürün sayfasının kendisi elenir. Bu kasıtlı olarak tutucudur: farklı yazımlı gerçek eşleşmeler de elenebilir. Katalog puanları müşteri deneyimi sayılmaması için tek başına puan satırları çıkarılır.

Özet sorularında erişilebilir metin, o yoksa görüntü kullanılır; Exa ve sohbet modelinin ek arama araçları kapalıdır. Ürün yanıtının hedefi 3–4 konuşma cümlesidir. Yanıt kalitesi modele bağlıdır; bu bir kesin doğruluk veya süre garantisi değildir.

## Doğrulama

- İlgili regresyon paketi: 53 test geçti, iki canlı opt-in test atlandı.
- Kullanıcının Trendyol'daki Eylülün Takısı Kadın Gold Renk Taşlı Dorika Kalp Bileklik sayfası ile canlı denendi.
- Bulut görüntü modeli ürünün tam adını doğru çıkardı. İlk denemelerde boş görüntü yakalama ve odağın başka pencereye kayması görüldü; soru başındaki uygulama referansı artık tutulur.
- Yerel görüntü denemesi tamamlanamadı: XCTest üzerinden ScreenCaptureKit yakalaması `-3811` verdi. E2B/E4B görüntü tanıma başarısı doğrulanmış sayılmaz.
- Başlık/metin üzerinden yerel araştırma çalıştı. İlk cevapların benzer ürün/katalog bilgisine kayması nedeniyle kaynak eşleşmesi ve kısa yanıt istemi sıkılaştırıldı. Araştırma+sentez bir yerel denemede yaklaşık 6 saniye sürdü; ses tanıma/TTS bu ölçüme dahil değil.
- Özet yolunun ürün araştırmasına girmediği otomatik testle doğrulandı; gerçek bir makale üzerinde mikrofon→özet→ses akışı test edilmedi.

Canlı test yalnızca açık ürün sayfası ve servis erişimiyle `SCREEN_QUESTION_LIVE=1` olarak çalışır. `SCREEN_QUESTION_BACKEND=cloud` veya `ollama`; yalnızca metin yolunu ölçmek için `SCREEN_QUESTION_TEXT_ONLY=1`. Ayar geçersizse test hata verir; backend tercihi test sürecinin geçici alanında tutulur, uygulama ayarı değiştirilmez.

## Son durum

- `build.sh` başarılı; `/Applications/Jarvis.app` güncellendi ve başlatıldı.
- Son gerçek Exa + E2B testi, sayfadan doğrulanmış sabit metinle (`SCREEN_QUESTION_FIXTURE=1`, yalnızca metin yolu) 3,4 saniyede geçti. Cevap üç cümlede dayanıklılık, diğer satıcılardaki fiyat ve satıcı güvenilirliğinin doğrulanamadığını söyledi; katalog bilgisi veya fiyat uydurmadı.
- Önceki canlı sekmeye bağlı tekrarlar sayfa bağlamı alınamadığı için başarısız oldu. Sabit metin testi pencere yakalama veya mikrofon/TTS doğrulaması değildir.

## Ürün amacı ve adlandırılmış fiyat teklifleri — aynı gün düzeltmesi

Kullanıcının düzeltmesiyle `bu ürün ne / ne işe yarar` artık ayrı açıklama niyetidir: sayfa/görüntüden ürünün türü ve amacı anlatılır; yorum ve fiyat araştırması açılmaz. `daha ucuz / fiyat / ne kadar / en ucuz nerede` soruları Akakçe, Cimri ve Epey alan adlarında ayrı Exa sorguları başlatır. Fiyat aramalarında taze içerik istenir (`maxAgeHours: 0`) ve satıcı tekliflerini korumak için sayfa metni alınır. API alanları için resmi başvuru: https://exa.ai/docs/reference/search . Erişim ve ürün kapsamı garanti değildir.

Fiyat yanıtı artık serbest sohbet modeline sıralatılmaz. Model aynı ürün için satıcı, fiyat, kargo ve birebir kaynak alıntısı çıkarır. Kod, satıcı ve TL tutarını ilgili karşılaştırma kaynağındaki alıntıyla doğrular; sonra sayısal sıralar ve kaynak + gerçek satıcı + fiyat cümlesini üretir. Kargo tüm tekliflerde bilinmiyorsa yalnızca ürün fiyatı sıralanır ve toplam en ucuz iddiasında bulunulmaz. Katalog/benzer ürün sayfalarını azaltmak için ürün adı sözcükleri başlıkta aranır; bu tutucu filtre bazı gerçek eşleşmeleri de kaçırabilir. Ürün/varyant ve stok yorumlaması hâlâ modelin çıkarımına bağlıdır; bu tüm internetin kesin en ucuzunu bulma garantisi değildir.

Doğrulama: 43 ilgili testten 41'i geçti, iki opt-in test atlandı. Yerel E2B ile sentetik 1.500/1.400 TL teklif testinde Beta Elektronik 1.400 TL seçildi; 128GB varyantı dışarıda kaldı. Aynı model bilekliğin takı olduğunu ve kullanım amacını açıkladı. Kullanıcının bileklik sayfasından önceden doğrulanan metinle yapılan gerçek Exa aramalarında aynı ürün için doğrulanmış karşılaştırma teklifi bulunamadı; ilgisiz ürünler elendi. Test fiyatları gerçek alışveriş teklifi değildir. Mikrofon/TTS ile baştan sona deneme yapılmadı.

## EP5543/80 yanlış negatif düzeltmesi

Kullanıcının 1 Kasım 2026 16:50 denemesi logdan yeniden üretildi. Hepsiburada başlığındaki pazarlama metninin bütün kelimelerini karşılaştırma sitesi başlığında arayan filtre, doğru EP5543/80 sonucunu eliyordu. Uzun arama sorgusu Exa'da Akakçe için sonuç da vermedi. Başarısız testte doğru Cimri sonucu bulunduğu hâlde sıfır sonuç kabul edildiği kayda geçti.

- Arama marka + tam model koduyla yapılır. Model ekleri korunur (`EP5543/80` ≠ `EP5543/90`); ürün URL'sindeki kod, eksik başlığı tamamlayabilir. Karşılaştırma sayfasındaki farklı model kodları ve başka markalar kabul edilmez.
- Akakçe'nin herkese açık kendi araması kullanılarak eşleşen ürün sayfası bulunur. Canlı HTML'deki Product/Offer JSON-LD içinden stoktaki, yeni, TRY fiyatlı teklifler alınır. Satıcı ve fiyat model tarafından yeniden üretilmez. Kargo, sayfanın teklif verisiyle aynı satıcı ve fiyat üzerinden eşleştirilir; eksik kargo ücretsiz sayılmaz.
- Exa'dan gelen diğer kaynaklarda, uzun menüler yerine gerçek TL fiyatının çevresindeki metin kullanılır. Fiyat yoksa modele uzun menü listesi okutulmaz.
- Yerel model bozuk/boş teklif çıktısı verse bile doğrudan okunan Akakçe teklifleri kaybolmaz. Erişim/teklif okuma başarısızlığı artık "daha ucuzu yok/bulamadım" ile aynı sonuç sayılmaz.
- Akakçe HTML yapısı değişebilir; okuyucu eşleşme veya veri doğrulaması başarısızsa fiyat uydurmaz. İnternetteki tüm satıcılarda kesin en düşük fiyat garantisi verilmez; yanıt okunan eşleşen teklifler için geçerlidir.

Gerçek ürünle canlı test, Akakçe'den 10 teklif okuyup Trendyol üzerindeki ALDIMGİTTİ satıcısının 21.350 TL teklifini seçti. Aynı veride Ayağıma Getir 22.532,13 TL idi (test anındaki değişebilir fiyatlar). Test, logdan alınan ürün bilgileri + gerçek ağ çağrıları + yerel E2B ile yürütüldü; mikrofon/TTS akışının yeniden denenmesi değildir. Küçültülmüş gerçek sayfa verisi `Fixtures/akakce-philips-prices.html` altında satıcı/kargo/model regresyonu için saklandı.
