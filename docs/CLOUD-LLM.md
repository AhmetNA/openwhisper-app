# Bulut LLM ile Jarvis sohbeti

Jarvis'in serbest sohbeti (`JarvisChat`) OpenAI uyumlu herhangi bir servise bağlanabilir.

Komutlar, metin temizleme, SetFit kararları ve wake kontrolü her zaman yerelde kalır.

## Kurulum

1. **Ayarlar › API Anahtarları › Bulut LLM:** adresi (`https://…/v1`) ve anahtarı girip kaydet. Kaydederken şu kontroller yapılır:
   - adres https mi (yerel sunucu için http de olur),
   - anahtarda boşluk var mı, çok kısa mı,
   - `/models` OpenAI biçiminde cevap veriyor mu.
2. **Ayarlar › Modeller › Jarvis sohbeti:** önce Bulut'u, sonra bulut modelini seç.
   - Seçilen model kısa bir mesajla denenir.
   - Sohbet isteğini reddeden, boş dönen ya da 1,5 sn'den geç başlayan model için uyarı çıkar.

Adres UserDefaults'ta `cloudLLMAddress`, model `cloudChatModel` altında durur. Anahtar Keychain'de `com.openwhisper.app.llm` / `cloud.api_key` altında saklanır.

## Davranış

- **Düşünme kapalı:** istekle `chat_template_kwargs.enable_thinking=false` ve `reasoning_effort=none` gider. Açık modeller düşünürken ilk kelime 1–5 sn gecikiyor.
  - Bu alanları reddeden sunucuda model denemesi alanlar olmadan tekrarlanır.
  - Sonuç `cloudChatThinkingOff` altında saklanır.
- **Yedek:** bulut model 1,5 sn içinde ilk parçayı göndermezse, ya da ondan önce hata verir veya boş dönerse, aynı mesajlar Ollama'ya gider (`ChatFallback`).
  - İlk parçadan sonra geçiş yapılmaz, çünkü Jarvis o cümleyi okumaya başlamış olabilir.
- **Log:** `[Chat] '…' → '…' (cloud <model>, first sentence N ms, all M ms)`. Yedeğe geçildiyse `ollama … after cloud <sebep>` yazar.

## Ölçüm (2026-10-21)

Ölçüm Jarvis'in gerçek sistem komutuyla yapıldı: 11 soru, düşünme kapalı, yerel model bellekteyken. Ses ilk cümle bitince başladığı için ölçüt ilk cümledir.

| Model | İlk kelime | İlk cümle (med) | İlk cümle (max) |
|---|---|---|---|
| Ollama gemma4:e4b-it-qat (yerel) | ~90 ms | ~690 ms | 0,9 sn |
| qwen3.8-flash-next (bulut) | ~350 ms | ~710 ms | 2,5 sn |
| deepseek-v4.1-flash (bulut) | ~320 ms | ~1,0 sn | 2,4 sn |

Ollama modeli bellekten düşmüşse ilk istek 3–9 sn sürüyor.
