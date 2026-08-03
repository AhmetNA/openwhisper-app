#!/bin/bash
# play-cafe-noise.sh — generate-cafe-noise.sh tarafından üretilen sentetik
# kafe gürültüsünü, sabit seviyede ve kesintisiz döngüde Mac'in hoparlöründen
# çalar. Gürültü/gürültü-engelleme A/B testinde arka plan olarak kullanmak
# içindir: bilgisayarın hoparlöründen çalınır, mikrofon bunu "ortam gürültüsü"
# olarak yakalar.
#
# Kullanım:
#   ./play-cafe-noise.sh [hafif|orta|yogun] [ek-sox-play-argümanları...]
#
# Dosya yoksa otomatik olarak generate-cafe-noise.sh ile üretilir.
# Durdurmak için Ctrl+C.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<EOF
Kullanım: $(basename "$0") [hafif|orta|yogun]

Seviyeler:
  hafif  -> yaklaşık -32 dBFS (uzak / sakin kafe)
  orta   -> yaklaşık -24 dBFS (varsayılan, tipik kafe uğultusu)
  yogun  -> yaklaşık -16 dBFS (kalabalık / yoğun kafe)

Dosya scripts/noise-test/cafe-noise-<seviye>.wav yoksa otomatik üretilir.
Durdurmak için Ctrl+C.
EOF
  exit 1
}

if ! command -v sox >/dev/null 2>&1; then
  echo "HATA: 'sox' bulunamadı. Kurulum için: brew install sox" >&2
  exit 1
fi

LEVEL="${1:-orta}"
case "$LEVEL" in
  hafif|orta|yogun) ;;
  -h|--help) usage ;;
  *)
    echo "HATA: geçersiz seviye '$LEVEL'. Geçerli değerler: hafif, orta, yogun" >&2
    usage
    ;;
esac

NOISE_FILE="$SCRIPT_DIR/cafe-noise-${LEVEL}.wav"

if [ ! -f "$NOISE_FILE" ]; then
  echo "==> $NOISE_FILE bulunamadı, üretiliyor..."
  "$SCRIPT_DIR/generate-cafe-noise.sh" "$LEVEL" "$NOISE_FILE"
fi

echo "==> Kafe gürültüsü çalınıyor (seviye=$LEVEL, dosya=$NOISE_FILE)"
echo "==> Sistem ses seviyenizi test öncesi sabit bir değere ayarlayın (test boyunca değiştirmeyin)."
echo "==> Durdurmak için Ctrl+C."
echo

# sox'un 'repeat' efekti sonlu bir tekrar sayısı ister; kesintisiz/uzun süreli
# çalma için dosyayı bir kabuk döngüsünde art arda çalıyoruz. Böylece test
# süresi 45s'lik dosya uzunluğuyla sınırlı kalmaz ve kullanıcı Ctrl+C ile
# istediği an durdurabilir.
while true; do
  play -q "$NOISE_FILE"
done
