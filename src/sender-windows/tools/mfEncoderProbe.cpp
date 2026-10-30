// PaneCast — Windows kodlayıcı kırisi (Faz 0 / ADR-005 ölçümü)
//
// Neden: ADR-005 "H.264 Constrained Baseline, B-frame yok, donanım zorunlu" diyor. macOS'ta
// bunu VideoToolbox'a tek satırda söylüyoruz (H264Encoder.swift:99). Windows'ta SDK profil
// düğmesi yalnız Base(66)/Main/High veriyor; donanım MFT'sinin SPS'inde constraint_set1_flag
// gerçekten 1 basılıyor mu, B-frame sayısı 0'a zorlanabiliyor mu ve çıktı Annex-B mi
// (TV yalnız Annex-B çözüyor) — bunlar beyanla değil cihazda ölçülecek şeyler.
//
// Program hiçbir yere yayın yapmaz, dosya yazmaz; stdout'a ALAN=değer basar.
// Derleme (PC'de, dev shell içinde):
//   cl /nologo /std:c++17 /EHsc /utf-8 mfEncoderProbe.cpp /link mfplat.lib mf.lib mfuuid.lib ole32.lib oleaut32.lib uuid.lib
//
// Kullanılan semboller SDK'da tek tek doğrulandı (mfapi.h:2032 MFTEnumEx, mftransform.h:1648
// MFT_FRIENDLY_NAME_Attribute, mfapi.h:457 MFCreateMemoryBuffer, codecapi.h:2381 B-frame anahtarı).
// Donanım/yazılım ayrımı attribute ile değil hangi enum bayrağının onu döndürdüğüyle raporlanıyor.

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <icodecapi.h>      // ICodecAPI arayüzü burada; codecapi.h yalnız GUID'leri verir
#include <codecapi.h>
#include <algorithm>
#include <stdio.h>
#include <vector>

static const UINT32 kW = 1920, kH = 1088, kFps = 60, kBitrate = 12000000;

static void Hr(const char* key, HRESULT hr) { printf("%s=0x%08X\n", key, (unsigned)hr); }

static void Hex(const char* key, const UINT8* p, size_t n) {
    printf("%s=", key);
    for (size_t i = 0; i < n; ++i) printf("%02x", p[i]);
    printf("\n");
}

// SPS: NAL başlığından sonra profile_idc, constraint baytları, level_idc gelir.
// Constrained Baseline = profile_idc 66 && constraint_set1_flag 1 (H.264 Tablo A.2).
static void Sps(const UINT8* nal, size_t len) {
    if (len < 4) { printf("SPS=too_short\n"); return; }
    const unsigned profile = nal[1], constraint = nal[2], level = nal[3];
    printf("SPS_profile_idc=%u\nSPS_constraint_byte=0x%02X\nSPS_level_idc=%u\n",
           profile, constraint, level);
    printf("SPS_constraint_set1_flag=%u\n", (constraint >> 6) & 1);
    printf("CONCLUSION=%s\n", (profile == 66 && ((constraint >> 6) & 1)) ? "CONSTRAINED_BASELINE"
           : profile == 66 ? "BASELINE_NOT_CONSTRAINED" : "OTHER_PROFILE");
}

static HRESULT SetVideoType(IMFMediaType** pp, GUID subtype, bool rateAndBitrate) {
    HRESULT hr = MFCreateMediaType(pp);
    if (FAILED(hr)) return hr;
    IMFMediaType* t = *pp;
    t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    t->SetGUID(MF_MT_SUBTYPE, subtype);
    t->SetUINT64(MF_MT_FRAME_SIZE, ((UINT64)kW << 32) | kH);
    t->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    t->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, 1);
    if (rateAndBitrate) {
        t->SetUINT64(MF_MT_FRAME_RATE, ((UINT64)kFps << 32) | 1);
        t->SetUINT64(MF_MT_PIXEL_ASPECT_RATIO, ((UINT64)1 << 32) | 1);
        t->SetUINT32(MF_MT_AVG_BITRATE, kBitrate);
        t->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base);   // 66 (codecapi.h:1221)
    } else {
        // Yazılım MFT girdide MF_E_ATTRIBUTENOTFOUND (0xC00D36E6) verdi: kare hızı ve
        // piksel oranı girdi türünde de isteniyor (ölçüldü).
        t->SetUINT64(MF_MT_FRAME_RATE, ((UINT64)kFps << 32) | 1);
        t->SetUINT64(MF_MT_PIXEL_ASPECT_RATIO, ((UINT64)1 << 32) | 1);
        t->SetUINT64(MF_MT_DEFAULT_STRIDE, kW);
    }
    return S_OK;
}

static IMFSample* Frame(UINT32 index) {
    const ULONG size = kW * kH * 3 / 2;                 // NV12
    IMFMediaBuffer* buf = nullptr;
    if (FAILED(MFCreateMemoryBuffer(size, &buf))) return nullptr;   // mfapi.h:457
    UINT8* p = nullptr;
    if (FAILED(buf->Lock(&p, nullptr, nullptr))) { buf->Release(); return nullptr; }
    // Dalgalı desen: sabit içerikte kodlayıcı hiç bit üretmeyebilir (SCK tarafında ölçülen tuzak).
    for (UINT32 y = 0; y < kH; ++y)
        for (UINT32 x = 0; x < kW; ++x)
            p[y * kW + x] = ((x >> 4) + (y >> 4) + index) & 1 ? 0x20 : 0xD0;
    for (UINT32 i = kW * kH; i < size; ++i) p[i] = 0x80;
    buf->Unlock();
    buf->SetCurrentLength(size);
    IMFSample* s = nullptr;
    if (FAILED(MFCreateSample(&s))) { buf->Release(); return nullptr; }
    s->AddBuffer(buf);
    s->SetSampleTime((LONGLONG)index * (10000000 / kFps));
    s->SetSampleDuration(10000000 / kFps);
    buf->Release();
    return s;
}

static void RunOne(IMFTransform* mft) {
    IMFMediaType* outType = nullptr;
    IMFMediaType* inType = nullptr;
    if (FAILED(SetVideoType(&outType, MFVideoFormat_H264, true)) ||
        FAILED(SetVideoType(&inType, MFVideoFormat_NV12, false))) {
        printf("CONFIG=media_type_oluşmadı\n");
    }
    HRESULT hr = mft->SetOutputType(0, outType, 0);      // MS kodlayıcısı çıktıyı önce ister
    Hr("HR_SetOutputType", hr);
    if (FAILED(hr)) { inType->Release(); outType->Release(); return; }
    hr = mft->SetInputType(0, inType, 0);
    Hr("HR_SetInputType", hr);
    inType->Release(); outType->Release();
    if (FAILED(hr)) return;

    ICodecAPI* api = nullptr;
    if (SUCCEEDED(mft->QueryInterface(__uuidof(ICodecAPI), (void**)&api))) {
        VARIANT ll; VariantInit(&ll); ll.vt = VT_BOOL; ll.boolVal = VARIANT_TRUE;
        Hr("LOWLAT_supported", api->IsSupported(&CODECAPI_AVLowLatencyMode));
        Hr("LOWLAT_set", api->SetValue(&CODECAPI_AVLowLatencyMode, &ll));
        VariantClear(&ll);
        VARIANT b; VariantInit(&b); b.vt = VT_UI4; b.ulVal = 0;
        Hr("BFRAMES_supported", api->IsSupported(&CODECAPI_AVEncMPVDefaultBPictureCount));
        Hr("BFRAMES_set0", api->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &b));
        VariantClear(&b);
        VARIANT g; VariantInit(&g); g.vt = VT_UI4; g.ulVal = kFps * 2;   // GOP 2 sn
        Hr("GOP_supported", api->IsSupported(&CODECAPI_AVEncMPVGOPSize));
        Hr("GOP_set", api->SetValue(&CODECAPI_AVEncMPVGOPSize, &g));
        VariantClear(&g);
    } else Hr("HR_ICodecAPI", E_NOINTERFACE);

    UINT32 fed = 0, produced = 0;
    std::vector<int> nals;
    bool annexB = false, lenPrefixed = false;
    int outFails = 0;
    // Süreç başlatma bildirimi: bazı MFT'ler bunu görmeden beslenmeyi reddediyor.
    Hr("HR_msg_config", mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0));
    MFT_OUTPUT_STREAM_INFO osi = {};
    Hr("HR_GetOutputStreamInfo", mft->GetOutputStreamInfo(0, &osi));
    printf("OSI_flags=0x%X OSI_cbSize=%u OSI_cbAlignment=%u\n", osi.dwFlags, osi.cbSize, osi.cbAlignment);
    for (UINT32 i = 0; i < 60 && produced == 0; ++i) {
        IMFSample* s = Frame(i);
        if (!s) break;
        hr = mft->ProcessInput(0, s, 0);
        s->Release();
        ++fed;
        if (FAILED(hr)) { Hr("HR_ProcessInput", hr); break; }
        // Ölçülen kusur: pSample=NULL bırakınca "H264 Encoder MFT" her ProcessOutput'da
        // 0x80070057 (E_INVALIDARG) döndürdü — çıktı örneğini çağıranın tahsis etmesi gerekiyor.
        MFT_OUTPUT_DATA_BUFFER odb = {};
        odb.dwStreamID = 0;
        IMFSample* outSample = nullptr;
        IMFMediaBuffer* outBuf = nullptr;
        if (SUCCEEDED(MFCreateMemoryBuffer(osi.cbSize ? osi.cbSize : (4u << 20), &outBuf))) {
            if (SUCCEEDED(MFCreateSample(&outSample))) {
                outSample->AddBuffer(outBuf);
                odb.pSample = outSample;
            }
            outBuf->Release();
        }
        ULONG status = 0;
        hr = mft->ProcessOutput(0, 1, &odb, &status);
        if (FAILED(hr)) { if (outFails < 3) Hr("HR_ProcessOutput", hr); ++outFails; if (outSample) outSample->Release(); continue; }
        ++produced;
        IMFMediaBuffer* raw = nullptr;
        if (odb.pSample && SUCCEEDED(odb.pSample->GetBufferByIndex(0, &raw))) {
            UINT8* d = nullptr; ULONG len = 0;
            if (SUCCEEDED(raw->Lock(&d, nullptr, &len))) {
                Hex("OUT_first48", d, std::min<ULONG>(len, 48));
                printf("OUT_bytes=%u\n", len);
                annexB = len >= 4 && d[0] == 0 && d[1] == 0 && d[2] == 0 && d[3] == 1;
                const unsigned be = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
                lenPrefixed = !annexB && be + 4 <= len;
                printf("ANNEXB=%d LENGTH_PREFIXED=%d\n", (int)annexB, (int)lenPrefixed);
                for (ULONG k = 0; k + 4 < len; ++k) {
                    if (d[k] == 0 && d[k + 1] == 0 && d[k + 2] == 0 && d[k + 3] == 1) {
                        const int t = d[k + 4] & 0x1F;
                        nals.push_back(t);
                        if (t == 7) Sps(d + k + 4, len - (k + 4));
                    }
                }
                raw->Unlock();
            } else Hr("HR_Lock", E_FAIL);
            raw->Release();
        } else Hr("HR_GetBuffer", E_FAIL);
        if (odb.pSample) odb.pSample->Release();
        if (odb.pEvents) odb.pEvents->Release();
    }
    printf("FED=%u PRODUCED=%u NAL=", fed, produced);
    for (size_t i = 0; i < nals.size(); ++i) printf("%d%s", nals[i], i + 1 < nals.size() ? "," : "");
    if (nals.empty()) printf("-");
    printf("\n");
    if (api) api->Release();
}

int main() {
    SetConsoleOutputCP(CP_UTF8);
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) { printf("FATAL=coinit\n"); return 1; }
    if (FAILED(MFStartup(MF_VERSION))) { printf("FATAL=mfstartup\n"); return 1; }
    printf("TARGET=%ux%u@%u %umbps profile_attr=Base66 gop_sec=2\n", kW, kH, kFps, kBitrate / 1000000);

    struct Mode { ULONG flags; const char* tag; } modes[] = {
        { MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, "HW_SYNC" },
        { MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, "HW_ASYNC" },
        { MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, "SW_SYNC" },
    };
    MFT_REGISTER_TYPE_INFO inInfo = { MFMediaType_Video, MFVideoFormat_NV12 };
    MFT_REGISTER_TYPE_INFO outInfo = { MFMediaType_Video, MFVideoFormat_H264 };

    for (const Mode& m : modes) {
        IMFActivate** acts = nullptr;
        UINT32 count = 0;
        HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, m.flags, &inInfo, &outInfo, &acts, &count);
        printf("\n=== %s enum=0x%08X count=%u ===\n", m.tag, (unsigned)hr, count);
        if (FAILED(hr) || !acts) continue;
        for (UINT32 i = 0; i < count; ++i) {
            printf("\n[%s#%u]\n", m.tag, i);
            WCHAR name[256] = {0};
            if (SUCCEEDED(acts[i]->GetString(MFT_FRIENDLY_NAME_Attribute, name, 256, nullptr)))
                wprintf(L"NAME=%ls\n", name);
            else printf("NAME=bilinmiyor\n");
            // Donanım MFT'leri async kilitli geliyor (SetInputType → 0xC00D6D77). Kilidi
            // açmanın iki olası yolu var; ikisini de ölçüyoruz: etkinleştiricinin kendi
            // attribute deposu (etkinleştirmeden ÖNCE) ve etkinleşen nesnenin deposu (SONRA).
            IMFAttributes* pre = nullptr;
            hr = acts[i]->QueryInterface(__uuidof(IMFAttributes), (void**)&pre);
            if (SUCCEEDED(hr) && pre) {
                Hr("HR_unlock_pre", pre->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE));
                pre->Release();
            } else Hr("HR_qi_activate_attributes", hr);
            IMFTransform* mft = nullptr;
            hr = acts[i]->ActivateObject(__uuidof(IMFTransform), (void**)&mft);
            if (FAILED(hr) || !mft) { Hr("HR_Activate", hr); continue; }
            // IMFActivate::GetAttributes YOK (derleyici ölçümü) — kilit, etkinleştirilen
            // nesnenin kendi attribute deposu üzerinden açılıyor.
            IMFAttributes* at = nullptr;
            hr = mft->QueryInterface(__uuidof(IMFAttributes), (void**)&at);
            Hr("HR_qi_attributes", hr);
            if (SUCCEEDED(hr) && at) {
                Hr("HR_unlock", at->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE));
                UINT32 async = 0;
                printf("ATTR_async=%u\n", at->GetUINT32(MF_TRANSFORM_ASYNC, &async) == S_OK ? async : 0xFFFF'FFFFu);
                at->Release();
            }
            RunOne(mft);
            mft->Release();
            acts[i]->ShutdownObject();
        }
        for (UINT32 i = 0; i < count; ++i) acts[i]->Release();
        CoTaskMemFree(acts);
    }
    MFShutdown();
    CoUninitialize();
    printf("\nDONE=true\n");
    return 0;
}
