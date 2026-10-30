// PaneCast — Windows çekirdeği: §3.2 sabit vektör uygunluk testi.
// Vektörler Çapraz-dil doğrudur: src/sender-macos/Tests/ATVMSenderTests/PairingTests.swift ve
// receiver/selfcheck/PairingSelfCheck.kt aynı girdilerden aynı baytları bekler (CryptoKit'ten
// bağımsız saf tamsayı P-256 ile üretilmişlerdi). Windows'un CNG üstünde ürettikleri de
// birebir aynı çıkmak ZORUNDA — değilse iki bilgisayar aynı TV ile eşleşemez.
//
// Derleme (PC'de, dev shell):
//   cl /nologo /std:c++17 /EHsc /utf-8 pairingVectors.cpp ..\src\Crypto.cpp ..\src\Pairing.cpp ^
//      /link bcrypt.lib crypt32.lib
#include "../src/Pairing.h"

#include <cstdio>
#include <cstring>
#include <string>

using namespace atvm;

namespace {

int checks = 0, failures = 0;

void Check(const std::string& name, bool ok) {
    ++checks;
    if (!ok) { ++failures; printf("BAŞARISIZ: %s\n", name.c_str()); }
}

void EqHex(const std::string& name, const Bytes& got, const char* wantHex) {
    const std::string g = BytesToHex(got);
    ++checks;
    if (g != wantHex) {
        ++failures;
        printf("BAŞARISIZ: %s\n  beklenen=%s\n  geldi   =%s\n", name.c_str(), wantHex, g.c_str());
    }
}

Bytes Str(const char* s) { return Bytes(s, s + strlen(s)); }
Bytes First16(const Bytes& b) { return Bytes(b.begin(), b.begin() + 16); }
Bytes Na(int i) { return First16(Sha256({Str("atvm-test-na"), Bytes{(uint8_t)i}})); }
Bytes Nb(int i) { return First16(Sha256({Str("atvm-test-nb"), Bytes{(uint8_t)i}})); }

// Vektörler (PairingTests.swift:7-32 ile birebir aynı).
const char* SK_MAC = "de92ec869fe292bd368bebc32e7472160442cfe548ceadffd7e380acaa5bb08f";
const char* PK_MAC = "04b5dc2d415217c4db1cc346507fe5dfd2be6af8a9e69c04860532507f29a1514f"
                     "5228c17094d5917ef0d9e767ac8040bac6105e0838191882796d9a81f590a392";
const char* PK_TV = "04708fbeb90a5c6a27f0925857d960e3a83015433e02dd490a168514bd96e92510"
                    "91e92e0b922cb32da1de8e1984b0065cf639b3b52dc2338f78ccdd5c73d0ec45";
const char* DH_KEY = "51762f9b40260d8d4a400dc059afa9f82bc8973834481838a1ceee59cb93e5ba";
const char* TH0 = "1c797718f49979b81785313301940e3cdd3b951bf60bd183186093587e75cd49";
const char* KC = "283fb2404f85d4a898ab71c170f82f246a1262908341cdb8140483ec61f22b57";
const char* CA0 = "d619532b95a21a87dd9f3e880d873097aed0d5868d048171e264dba6a0f0fe6e";
const char* CB0 = "0e27ce33e57858cfcfe8228129e88150965ec822919cb6fa08c54e71bdd0f083";
const char* CA19 = "0fefa362b7d9e94e1a856f745085aaaf070d30e328902258fdf714c0ebecc1d5";
const char* CB19 = "c9f4139a16709c0b7ccc66ab10708b1718dad906cfbaa96a2d9f7b2f20576668";
const char* TH = "ef4afb7e5f3b2dd6c17cff89d0df5be078b1be1babd95c9c974cf68a46e84428";
const char* PAIR_KEY = "a6259fd659ea4f8be90ec535f2e1cc2aa2d6ebed915e0653eabff080201f2f37";
const char* CONFIRM_MAC = "e5cc88e276c2f36b997be89d296fe1977eff40db5aab3a81fc3b6f31ab1626ad";
const char* CONFIRM_TV = "d581de5b0e6563481b50d96f3eb282e8406ab1c4057efcd5c98fedff5ce4b4fc";
const char* CTL_MAC = "46247813686802f958220348b31afbc5dd9eb347e021b8221d2b5dfb5974b246";
const char* CTL_TV = "5a0ae43bf13160151895abb6c06a6b11320eabacf0a620050e39177c1f3578d7";
const char* REV_TV = "e7461be6ae7053c5ac6ab19689763d6d7acc27e764d3c4c12946097dd25cd124";
const char* REV_MAC = "50836ac6b8cb43c5e16546184fb85a92b31d3df2c68d7f40dcb0deac2b42d6bd";
const char* FINGERPRINT = "37cd082d";
const uint32_t PASSKEY = 123456;

const Bytes kPkMac = HexToBytes(PK_MAC);
const Bytes kPkTv = HexToBytes(PK_TV);
const Bytes kNonceTv(16, 0x11);
const Bytes kNonceMac(16, 0x22);

/// Tam 20 turluk eşleşmeyi bellekte sürer; dönen anahtarı verir.
Bytes runFullPairing() {
    EcdhKey sk;
    Check("skMac içeri alındı (pkMac türedi)",
          EcdhKey::FromPrivate(HexToBytes(SK_MAC), kPkMac, sk) &&
              BytesToHex(sk.publicX963()) == PK_MAC);
    int nonceIndex = 0;
    PasskeyInitiator init(PASSKEY, std::move(sk), [&nonceIndex] { return Na(nonceIndex++); });

    Msg out = init.initMessage();
    Check("pair_init.pk = pkMac", out.type() == "pair_init" && out.text["pk"] == B64Encode(kPkMac));

    Msg peer("pair_key");
    peer.text["pk"] = B64Encode(kPkTv);
    auto f = init.handle(peer, out);
    Check("pair_key → pk_commit(0)", f.kind == PasskeyInitiator::Error::None && out.type() == "pk_commit");
    EqHex("dh = vektör (CNG ters sırası düzeltildi dahil)", init.dh(), DH_KEY);
    EqHex("th0", Sha256({Str("atvm-pair-v2"), kPkMac, kPkTv}), TH0);
    EqHex("kc (HKDF kendi üstümüzde)", init.commitKeyBytes(), KC);

    for (int round = 0; round < PairingConst::kRounds; ++round) {
        if (out.type() != "pk_commit" || out.num("i", -1) != round) {
            Check("tur " + std::to_string(round) + " taahhüt bekleniyordu", false);
            return {};
        }
        const Bytes ca = B64Decode(out.text["c"]);
        if (round == 0) EqHex("ca0", ca, CA0);
        if (round == 19) EqHex("ca19", ca, CA19);
        Check("ca tur/bit kodlaması (" + std::to_string(round) + ")",
              ca == Commitment(init.commitKeyBytes(), Role::Mac, round,
                               PasskeyBit(PASSKEY, round), Na(round)));

        const Bytes cb = Commitment(init.commitKeyBytes(), Role::Tv, round,
                                    PasskeyBit(PASSKEY, round), Nb(round));
        if (round == 0) EqHex("cb0", cb, CB0);
        if (round == 19) EqHex("cb19", cb, CB19);

        Msg c("pk_commit");
        c.number["i"] = round;
        c.text["c"] = B64Encode(cb);
        f = init.handle(c, out);
        if (out.type() != "pk_open" || out.num("i", -1) != round) {
            Check("tur " + std::to_string(round) + " açılış bekleniyordu", false);
            return {};
        }
        Check("pk_open.n = na(round)", out.text["n"] == B64Encode(Na(round)));

        Msg o("pk_open");
        o.number["i"] = round;
        o.text["n"] = B64Encode(Nb(round));
        f = init.handle(o, out);
        if (f.kind != PasskeyInitiator::Error::None) {
            Check("tur " + std::to_string(round) + " açılışı reddetti", false);
            return {};
        }
    }

    Check("20 tur sonunda pair_confirm gitti", out.type() == "pair_confirm");
    EqHex("th (transcript özeti)", init.transcriptHash(), TH);
    EqHex("confirm(Mac)", Confirm(init.key(), Role::Mac, init.transcriptHash()), CONFIRM_MAC);
    Check("pair_confirm.mac = vektör", out.text["mac"] == B64Encode(HexToBytes(CONFIRM_MAC)));

    Msg paired("paired");
    paired.text["mac"] = B64Encode(HexToBytes(CONFIRM_TV));
    f = init.handle(paired, out);
    Check("paired doğrulandı ve makine bitti",
          f.kind == PasskeyInitiator::Error::None && out.type().empty());
    EqHex("K (eşleşme anahtarı)", init.key(), PAIR_KEY);
    Check("parmak izi", Fingerprint(init.key()) == FINGERPRINT);
    return init.key();
}

void negativeTests() {
    {
        EcdhKey sk;
        Check("yansıtılan anahtar reddedilir", [&] {
            if (!EcdhKey::FromPrivate(HexToBytes(SK_MAC), kPkMac, sk)) return false;
            Bytes dh;
            return !sk.SecretWith(kPkMac, dh);      // kendi açık anahtarımız
        }());
    }
    {
        Bytes bad = kPkTv;
        bad[64] ^= 0x01;                            // eğri dışı nokta
        EcdhKey sk;
        Check("eğri dışı nokta reddedilir",
              EcdhKey::FromPrivate(HexToBytes(SK_MAC), kPkMac, sk) && [&] {
                  Bytes dh;
                  return !sk.SecretWith(bad, dh);
              }());
    }
    {
        uint32_t v = 0;
        Check("PIN tam 6 rakam olmalı",
              PasskeyFromText("012345", v) && v == 12345 && !PasskeyFromText("12345", v) &&
                  !PasskeyFromText("12345a", v));
    }
}

}  // namespace

int main() {
    const Bytes key = runFullPairing();
    Check("eşleşme tamamlandı", key.size() == 32);
    if (key.size() == 32) {
        EqHex("P(K,ctl,mac)", SessionProof(key, Channel::Control, Role::Mac, kNonceTv, kNonceMac),
              CTL_MAC);
        EqHex("P(K,ctl,tv)", SessionProof(key, Channel::Control, Role::Tv, kNonceTv, kNonceMac),
              CTL_TV);
        EqHex("P(K,rev,tv)", SessionProof(key, Channel::Reverse, Role::Tv, kNonceMac, kNonceTv),
              REV_TV);
        EqHex("P(K,rev,mac)", SessionProof(key, Channel::Reverse, Role::Mac, kNonceMac, kNonceTv),
              REV_MAC);
        // Kanal ayrımı (§3.2): rev kanıtı ctl kanalda yansıtılamaz.
        Check("kanallar arası ayrım",
              !ConstantTimeEqual(SessionProof(key, Channel::Control, Role::Mac, kNonceTv, kNonceMac),
                                 SessionProof(key, Channel::Reverse, Role::Mac, kNonceMac, kNonceTv)));
    }
    negativeTests();
    if (failures == 0) printf("eşleştirme vektörleri: %d/%d GEÇTİ\n", checks, checks);
    else { printf("eşleştirme vektörleri: %d/%d BAŞARISIZ\n", failures, checks); return 1; }
    return 0;
}
