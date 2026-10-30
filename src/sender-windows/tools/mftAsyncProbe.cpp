// PaneCast — Windows donanım kodlayıcısının async/D3D11 yolu (Faz 0 / ADR-005, ADR-008)
//
// Neden: Faz 0'da donanım MFT'lerinin sync kilitli geldiği ÖLÇÜLDÜ (SetInputType →
// 0xC00D6D77 MF_E_TRANSFORM_ASYNC_LOCKED; unlock attribute'ı S_OK dönüp etki etmiyor) ve
// yazılım MFT'si 13 kare (≈217 ms) kuyrukla yayın yolu olamıyor. Yani donanım yolu ancak
// olay API'siyle (IMFMediaEventGenerator + METransformNeedInput/HaveOutput) sürülebilir.
// Bu kıri o yolu D3D11 NV12 yüzeyleriyle sürüp yayın kararının sayılarını üretir:
// kare başına girdi→çıktı gecikmesi, duvar saati fps, ilk çıktı gecikmesi, B-frame sayısı
// (slice_type'tan), Annex-B ve Constrained Baseline SPS.
//
// Program hiçbir yere yayın yapmaz, dosya yazmaz; stdout'a ALAN=değer basar.
// Derleme (PC'de): scripts/win-build.sh mftAsyncProbe LIBS="mfplat.lib mf.lib mfuuid.lib
//   ole32.lib oleaut32.lib uuid.lib d3d11.lib dxgi.lib" tools/mftAsyncProbe.cpp

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mftransform.h>
#include <mferror.h>
#include <icodecapi.h>
#include <codecapi.h>
#include <d3d11.h>
#include <dxgi.h>
#include <condition_variable>
#include <mutex>
#include <stdio.h>
#include <vector>
#include <algorithm>

static const UINT32 kW = 1920, kH = 1088, kFps = 60, kBitrate = 12000000;
static const UINT32 kFrames = 120;
static const LONGLONG kTick = 10000000 / kFps;

static LARGE_INTEGER g_qpc;
static double NowMs() {
    LARGE_INTEGER c; QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / g_qpc.QuadPart;
}

static void Hr(const char* key, HRESULT hr) { printf("%s=0x%08X\n", key, (unsigned)hr); }

static void Sps(const UINT8* nal, size_t len) {
    if (len < 4) { printf("SPS=too_short\n"); return; }
    const unsigned profile = nal[1], constraint = nal[2], level = nal[3];
    printf("SPS_profile_idc=%u\nSPS_constraint_byte=0x%02X\nSPS_level_idc=%u\n",
           profile, constraint, level);
    printf("SPS_constraint_set1_flag=%u\n", (constraint >> 6) & 1);
    printf("CONSTRAINED_BASELINE=%d\n",
           (profile == 66 && ((constraint >> 6) & 1)) ? 1 : 0);
}

// Emülasyon koruması (00 00 03) soyulmuş tampon üzerinden bit okuyucu.
struct Bits {
    std::vector<UINT8> b; size_t pos = 0;
    int ReadBit() {
        if (pos >> 3 >= b.size()) return 0;
        int v = (b[pos >> 3] >> (7 - (pos & 7))) & 1;
        ++pos; return v;
    }
    UINT32 Ue() {
        UINT32 n = 0;
        while (ReadBit() == 0 && n < 32) ++n;
        UINT32 v = (1u << n) - 1u;
        for (UINT32 i = 0; i < n; ++i) v += (UINT32)ReadBit() << (n - 1 - i);
        return v;
    }
};

// AU içindeki ilk dilim NAL'ının slice_type'ını verir: 0 P, 1 B, 2 I, 3 SP, 4 SI (mod 5).
static int SliceType(const UINT8* d, ULONG len, bool* annexB) {
    for (ULONG k = 0; k + 5 < len; ++k) {
        if (d[k] || d[k + 1] || d[k + 2] || d[k + 3] != 1) continue;
        const UINT8 type = d[k + 4] & 0x1F;
        if (k == 0 && annexB) *annexB = true;
        if (type != 1 && type != 5) continue;
        std::vector<UINT8> clean;
        for (ULONG i = k + 5; i < len; ++i) {
            if (i + 2 < len && d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 3) {
                clean.push_back(0); clean.push_back(0); i += 2; continue;
            }
            clean.push_back(d[i]);
        }
        Bits br; br.b.swap(clean);
        br.Ue();                                   // first_mb_in_slice
        return (int)(br.Ue() % 5);
    }
    return -1;
}

struct Run {
    bool d3d = false, paced = false;
    std::mutex m; std::condition_variable cv;
    double tIn[kFrames * 2] = {};
    std::vector<double> lat;
    UINT32 fed = 0, produced = 0, evNeed = 0, evHave = 0;
    UINT32 sliceP = 0, sliceB = 0, sliceI = 0;
    double t0 = 0, firstOut = 0, tEnd = 0;
    bool annexB = false, spsDone = false, eosSent = false, done = false;
    void Finish() { done = true; cv.notify_all(); }
};

static Run* g_run = nullptr;
static IMFTransform* g_mft = nullptr;
static ID3D11Device* g_dev = nullptr;
static ID3D11DeviceContext* g_ctx = nullptr;
static ID3D11Texture2D* g_tex = nullptr;
static ID3D11Texture2D* g_stag = nullptr;

static IMFSample* MemFrame(UINT32 index) {
    const ULONG size = kW * kH * 3 / 2;
    IMFMediaBuffer* buf = nullptr;
    if (FAILED(MFCreateMemoryBuffer(size, &buf))) return nullptr;
    UINT8* p = nullptr;
    if (FAILED(buf->Lock(&p, nullptr, nullptr))) { buf->Release(); return nullptr; }
    for (UINT32 y = 0; y < kH; ++y)
        for (UINT32 x = 0; x < kW; ++x)
            p[y * kW + x] = ((x >> 4) + (y >> 4) + index) & 1 ? 0x20 : 0xD0;
    for (UINT32 i = kW * kH; i < size; ++i) p[i] = 0x80;
    buf->Unlock();
    buf->SetCurrentLength(size);
    IMFSample* s = nullptr;
    if (FAILED(MFCreateSample(&s))) { buf->Release(); return nullptr; }
    s->AddBuffer(buf);
    s->SetSampleTime((LONGLONG)index * kTick);
    s->SetSampleDuration(kTick);
    buf->Release();
    return s;
}

static bool D3dInit() {
    if (g_dev) return true;
    UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
    D3D_FEATURE_LEVEL fl;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                                 nullptr, 0, D3D11_SDK_VERSION, &g_dev, &fl, &g_ctx)))
        return false;
    D3D11_TEXTURE2D_DESC td = {};
    td.Width = kW; td.Height = kH; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_NV12; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_VIDEO_ENCODER;
    if (FAILED(g_dev->CreateTexture2D(&td, nullptr, &g_tex))) return false;
    td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(g_dev->CreateTexture2D(&td, nullptr, &g_stag))) return false;
    return true;
}

static IMFSample* D3dFrame(UINT32 index) {
    D3D11_MAPPED_SUBRESOURCE mp = {};
    if (FAILED(g_ctx->Map(g_stag, 0, D3D11_MAP_WRITE, 0, &mp))) return nullptr;
    UINT8* base = (UINT8*)mp.pData; const UINT32 p = mp.RowPitch;
    for (UINT32 y = 0; y < kH; ++y) {
        UINT8* row = base + (size_t)y * p;
        for (UINT32 x = 0; x < kW; ++x)
            row[x] = ((x >> 4) + (y >> 4) + index) & 1 ? 0x20 : 0xD0;
    }
    UINT8* uv = base + (size_t)p * kH;
    for (UINT32 y = 0; y < kH / 2; ++y)
        for (UINT32 x = 0; x < kW / 2; ++x) uv[(size_t)y * p + x] = 0x80;
    g_ctx->Unmap(g_stag, 0);
    g_ctx->CopyResource(g_tex, g_stag);
    IMFMediaBuffer* buf = nullptr;
    if (FAILED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), g_tex, 0, FALSE, &buf)))
        return nullptr;
    IMFSample* s = nullptr;
    if (FAILED(MFCreateSample(&s))) { buf->Release(); return nullptr; }
    s->AddBuffer(buf);
    s->SetSampleTime((LONGLONG)index * kTick);
    s->SetSampleDuration(kTick);
    buf->Release();
    return s;
}

class Cb : public IMFAsyncCallback {
public:
    IMFMediaEventGenerator* gen = nullptr;
    ULONG STDMETHODCALLTYPE AddRef() override { return 2; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** pp) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IMFAsyncCallback)) {
            *pp = this; return S_OK;
        }
        *pp = nullptr; return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE GetParameters(DWORD*, DWORD*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Invoke(IMFAsyncResult* ar) override {
        IMFMediaEvent* ev = nullptr;
        MediaEventType mt = MEUnknown;
        if (gen && SUCCEEDED(gen->EndGetEvent(ar, &ev)) && ev) {
            ev->GetType(&mt);
            ev->Release();
        }
        if (gen) gen->BeginGetEvent(this, nullptr);
        Run* r = g_run;
        if (!r || !g_mft) return S_OK;
        if (mt == METransformNeedInput) {
            std::lock_guard<std::mutex> lk(r->m);
            ++r->evNeed;
            if (r->fed >= kFrames) {
                if (!r->eosSent) {
                    r->eosSent = true;
                    g_mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
                }
                return S_OK;
            }
            if (r->paced) {
                const double target = r->t0 + r->fed * (1000.0 / kFps);
                const double wait = target - NowMs();
                if (wait > 0.3) Sleep((DWORD)wait);
            }
            IMFSample* s = r->d3d ? D3dFrame(r->fed) : MemFrame(r->fed);
            if (!s) { r->Finish(); return S_OK; }
            r->tIn[r->fed] = NowMs();
            HRESULT hr = g_mft->ProcessInput(0, s, 0);
            s->Release();
            if (FAILED(hr)) { Hr("HR_ProcessInput", hr); r->Finish(); return S_OK; }
            ++r->fed;
        } else if (mt == METransformHaveOutput) {
            MFT_OUTPUT_DATA_BUFFER odb = {};
            odb.dwStreamID = 0;
            odb.pSample = nullptr;                 // async MFT çıktıyı kendisi tahsis eder
            ULONG status = 0;
            HRESULT hr = g_mft->ProcessOutput(0, 1, &odb, &status);
            Run* rr = g_run;
            if (FAILED(hr)) {
                if (hr != MF_E_TRANSFORM_NEED_MORE_INPUT) Hr("HR_ProcessOutput", hr);
                if (odb.pSample) odb.pSample->Release();
                if (odb.pEvents) odb.pEvents->Release();
                return S_OK;
            }
            std::lock_guard<std::mutex> lk(rr->m);
            ++rr->evHave; ++rr->produced;
            const double now = NowMs();
            if (!rr->firstOut) rr->firstOut = now;
            if (odb.pSample) {
                LONGLONG t = 0;
                odb.pSample->GetSampleTime(&t);
                const UINT32 idx = (UINT32)(t / kTick);
                if (idx < kFrames * 2 && rr->tIn[idx] > 0)
                    rr->lat.push_back(now - rr->tIn[idx]);
                IMFMediaBuffer* raw = nullptr;
                if (SUCCEEDED(odb.pSample->GetBufferByIndex(0, &raw)) && raw) {
                    UINT8* d = nullptr; ULONG len = 0;
                    if (SUCCEEDED(raw->Lock(&d, nullptr, &len)) && d) {
                        if (!rr->annexB && len >= 4 && !d[0] && !d[1] && !d[2] && d[3] == 1)
                            rr->annexB = true;
                        if (!rr->spsDone) {
                            for (ULONG k = 0; k + 4 < len; ++k)
                                if (!d[k] && !d[k + 1] && !d[k + 2] && d[k + 3] == 1 &&
                                    (d[k + 4] & 0x1F) == 7) {
                                    Sps(d + k + 4, len - (k + 4)); rr->spsDone = true; break;
                                }
                        }
                        if (rr->produced <= 60) {
                            const int st = SliceType(d, len, nullptr);
                            if (st == 0) ++rr->sliceP;
                            else if (st == 1) ++rr->sliceB;
                            else if (st == 2) ++rr->sliceI;
                        }
                        raw->Unlock();
                    }
                    raw->Release();
                }
                odb.pSample->Release();
            }
            if (odb.pEvents) odb.pEvents->Release();
            if (rr->produced >= kFrames) { rr->tEnd = now; rr->Finish(); }
        } else if (mt == METransformDrainComplete) {
            std::lock_guard<std::mutex> lk(r->m);
            r->tEnd = NowMs();
            r->Finish();
        }
        return S_OK;
    }
};

static HRESULT SetType(IMFTransform* mft, bool out, GUID subtype, bool d3d) {
    IMFMediaType* t = nullptr;
    HRESULT hr = MFCreateMediaType(&t);
    if (FAILED(hr)) return hr;
    t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    t->SetGUID(MF_MT_SUBTYPE, subtype);
    t->SetUINT64(MF_MT_FRAME_SIZE, ((UINT64)kW << 32) | kH);
    t->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    t->SetUINT64(MF_MT_FRAME_RATE, ((UINT64)kFps << 32) | 1);
    t->SetUINT64(MF_MT_PIXEL_ASPECT_RATIO, ((UINT64)1 << 32) | 1);
    t->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, 1);
    if (out) {
        t->SetUINT32(MF_MT_AVG_BITRATE, kBitrate);
        t->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base);
    } else if (!d3d) {
        t->SetUINT64(MF_MT_DEFAULT_STRIDE, kW);
    }
    hr = out ? mft->SetOutputType(0, t, 0) : mft->SetInputType(0, t, 0);
    t->Release();
    return hr;
}

static void Report(Run& r) {
    printf("FED=%u PRODUCED=%u EV_NEED=%u EV_HAVE=%u\n",
           r.fed, r.produced, r.evNeed, r.evHave);
    if (r.firstOut > 0 && r.t0 > 0)
        printf("FIRST_OUT_MS=%.1f\n", r.firstOut - r.t0);
    if (!r.lat.empty()) {
        std::vector<double> v = r.lat;
        std::sort(v.begin(), v.end());
        double sum = 0; for (double d : v) sum += d;
        printf("LAT_AVG_MS=%.1f LAT_P50_MS=%.1f LAT_P95_MS=%.1f LAT_MAX_MS=%.1f\n",
               sum / v.size(), v[v.size() / 2],
               v[(size_t)(v.size() * 0.95 < v.size() ? v.size() * 0.95 : v.size() - 1)],
               v.back());
    } else printf("LAT_AVG_MS=-\n");
    if (r.produced > 1 && r.tEnd > r.firstOut)
        printf("FPS_WALL=%.1f\n", (r.produced - 1) * 1000.0 / (r.tEnd - r.firstOut));
    printf("ANNEXB=%d SLICE_P=%u SLICE_B=%u SLICE_I=%u\n",
           (int)r.annexB, r.sliceP, r.sliceB, r.sliceI);
}

static void RunOnce(IMFActivate* act, const char* tag, bool d3d, bool paced, int variant,
                    bool* configured) {
    printf("\n=== %s MODE=%s PHASE=%s SEQ=%d ===\n", tag,
           d3d ? "HW_ASYNC_D3D11" : "HW_ASYNC_MEM", paced ? "paced60" : "burst", variant);
    if (configured) *configured = false;
    Run r; r.d3d = d3d; r.paced = paced; g_run = &r;
    // Kilit-açma ve olay sırası beyanla değil ölçümle: SEQ olası sıraları dener.
    // 0: ön, out, in | 1: ön, olay, out, in | 2: ön, out, olay, in | 3: ön, in, out
    // 4: son, out, in | 5: ön+son, out, in
    const bool unlockPre = variant != 4;
    if (unlockPre) {
        IMFAttributes* pre = nullptr;
        HRESULT hq = act->QueryInterface(__uuidof(IMFAttributes), (void**)&pre);
        if (SUCCEEDED(hq) && pre) {
            Hr("HR_unlock_pre", pre->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE));
            pre->Release();
        } else Hr("HR_qi_pre", hq);
    }
    IMFTransform* mft = nullptr;
    HRESULT hr = act->ActivateObject(__uuidof(IMFTransform), (void**)&mft);
    if (FAILED(hr) || !mft) { Hr("HR_Activate", hr); g_run = nullptr; return; }
    g_mft = mft;
    // Belgelenmiş kilit-açma yolu: IMFTransform::GetAttributes deposu (MS "Asynchronous
    // MFTs"); QI(IMFAttributes) donanım MFT'sinde E_NOINTERFACE döndürdü (ölçüldü).
    IMFAttributes* at = nullptr;
    HRESULT hga = mft->GetAttributes(&at);
    Hr("HR_GetAttributes", hga);
    if (SUCCEEDED(hga) && at) {
        Hr("HR_unlock", at->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE));
        at->Release();
    }
    IMFMediaEventGenerator* gen = nullptr;
    Cb* cb = new Cb();
    auto startEvents = [&] {
        if (gen) return;
        HRESULT h = mft->QueryInterface(__uuidof(IMFMediaEventGenerator), (void**)&gen);
        Hr("HR_EventGenerator", h);
        if (SUCCEEDED(h) && gen) {
            cb->gen = gen;
            Hr("HR_BeginGetEvent", gen->BeginGetEvent(cb, nullptr));
        }
    };
    if (d3d) {
        UINT token = 0;
        IMFDXGIDeviceManager* mgr = nullptr;
        hr = MFCreateDXGIDeviceManager(&token, &mgr);
        if (SUCCEEDED(hr) && mgr) {
            hr = mgr->ResetDevice(g_dev, token);
            if (SUCCEEDED(hr))
                Hr("HR_SET_D3D_MANAGER",
                   mft->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, (ULONG_PTR)mgr));
            else Hr("HR_ResetDevice", hr);
            mgr->Release();
        } else Hr("HR_DXGIDeviceManager", hr);
    }
    if (variant == 1) startEvents();
    auto setOut = [&] { return SetType(mft, true, MFVideoFormat_H264, d3d); };
    auto setIn = [&] { return SetType(mft, false, MFVideoFormat_NV12, d3d); };
    HRESULT hrIn = E_FAIL;
    if (variant == 2) {
        Hr("HR_SetOutputType", setOut());
        startEvents();
        hrIn = setIn(); Hr("HR_SetInputType", hrIn);
    } else if (variant == 3) {
        hrIn = setIn(); Hr("HR_SetInputType", hrIn);
        Hr("HR_SetOutputType", setOut());
    } else {
        Hr("HR_SetOutputType", setOut());
        hrIn = setIn(); Hr("HR_SetInputType", hrIn);
    }
    if (FAILED(hrIn)) {
        printf("CONFIG=failed\n");
        if (gen) gen->Release();
        mft->Release(); g_mft = nullptr; g_run = nullptr;
        delete cb; act->ShutdownObject();
        return;
    }
    if (configured) *configured = true;
    ICodecAPI* api = nullptr;
    if (SUCCEEDED(mft->QueryInterface(__uuidof(ICodecAPI), (void**)&api)) && api) {
        VARIANT v; VariantInit(&v); v.vt = VT_BOOL; v.boolVal = VARIANT_TRUE;
        Hr("LOWLAT_set", api->SetValue(&CODECAPI_AVLowLatencyMode, &v)); VariantClear(&v);
        VariantInit(&v); v.vt = VT_UI4; v.ulVal = 0;
        Hr("BFRAMES_set0", api->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &v));
        VariantClear(&v);
        VariantInit(&v); v.vt = VT_UI4; v.ulVal = kFps * 2;
        Hr("GOP_set", api->SetValue(&CODECAPI_AVEncMPVGOPSize, &v)); VariantClear(&v);
        api->Release();
    }
    startEvents();
    if (!gen) {
        mft->Release(); g_mft = nullptr; g_run = nullptr;
        delete cb; act->ShutdownObject();
        return;
    }
    Hr("HR_BeginStreaming", mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0));
    Hr("HR_StartOfStream", mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0));
    {
        std::unique_lock<std::mutex> lk(r.m);
        r.t0 = NowMs();
        r.cv.wait_for(lk, std::chrono::seconds(25), [&] { return r.done; });
        if (!r.done) printf("TIMEOUT=1\n");
    }
    Report(r);
    gen->Release();
    mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    mft->Release();
    g_mft = nullptr; g_run = nullptr;
    delete cb;
    act->ShutdownObject();
}

int main() {
    SetConsoleOutputCP(CP_UTF8);
    QueryPerformanceFrequency(&g_qpc);
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) { printf("FATAL=coinit\n"); return 1; }
    if (FAILED(MFStartup(MF_VERSION))) { printf("FATAL=mfstartup\n"); return 1; }
    printf("TARGET=%ux%u@%u %umbps frames=%u\n", kW, kH, kFps, kBitrate / 1000000, kFrames);
    printf("D3D11_DEVICE=%d\n", (int)D3dInit());
    if (!g_dev) { printf("FATAL=d3d11\n"); return 1; }

    MFT_REGISTER_TYPE_INFO inInfo = { MFMediaType_Video, MFVideoFormat_NV12 };
    MFT_REGISTER_TYPE_INFO outInfo = { MFMediaType_Video, MFVideoFormat_H264 };
    IMFActivate** acts = nullptr; UINT32 count = 0;
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                           MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                           &inInfo, &outInfo, &acts, &count);
    printf("HW_ASYNC enum=0x%08X count=%u\n", (unsigned)hr, count);
    if (FAILED(hr) || !acts) { MFShutdown(); CoUninitialize(); return 1; }
    std::vector<std::wstring> names(count);
    for (UINT32 i = 0; i < count; ++i) {
        WCHAR name[256] = { 0 };
        if (SUCCEEDED(acts[i]->GetString(MFT_FRIENDLY_NAME_Attribute, name, 256, nullptr)))
            names[i] = name;
        wprintf(L"[%u] NAME=%ls\n", i, names[i].c_str());
    }
    // Etkinleştiriciler tek kullanımlık: her koşu yeniden yoklama ister.
    auto enumHw = [&]() -> std::vector<IMFActivate*> {
        IMFActivate** list = nullptr; UINT32 n = 0;
        HRESULT h = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                              MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                              &inInfo, &outInfo, &list, &n);
        std::vector<IMFActivate*> v;
        if (SUCCEEDED(h) && list) {
            for (UINT32 i = 0; i < n; ++i) v.push_back(list[i]);
            CoTaskMemFree(list);
        }
        return v;
    };
    auto freeList = [](std::vector<IMFActivate*>& v) {
        for (auto* a : v) a->Release();
        v.clear();
    };
    char tags[8][512] = {};
    for (UINT32 i = 0; i < count && i < 8; ++i)
        WideCharToMultiByte(CP_UTF8, 0, names[i].c_str(), -1, tags[i], 512, nullptr, nullptr);
    int winV[8] = { -1, -1, -1, -1, -1, -1, -1, -1 };
    // 1) sıra keşfi: ilk iki kodlayıcıda kilit-açma/olay sıraları denenir.
    for (UINT32 e = 0; e < count && e < 2; ++e) {
        for (int v = 0; v < 6 && winV[e] < 0; ++v) {
            auto list = enumHw();
            if (e < list.size()) {
                bool ok = false;
                RunOnce(list[e], tags[e], false, false, v, &ok);
                if (ok) winV[e] = v;
            }
            freeList(list);
        }
        printf("WIN_SEQ[%u]=%d\n", e, winV[e]);
    }
    // 2) kazanan sırayla tam matris: kodlayıcı × D3D11/bellek × paced/burst.
    for (UINT32 e = 0; e < count; ++e) {
        const int v = winV[e] >= 0 ? winV[e] : 0;
        for (int mode = 0; mode < 4; ++mode) {
            auto list = enumHw();
            if (e < list.size())
                RunOnce(list[e], tags[e], (mode & 1) == 0, (mode & 2) == 0, v, nullptr);
            freeList(list);
        }
    }
    for (UINT32 i = 0; i < count; ++i) acts[i]->Release();
    CoTaskMemFree(acts);
    if (g_tex) g_tex->Release();
    if (g_stag) g_stag->Release();
    if (g_ctx) g_ctx->Release();
    if (g_dev) g_dev->Release();
    MFShutdown();
    CoUninitialize();
    printf("\nDONE=true\n");
    return 0;
}
