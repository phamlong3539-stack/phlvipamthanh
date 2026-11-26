# PHL Voice & Music Engine (`arm64` iOS `.dylib` + GitHub Admin Pipeline)

Hệ thống đổi giọng micro thời gian thực và phát nhạc tách biệt dành cho iOS (`arm64`) inject qua **Esign** (hoặc các công cụ ký IPA tương tự), vận hành hoàn toàn tập trung qua hai kho GitHub:

- **Kho Admin, Dữ liệu Giọng & Khóa:** `https://github.com/phamlong3539-stack/amthanh_dylib`
- **Kho Nhạc ổn định:** `https://github.com/phamlong3539-stack/phl-music-data`

---

## 1. Cấu trúc Dự án

```text
phl-voice-music-engine/
├── amthanh-dylib-repo/                 # Đẩy lên kho phamlong3539-stack/amthanh_dylib
│   ├── admin/
│   │   ├── config.json                 # Cấu hình giọng, khóa, bảo trì & liên kết nhạc
│   │   └── source_audio/*.wav          # 1 đoạn âm thanh mẫu gốc cho mỗi giọng
│   ├── scripts/
│   │   └── build_manifest.py           # Phân tích âm thanh -> tham số DSP + ký HMAC-SHA256
│   └── .github/workflows/
│       └── publish-voice-engine.yml    # GitHub Actions tự xuất dist/packs/*.json & dist/manifest.json
│
├── phl-music-data-repo/                # Đẩy lên kho phamlong3539-stack/phl-music-data
│   ├── tracks/                         # Thả file nhạc (.mp3, .m4a, .aac, .wav, .flac, .ogg)
│   ├── playlist.json                   # Danh sách nhạc chuẩn
│   ├── scripts/sync_playlist.py        # Quét tracks/, tính SHA-256 & thời lượng
│   └── .github/workflows/
│       └── sync-playlist.yml           # GitHub Actions tự cập nhật playlist.json
│
└── ios-dylib/                          # Mã nguồn C++17 / Objective-C++ biên dịch .dylib arm64
    ├── Makefile
    ├── scripts/gen_obfuscated_key.py   # Tạo bảng byte XOR xoay vòng khi build (không plain-text)
    └── src/
        ├── PHLVoiceDSP.hpp             # DSP lock-free real-time (Pitch/Formant/EQ/Gate/Comp/Limiter)
        ├── PHLSyncManager.h / .mm      # Đồng bộ GitHub ?cb=, HMAC-SHA256 + Keychain Anti-Tamper Seal
        ├── PHLMusicManager.h / .mm     # Trình tải & phát nhạc độc lập hoàn toàn với mic
        ├── PHLOverlayUI.h / .mm        # Menu nổi kéo thả, tự thu sát mép, 3 tab, progress chống đơ
        └── PHLVoiceMain.mm             # __attribute__((constructor)) + Fishhook & AVAudioInputNode
```

---

## 2. Cơ chế Bảo mật & Chống Crack Quyền Admin

1. **Không lưu mật khẩu Admin hay khóa ký dạng plain-text trong `.dylib`:**
   - Mọi quyền thêm/sửa/xóa/khóa/mở khóa/bảo trì nằm trên GitHub `phamlong3539-stack/amthanh_dylib` và `phamlong3539-stack/phl-music-data`.
   - `VOICE_SIGNING_SECRET` được lưu trong **GitHub Repository Secrets**.
2. **Hai lớp xác thực phía `.dylib`:**
   - **Lớp 1 — Chữ ký `HMAC-SHA256` & `payload_sha256`:** Khi biên dịch `.dylib` với `make SIGNING_SECRET="..."`, script `gen_obfuscated_key.py` mã hóa khóa thành bảng byte XOR xoay vòng ngẫu nhiên mỗi lần build (không có chuỗi plain-text trong nhị phân) để xác minh trực tiếp chữ ký `HMAC-SHA256` của `dist/manifest.json`. Nếu build mặc định không truyền secret (`make`), `.dylib` vẫn xác minh `payload_sha256`, `pack_sha256` và khóa fingerprint theo Keychain.
   - **Lớp 2 — Keychain Device Anti-Tamper Seal & Anti-Rollback:** Cache cục bộ trong `Library/Application Support/PHLVoiceEngine/` được niêm phong bằng khóa ngẫu nhiên 256-bit lưu trong **iOS Keychain** (`ThisDeviceOnly`) kèm bộ đếm phiên bản đơn điệu (`monotone_version`). Nếu người dùng sửa file cache (`"locked": false`) hoặc thay bằng file cũ, chữ ký niêm phong thất bại ngay lập tức -> `.dylib` **từ chối dữ liệu giả, bật cờ cảnh báo và giữ micro ở trạng thái khóa an toàn (passthrough giọng gốc)**.

---

## 3. Hướng dẫn Triển khai lên 2 Kho GitHub

### Bước A: Thiết lập `phamlong3539-stack/amthanh_dylib`
1. Copy toàn bộ nội dung trong `amthanh-dylib-repo/` lên nhánh `main` của kho `phamlong3539-stack/amthanh_dylib`.
2. Vào **GitHub Repo -> Settings -> Secrets and variables -> Actions -> New repository secret**:
   - **Name:** `VOICE_SIGNING_SECRET`
   - **Secret:** Một chuỗi bí mật ngẫu nhiên mạnh (tối thiểu 24–32 ký tự, ví dụ sinh bằng `openssl rand -hex 32`).
3. Vào **Settings -> Actions -> General -> Workflow permissions**: chọn **Read and write permissions** để GitHub Actions push được thư mục `dist/` lên `main`.
4. Chạy thử workflow `Publish PHL Voice Engine Manifest` (hoặc push một thay đổi trong `admin/config.json`). Khi thành công, kho sẽ có:
   - `dist/manifest.json` (đã ký HMAC-SHA256)
   - `dist/packs/<id>.json` (chứa bộ 10 tham số DSP tự tái tạo từ audio mẫu)

### Bước B: Thiết lập `phamlong3539-stack/phl-music-data`
1. Copy toàn bộ nội dung trong `phl-music-data-repo/` lên nhánh `main` của kho `phamlong3539-stack/phl-music-data`.
2. Bật **Read and write permissions** cho GitHub Actions trong **Settings -> Actions -> General**.
3. Thả các file nhạc (`.mp3`, `.m4a`, `.aac`, `.wav`, `.flac`, `.ogg`) vào thư mục `tracks/` rồi push lên `main`.
4. Workflow `Sync & Validate PHL Music Playlist` sẽ tự động kiểm tra, tính SHA-256, đo thời lượng và cập nhật `playlist.json`.

---

## 4. Cách Vận hành Hàng ngày cho Admin (Không cần build lại `.dylib`)

- **Thêm giọng nói mới từ 1 đoạn âm thanh mẫu:**
  1. Đẩy 1 file âm thanh mẫu (`.wav`, `.mp3`, `.m4a`, ...) vào `admin/source_audio/<ten>.wav` trong kho `amthanh_dylib`.
  2. Khai báo thêm object mới trong `voices` ở `admin/config.json` (đặt `"locked": false`).
  3. Push lên `main` -> Actions tự phân tích tần số cơ bản `F0`, phổ tần số, độ ồn nền và xuất `dist/packs/<id>.json` + `dist/manifest.json` mới. Sau ~15 giây (hoặc khi người dùng bấm **Đồng bộ ngay**), giọng mới xuất hiện trên App!
- **Khóa từng giọng / Khóa toàn bộ / Bật bảo trì:**
  - Chỉnh `"locked": true` ở giọng cần khóa, hoặc `"global_lock": true`, hoặc `"maintenance": { "enabled": true, "message": "..." }` trong `admin/config.json` -> Push lên `main`.
- **Khóa nhạc từ xa:**
  - Chỉnh `"global_lock": true` hoặc thêm ID bài hát vào `"locked_track_ids": ["..."]` trong mục `"music"` của `admin/config.json`, **hoặc** chỉnh `"locked": true` trực tiếp trong `playlist.json` của kho `phl-music-data`.

---

## 5. Biên dịch `.dylib` (`arm64`) & Chèn bằng Esign

### Biên dịch trên macOS (đã cài Xcode / Command Line Tools)
```bash
cd ios-dylib

# Cách 1 (Khuyến nghị - xác thực chặt chẽ HMAC-SHA256 không lộ plain-text secret):
make clean
make SIGNING_SECRET="CHUOI_VOICE_SIGNING_SECRET_CUA_BAN"

# Cách 2 (Zero-Secret trong binary, dùng Keychain Anti-Tamper + SHA-256):
make clean
make

# Kiểm tra kiến trúc arm64 và thư viện liên kết (không phụ thuộc Substrate):
make verify
```
File thành phẩm nằm tại: `ios-dylib/build/PHLVoiceEngine.dylib`.

### Chèn & Ký IPA bằng Esign trên iPhone/iPad
1. Chuyển file `PHLVoiceEngine.dylib` sang iPhone/iPad và nhập vào ứng dụng **Esign**.
2. Chọn file `.ipa` của Game/App -> nhấn **Ký (Signature)** -> **Thêm thư viện (Add Library / Inject dylib)** -> chọn `PHLVoiceEngine.dylib`.
3. *(Lưu ý quan trọng nếu Game chưa từng xin quyền micro)*: Trong mục cấu hình `Info.plist` của Esign, đảm bảo có khóa `NSMicrophoneUsageDescription` (ví dụ: `"Cho phép sử dụng micro để chat voice và xử lý âm thanh"`), nếu không iOS có thể đóng app khi game mở mic.
4. Nhấn **Ký & Cài đặt**. Khi mở Game/App:
   - Nút nổi **`PHL MIC`** sẽ xuất hiện (có thể kéo thả mượt và tự thu gọn sát mép màn hình).
   - Chạm **`PHL MIC`** để mở Menu 3 Tab tách biệt: **Đổi Giọng**, **Nhạc** (phát độc lập từ `phl-music-data`), và **Hệ Thống** (nút **Đồng bộ ngay** + chẩn đoán hook micro thời gian thực).
