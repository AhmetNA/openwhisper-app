# Yerel ve bulut sohbet özellikleri — 1 Kasım 2026

Buluta özel kalan `CloudSessionNavigation.handle` girişindeki zorunluluk kaldırıldı. Claude/Codex sohbet gezinmesi artık seçili sohbet sağlayıcısını kullanır. Başlık eşleşmesi model çağırmadan çalışır; içerik ve göreli gezinme kararları yerelde şemalı JSON üreten Ollama üzerinden, bulutta mevcut sohbet istemcisinden alınır. İki yol da aynı aday kimliği doğrulamasından geçer.

Önceki sohbet kimliği uygulamada etkinlik zamanına göre hesaplanır. Küçük yerel modelin bir adayı yanlışlıkla seçmesi durumuna karşı yerelde ayrıca istek–aday eşleşme kontrolü yapılır. Geçersiz kimlik, aynı başlığı taşıyan belirsiz aday, mevcut sohbet veya doğrulanmamış eşleşme açılmaz. Hata durumunda kullanıcıdan netleştirme istenir veya modele ulaşılamadığı bildirilir.

Kod incelemesinde sohbet/web araması, Spotify yorumlama, komut yeniden yorumlama, sohbet özetleri ve ekran öğesi/görsel seçiminde yerel yollar zaten mevcuttu. Ek bir bulut seçme zorunluluğu bulunmadı. Bu, farklı modellerin doğruluk veya hızlarının eşit olduğu anlamına gelmez.

Canlı karar testleri sentetik sohbetlerle seçili Gemma modelini kullanır; gerçek sohbetleri açmaz veya değiştirmez. Senaryolar: önceki sohbet, yeni sohbet, içerikten konu eşleştirme, olumsuz istek ve iki eşleşmeyen konu. Mikrofonla gerçek Claude/Codex pencere geçişi ayrıca denenmedi.

Çalıştırma (app dizini):
`JARVIS_LIVE_NAV_TEST=1 swift test --filter CloudSessionNavigationTests`
