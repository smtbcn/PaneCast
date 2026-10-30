// PaneCast — CNG kriptografi kırisi (Windows çekirdeğinin ilk ölçümü, görev #7'nin ön koşulu)
//
// Neden: eşleştirme (docs/protocol.md §3.2) ECDH P-256 + HKDF-SHA256 + HMAC-SHA256 ister.
// macOS CryptoKit ve Android javax.crypto bu sırrı büyük-endian x koordinati olarak veriyor
// (test vektörlerinde dhKey öyle). BCrypt'in BCRYPT_KDF_RAW_SECRET çıktısının bayt sırası
// tartışmalı; **varsaymak tüm eşleştirmeyi sessizce bozar**. Bu program depodaki sabit vektörle
// cevap verir: skMac + pkTv → dhKey mi, tersi mi?
//
// Vektörün kaynağı: src/sender-macos/Tests/ATVMSenderTests/PairingTests.swift ve
// receiver/selfcheck/PairingSelfCheck.kt (CryptoKit'ten bağımsız tamsayı P-256 üretimi).
//
// Derleme (PC'de, dev shell):
//   cl /nologo /std:c++17 /EHsc /utf-8 cryptoProbe.cpp /link bcrypt.lib
#include <windows.h>
#include <bcrypt.h>
#include <stdio.h>

#pragma comment(lib, "bcrypt.lib")

static void Hex(const char* k, const UCHAR* p, ULONG n) {
    printf("%s=", k);
    for (ULONG i = 0; i < n; ++i) printf("%02x", p[i]);
    printf("\n");
}

static void Unhex(const char* hex, UCHAR* out, size_t outLen) {
    for (size_t i = 0; i < outLen; ++i) {
        unsigned v = 0; sscanf(hex + 2 * i, "%02x", &v); out[i] = (UCHAR)v;
    }
}

// Vektör (çift sayı: hex 64 karakter = 32 bayt; pk 130 karakter = 65 bayt X9.63)
static const char* SK_MAC = "de92ec869fe292bd368bebc32e7472160442cfe548ceadffd7e380acaa5bb08f";
static const char* PK_MAC = "04b5dc2d415217c4db1cc346507fe5dfd2be6af8a9e69c04860532507f29a1514f"
                            "5228c17094d5917ef0d9e767ac8040bac6105e0838191882796d9a81f590a392";
static const char* PK_TV  = "04708fbeb90a5c6a27f0925857d960e3a83015433e02dd490a168514bd96e92510"
                            "91e92e0b922cb32da1de8e1984b0065cf639b3b52dc2338f78ccdd5c73d0ec45";
static const char* DH_KEY = "51762f9b40260d8d4a400dc059afa9f82bc8973834481838a1ceee59cb93e5ba";
static const char* TH0    = "1c797718f49979b81785313301940e3cdd3b951bf60bd183186093587e75cd49";
static const char* KC     = "283fb2404f85d4a898ab71c170f82f246a1262908341cdb8140483ec61f22b57";

#define BCHECK(expr) do { NTSTATUS st = (expr); if (st < 0) { printf("FATAL " #expr " = 0x%08lx\n", (unsigned long)st); return 1; } } while (0)

int main() {
    BCRYPT_ALG_HANDLE hEcdh = nullptr, hHash = nullptr;
    BCHECK(BCryptOpenAlgorithmProvider(&hEcdh, BCRYPT_ECDH_P256_ALGORITHM, nullptr, 0));
    BCHECK(BCryptOpenAlgorithmProvider(&hHash, BCRYPT_SHA256_ALGORITHM, nullptr, 0));

    // --- 1) Tamamen CNG ile üretilmiş anahtarın blob biçimini ÖĞREN -----------------
    BCRYPT_KEY_HANDLE gen = nullptr;
    BCHECK(BCryptGenerateKeyPair(hEcdh, &gen, 256, 0));
    BCHECK(BCryptFinalizeKeyPair(gen, 0));
    ULONG cbPriv = 0, cbPub = 0, done = 0;
    BCHECK(BCryptExportKey(gen, nullptr, BCRYPT_ECCPRIVATE_BLOB, nullptr, 0, &cbPriv, 0));
    BCHECK(BCryptExportKey(gen, nullptr, BCRYPT_ECCPUBLIC_BLOB, nullptr, 0, &cbPub, 0));
    printf("GEN_PRIV_BLOB_BYTES=%u GEN_PUB_BLOB_BYTES=%u\n", cbPriv, cbPub);
    BYTE privBlob[512] = {}, pubBlob[256] = {};
    BCHECK(BCryptExportKey(gen, nullptr, BCRYPT_ECCPRIVATE_BLOB, privBlob, cbPriv, &done, 0));
    Hex("GEN_PRIV_HDR_MAGIC", privBlob, 4);
    printf("GEN_PRIV_cbKey=%u\n", *(ULONG*)(privBlob + 4));
    BCHECK(BCryptExportKey(gen, nullptr, BCRYPT_ECCPUBLIC_BLOB, pubBlob, cbPub, &done, 0));
    printf("GEN_PUB_HDR_cbKey=%u\n", *(ULONG*)(pubBlob + 4));
    // Özel skalar hangi uçta yazılı? X'in ilk baytı ile karşılaştırma için ikisini de bas.
    const ULONG cbKey = *(ULONG*)(pubBlob + 4);
    Hex("GEN_PUB_X", pubBlob + 8, cbKey < 32 ? cbKey : 32);

    // --- 2) Vektördeki sabit skaları içeri al: düzen doğruysa açık anahtar pkMac olur -
    // BCRYPT_ECCPRIVATE_BLOB: magic(4) + cbKey(4) + X + Y + d (+ ECDH için ek alanlar)
    struct { BCRYPT_ECCKEY_BLOB hdr; UCHAR xy[64]; UCHAR d[32]; ULONG cbCount; } pv = {};
    pv.hdr.dwMagic = BCRYPT_ECDH_PRIVATE_P256_MAGIC;
    pv.hdr.cbKey = 32;
    Unhex(PK_MAC + 2, pv.xy, 32);            // X (pk = 04 || X || Y)
    Unhex(PK_MAC + 66, pv.xy + 32, 32);      // Y
    Unhex(SK_MAC, pv.d, 32);
    pv.cbCount = 0;
    BCRYPT_KEY_HANDLE skMac = nullptr;
    NTSTATUS st = BCryptImportKeyPair(hEcdh, nullptr, BCRYPT_ECCPRIVATE_BLOB, &skMac,
                                      (UCHAR*)&pv, (ULONG)sizeof(pv), 0);
    printf("IMPORT_skMac=0x%08lx (blob %lu bayt)\n", (unsigned long)st, (unsigned long)sizeof(pv));
    if (st < 0) { printf("SONUC=import_edemedi\n"); return 1; }

    // İçeri alınca CNG açık anahtarı yeniden türetir: vektörle birebir mi?
    BYTE outPub[256] = {}; ULONG cbOut = 0;
    BCHECK(BCryptExportKey(skMac, nullptr, BCRYPT_ECCPUBLIC_BLOB, outPub, sizeof(outPub), &cbOut, 0));
    Hex("IMPORTED_PUB_X", outPub + 8, 32);
    printf("PUB_X_VEKTORLE_AYNI=%d\n", memcmp(outPub + 8, pv.xy, 32) == 0);

    // --- 3) pkTv'yi açık anahtar olarak içeri al -------------------------------------
    struct { BCRYPT_ECCKEY_BLOB hdr; UCHAR xy[64]; } pu = {};
    pu.hdr.dwMagic = BCRYPT_ECDH_PUBLIC_P256_MAGIC;
    pu.hdr.cbKey = 32;
    Unhex(PK_TV + 2, pu.xy, 32);
    Unhex(PK_TV + 66, pu.xy + 32, 32);
    BCRYPT_KEY_HANDLE pkTv = nullptr;
    st = BCryptImportKeyPair(hEcdh, nullptr, BCRYPT_ECCPUBLIC_BLOB, &pkTv,
                             (UCHAR*)&pu, (ULONG)sizeof(pu), 0);
    printf("IMPORT_pkTv=0x%08lx\n", (unsigned long)st);
    if (st < 0) return 1;

    // --- 4) Gizli anlaşma: RAW_SECRET büyük-endian mı? -------------------------------
    BCRYPT_HANDLE agree = nullptr;
    BCHECK(BCryptSecretAgreement(skMac, pkTv, &agree, 0));
    UCHAR secret[64] = {}; ULONG cbSecret = 0;
    st = BCryptDeriveKey(agree, BCRYPT_KDF_RAW_SECRET, nullptr, secret,
                         sizeof(secret), &cbSecret, 0);
    printf("RAW_SECRET=0x%08lx cb=%u\n", (unsigned long)st, cbSecret);
    if (st >= 0 && cbSecret == 32) {
        Hex("RAW_SECRET", secret, cbSecret);
        UCHAR want[32] = {}; Unhex(DH_KEY, want, 32);
        UCHAR rev[32] = {}; for (int i = 0; i < 32; ++i) rev[i] = want[31 - i];
        printf("SONUC_ESIT_BIG_ENDIAN=%d SONUC_ESIT_LITTLE_ENDIAN=%d\n",
               memcmp(secret, want, 32) == 0, memcmp(secret, rev, 32) == 0);
    }

    // --- 5) HMAC-SHA256 (§3.2 taahhüt/onay biçimi) ---------------------------------
    BCRYPT_ALG_HANDLE hMac = nullptr;
    BCHECK(BCryptOpenAlgorithmProvider(&hMac, BCRYPT_SHA256_ALGORITHM, nullptr,
                                       BCRYPT_ALG_HANDLE_HMAC_FLAG));
    UCHAR mac[32] = {}; ULONG cbMac = 0;
    UCHAR key[32] = {}; Unhex(DH_KEY, key, 32);
    const char tag[] = "atvm-confirm-v2|mac";
    BCHECK(BCryptHash(hMac, key, sizeof(key), (PUCHAR)tag, (ULONG)strlen(tag),
                      mac, sizeof(mac)));
    printf("HMAC_len=32 (BCryptHash tek seferlik)\n");
    Hex("HMAC_tag", mac, 32);

    // HKDF-SHA256: tuz = TH0 vektörü, bilgi = "atvm-pk-commit-v2", beklenen = kc vektörü.
    // Bu SDK'da BCryptDeriveKey 7 parametreli ve pParameterList ALIYOR (bcrypt.h:1492 ölçümü)
    // → §3.2'nin HKDF adımı üçüncü taraf kütüphane olmadan karşılanabiliyor mu, burada görülür.
    const char info[] = "atvm-pk-commit-v2";
    UCHAR salt[32] = {}; Unhex(TH0, salt, 32);
    BCryptBuffer hkdfParams[] = {
        { 32, KDF_HKDF_SALT, salt },
        { (ULONG)strlen(info), KDF_HKDF_INFO, (PUCHAR)info },
    };
    BCryptBufferDesc hkdfDesc = { BCRYPTBUFFER_VERSION, 2, hkdfParams };
    UCHAR kc[32] = {}; ULONG cbKc = 0;
    st = BCryptDeriveKey(agree, BCRYPT_KDF_HKDF, &hkdfDesc, kc, sizeof(kc), &cbKc, 0);
    printf("HKDF=0x%08lx cb=%u\n", (unsigned long)st, cbKc);
    if (st >= 0 && cbKc == 32) {
        Hex("HKDF_kc", kc, cbKc);
        UCHAR wantKc[32] = {}; Unhex(KC, wantKc, 32);
        printf("HKDF_VEKTORLE_AYNI=%d\n", memcmp(kc, wantKc, 32) == 0);
    }

    BCryptDestroyKey(skMac); BCryptDestroyKey(pkTv); BCryptCloseAlgorithmProvider(hEcdh, 0);
    BCryptCloseAlgorithmProvider(hHash, 0); BCryptCloseAlgorithmProvider(hMac, 0);
    printf("DONE=true\n");
    return 0;
}
