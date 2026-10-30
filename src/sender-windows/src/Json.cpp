#include "Json.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace atvm {

std::string JsonObject::escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 2);
    for (unsigned char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out.push_back(static_cast<char>(c));   // UTF-8 olduğu gibi geçer (JSON serbest)
            }
        }
    }
    return out;
}

std::string JsonObject::dump() const {
    std::string out = "{";
    bool first = true;
    auto add = [&](const std::string& piece) {
        if (!first) out += ',';
        first = false;
        out += piece;
    };
    for (const auto& [k, v] : strings_) add("\"" + escape(k) + "\":\"" + escape(v) + "\"");
    for (const auto& [k, v] : numbers_) {
        add("\"" + escape(k) + "\":" + std::to_string(v));
    }
    for (const auto& [k, v] : doubles_) {
        char buf[32];
        snprintf(buf, sizeof(buf), "%.6g", v);
        add("\"" + escape(k) + "\":" + buf);
    }
    out += "}";
    return out;
}

namespace {

struct Cursor {
    const std::string& s;
    size_t i = 0;

    void skip() {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) ++i;
    }
    bool eat(char c) {
        skip();
        if (i < s.size() && s[i] == c) { ++i; return true; }
        return false;
    }
};

/// Dize okur; kaçışları çözer. Biterken yanlışsa false.
bool readString(Cursor& c, std::string& out) {
    if (!c.eat('"')) return false;
    while (c.i < c.s.size()) {
        const char ch = c.s[c.i++];
        if (ch == '"') return true;
        if (ch != '\\') { out.push_back(ch); continue; }
        if (c.i >= c.s.size()) return false;
        const char e = c.s[c.i++];
        switch (e) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        case 't': out.push_back('\t'); break;
        case 'u': {
            if (c.i + 4 > c.s.size()) return false;
            unsigned cp = 0;
            for (int k = 0; k < 4; ++k) {
                const char h = c.s[c.i + k];
                cp <<= 4;
                if (h >= '0' && h <= '9') cp |= (h - '0');
                else if (h >= 'a' && h <= 'f') cp |= (h - 'a' + 10);
                else if (h >= 'A' && h <= 'F') cp |= (h - 'A' + 10);
                else return false;
            }
            c.i += 4;
            // Tek düzlem BMP: UTF-8'e çevir (surrogate çiftleri protokolde kullanılmıyor).
            if (cp < 0x80) out.push_back(static_cast<char>(cp));
            else if (cp < 0x800) {
                out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
                out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
            } else {
                out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
                out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
            }
            break;
        }
        default: return false;
        }
    }
    return false;
}

bool skipValue(Cursor& c);

bool skipObject(Cursor& c) {
    if (!c.eat('{')) return false;
    c.skip();
    if (c.eat('}')) return true;
    while (true) {
        std::string key;
        if (!readString(c, key)) return false;
        if (!c.eat(':')) return false;
        if (!skipValue(c)) return false;
        c.skip();
        if (c.eat(',')) continue;
        return c.eat('}');
    }
}

bool skipArray(Cursor& c) {
    if (!c.eat('[')) return false;
    c.skip();
    if (c.eat(']')) return true;
    while (true) {
        if (!skipValue(c)) return false;
        c.skip();
        if (c.eat(',')) continue;
        return c.eat(']');
    }
}

bool skipValue(Cursor& c) {
    c.skip();
    if (c.i >= c.s.size()) return false;
    const char ch = c.s[c.i];
    if (ch == '{') return skipObject(c);
    if (ch == '[') return skipArray(c);
    if (ch == '"') { std::string tmp; return readString(c, tmp); }
    if (ch == 't' || ch == 'f' || ch == 'n') {     // true/false/null: uzunlukları sabit
        static const char* lit[] = {"true", "false", "null"};
        for (const char* l : lit) {
            const size_t n = 4;
            if (c.s.compare(c.i, n, l) == 0) { c.i += n; return true; }
        }
        return false;
    }
    // Sayı: [-+digits][.digits][e...]
    size_t start = c.i;
    if (c.s[c.i] == '-' || c.s[c.i] == '+') ++c.i;
    bool digits = false;
    while (c.i < c.s.size()) {
        const char d = c.s[c.i];
        if ((d >= '0' && d <= '9')) { digits = true; ++c.i; continue; }
        if (d == '.' || d == 'e' || d == 'E' || d == '-' || d == '+') { ++c.i; continue; }
        break;
    }
    if (!digits || c.i == start) return false;
    return true;
}

/// Sayı değer okur (tam olarak ayrıştırılmış metin üzerinden).
bool readNumber(Cursor& c, long long& out) {
    c.skip();
    size_t start = c.i;
    if (!skipValue(c)) return false;
    const std::string text = c.s.substr(start, c.i - start);
    char* end = nullptr;
    const double v = strtod(text.c_str(), &end);
    if (end == text.c_str()) return false;
    out = llround(v);
    return true;
}

}  // namespace

std::optional<FlatJson> ParseFlatJson(const std::string& text) {
    Cursor c{text, 0};
    if (!c.eat('{')) return std::nullopt;
    FlatJson out;
    c.skip();
    if (c.eat('}')) return out;
    while (true) {
        std::string key;
        if (!readString(c, key)) return std::nullopt;
        if (!c.eat(':')) return std::nullopt;
        c.skip();
        if (c.i >= c.s.size()) return std::nullopt;
        const char head = c.s[c.i];
        if (head == '"') {
            std::string v;
            if (!readString(c, v)) return std::nullopt;
            out.strings[key] = v;
        } else if (head == '{' || head == '[') {
            // §7: eski uçlar tanımadığı alanı yok sayabilmeli — iç içe değer atlanır.
            if (head == '{' ? !skipObject(c) : !skipArray(c)) return std::nullopt;
        } else if (c.s.compare(c.i, 4, "true") == 0 || c.s.compare(c.i, 5, "false") == 0) {
            return std::nullopt;              // protokol hiçbir alanı boolean göndermiyor
        } else if (c.s.compare(c.i, 4, "null") == 0) {
            c.i += 4;                          // null = alan yok sayılır
        } else {
            long long v = 0;
            if (!readNumber(c, v)) return std::nullopt;
            out.numbers[key] = v;
        }
        c.skip();
        if (c.eat(',')) continue;
        if (c.eat('}')) break;
        return std::nullopt;
    }
    c.skip();
    if (c.i != c.s.size()) return std::nullopt;      // nesneden sonra artık: bozuk satır
    return out;
}

}  // namespace atvm
