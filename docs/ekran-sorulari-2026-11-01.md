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
