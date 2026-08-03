#!/bin/bash
# generate-cafe-noise.sh — kafe/açık ofis ortamına benzeyen sentetik gürültü
# üretir (WAV dosyası). Gerçek bir kafe kaydı DEĞİLDİR; sox ile sentezlenmiş
# katmanlı gürültüden oluşur:
#   - alçak uğultu (kahverengi gürültü, alçak geçiren filtre)  -> HVAC/klima hissi
#   - iki "mırıltı" katmanı (pembe gürültü, konuşma bandına bant geçiren filtre,
#     farklı hızlarda tremolo modülasyonu) -> örtüşen konuşma/kahkaha hissi
#   - hafif tiz doku (beyaz gürültü, yüksek geçiren filtre) -> bardak/tabak sesi hissi
#
# Bu, GERÇEKÇİ bir kafe kaydının yerini tutmaz; sadece "geniş bantlı, konuşma
# bandında baskın, hafif dalgalanan" bir maskeleme gürültüsü üretir. Amaç,
# canlı mikrofon testinde tekrarlanabilir ve sabit seviyeli bir arka plan
# gürültüsü sağlamaktır.
#
# Kullanım:
#   ./generate-cafe-noise.sh [hafif|orta|yogun] [cikti_dosyasi.wav]
#
# Argüman verilmezse seviye "orta", çıktı dosyası bu script ile aynı
# klasörde cafe-noise-<seviye>.wav olur.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<EOF
Kullanım: $(basename "$0") [hafif|orta|yogun] [cikti_dosyasi.wav]

Seviyeler (yaklaşık tepe genlik hedefi, RMS değil):
  hafif  -> yaklaşık -32 dBFS (uzak / sakin kafe)
  orta   -> yaklaşık -24 dBFS (varsayılan, tipik kafe uğultusu)
  yogun  -> yaklaşık -16 dBFS (kalabalık / yoğun kafe)

Örnek:
  $(basename "$0") orta
  $(basename "$0") yogun ~/Desktop/kafe-yogun.wav
EOF
  exit 1
}

if ! command -v sox >/dev/null 2>&1; then
  echo "HATA: 'sox' bulunamadı. Kurulum için: brew install sox" >&2
  exit 1
fi

LEVEL="${1:-orta}"

case "$LEVEL" in
  hafif) PEAK_DB=-32 ;;
  orta) PEAK_DB=-24 ;;
  yogun) PEAK_DB=-16 ;;
  -h|--help) usage ;;
  *)
    echo "HATA: geçersiz seviye '$LEVEL'. Geçerli değerler: hafif, orta, yogun" >&2
    usage
    ;;
esac

OUT="${2:-$SCRIPT_DIR/cafe-noise-${LEVEL}.wav}"

DURATION=45   # saniye; play-cafe-noise.sh bu dosyayı döngüde çalar
SR=44100

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cafe-noise.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Katmanlar sentezleniyor (${DURATION}s, seviye=${LEVEL})..."

# Katman 1: alçak uğultu (HVAC/ambiyans hissi)
sox -n -r "$SR" -c 1 "$TMP_DIR/rumble.wav" \
  synth "$DURATION" brownnoise lowpass 300 gain -n -18

# Katman 2 ve 3: konuşma bandında iki "mırıltı" katmanı, farklı tremolo
# hızlarıyla tek düze bir ton yerine dalgalanan bir doku elde edilir.
sox -n -r "$SR" -c 1 "$TMP_DIR/babble1.wav" \
  synth "$DURATION" pinknoise bandpass 900 1800 tremolo 0.7 40 gain -n -20

sox -n -r "$SR" -c 1 "$TMP_DIR/babble2.wav" \
  synth "$DURATION" pinknoise bandpass 1800 2600 tremolo 1.3 35 gain -n -22

# Katman 4: hafif tiz doku (bardak/tabak/çatal-bıçak hissi)
# Not: highpass filtresi girişte ara taşma (clipping) uyarısı vermesin diye
# filtreden önce küçük bir ön kazanç düşüşü uygulanır; son seviye yine gain -n
# ile hedeflenen dBFS'e normalize edilir.
sox -n -r "$SR" -c 1 "$TMP_DIR/hiss.wav" \
  synth "$DURATION" whitenoise gain -10 highpass 4000 gain -n -30

echo "==> Katmanlar karıştırılıyor..."
sox -m \
  "$TMP_DIR/rumble.wav" \
  "$TMP_DIR/babble1.wav" \
  "$TMP_DIR/babble2.wav" \
  "$TMP_DIR/hiss.wav" \
  "$TMP_DIR/mixed.wav"

echo "==> Seviye ayarlanıyor ve döngü için fade uygulanıyor..."
mkdir -p "$(dirname "$OUT")"
sox "$TMP_DIR/mixed.wav" "$OUT" gain -n "$PEAK_DB" fade t 0.5 0 0.5

echo "Tamamlandı: $OUT"
echo "  Seviye: $LEVEL (hedef tepe genlik: ${PEAK_DB} dBFS)"
echo "  Süre: ${DURATION}s (play-cafe-noise.sh bunu döngüde çalar)"
echo
echo "Not: Bu sentetik bir gürültüdür, gerçek bir kafe kaydı değildir."
echo "Amaç, canlı mikrofon testinde tekrarlanabilir/sabit bir arka plan sağlamaktır."
