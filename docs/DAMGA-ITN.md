# Damga değerlendirmesi — 20 Ekim 2026

Karar: Türkçe dikte için eklemeye değer. Küçük ve hızlı bir CPU bileşeniyle sayı, tarih, tutar ve iletişim bilgilerinin yazımını düzeltiyor. Projeye deneysel, varsayılanı kapalı bir seçenek olarak eklendi. Kendi Whisper/Qwen ses kayıtlarımızda doğruluk ölçülmeden varsayılan yapılmamalı.

## Kaynak incelemesi

- [Depo](https://github.com/mihu-ai/damga), incelenen commit: `25ff3121c7830e2e633a2017fcfb03b90cb15011`.
- [Paket tanımı](https://github.com/mihu-ai/damga/blob/25ff3121c7830e2e633a2017fcfb03b90cb15011/pyproject.toml): Damga 1.0.3, Apache-2.0, Python >=3.9; normal çalışma için Python bağımlılığı yok. macOS arm64 Python 3.12 hazır paketi indirildi ve çalıştırıldı. İndirme yaklaşık 17,7 MiB.
- [Native çalışma yolu](https://github.com/mihu-ai/damga/blob/25ff3121c7830e2e633a2017fcfb03b90cb15011/damga/core/engine.py): derlenmiş WFST dosyaları, küçük C++ uzantısı ve statik OpenFst. Çalışırken GPU, internet veya dil modeli gerekmiyor. Özel kategori seçimi ve `strict=True`, hazır native çalışma yolunda desteklenmiyor; Pynini gerektiriyor. Entegrasyon bunları kurmuyor.
- [Eski macOS ölçümü](https://github.com/mihu-ai/damga/blob/25ff3121c7830e2e633a2017fcfb03b90cb15011/benchmarks/results/macos-rosetta-x86_64-20261010.md): x86_64/Rosetta, Python 3.11, Pynini, Damga 0.1.0. Başlangıç sonrası RSS 489 MB, tepe RSS 648 MB; kısa ITN p50 1,109 ms, streaming p50 1,236 ms. Bunlar M5 native 1.0.3 ölçümleri değil.
- [Yazarların doğruluk açıklaması](https://github.com/mihu-ai/damga/blob/25ff3121c7830e2e633a2017fcfb03b90cb15011/README.md#real-recognizer-output): 1.200 sentetik cümlede TTS → Mihu STT v1.2 → Damga genel exact-match %79. Bu, Damga'nın tek başına doğruluğu veya bu projenin Whisper/Qwen başarımı anlamına gelmiyor. Kaçan telefon rakamlarını ve yanlış duyulan isimleri güvenilir biçimde yeniden üretemez.

## Yerel M5 sonucu

macOS 27.2 arm64, Apple M5, Python 3.12.14, Damga 1.0.3 native. Projeye eklenen koruma katmanıyla birlikte ölçüldü. [Ham sonuç](../damga_server/results/apple-m5-native-2026-10-20.json).

| Ölçüm | Sonuç |
|---|---:|
| Sentetik metin örnekleri | 30/30 beklenen çıktı |
| İkinci kez uygulama | 30/30 çıktı sabit |
| Isınmış çağrı sayısı | 3.000 |
| p50 / p95 | 0,62 / 1,81 ms |
| Başlatma | 44,6 ms |
| Ölçüm sonu RSS | 55,9 MiB |
| Tepe RSS | 56,2 MiB |

Sayı, ondalık, yüzde, TL/kuruş, tarih, saat, telefon, IBAN, e-posta ve adres örnekleri; normal Türkçe cümleler, teknik terimler, URL, kod, satır sonu ve kullanıcı sözlüğü koruması sınandı. Bu küçük set projeye özgü regresyon kontrolüdür; genel doğruluk yüzdesi olarak kullanılmamalı. Gecikme koruma + ITN süresidir; HTTP/Swift, ASR ve yapıştırma süresi dahil değildir. RSS ayrı Python işleminin CPU belleğidir; GPU VRAM veya tüm Jarvis sürecinin bellek tüketimi değildir.

## Uygulamadaki akış

1. ASR metni mevcut Jarvis yönlendirmesine gider. Komut kararından sonra yalnızca dikte çıktısına ITN uygulanır.
2. Öğrenilmiş düzeltmeler ve sözlük düzeltmeleri çalışır; Damga yazılı biçimi üretir; mevcut yasak-artifakt süzgeci uygulanır; metin yapıştırılır veya panoya kopyalanır.
3. Ollama açıksa arka plandaki temizlenmiş sonuç da yeniden ITN'den geçer. Ham metin mevcut değiştirme kısayolunda korunur.
4. Kayıt yeniden analizi ve sistem sesi panosu aynı biçimlendirme yardımcısını kullanır.

Damga ayrı temizleme modeli olarak seçilmez; Ollama'dan bağımsız bir anahtardır. Türkçe seçiliyken çalışır; İngilizce/otomatik dil seçimine uygulanmaz. TTS'nin mevcut `spokenForm` davranışına TN eklenmedi.

`127.0.0.1:8774` üzerindeki yerel Python işlemi mevcut `LocalModelServer` altyapısıyla açılır. Açılış en fazla 3 sn, dönüşüm isteği en fazla 750 ms bekler. Eksik kurulum, geçersiz yanıt, kapanma veya zaman aşımında girdi aynen döner. 4.000 karakterden uzun girdiler de aynen korunur. Anahtar kapanınca, dil değişince ve uygulama kapanınca işlem durdurulur; ebeveyn ölürse sunucu kendisi kapanır. Sunucu loguna metin yazılmaz.

## Sınırlar

- Bağlamsız sayı/yıl ayrımı kusursuz değil: `iki bin yirmi altı seçimleri` → `2.026 seçimleri`. `yarımda geleceğim` → `12:30'da geleceğim`. Bunlar varsayılanı kapalı tutma nedenleri.
- `repair_spelling=False`: ASCII veya bitişik yazılmış sayı kelimelerini agresif düzeltme kapalı. Normal WFST kuralları ve markalar/sözcük kodlama kuralları yine mevcut. Yerleşik `strict` modu kullanılmıyor.
- Yazılı URL/e-posta/IBAN, kod blokları ve satır içi kod, camelCase, kısaltmalar ve sözlük terimleri geçici işaretlerle korunur; işaret kaybolur veya sırası değişirse tüm cümlede özgün metne dönülür. Bu, her olası kod dilini tanıyan bir çözüm değil.
- İlk yapıştırmadan sonra ham metne dönülebilir. Gönderme komutuyla hemen gönderilmiş metin için mevcut davranış gereği değiştirme yoktur.
- Fiziksel mikrofon, kendi gerçek ASR hata setimiz ve ayarın görsel uygulama testi henüz yapılmadı. Kaynak entegrasyonu ve derleme/test kanıtı, kurulu `/Applications/Jarvis.app` sürümünün güncellendiği anlamına gelmez.

## Tekrar çalıştırma

Uygulama deposundan:

```bash
bash damga_server/setup.sh
bash build.sh
"$HOME/Library/Application Support/OpenWhisper/damga/.venv/bin/python" damga_server/evaluate.py --out /tmp/damga-results.json
DAMGA_TEST_INSTALL="$HOME/Library/Application Support/OpenWhisper/damga" swift test --filter DamgaNormalizerTests
```

`DAMGA_INSTALL_DIR` ile kurulumu geçici bir dizine yönlendirmek de mümkün. Gerçek native runtime, Swift HTTP bağlantısı üzerinden ayrıca sınandı; bozuk yanıt, boş yanıt, eksik kurulum, zaman aşımı, yeniden başlatma ve istek sırasında kapatma testleri de geçti.

20 Ekim doğrulaması: tüm Swift test takımı 597 test, 0 hata, ek veri gerektiren 3 test atlandı. Damga'nın 8 Swift testi gerçek-runtime testi dahil geçti. Python metin seti 30/30 geçti. `git diff --check` ve shell sözdizimi kontrolü temiz. Derleme mevcut projedeki Swift eşzamanlılık uyarılarını taşıyor; Damga'ya özgü derleme hatası yok. Kurulum yalnızca geçici bir klasörde denendi; kullanıcının kurulu uygulaması veya kalıcı ayarları bu çalışma sırasında güncellenmedi.
