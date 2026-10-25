# Konuşma hatalarını loglardan ayırma

Ana dosya `/tmp/openwhisper.log`. Yeni kayıtlardaki `[SpeechDiag]` satırları tek satırlık JSON'dur; uzun metin kesilmez, satır sonları JSON içinde korunur. `speech` UUID'si aynı konuşmanın ASR, yönlendirme ve gecikmeli temizleme/yapıştırma işlemlerini bağlar. `batch` ses parçasını, `decode` ayrı Whisper çağrısını ayırır. Wake doğrulaması gibi oturuma bağlı olmayan çözümler `speech=unbound` olarak görünür.

1. `session.begin`: tetikleyici, model, dil, hedef uygulama ve konuşmacı filtresi.
2. `capture.stop` / `capture.discard`: kaydın durma/atılma nedeni. `batch.audio`: 16 kHz ses parçalarının başlangıç/bitişi ve örtüşmesi. Bunlar ASR'nin aldığı ses zamanlarıdır, konuşma zamanları değildir.
3. `decode.segment`: modelin her bölümde duyduğu metin, zamanlar, token sayısı, güven ve sessizlik ölçüleri. Yüksek token sayısı veya düşük güven tek başına hata kanıtı değildir.
4. `decode.primary`, `decode.recovery`, `decode.comparison`, `decode.selected`: ilk/ikinci metin, karşılaştırma ve hangisinin seçildiği. `asr.sanitized` modelden sonraki temizlenmiş metindir.
5. `batch.afterSpeakerFilter`, `transcript.joined`, `transcript.afterWakeEcho`, `transcript.afterSoundAlikes`: konuşmacı ayırma, parçaları birleştirme, wake/yanıt yankısı kaldırma ve ses-benzeri düzeltme sonrası metin.
6. `route.selected`: ilk çalıştırılacak yönlendirme. `spotifyOrConversation` hâlâ karar bekleyen bir yoldur; ardından aynı speech kimliğindeki `[Route]`, `[Addressee]`, `[Result]` kayıtlarına bakılır.
7. `dictation.*`, `cleanup.*`, `delivery.*`: öğrenilmiş/sözlük düzeltmesi, model temizlemesi ve teslim edilen metin. `pastedUnverified` teslim doğrulaması değildir. `session.routingFinished` sonrasında asenkron teslim/temizleme kayıtları gelebilir.

Son oturumları bulmak:

```sh
rg '\[SpeechDiag\].*"stage":"session.begin"' /tmp/openwhisper.log | tail -3
rg 'speech=BURAYA_UUID|"speech":"BURAYA_UUID"' /tmp/openwhisper.log
```

`session.recording` kaydı ses geçmişinin UUID'sini verir. Kaydedilmiş konuşmanın `~/Library/Application Support/OpenWhisper/Recordings/<UUID>.log` başlığında da speech kimliği bulunur. Erken ASR kayıtları ana logdadır; loglar geriye dönük oluşmaz. Sesin gerçekten eksik olup olmadığını anlamak için varsa aynı UUID'li `.caf` kaydıyla karşılaştırılır. Yeni bir ses kaydı mekanizması veya uzak aktarım eklenmedi.

## Her dinlemenin sonucu

`session.summary` her tamamlanan yönlendirme için, ses geçmişte tutulmasa da
`/tmp/openwhisper.log` dosyasına yazılır. Tutulan seslerde aynı özet kayıt izinde de bulunur.
`routes` seçilen yolu, `attempts` başlatılan komutları, `actions` bildirilen işlem sonuçlarını,
`deliveries` yapıştırma sonucunu, `replies` sesli/ekranda yanıt sonucunu,
`screenMessages` gösterilen mesajları, `reasons` atlama/eleme nedenlerini içerir.
`none_reported` o kategoride sonuç bildirilmediği anlamına gelir; başarı anlamına gelmez.
Ses filtresi reddi, boş/elenen ASR çıktısı, iptal, dil kontrolü, kapalı sesli yanıt ve
aktif yeni kayıt gibi nedenler açıkça kaydedilir. Sonradan devam eden asenkron düzeltmeler
aynı `speech` kimliği altında ayrıca izlenir; özet yönlendirme dönüş anını kapsar.
