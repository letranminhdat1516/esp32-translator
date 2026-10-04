import Testing
@testable import TranslatorCore

@Suite struct VietnameseFixupTests {
    /// Mishearings observed in the measurement spike
    @Test(arguments: [
        ("Tôi đang đợi xe Grant out trước cửa khách sạn", "Tôi đang đợi xe Grab trước cửa khách sạn"),
        ("Tôi đang đợi xe Gran out trước cửa khách sạn", "Tôi đang đợi xe Grab trước cửa khách sạn"),
        ("Tôi đang đợi xe gram trước cửa khách sạn", "Tôi đang đợi xe Grab trước cửa khách sạn"),
        ("Bạn có biết mật khẩu hoa phay ở đây không", "Bạn có biết mật khẩu Wi-Fi ở đây không"),
        ("Bạn có biết mật khẩu khoai tây ở đây không", "Bạn có biết mật khẩu Wi-Fi ở đây không"),
        ("Bạn có biết mật khẩu phai ở đây không", "Bạn có biết mật khẩu Wi-Fi ở đây không"),
        ("Ở đây có wifi không em", "Ở đây có Wi-Fi không em"),
        ("Mình nhắn tin qua giữa lo cho tiện nhé", "Mình nhắn tin qua Zalo cho tiện nhé"),
        ("Mình nhắn tin qua Zalo lo cho tiện nhé", "Mình nhắn tin qua Zalo cho tiện nhé"),
        ("1 đối tác ở C nga co nên tháng sau", "1 đối tác ở Singapore nên tháng sau"),
        ("1 đối tác ngở Phi Nga to nên tháng sau", "1 đối tác ở Singapore nên tháng sau"),
        ("1 đối tác ở China com nên tháng sau", "1 đối tác ở Singapore nên tháng sau"),
        ("gửi qua phây búc nhé", "gửi qua Facebook nhé"),
        ("gửi i meo cho chị", "gửi email cho chị"),
        ("ô kê mai gặp nhé", "OK mai gặp nhé"),
    ])
    func loanwords(heard: String, meant: String) {
        #expect(VietnameseFixup.fixLoanwords(heard) == meant)
    }

    /// Ordinary Vietnamese that looks like a rule must stay as it is
    @Test(arguments: [
        "Tôi lo lắng giữa lo âu và hy vọng",
        "Tôi mua khoai tây ở chợ",
        "Một gram vàng giá bao nhiêu",
        "Xe ra cổng rồi",
        "Bông hoa pha lê đẹp quá",
        "Ngỡ ngàng quá",
    ])
    func loanwordsLeaveOrdinaryWords(_ text: String) {
        #expect(VietnameseFixup.fixLoanwords(text) == text)
    }

    @Test(arguments: [
        // Wrong VI→EN cases from the spike
        ("Em ơi, tính tiền!", "Cho tôi thanh toán!"),
        ("Em ơi tính tiền", "Cho tôi thanh toán"),
        ("Cái áo này giá ba trăm nghìn, em lấy anh hai trăm rưỡi thôi.",
         "Cái áo này giá ba trăm nghìn, em tính anh hai trăm năm mươi thôi."),
        ("em lấy anh 250.000 thôi", "em tính anh 250.000 thôi"),
        ("Thôi kệ đi, đừng để bụng.", "Thôi kệ đi, đừng giận."),
        ("Ăn quả nhớ kẻ trồng cây.", "Hãy biết ơn những người đã giúp đỡ mình."),
        // Awkward cases
        ("Anh ơi, cho em hỏi đường ra bến xe với ạ.", "Cho em hỏi đường ra bến xe với ạ."),
        ("Mắc quá, bớt chút đi chị.", "Đắt quá, giảm giá chút đi chị."),
        ("Đi đâu mà vội mà vàng.", "Sao phải vội vàng thế."),
        // Vocative at the end, and loanwords before translation
        ("Cho em hai ly trà đá nhé chị ơi", "Cho em hai ly trà đá nhé"),
        ("mật khẩu hoa phay là gì vậy anh ơi", "mật khẩu Wi-Fi là gì vậy"),
    ])
    func forTranslation(spoken: String, translated: String) {
        #expect(VietnameseFixup.forTranslation(spoken) == translated)
    }

    @Test(arguments: [
        "Em lấy anh hai cái nhé.",
        "Anh lấy em nhé, em đồng ý không?",
        "Tôi bị mắc kẹt trong thang máy.",
        "Bớt chút đường cho tôi.",
        "Tính tiền điện tháng này bao nhiêu?",
        "Trời ơi, đẹp quá!",
        "Mẹ ơi, con về rồi.",
        "Ông bà ấy sống ở quê.",
    ])
    func forTranslationLeavesOtherSentences(_ text: String) {
        #expect(VietnameseFixup.forTranslation(text) == text)
    }
}
