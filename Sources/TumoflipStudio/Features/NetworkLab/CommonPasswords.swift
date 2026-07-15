import Foundation

/// Небольшой встроенный список частых WPA-паролей (>=8 символов) для быстрого
/// первого прохода «умного» подбора. Срабатывает мгновенно на слабых паролях.
/// Только для своих/авторизованных сетей.
enum CommonPasswords {
    static let list: [String] = [
        "12345678", "123456789", "1234567890", "password", "password1", "password123",
        "qwerty123", "qwertyuiop", "1qaz2wsx", "1q2w3e4r", "1q2w3e4r5t", "q1w2e3r4",
        "11111111", "000000000", "00000000", "88888888", "12341234", "147258369",
        "123123123", "112233445", "12121212", "987654321", "qwertyui", "asdfghjkl",
        "zxcvbnm123", "iloveyou", "iloveyou1", "letmein12", "welcome123", "admin123",
        "administrator", "passw0rd", "Passw0rd", "P@ssw0rd", "Password1", "Qwerty123",
        "wifipassword", "internet1", "internet123", "changeme1", "superman1", "abc12345",
        "abcd1234", "a1b2c3d4", "samsung1", "google123", "homewifi1", "mypassword",
        "secret123", "trustno1", "monkey123", "dragon123", "football1", "baseball1",
        "starwars1", "master123", "shadow123", "sunshine1", "princess1", "whatever1",
        "computer1", "freedom12", "qazwsxedc", "zaq12wsx", "asdf1234", "test1234",
        "guest1234", "user1234", "root1234", "default1", "wireless1", "network1",
        "router123", "linksys123", "netgear12", "dlink1234", "tplink123", "tplinkwifi",
        "keenetic1", "rostelecom", "rostelekom", "internet2024", "internet2023",
        "parol123", "parol1234", "12345678a", "qwerty12345", "1234qwer", "qwer1234",
        "11223344", "10203040", "13243546", "14725836", "19283746", "55555555",
        "77777777", "99999999", "qweqweqwe", "asdasdasd", "zxczxczxc", "1qazxsw2",
    ]
}
