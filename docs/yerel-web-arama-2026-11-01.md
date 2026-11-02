# Yerel sohbet için web araması — 1 Kasım 2026

## Neden

`/tmp/openwhisper.log` içindeki 13:09:29 yerel yanıtı, “2026 Dünya Kupası'nı kim kazandı?” sorusuna arama yapmadan “henüz oynanmadı” dedi. 13:09:49 bulut yolu ise Exa araması yaptı. `JarvisChat` yalnızca bulut istemcisine Exa anahtarı veriyordu; yerel modele internete erişemediğini belirten sistem mesajı gönderiliyordu.

## Değişiklik

`LocalSearchChatClient`, seçili yerel modelden şemalı JSON ile arama sorgusu/arama gerekmiyor kararı alır. Gerektiğinde mevcut Exa anahtarını kullanır ve sonuçları yerel modele verir. Modelin native tool calling desteğine gerek yoktur. Bulutun Ollama'ya düşmesi de aynı akışı kullanır. Arama veya hazırlık hatası, doğrulanmamış bir model cevabına düşmez. Anahtar yoksa mevcut çevrimdışı yol korunur. Arama hazırlığına ekran, e-posta ve kullanıcı hafızası sistem bağlamı eklenmez.

Ayarlar açıklaması Exa'nın hem yerel hem bulut sohbetinde kullanıldığını belirtir. Yerel cevap üretimi Ollama'da kalır; arama sorgusu Exa'ya gider.

## Doğrulama

- 38 ilgili test geçti; bu sayıya açıkça etkinleştirilen canlı test dahildir.
- Canlı test seçili `gemma4:e2b-it-qat` ve kayıtlı Exa anahtarıyla aynı soruyu sordu; gerçekten arama yapıldığını callback üzerinden doğruladı.
- Yerel yanıt bulutun kayıtlı yanıtıyla aynı oldu. Bu test arama bağlantısını ve sonuçların modele ulaştığını doğrular; web kaynağının olgusal doğruluğuna dair bağımsız bir denetim değildir.
- Sesli mikrofon akışı ayrıca denenmedi.

Canlı test: `JARVIS_LIVE_SEARCH_TEST=1 swift test --filter LocalSearchChatClientTests.testLiveLocalSearch` (app dizininden). Anahtar kodda veya test çıktısında tutulmaz.
