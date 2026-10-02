# ESP32 Translator: phiên dịch Anh ↔ Việt trực tiếp

Board Waveshare ESP32-S3-Touch-AMOLED-1.75C + iPhone (iOS 26) + AirPods Pro.

## Kiến trúc

```
Họ → Bạn   Mic ESP32 ─ADPCM/BLE 20ms─► SpeechTranscriber en-US ─câu chốt─► dịch EN→VI ─► giọng đọc vi-VN ─► AirPods
Bạn → Họ   Mic AirPods (khử vọng) ───► DictationTranscriber vi-VN ─từng phần─► dịch VI→EN ─BLE─► phụ đề trên ESP32
Điều phối  Bạn đang nói (hoặc vừa ngừng < 1 s) → bỏ kết quả kênh Họ → Bạn, để mic board không dịch nhầm giọng bạn
```

Những điểm giữ độ trễ thấp:
- **Chạy trên máy, không cần mạng**: nhận dạng giọng nói (SpeechAnalyzer) và dịch (Translation, iOS 26.4+ dùng `.lowLatency`) đều chạy offline, sóng 4G yếu cũng không ảnh hưởng.
- **Model nạp sẵn**: analyzer chạy suốt phiên (`modelRetention: .processLifetime`), giọng đọc được nạp sẵn lúc mở app.
- **Phụ đề chạy theo lời nói**: kết quả nhận dạng tạm được dịch liền. Bản dịch cũ chưa kịp hiện sẽ bị bỏ (`LatestWinsTranslator`), nên chữ trên board luôn bám theo câu đang nói.
- **Giọng đọc theo từng câu**: đọc ngay khi model chốt câu (`fastResults`), không đợi người kia nói hết lượt.
- **BLE**: 2M PHY, khoảng kết nối 15–30 ms, MTU 247. Âm thanh gửi bằng notify không cần xác nhận, chữ gửi bằng write-without-response. Mỗi gói ADPCM tự mang trạng thái, nên mất một gói chỉ thành một khoảng lặng 20 ms.

## Thư mục

| Đường dẫn | Nội dung |
|---|---|
| `firmware/` | ESP-IDF 5.5: `ble_link.c` (GATT), `audio_in.c` (2 mic → ADPCM), `ui.c` (LVGL, font Be Vietnam Pro) |
| `ios/` | App SwiftUI, tạo project bằng `xcodegen generate` |
| `fonts/` | Font Be Vietnam Pro (giấy phép OFL) |

## Giao thức BLE (service `A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A`)

| Char | Thuộc tính | Dữ liệu |
|---|---|---|
| `…0002` audio | notify | `[seq u16][predictor i16][index u8][IMA ADPCM 4-bit, nibble thấp trước]`, 16 kHz mono |
| `…0003` text | write / write-no-rsp | `[flags u8][kind u8][UTF-8]`. flags bit0 = chunk đầu, bit1 = chunk cuối. kind 0 = phụ đề, 1 = trạng thái |
| `…0004` control | read / write / notify | 1 byte: 0 = tắt mic board, 1 = bật |

## Chạy

Firmware:
```sh
. ~/esp/esp-idf/export.sh
cd firmware && idf.py -p /dev/cu.usbmodem1101 flash monitor
```

App iPhone:
1. Xcode → Settings → Components: tải **iOS 26.4 Platform**.
2. Mở `ios/ESPTranslator.xcodeproj` → target ESPTranslator → Signing & Capabilities: chọn Team (Apple ID cá nhân là đủ).
3. Cắm iPhone, bật Developer Mode trên iPhone (Cài đặt → Quyền riêng tư & Bảo mật), rồi bấm Run.
4. Lần đầu mở app: tải gói dịch Anh ↔ Việt và model nhận dạng. Sau đó dùng offline.

Khôi phục firmware demo gốc: tải bản factory từ [repo của Waveshare](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75) rồi nạp lại.
Nếu đã tự sao lưu toàn bộ flash (`esptool read-flash 0 0x2000000 backup.bin`) thì nạp lại bằng `esptool write-flash 0 backup.bin`.
Thư mục `backup/` nằm trong `.gitignore`, vì bản sao lưu có thể chứa mật khẩu Wi-Fi.

## Tinh chỉnh

Trong `ios/Sources/App/ConversationEngine.swift`:
- `echoHold` (mặc định 1 s): thời gian vẫn bỏ kết quả mic board sau khi bạn ngừng nói. Tăng lên nếu board vẫn dịch nhầm giọng bạn.
- `turnGap` (mặc định 2 s): ngừng nói lâu hơn khoảng này thì board bắt đầu màn phụ đề mới.

Trong `ios/Sources/Speech/Speaker.swift`:
- `rate`: tốc độ giọng đọc.

Trong `firmware/main/audio_in.c`:
- `MIC_GAIN_DB`: độ khuếch đại mic board.

## Giấy phép

Code: MIT. Font Be Vietnam Pro: SIL OFL 1.1 (`fonts/OFL.txt`).
