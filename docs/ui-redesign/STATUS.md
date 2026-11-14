# Tình trạng redesign (đêm 15/11/2026)

Nhánh `ui-redesign` (đã push). Kiến trúc trong `ARCHITECTURE.md`, kế hoạch trong `PLAN.md`, ảnh 12 màn trong `shots/`.

## Đã xong
- Design system "Nhạc cụ" (Space Grotesk + JetBrains Mono, board vẽ như vật thể thật), 12 màn nối logic thật, Live Activity + Dynamic Island.
- Lần đầu mở app: xin quyền thật, ghép board bằng mã 6 số (chuẩn LE Secure Connections), chọn ngôn ngữ.
- Màn dịch: vòng mức giọng và phụ đề tạm tách khỏi danh sách (không vẽ lại cả list), Nghe lại / Sửa / Báo dịch sai, overlay mất kết nối, chế độ chỉ iPhone (mic iPhone nghe họ, "Giữ để nói").
- Lịch sử lưu trên máy (tắt được, không iCloud, file protection), báo sai kèm ghi âm, chỉ xuất file khi bạn bấm Gửi (không có server).
- Firmware: màn ghép "Ghép với iPhone" có Đúng/Sai, chỉ cho dùng khi đã ghép bằng mã, chống spam, board đang khoá thì không duyệt được. **Chưa nạp vào board.**
- Review độc lập + 3 lượt kiểm tra bảo mật tự động: đã sửa hết lỗi nặng.
- Test: 361 Swift Testing + 117 XCTest pass; build iPhone (app + widget) và firmware đều thành công.

## Sáng mai thử thế nào
1. Nạp firmware mới: `cd firmware && source ~/esp/esp-idf/export.sh && idf.py -p /dev/cu.usbmodem101 flash`.
2. Mở `ios/ESPTranslator.xcodeproj`, chọn iPhone "Cicca", Run (Xcode hỏi Team thì chọn tài khoản dev của bạn).
3. iPhone đã ghép board trước đây sẽ phải ghép lại một lần: board và iPhone cùng hiện 6 số, bấm "Đúng" trên board. Không thấy hộp thoại thì "Quên board này" trong app và quên thiết bị trong Cài đặt Bluetooth rồi ghép lại.
4. Xem nhanh giao diện không cần board: `ios/Tools/snap.sh` (chụp trên simulator) hoặc chạy app với `-demo live`.

## Cần thử trên máy thật (chưa kiểm được trên simulator)
- Ghép bằng mã với board thật, và trường hợp bấm Sai / huỷ.
- Chế độ chỉ iPhone: AirPods có giữ chất lượng nhạc khi mic iPhone nghe họ không; "Giữ để nói" có mất âm đầu không.
- Live Activity trên màn khoá thật, nút Dừng / Tắt mic.
- Tốc độ (bản sửa hôm qua): câu tiếng Anh còn ra chữ rác không, phụ đề có bị cắt khi ngập ngừng không.

## Còn mở
- Board giả khai phiên bản 2 nhưng không mã hoá thì iOS không phân biệt được; dấu hiệu là không có hộp thoại ghép kèm mã (đã nhắc trên màn ghép). Sửa tận gốc cần challenge-response.
- % pin board để trống: firmware chưa gửi pin qua BLE.
- Ở chế độ board, recognizer chết khi board im lặng chỉ được phát hiện ở gói audio kế tiếp.
- Server nhận dữ liệu chia sẻ: chưa làm (đang xuất file).
