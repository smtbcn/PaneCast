// PaneCast — Windows yayıncısı: düz JSON nesneleri (kontrol kanalının tel biçimi).
// docs/protocol.md §3: tek satır = tek JSON nesnesi, `\n` ile biter, satır tavanı 8192 bayt.
// Mesajlar düz (iç içe nesne/dizi yok) ve sayı/alan adlarını biz yazıyoruz; bu yüzden
// tam bir JSON ayrıştırıcısı değil, protokolün gerektirdiği kadarı burada duruyor (ADR-001: bağımlılık yok).
#pragma once

#include <map>
#include <optional>
#include <string>

namespace atvm {

/// Yazma: alanlar eklenme sırasında taşınabilir sırada tutulur (std::map alphabetical —
/// protokol anahtar sırasına bakmaz, JSON nesnesi sırasızdır).
class JsonObject {
public:
    void set(const std::string& key, const std::string& value) { strings_[key] = value; }
    void set(const std::string& key, long long value) { numbers_[key] = value; }
    void set(const std::string& key, double value) { doubles_[key] = value; }

    std::string dump() const;
    /// UTF-8 güvenli kaçış (" ve \ ve kontrol karakterleri).
    static std::string escape(const std::string& s);

private:
    std::map<std::string, std::string> strings_;
    std::map<std::string, long long> numbers_;
    std::map<std::string, double> doubles_;
};

/// Okuma: aykırı JSON → std::nullopt (yayıncı `denied/bad_json` bekler, alıcı öyle davranıyor).
struct FlatJson {
    std::map<std::string, std::string> strings;
    std::map<std::string, long long> numbers;
    std::map<std::string, bool> bools;

    std::string str(const std::string& k) const {
        auto it = strings.find(k);
        return it == strings.end() ? std::string() : it->second;
    }
    long long num(const std::string& k, long long def) const {
        auto it = numbers.find(k);
        return it == numbers.end() ? def : it->second;
    }
    bool boolean(const std::string& k, bool def) const {
        auto it = bools.find(k);
        return it == bools.end() ? def : it->second;
    }
};

std::optional<FlatJson> ParseFlatJson(const std::string& text);

}  // namespace atvm
