# 🎙️ OpenWhisper — macOS için %100 Yerel ve Yapay Zeka Destekli Sesli Yazma (Voice-to-Text)

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0%2B-blue?style=for-the-badge&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Architecture-Apple%20Silicon%20(M1%2FM2%2FM3%2FM4)-orange?style=for-the-badge&logo=apple" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-5.10-F05138?style=for-the-badge&logo=swift" alt="Swift 5.10">
  <img src="https://img.shields.io/badge/Engine-WhisperKit%20CoreML-teal?style=for-the-badge" alt="WhisperKit CoreML">
  <img src="https://img.shields.io/badge/AI%20Cleanup-Ollama%20(ZORUNLU)-black?style=for-the-badge&logo=ollama" alt="Ollama Mandatory">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="MIT License">
</p>

**OpenWhisper**, macOS işletim sistemi için geliştirilmiş, konuşmalarınızı **%100 yerel (offline)** olarak yüksek doğrulukla metne dönüştüren açık kaynaklı bir sesli yazma uygulamasıdır.

Hiçbir ses veriniz bulut sunucularına gönderilmez. Whisper modeli doğrudan Mac'inizdeki **Apple Silicon (CoreML & Neural Engine)** üzerinde çalışır. Yerel yapay zeka **Ollama** entegrasyonu sayesinde konuşmanızdaki dolgu kelimeler ("ııı", "şey", "um", "yani") otomatik olarak temizlenir, noktalama ve gramer kusursuzlaştırılır.

---

## ⚠️ ZORUNLU SİSTEM GEREKSİNİMLERİ (PREREQUISITES)

Uygulamanın kurulup çalışabilmesi için sisteminizde aşağıdaki **3 bileşenin** bulunması **ZORUNLUDUR**:

| Bileşen | Zorunluluk Durumu | Açıklama |
|---|---|---|
| 🍏 **Apple Silicon Mac** | **ZORUNLU** | M1, M2, M3, M4 işlemcili Mac (Intel desteklenmez). |
| 🛠️ **Command Line Tools** | **ZORUNLU** | **Xcode uygulamasını indirmeye GEREK YOKTUR!** Sadece komut satırı araçları (`xcode-select --install`) yeterlidir. |
| 🦙 **Ollama (Yerel AI)** | **ZORUNLU** | Dikte edilen metindeki dolgu kelimelerini ("ııı", "şey", "um") temizlemek ve grameri düzeltmek için **Ollama ve `qwen2.5:7b` modelinin kurulması ZORUNLUDUR.** |

---

## 🚀 ZORUNLU KURULUM ADIMLARI (STEP-BY-STEP INSTALLATION)

Projeyi yeni bir Mac bilgisayara kurarken aşağıdaki adımları **sırasıyla ve eksiksiz** uygulayınız.

### 1. Adım: Command Line Tools Kurulumu (ZORUNLU)
*(Tam Xcode uygulamasını App Store'dan indirmenize gerek yoktur)*

Terminal uygulamasını açın ve şu komutu çalıştırın:
```bash
xcode-select --install
```
Ekrana gelen açılır pencerede **"Yükle" (Install)** butonuna basıp kurulumun tamamlanmasını bekleyin (~1-2 dk).

---

### 2. Adım: Ollama ve AI Modelinin Kurulumu (ZORUNLU)
Dikte temizleme motorunun çalışabilmesi için Ollama'nın ve yapay zeka modelinin yüklenmesi **şarttır**.

Terminal'de sırasıyla şu iki komutu çalıştırın:

```bash
# 1. Homebrew ile Ollama'yı kurun (Homebrew yoksa: https://brew.sh)
brew install ollama

# 2. Zorunlu yapay zeka modelini indirin
ollama pull qwen2.5:7b
```

> **Not:** Ollama kurulduktan sonra arka planda otomatik servis olarak çalışır (`http://localhost:11434`). Ekstra bir şey başlatmanıza gerek yoktur.

---

### 3. Adım: OpenWhisper'ı Derleme ve Çalıştırma (ZORUNLU)

Terminal'de proje klasörünün içine girip derleme betiğini çalıştırın:

```bash
# Projenin app klasörüne gidin
cd app

# Uygulamayı derleyin, /Applications klasörüne kursun ve başlatsın
bash build.sh
```

---

## ⚙️ macOS İZİNLERİ VE KLAVYE AYARLARI

Uygulama ilk kez başladığında menü çubuğunuzda (sağ üstte) turkuaz renkli bir mikrofon ikonu belirir. Uygulamanın sorunsuz çalışması için şu 2 ayarın yapılması **ZORUNLUDUR**:

### 1. Erişilebilirlik (Accessibility) İzni
Uygulamanın `Fn` tuşunu algılaması ve yazılan metni imlecin olduğu yere yapıştırabilmesi için:
* **Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik** bölümüne gidin.
* listeden **OpenWhisper** uygulamasını bulun ve anahtarı **AÇIK (ON)** konuma getirin.

### 2. Klavye Fn/Globe Tuşu Ayarı
macOS varsayılan olarak `Fn` tuşuna basıldığında Emoji menüsünü açar. Bunun çakışmaması için:
1. **Sistem Ayarları → Klavye** menüsüne gidin.
2. **"🌐 tuşuna basıldığında"** (Press 🌐 key to) seçeneğini **"Hiçbir Şey Yapma" (Do Nothing)** olarak ayarlayın.

---

## 📖 KULLANIM KILAVUZU

OpenWhisper menü çubuğunuzda sessizce çalışır. Metin girişi yapılabilen her yerde (VS Code, Terminal, Slack, Notlar, Chrome vs.) kullanılabilir.

- 🎙️ **Bas-Konuş (Hold-to-Talk)**:
  `🌐 Fn` tuşuna **basılı tutun**, konuşun ve tuşu **bırakın**. Metin temizlenerek anında imlecinize yazılır.
  *(İlk konuşmada Whisper ses modeli otomatik indirilir, ~1-2 dk sürer).*

- 🔒 **Eller Serbest Modu (Hands-Free Lock)**:
  `🌐 Fn` tuşuna basılı tutarken **`Space`** veya **`Enter`** tuşuna bir kez basın. Kilit aktifleşir. Parmağınızı Fn'den çekip uzun uzun konuşun. Bitirmek için tekrar **`Space`** veya **`Enter`** tuşuna basın.

- ❌ **İptal Etme**:
  Konuşma sırasında **`Esc`** tuşuna basarsanız kayıt metne dönüştürülmeden anında iptal edilir.

---

## 📊 WHISPER MODEL SEÇENEKLERİ

Uygulama menü çubuğundaki ikona tıklanarak Ayarlar menüsünden model değiştirilebilir:

| Model | Boyut | Hız | Kullanım Amacı |
|---|---|---|---|
| **tiny** | 39 MB | En Hızlı | Kısa basit notlar |
| **base** | 140 MB | Hızlı | Günlük standart dikte |
| **small** | 460 MB | Orta | Uzun paragraflar ve çoklu dil |
| **Large v3 Turbo** *(Varsayılan & Önerilen)* | ~1.6 GB | Dengeli | En yüksek doğruluk (Türkçe & İngilizce hibrit mod) |

---

## 📄 LİSANS

Bu proje [MIT Lisansı](LICENSE) altında lisanslanmıştır. Free & Open Source.
