#!/bin/bash
# perf-report.sh — /tmp/openwhisper.log içindeki [Perf] satırlarını ayrıştırıp
# gürültü engelleme açık (ns=on) / kapalı (ns=off) karşılaştırma tablosu basar.
#
# Beklenen log satırları (sıra ve fazladan alanlar önemli değildir):
#   [Perf] engineStart=<ms> ns=<on|off>
#   [Perf] decode=<ms> total=<ms> ns=<on|off> samples=<n>
#   [Perf] decode=<ms> total=<ms> ns=<on|off> samples=<n> llm=<ms>
#
# Kullanım:
#   ./scripts/perf-report.sh [log_dosyasi]
#
# log_dosyasi verilmezse /tmp/openwhisper.log kullanılır.

set -euo pipefail

LOG_FILE="${1:-/tmp/openwhisper.log}"

if [ ! -f "$LOG_FILE" ]; then
  echo "HATA: log dosyası bulunamadı: $LOG_FILE" >&2
  echo "Uygulamayı çalıştırıp en az birkaç dikte yaptıktan sonra tekrar deneyin." >&2
  exit 1
fi

if ! grep -q '^\[Perf\]' "$LOG_FILE" 2>/dev/null; then
  echo "UYARI: '$LOG_FILE' içinde [Perf] ile başlayan satır bulunamadı." >&2
  echo "Ölçemediğim şeyi ölçemedim: bu betik veri üretmez, sadece var olan logu okur." >&2
  exit 1
fi

# awk ile tek geçişte ayrıştır: her metrik (engineStart, decode, total, llm)
# için ns=on / ns=off gruplarında değer listeleri biriktirilir. Alan sırası ve
# fazladan alanlar önemli değildir; sadece "isim=değer" biçimindeki alanlar
# tanınır, eksik alanlar sessizce atlanır (satır çökmeye sebep olmaz).
awk '
BEGIN {
  FS = "[ \t]+"
}
/^\[Perf\]/ {
  ns = ""
  # Satırdaki her alanı tara, "anahtar=değer" olanları çıkar
  n = NF
  delete kv
  for (i = 1; i <= n; i++) {
    field = $i
    eq = index(field, "=")
    if (eq > 0) {
      key = substr(field, 1, eq - 1)
      val = substr(field, eq + 1)
      kv[key] = val
    }
  }
  if (!("ns" in kv)) next
  ns = kv["ns"]
  if (ns != "on" && ns != "off") next

  for (key in kv) {
    if (key == "ns" || key == "samples") continue
    val = kv[key]
    # Sadece sayısal görünen değerleri kabul et
    if (val !~ /^-?[0-9]+(\.[0-9]+)?$/) continue
    idx = count[key, ns] + 1
    count[key, ns] = idx
    values[key, ns, idx] = val + 0
    metrics[key] = 1
  }
}
END {
  for (key in metrics) metriclist[++mcount] = key
  # basit alfabetik sıralama (bash uyumlu, harici araç gerektirmez)
  for (i = 1; i <= mcount; i++) {
    for (j = i + 1; j <= mcount; j++) {
      if (metriclist[j] < metriclist[i]) {
        tmp = metriclist[i]; metriclist[i] = metriclist[j]; metriclist[j] = tmp
      }
    }
  }

  for (m = 1; m <= mcount; m++) {
    key = metriclist[m]
    printf "%s\n", key
    printf "%s\n", "----------------------------------------"

    for (gi = 1; gi <= 2; gi++) {
      grp = (gi == 1) ? "on" : "off"
      n = count[key, grp] + 0
      if (n == 0) {
        printf "  ns=%-3s : örnek yok\n", grp
        continue
      }
      # değerleri diziye kopyala ve sırala (basit insertion sort, n küçük)
      for (k = 1; k <= n; k++) sorted[k] = values[key, grp, k]
      for (k = 2; k <= n; k++) {
        v = sorted[k]; p = k - 1
        while (p >= 1 && sorted[p] > v) { sorted[p+1] = sorted[p]; p-- }
        sorted[p+1] = v
      }
      sum = 0
      for (k = 1; k <= n; k++) sum += sorted[k]
      mean = sum / n
      if (n % 2 == 1) {
        median = sorted[(n+1)/2]
      } else {
        median = (sorted[n/2] + sorted[n/2+1]) / 2
      }
      medians[key, grp] = median
      means[key, grp] = mean
      counts[key, grp] = n

      printf "  ns=%-3s : n=%-3d medyan=%.1fms ortalama=%.1fms\n", grp, n, median, mean
      if (n < 3) {
        printf "    UYARI: örnek sayısı az (n=%d < 3), medyan/ortalama güvenilir olmayabilir.\n", n
      }
      delete sorted
    }

    if ((count[key, "on"] + 0) > 0 && (count[key, "off"] + 0) > 0) {
      d_med = medians[key, "on"] - medians[key, "off"]
      d_mean = means[key, "on"] - means[key, "off"]
      base = medians[key, "off"]
      if (base != 0) {
        pct = (d_med / base) * 100
        printf "  Fark (medyan, on - off): %+.1fms (%+.1f%%)\n", d_med, pct
      } else {
        printf "  Fark (medyan, on - off): %+.1fms\n", d_med
      }
      printf "  Fark (ortalama, on - off): %+.1fms\n", d_mean
    } else {
      printf "  Karşılaştırma yapılamıyor: her iki grupta (ns=on ve ns=off) da örnek gerekli.\n"
    }
    print ""
  }
}
' "$LOG_FILE"
