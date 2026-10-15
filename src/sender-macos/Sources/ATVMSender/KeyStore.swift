import Foundation
import Security

/// Eşleşme anahtarlarının deposu: macOS Anahtar Zinciri, `kSecClassGenericPassword`,
/// servis = uygulama paketi kimliği, hesap = TV'nin IPv4 adresi, değer = 32 bayt anahtar.
/// Önceki sürümün düz dosyası (`paired_keys.json`, base64) ilk erişimde buraya taşınır ve silinir.
/// TV adları sır değildir; arayüz listesi için `paired_names.json` içinde kalır.
enum KeyStore {
    /// build-sender-app.sh'deki CFBundleIdentifier ile aynı. Sabit tutulur: paketsiz koşan CLI
    /// (`swift build` çıktısı) ile .app aynı kaydı görsün.
    static let service = "dev.atvm.sender"
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AndroidTVMirror")
    static let legacyFile = dir.appendingPathComponent("paired_keys.json")
    static let namesFile = dir.appendingPathComponent("paired_names.json")

    private static var migrationNote: String?
    private static let migrated: Void = migrateLegacyFile()

    /// Eski dosyayı hemen taşır; taşıma olduysa arayüz günlüğü için sonucu döndürür.
    static func prepare() -> String? {
        _ = migrated
        return migrationNote
    }

    static func key(for host: String) -> Data? {
        _ = migrated
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == 32 else { return nil }
        return data
    }

    /// Yalnız kaydın varlığına bakar; gizli değeri okumaz (liste çizimi her satırda çağırır).
    static func isPaired(_ host: String) -> Bool {
        _ = migrated
        var q = query(host)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func store(host: String, key: Data) -> OSStatus {
        _ = migrated
        return write(host: host, key: key)
    }

    static func remove(_ host: String) {
        _ = migrated
        SecItemDelete(query(host) as CFDictionary)
        var n = names(); n.removeValue(forKey: host); writeNames(n)
    }

    /// Eşleşmiş TV'lerin insanca okunur adları (arayüz listesi için; anahtar değeri tutulmaz).
    static func names() -> [String: String] {
        guard let data = try? Data(contentsOf: namesFile),
              let d = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return d
    }
    static func storeName(_ name: String, for host: String) {
        guard !host.hasPrefix("127.") else { return }   // döngü içi test kaydı listeyi kirletmesin
        var d = names()
        if d[host] == name { return }
        d[host] = name
        writeNames(d)
    }

    /// Yalnız gösterim adını düşürür; Anahtar Zinciri'ne dokunmaz. Adresi taşımış ve eşleşmesi
    /// olmayan eskimiş satırlar listeyi kirletmesin diye `TvDiscovery` tarafından çağrılır.
    static func dropName(_ host: String) {
        var d = names()
        guard d.removeValue(forKey: host) != nil else { return }
        writeNames(d)
    }

    private static func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: host]
    }

    private static func write(host: String, key: Data) -> OSStatus {
        let status = SecItemUpdate(query(host) as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query(host)
        add[kSecValueData as String] = key
        add[kSecAttrLabel as String] = "Pane Cast eşleşme anahtarı"
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func writeNames(_ dict: [String: String]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let e = try? JSONEncoder().encode(dict) { try? e.write(to: namesFile, options: .atomic) }
    }

    /// Düz dosyadaki anahtarlar Anahtar Zinciri'ne yazılır; hepsi yazılabildiyse dosya silinir,
    /// biri bile yazılamadıysa dosya yerinde kalır (anahtar kaybolmasın) ve sonraki açılışta yeniden denenir.
    private static func migrateLegacyFile() {
        guard let data = try? Data(contentsOf: legacyFile) else { return }
        let entries = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        var moved = 0, failed: [OSStatus] = []
        for (host, b64) in entries {
            guard let key = Data(base64Encoded: b64), key.count == 32 else { continue }
            let s = write(host: host, key: key)
            if s == errSecSuccess { moved += 1 } else { failed.append(s) }
        }
        if failed.isEmpty {
            try? FileManager.default.removeItem(at: legacyFile)
            migrationNote = "eşleşme anahtarları Anahtar Zinciri'ne taşındı (\(moved)); düz dosya silindi"
        } else {
            migrationNote = "Anahtar Zinciri'ne taşıma yarım kaldı (OSStatus \(failed)); düz dosya korunuyor"
        }
    }
}
