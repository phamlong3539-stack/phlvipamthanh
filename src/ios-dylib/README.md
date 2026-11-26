# PHLVoiceEngine iOS Dynamic Library (`arm64`)

Xem hướng dẫn tổng thể dự án tại [../README.md](../README.md).

## Cách 1: Build tự động trên GitHub Actions (Không cần máy Mac)
1. Tạo 1 repository trên GitHub (khuyên dùng **Private** nếu muốn giữ kín mã nguồn, ví dụ `phl-voice-dylib-builder`).
2. Upload toàn bộ nội dung bên trong thư mục `ios-dylib/` (gồm `Makefile`, `src/`, `scripts/`, và `.github/workflows/build-ios-dylib.yml`) lên nhánh `main`.
3. *(Tùy chọn - khuyến nghị)* Vào **Settings -> Secrets and variables -> Actions -> New repository secret**, thêm `VOICE_SIGNING_SECRET` trùng với secret của repo `amthanh_dylib`.
4. Vào tab **Actions** -> chọn **Build iOS arm64 PHLVoiceEngine.dylib** -> bấm **Run workflow** (nếu bật `create_release: true` sẽ tạo luôn link tải trực tiếp `.dylib` ở mục **Releases**).
5. Tải file `PHLVoiceEngine-arm64-dylib` trong mục **Artifacts** (hoặc tải thẳng `.dylib` trong **Releases**), giải nén và chèn vào IPA bằng **Esign**.

## Cách 2: Build trực tiếp trên macOS + Xcode
```bash
make clean && make SIGNING_SECRET="YOUR_VOICE_SIGNING_SECRET"
make verify
```
Hoặc build không nhúng khóa:
```bash
make clean && make
```
File thành phẩm nằm tại `build/PHLVoiceEngine.dylib` (`arm64`, `iOS >= 13.0`, không phụ thuộc CydiaSubstrate/ElleKit).
