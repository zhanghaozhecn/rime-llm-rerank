/*
 * rime_llm.cpp — RIME LLM 候选重排 C++ 插件 (CPU)
 * 编译: cmake -G "Visual Studio 17 2022" -A x64 -S . -B build
 *        cmake --build build --config Release
 * Lua:  require("rime_llm") → llm.score(ctx, cands)
 */

#define NOMINMAX
#include <windows.h>
#include <objbase.h>
#include <oleauto.h>
// UIA 客户端接口（IUIAutomationTextPattern 等）在 Client.h，TextUnit 枚举在 Core.h
#include <UIAutomationClient.h>
#include <UIAutomationCore.h>
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "UIAutomationCore.lib")

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include "llama.h"

#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstring>
#include <cstdarg>
#include <cstdlib>
#include <algorithm>

// ============================================================
// 配置默认值
// ============================================================
// 默认模型路径 = RIME 用户目录根\Qwen...gguf（2026-08-31 用户澄清定案：
// "用户文件夹"= 小狼毫右键的用户文件夹 %APPDATA%\Rime——方案配置所在
// 处，模型直接放根目录、不套子文件夹；8-27 曾误用 %USERPROFILE%\
// gguf_models\。自定义位置用 schema model_path 显式指向。便携模式小狼毫
// 的用户目录不在 %APPDATA%\Rime，此类部署需显式配置 model_path）
static std::string default_model_path() {
  const char *ad = getenv("APPDATA");
  if (ad && *ad)
    return std::string(ad) + "\\Rime\\Qwen3.5-0.8B-Q4_K_M.gguf";
  return "Qwen3.5-0.8B-Q4_K_M.gguf";
}
static std::string  g_model_path      = default_model_path();
static int          g_min_tokens      = 1;
static int          g_max_ctx_tokens  = 10; // tok=10 准确率 93.4%，10→17 收益仅 +1.1pp 但延迟翻倍
static int          g_n_threads       = 4;  // 默认=GGML 默认; 可用 bench_threads 实测后配置
static int          g_n_ctx           = 128; // KV: 11 seqs × (ctx 10 + cand 2) = 132, 64 溢出
                                              //（2026-09-11 对齐源码版 llm_filter.cc 同款修正：
                                              //  64 时 score 的 S2 恒 ~100ms vs 128 的 ~40ms，
                                              //  真机 DLL 日志实证）
static int          g_n_seq_max       = 12;  // 模板 seq 0 + 最多 11 worker seq

// ============================================================
// 模型状态
// ============================================================
static llama_model        * g_model   = nullptr;
static llama_context      * g_ctx     = nullptr;
static const llama_vocab  * g_vocab   = nullptr;
static std::mutex           g_mutex;
static std::atomic<bool>    g_loaded{false};
static std::atomic<bool>    g_loading{false};
static std::vector<double>      g_last_scores;
static std::vector<std::string> g_last_cands;

// ============================================================
// 预解码状态：prepare() 在 commit 后异步执行 Step 1 + KV copy
// score() 检测 ctx 一致时直接跳到 Step 2
// ============================================================
static std::vector<llama_token> g_prep_ctx;     // 预解码的上下文 token
static std::vector<float>       g_prep_logits;  // ctx_last logits
static bool                      g_prep_ready = false; // prepare() 已完成
static std::atomic<int>         g_prep_seq{0};  // 请求序列号，跳过过期请求
static long                      g_seq0_gen = 0; // seq0 KV 代次: 任何覆盖 seq0 的 decode 递增
static long                      g_prep_gen = 0; // prepare 完成时的代次

static int g_score_log_cnt = 0;  // score 日志限频计数器

// ============================================================
// 轻量日志
// 目录: Lua 侧设置 log_dir (RIME 用户目录); 未设置则回退 %TEMP%
// ============================================================
static std::string g_log_dir;

static void log_msg(const char * fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    char path[MAX_PATH];
    if (!g_log_dir.empty() && g_log_dir.size() < MAX_PATH - 32) {
        strcpy_s(path, g_log_dir.c_str());
        strcat_s(path, "\\rime_llm_log.txt");
    } else {
        GetTempPathA(sizeof(path), path);
        strcat_s(path, sizeof(path), "rime_llm_log.txt");
    }
    // 日志轮转（2026-09-04）：>5MB 改名 .old（单文件轮转）防无限增长；
    // 改名失败（被占等罕见）则继续追加，不丢日志
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (GetFileAttributesExA(path, GetFileExInfoStandard, &fa) &&
        ((((unsigned long long)fa.nFileSizeHigh << 32) |
          (unsigned long long)fa.nFileSizeLow) > 5ull * 1024 * 1024)) {
        std::string oldp = std::string(path) + ".old";
        DeleteFileA(oldp.c_str());
        MoveFileA(path, oldp.c_str());
    }
    FILE * f = fopen(path, "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
}


// ============================================================
// 光标上文旁路（2026-09-10 插件版全功能：三层上文的前两层）
//   COM = Word/WPS 文字文档模型（前台 OpusApp 门控；Kwps→Word 双 ProGID，
//         WPS 双注册 Word CLSID 但以文档打开为条件，Kwps 优先无歧义）
//   UIA = UIA TextPattern 焦点元素前文（通用现代应用：Chromium 系/记事本
//         实测 8-13ms；读的是"当时焦点元素"，消费时校验前台进程一致）
//   历史 = lua 侧 commit_history 兜底（llm_processor.get_context）
// 实验依据与真机数据：memory wps-context-investigation.md 十一/十二节
//（探针 scripts/probe_wps_ctx.cpp / probe_uia_ctx.cpp，源码版 llm_filter.cc
//  comctx 同源实现已真机验证）。单后台线程 STA：2s 周期 + kick（commit 后）
// 刷新；lua 调用线程经 mutex 快照消费，COM/UIA 调用绝不在按键同步路径。
// ============================================================
namespace ctxlink {

static std::mutex g_mu;
static std::string g_com_text;                 // UTF-8
static unsigned long long g_com_stamp = 0;
static std::string g_uia_text;                 // UTF-8
static unsigned long long g_uia_stamp = 0;
static DWORD g_uia_pid = 0;                    // 快照来源焦点元素进程

static std::mutex g_cv_mu;
static std::condition_variable g_cv;
static std::atomic<bool> g_kick{false};
static std::atomic<bool> g_started{false};
static std::atomic<unsigned long long> g_last_kick_ms{0};  // 打字活跃期判定

// 前台 Office 判定（2026-09-11 扩展演示）：OpusApp 同属 MS Word（开发代号
// Opus）与 WPS 文字（复刻 Word 窗口体系）；PP12FrameClass 同属 MS
// PowerPoint（2010+）与 WPS 演示（实测 12.1.0.28505）→ 两个类名圈定
// "文字处理器 + 演示文档"。表格 XLMAIN（复刻 Excel）刻意不含——单元格
// 编辑态 COM 盲区（Office 系通病：编辑态对象模型挂起、无 Selection.Start
// 等价物），输入法打字恰在盲区，落 UIA/历史兜底。候选窗不抢前台。
enum class OfficeKind { NONE, WRITER, PPT };
static OfficeKind foreground_office() {
    HWND fg = GetForegroundWindow();
    if (!fg) return OfficeKind::NONE;
    wchar_t cls[64];
    if (GetClassNameW(fg, cls, 64) <= 0) return OfficeKind::NONE;
    if (wcscmp(cls, L"OpusApp") == 0) return OfficeKind::WRITER;
    if (wcscmp(cls, L"PP12FrameClass") == 0) return OfficeKind::PPT;
    return OfficeKind::NONE;
}
static DWORD foreground_pid() {
    HWND fg = GetForegroundWindow();
    DWORD pid = 0;
    if (fg) GetWindowThreadProcessId(fg, &pid);
    return pid;
}

// ---- COM 读链（源码版 llm_filter.cc comctx 同源）----
static HRESULT disp_invoke(IDispatch * obj, const wchar_t * name, WORD flags,
                           DISPPARAMS * pdp, VARIANT * ret) {
    DISPID dispid = 0;
    HRESULT hr = obj->GetIDsOfNames(IID_NULL, (LPOLESTR *)&name, 1,
                                    LOCALE_USER_DEFAULT, &dispid);
    if (FAILED(hr)) return hr;
    VariantInit(ret);
    return obj->Invoke(dispid, IID_NULL, LOCALE_USER_DEFAULT, flags, pdp,
                       ret, nullptr, nullptr);
}
static HRESULT disp_get(IDispatch * obj, const wchar_t * name, VARIANT * ret) {
    DISPPARAMS dp;
    ZeroMemory(&dp, sizeof(dp));
    return disp_invoke(obj, name, DISPATCH_PROPERTYGET, &dp, ret);
}

enum class ComRead { OK, NO_DOC, DEAD };

static ComRead com_read_chain(IDispatch * app, std::string & out) {
    VARIANT vwin, vsel, vstart, vdoc, vrng, vtxt;
    VariantInit(&vwin); VariantInit(&vsel); VariantInit(&vstart);
    VariantInit(&vdoc); VariantInit(&vrng); VariantInit(&vtxt);
    auto vt_ok = [](const VARIANT & v) {
        return v.vt == VT_DISPATCH && v.pdispVal;
    };
    HRESULT hr;
    if (FAILED(hr = disp_get(app, L"ActiveWindow", &vwin)) || !vt_ok(vwin) ||
        FAILED(hr = disp_get(vwin.pdispVal, L"Selection", &vsel)) ||
        !vt_ok(vsel) ||
        FAILED(hr = disp_get(vsel.pdispVal, L"Start", &vstart)) ||
        vstart.vt != VT_I4) {
        VariantClear(&vwin); VariantClear(&vsel); VariantClear(&vstart);
        VariantClear(&vdoc); VariantClear(&vrng); VariantClear(&vtxt);
        if (hr == DISP_E_EXCEPTION || hr == DISP_E_MEMBERNOTFOUND)
            return ComRead::NO_DOC;
        return ComRead::DEAD;
    }
    long pos = vstart.lVal, from = pos - 64;
    if (from < 0) from = 0;
    ComRead res = ComRead::OK;
    do {
        if (FAILED(hr = disp_get(app, L"ActiveDocument", &vdoc)) ||
            !vt_ok(vdoc)) {
            res = (hr == DISP_E_EXCEPTION) ? ComRead::NO_DOC : ComRead::DEAD;
            break;
        }
        VARIANT args[2];  // rgvark 反序：末参数 (pos) 在前
        VariantInit(&args[0]); args[0].vt = VT_I4; args[0].lVal = pos;
        VariantInit(&args[1]); args[1].vt = VT_I4; args[1].lVal = from;
        DISPPARAMS dp;
        ZeroMemory(&dp, sizeof(dp));
        dp.rgvarg = args; dp.cArgs = 2;
        if (FAILED(hr = disp_invoke(vdoc.pdispVal, L"Range",
                                    DISPATCH_METHOD | DISPATCH_PROPERTYGET,
                                    &dp, &vrng)) || !vt_ok(vrng)) {
            res = (hr == DISP_E_EXCEPTION) ? ComRead::NO_DOC : ComRead::DEAD;
            break;
        }
        if (FAILED(hr = disp_get(vrng.pdispVal, L"Text", &vtxt)) ||
            vtxt.vt != VT_BSTR) {
            res = (hr == DISP_E_EXCEPTION) ? ComRead::NO_DOC : ComRead::DEAD;
            break;
        }
        int n = WideCharToMultiByte(CP_UTF8, 0, vtxt.bstrVal, -1, nullptr, 0,
                                    nullptr, nullptr);
        if (n > 0) {
            out.resize(n - 1);
            if (n > 1)
                WideCharToMultiByte(CP_UTF8, 0, vtxt.bstrVal, -1, &out[0], n,
                                    nullptr, nullptr);
        }
    } while (false);
    VariantClear(&vwin); VariantClear(&vsel); VariantClear(&vstart);
    VariantClear(&vdoc); VariantClear(&vrng); VariantClear(&vtxt);
    return res;
}

// ---- 演示读链（WPP/PowerPoint，2026-09-11 本机实测验证）----
// app.ActiveWindow.Selection.Type==3(文本编辑) 时：start = TextRange.Start
//（框内 1-based 偏移）；前文 = ShapeRange.TextFrame.TextRange.Characters(
// max(1,start-64), min(64, start-1)).Text。Type!=3 → NO_DOC 语义
//（无文本编辑：形状/幻灯片选择态）。表格 XLMAIN 不在此链（编辑态盲区）。
static ComRead ppt_read_chain(IDispatch * app, std::string & out) {
    VARIANT vwin, vsel, vtype, vstart, vshape, vframe, vrng, vtxt;
    VariantInit(&vwin); VariantInit(&vsel); VariantInit(&vtype);
    VariantInit(&vstart); VariantInit(&vshape); VariantInit(&vframe);
    VariantInit(&vrng); VariantInit(&vtxt);
    auto vt_ok = [](const VARIANT & v) {
        return v.vt == VT_DISPATCH && v.pdispVal;
    };
    HRESULT hr;
    if (FAILED(hr = disp_get(app, L"ActiveWindow", &vwin)) || !vt_ok(vwin) ||
        FAILED(hr = disp_get(vwin.pdispVal, L"Selection", &vsel)) ||
        !vt_ok(vsel) ||
        FAILED(hr = disp_get(vsel.pdispVal, L"Type", &vtype)) ||
        vtype.vt != VT_I4) {
        VariantClear(&vwin); VariantClear(&vsel); VariantClear(&vtype);
        VariantClear(&vstart); VariantClear(&vshape); VariantClear(&vframe);
        VariantClear(&vrng); VariantClear(&vtxt);
        if (hr == DISP_E_EXCEPTION) return ComRead::NO_DOC;
        return ComRead::DEAD;
    }
    if (vtype.lVal != 3) {  // ppSelectionText = 3：非文本编辑态
        VariantClear(&vwin); VariantClear(&vsel); VariantClear(&vtype);
        VariantClear(&vstart); VariantClear(&vshape); VariantClear(&vframe);
        VariantClear(&vrng); VariantClear(&vtxt);
        return ComRead::NO_DOC;
    }
    ComRead res = ComRead::OK;
    do {
        if (FAILED(hr = disp_get(vsel.pdispVal, L"TextRange", &vrng)) ||
            !vt_ok(vrng) ||
            FAILED(hr = disp_get(vrng.pdispVal, L"Start", &vstart)) ||
            vstart.vt != VT_I4) {
            res = (hr == DISP_E_EXCEPTION) ? ComRead::NO_DOC : ComRead::DEAD;
            break;
        }
        long start = vstart.lVal;               // 1-based
        long len = start - 1 > 64 ? 64 : start - 1;  // 前文字数（截 64）
        if (len <= 0) { out.clear(); break; }   // 光标在框首：前文真空
        if (FAILED(hr = disp_get(vsel.pdispVal, L"ShapeRange", &vshape)) ||
            !vt_ok(vshape) ||
            FAILED(hr = disp_get(vshape.pdispVal, L"TextFrame", &vframe)) ||
            !vt_ok(vframe)) {
            res = (hr == DISP_E_EXCEPTION) ? ComRead::NO_DOC : ComRead::DEAD;
            break;
        }
        VARIANT vfull;
        VariantInit(&vfull);
        if (FAILED(hr = disp_get(vframe.pdispVal, L"TextRange", &vfull)) ||
            !vt_ok(vfull)) {
            VariantClear(&vfull);
            res = (hr == DISP_E_EXCEPTION) ? ComRead::NO_DOC : ComRead::DEAD;
            break;
        }
        // Characters(start_index, length)：rgvark 反序 [length, start_index]
        VARIANT args[2];
        VariantInit(&args[0]); args[0].vt = VT_I4; args[0].lVal = len;
        VariantInit(&args[1]); args[1].vt = VT_I4;
        args[1].lVal = start - len;             // 起始字符 = start-len（含尾部）
        DISPPARAMS dp;
        ZeroMemory(&dp, sizeof(dp));
        dp.rgvarg = args; dp.cArgs = 2;
        VariantClear(&vrng);  // 复用作出参：先释放首个 TextRange 引用
        if (FAILED(hr = disp_invoke(vfull.pdispVal, L"Characters",
                                    DISPATCH_METHOD | DISPATCH_PROPERTYGET,
                                    &dp, &vrng)) || !vt_ok(vrng)) {
            VariantClear(&vfull);
            res = (hr == DISP_E_EXCEPTION) ? ComRead::NO_DOC : ComRead::DEAD;
            break;
        }
        VariantClear(&vfull);
        if (FAILED(hr = disp_get(vrng.pdispVal, L"Text", &vtxt)) ||
            vtxt.vt != VT_BSTR) {
            res = (hr == DISP_E_EXCEPTION) ? ComRead::NO_DOC : ComRead::DEAD;
            break;
        }
        int n = WideCharToMultiByte(CP_UTF8, 0, vtxt.bstrVal, -1, nullptr, 0,
                                    nullptr, nullptr);
        if (n > 0) {
            out.resize(n - 1);
            if (n > 1)
                WideCharToMultiByte(CP_UTF8, 0, vtxt.bstrVal, -1, &out[0], n,
                                    nullptr, nullptr);
        }
    } while (false);
    VariantClear(&vwin); VariantClear(&vsel); VariantClear(&vtype);
    VariantClear(&vstart); VariantClear(&vshape); VariantClear(&vframe);
    VariantClear(&vrng); VariantClear(&vtxt);
    return res;
}

// ---- UIA 读链（2026-09-11 瘦身：~10 个跨进程往返 → 6 个）----
// 省法：①GetPattern 失败即无 TextPattern（去掉 IsTextPatternAvailable
// 属性往返）；②selection range 直接 Clone 后把 Start 端点前移 64 字
//（数学上等价于 [doc.Start, sel.Start) 截尾 64——去掉 DocumentRange +
// 2×MoveEndpointByRange 共 3 个往返）。每次跨进程往返 1-3ms 且打断
// 目标应用 UI 线程，读链瘦身同时降两边开销（真机 A/B：ctxlink 活跃
// 期 score 均值 +36%，2026-09-11 排查）。
static bool uia_read(IUIAutomation * uia, std::string & out, DWORD & pid) {
    IUIAutomationElement * el = nullptr;
    if (FAILED(uia->GetFocusedElement(&el)) || !el)
        return false;
    bool ret = false;
    int elpid = 0;
    el->get_CurrentProcessId(&elpid);
    IUIAutomationTextPattern * tp = nullptr;
    if (SUCCEEDED(el->GetCurrentPattern(UIA_TextPatternId,
                                        (IUnknown **)&tp)) && tp) {
        IUIAutomationTextRangeArray * sel = nullptr;
        if (SUCCEEDED(tp->GetSelection(&sel)) && sel) {
            IUIAutomationTextRange * s0 = nullptr;
            int nsel = 0;
            sel->get_Length(&nsel);
            if (nsel > 0) sel->GetElement(0, &s0);
            sel->Release();
            if (s0) {
                IUIAutomationTextRange * r = nullptr;
                if (SUCCEEDED(s0->Clone(&r))) {
                    // r = [光标(或选区起点)-64 字, 光标]：Start 端点前移
                    int moved = 0;
                    r->MoveEndpointByUnit(TextPatternRangeEndpoint_Start,
                                          TextUnit_Character, -64, &moved);
                    BSTR txt = nullptr;
                    if (SUCCEEDED(r->GetText(-1, &txt)) && txt) {
                        int n = WideCharToMultiByte(
                            CP_UTF8, 0, txt, -1, nullptr, 0,
                            nullptr, nullptr);
                        if (n > 0) {
                            out.resize(n - 1);
                            if (n > 1)
                                WideCharToMultiByte(
                                    CP_UTF8, 0, txt, -1, &out[0], n,
                                    nullptr, nullptr);
                            ret = true;
                        }
                        SysFreeString(txt);
                    }
                    r->Release();
                }
                s0->Release();
            }
        }
        tp->Release();
    }
    if (ret && elpid) pid = (DWORD)elpid;
    el->Release();
    return ret;
}

static void thread_proc() {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    IUIAutomation * uia = nullptr;
    bool uia_ok = SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation, nullptr,
                                             CLSCTX_INPROC_SERVER,
                                             IID_IUIAutomation,
                                             (void **)&uia));
    // 仅 WPS 系 ProgID（2026-09-11 定案）：COM 旁路只补 TSF/UIA 墙上唯一
    // 缺口=WPS（微软 Word/PPT 的 TSF/UIA 完整，无需 COM）。类名二义由
    // 附着成败天然消解：Kwps 附着成功=WPS 文字（用 COM）；失败=微软 Word
    // 或无文档（落 UIA/历史）——Word/PPT 的 ProgID 回落已撤（共存双注册
    // 误附风险随之归零）。
    CLSID clsid_kwps, clsid_kwpp;
    bool has_kwps = SUCCEEDED(CLSIDFromProgID(L"Kwps.Application",
                                              &clsid_kwps));
    bool has_kwpp = SUCCEEDED(CLSIDFromProgID(L"KWPP.Application",
                                              &clsid_kwpp));
    if (!uia_ok && !has_kwps && !has_kwpp)
        return;  // 无任何可用通道（极罕见）

    IDispatch * app = nullptr;
    OfficeKind app_kind = OfficeKind::NONE;  // 附着实例类型（文字/演示链路不同）
    bool logged_attach = false;
    bool com_pending = true;  // 前台 Office 且未附着 → 500ms 快速重试
                              //（文档打开瞬间 WPS 才注册 ROT，缩短发现间隙；
                              //  成功即回 2s，开销仅微秒级 ROT 查询）
    for (;;) {
        {
            std::unique_lock<std::mutex> lk(g_cv_mu);
            g_cv.wait_for(lk, std::chrono::milliseconds(
                                  g_kick.load() ? 1 : (com_pending ? 500 : 2000)));
        }
        bool woken_by_kick = g_kick.exchange(false);
        com_pending = false;

        // COM：前台 Office 才读（读端门控省后台空转；切回的
        // 首词缓存 age ≤ 2s+读链，kick/周期兜住）
        if (has_kwps || has_kwpp) {
            OfficeKind fg = foreground_office();
            if (fg != OfficeKind::NONE) {
                // 前台类型切换（文字↔演示）→ 释放旧附着，按前台类型选
                // ProgID（防 WPS 文字后台开文档时误附 Kwps 读错对象）
                if (app && fg != app_kind) {
                    app->Release();
                    app = nullptr;
                    app_kind = OfficeKind::NONE;
                    logged_attach = false;
                }
                if (!app) {
                    const char * via = nullptr;
                    IUnknown * punk = nullptr;
                    if (fg == OfficeKind::WRITER && has_kwps) {
                        if (SUCCEEDED(GetActiveObject(clsid_kwps, nullptr,
                                                      &punk)) && punk)
                            via = "Kwps.Application";
                    } else if (fg == OfficeKind::PPT && has_kwpp) {
                        if (SUCCEEDED(GetActiveObject(clsid_kwpp, nullptr,
                                                      &punk)) && punk)
                            via = "KWPP.Application";
                    }
                    if (punk) {
                        punk->QueryInterface(IID_IDispatch, (void **)&app);
                        punk->Release();
                        app_kind = fg;
                        if (!logged_attach) {
                            log_msg("ctx probe: com attached (%s)", via);
                            logged_attach = true;
                        }
                    }
                }
                if (app) {
                    std::string txt;
                    ComRead r = (app_kind == OfficeKind::PPT)
                                    ? ppt_read_chain(app, txt)
                                    : com_read_chain(app, txt);
                    std::lock_guard<std::mutex> lk(g_mu);
                    if (r == ComRead::OK) {
                        g_com_text = txt;
                        g_com_stamp = GetTickCount64();
                    } else {
                        g_com_text.clear();
                        g_com_stamp = 0;
                        if (r == ComRead::DEAD) {
                            if (logged_attach) {
                                log_msg("ctx probe: office app gone, "
                                        "will re-attach");
                                logged_attach = false;
                            }
                            app->Release();
                            app = nullptr;
                            app_kind = OfficeKind::NONE;
                        }
                        // NO_DOC（文档全关/演示非文本编辑态）：保留引用重试
                    }
                } else {
                    std::lock_guard<std::mutex> lk(g_mu);
                    g_com_text.clear();
                    g_com_stamp = 0;
                }
            } else {
                std::lock_guard<std::mutex> lk(g_mu);
                g_com_text.clear();
                g_com_stamp = 0;  // 前台非 Office：COM 缓存即刻失效
            }
            com_pending = (foreground_office() != OfficeKind::NONE) && !app;
        }

        // UIA：读当前焦点元素（不限前台是谁——消费时校验进程一致）。
        // 打字活跃期（最近 3s 内有 kick）暂停周期读：动态内容应用（终端
        // 状态行时间戳等）的周期刷新令快照文本抖动 → prepare/score 双双
        // 失配 + 推理锁竞争（真机实测 150-215ms 长尾，2026-09-11）；
        // kick 读已覆盖上屏后的更新需求，打字期间快照保持稳定。
        if (uia_ok && (woken_by_kick ||
                       GetTickCount64() - g_last_kick_ms.load() > 3000)) {
            std::string txt;
            DWORD pid = 0;
            if (uia_read(uia, txt, pid)) {
                std::lock_guard<std::mutex> lk(g_mu);
                g_uia_text = txt;
                g_uia_stamp = GetTickCount64();
                g_uia_pid = pid;
            } else {
                std::lock_guard<std::mutex> lk(g_mu);
                g_uia_text.clear();
                g_uia_stamp = 0;
                g_uia_pid = 0;
            }
        }
    }
}

static void ensure_started() {
    bool expect = false;
    if (g_started.compare_exchange_strong(expect, true))
        std::thread(thread_proc).detach();
}
static void kick() {
    g_last_kick_ms.store(GetTickCount64());
    g_kick.store(true);
    g_cv.notify_all();
}

// lua 调用线程消费：三层前两层判定（历史兜底由 lua 侧完成）。
// 返回 true 时 text/src 有效（src = "com" | "uia"）。
static bool pick(std::string & text, const char *& src) {
    unsigned long long now = GetTickCount64();
    if (foreground_office() != OfficeKind::NONE) {
        std::lock_guard<std::mutex> lk(g_mu);
        if (g_com_stamp && now - g_com_stamp <= 2500 && !g_com_text.empty()) {
            text = g_com_text;
            src = "com";
            return true;
        }
    }
    {
        // UIA 快照：新鲜 && 前台进程 == 快照来源进程（防切窗残留文本误用）
        DWORD fg = foreground_pid();
        std::lock_guard<std::mutex> lk(g_mu);
        if (g_uia_stamp && now - g_uia_stamp <= 2500 && !g_uia_text.empty() &&
            g_uia_pid != 0 && g_uia_pid == fg) {
            text = g_uia_text;
            src = "uia";
            return true;
        }
    }
    return false;
}

}  // namespace ctxlink


// ============================================================
// 异步模型加载
// ============================================================
static void load_model_async() {
    if (g_loaded.load() || g_loading.load()) return;
    g_loading.store(true);

    std::thread([]() {
#ifdef _WIN32
        // 加载期让渡 CPU（2026-09-04，与源码版同步）：模型读取+反量化+预热
        // 吃满 CPU/IO，会拖挂并发启动的进程（源码版实测 QQ 音乐等 CEF 应用
        // 秒级挂起）；warmup 前恢复 NORMAL——llama 的 decode worker 靠条件
        // 变量协同，低优先级下会被 NORMAL 线程饿死，卡在 warmup 不返回
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#endif
        log_msg("loading model: %s", g_model_path.c_str());

        llama_backend_init();

        llama_model_params mparams = llama_model_default_params();
        mparams.use_mmap = 1;

        g_model = llama_model_load_from_file(g_model_path.c_str(), mparams);
        if (!g_model) {
            log_msg("ERROR: failed to load model");
            g_loading.store(false);
            return;
        }
        g_vocab = llama_model_get_vocab(g_model);

        int n_thr = g_n_threads;

        llama_context_params cparams = llama_context_default_params();
        cparams.n_ctx           = g_n_ctx;
        cparams.n_threads       = n_thr;
        cparams.n_threads_batch = n_thr;
        cparams.n_seq_max       = g_n_seq_max;

        g_ctx = llama_new_context_with_model(g_model, cparams);
        if (!g_ctx) {
            log_msg("ERROR: failed to create context");
            llama_model_free(g_model);
            g_model = nullptr;
            g_loading.store(false);
            return;
        }

#ifdef _WIN32
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_NORMAL);
#endif

        // warmup
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            llama_memory_clear(llama_get_memory(g_ctx), false);
            const char * warmup = "\n";
            llama_token tokens[4];
            int n_tokens = llama_tokenize(g_vocab, warmup, (int)strlen(warmup),
                                           tokens, 4, true, true);
            if (n_tokens > 0) {
                llama_batch batch = llama_batch_get_one(tokens, n_tokens);
                llama_decode(g_ctx, batch);
            }
        }

        g_loaded.store(true);
        g_loading.store(false);
        log_msg("model ready (n_ctx=%d threads=%d)", g_n_ctx, n_thr);
    }).detach();
}

// 卸载模型（model_path 变更时由 lua_newindex 调用，2026-09-01）：旧模型
// 驻留内存会让新路径被无视——卸载后下一次 prepare/score 懒加载新路径。
// 与源码版 llm_filter.cc 的 unload_model 同构（等待在途加载 + 锁内释放）。
static void unload_model() {
    while (g_loading.load())
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_loaded.load() || g_model || g_ctx) {
        if (g_ctx) { llama_free(g_ctx); g_ctx = nullptr; }
        if (g_model) { llama_model_free(g_model); g_model = nullptr; }
        g_vocab = nullptr;
        g_loaded.store(false);
        g_prep_ready = false;
        g_prep_ctx.clear();
        g_prep_logits.clear();
        log_msg("model unloaded (model_path changed)");
    }
}

// ============================================================
// 分词
// ============================================================
static std::vector<llama_token> tokenize(const char * text) {
    std::vector<llama_token> toks(128);
    int n = llama_tokenize(g_vocab, text, (int)strlen(text),
                            toks.data(), (int)toks.size(), true, true);
    // llama_tokenize API 约定：buffer 不足时返回负值，-n 为所需 token 数。
    // 首次调用带 128 上限，超长文本（如整段上文）会返回负 → resize 后重试。
    if (n < 0) {
        toks.resize(-n);
        n = llama_tokenize(g_vocab, text, (int)strlen(text),
                           toks.data(), (int)toks.size(), true, true);
    }
    toks.resize(std::max(0, n));
    return toks;
}

// ============================================================
// Softmax CE 辅助：-log(softmax(x)[target])
// ============================================================
static double cross_entropy(float * logits, int vs, int target_id) {
    float m = -1e30f;
    for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    double se = 0;
    for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
    return -((double)(logits[target_id] - m) - log(se));
}

// 归一化 (max, logsumexp) 一次计算, 多目标 CE 共享复用:
// Step 1 所有候选对同一 ctx logits 打分, 原实现对每个候选重扫
// O(vocab) (5 候选取 5 次 -> 实测 CE1 段 ~6ms), 共享后一次扫描 + 查表
// (-> ~2ms)
static void logits_normalizer(float * logits, int vs, float & m, double & lse) {
    m = -1e30f;
    for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    double se = 0;
    for (int k = 0; k < vs; k++) se += exp((double)(logits[k] - m));
    lse = log(se);
}
static double ce_target(float * logits, int target_id, float m, double lse) {
    return -((double)(logits[target_id] - m) - lse);
}

// ============================================================
// 核心评分：ctx 仅 1 次 decode + KV copy + 多序列分层并行候选 decode
//
// Step 1: decode ctx → 保存 logits → 所有候选的第 1 个 token CE 从此计算
// Step 2: KV copy ctx → M 个 seq，并行 decode 候选首 token → 第 2 token CE
// Step 3: 同一批 seq 继续 decode → 第 3 token CE
//
// 原理：P(tok_i0|ctx) 对所有 i 共享同一个 ctx_last hidden state
//       多 token 候选每个 seq 仅 1 个新 token，SSM 跨序列干扰可忽略
//       ith = batch 数组索引（不是 logits 标记序号）
// ============================================================
static void score_batch(const std::vector<llama_token> & ctx_ids,
                         const std::vector<std::vector<llama_token>> & cands,
                         std::vector<double> & scores_out) {
    scores_out.assign(cands.size(), -1e10);
    int n_cands = (int)cands.size();
    if (n_cands == 0) return;

    auto t0 = std::chrono::high_resolution_clock::now();
    std::lock_guard<std::mutex> lock(g_mutex);
    auto t1 = std::chrono::high_resolution_clock::now();
    double wait_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();


    int ctx_len = (int)ctx_ids.size();
    int vs = llama_n_vocab(g_vocab);

    // 按 token 数分组
    std::vector<int> idx2, idx3;
    for (int i = 0; i < n_cands; i++) {
        if (cands[i].size() >= 2) idx2.push_back(i);
        if (cands[i].size() >= 3) idx3.push_back(i);
    }
    int M = (int)idx2.size();
    int K = (int)idx3.size();
    std::vector<int> cand_to_seq(n_cands, -1);  // candidate index → seq id

    // 检测预解码状态：ctx 完全匹配 且 seq0 未被其他 decode 覆盖 → 跳过 Step 1
    // 代次匹配防止: 完整流程 score 覆盖 seq0 后, 旧 prep 状态被误用 (KV 与 logits 不一致)
    bool use_prep = g_prep_ready && ctx_ids == g_prep_ctx && g_seq0_gen == g_prep_gen;
    std::vector<float> ctx_logits;
    double ms1 = 0;

    if (!use_prep) {
        // ---- 完整流程：Step 1 ctx decode ----
        auto ts1_0 = std::chrono::high_resolution_clock::now();
        // memory_clear 第 2 参：true=零化整个 KV cache（40 万次 decode 的
        // benchmark 会拖慢吞吐）；false=仅重置元数据。新序列的因果注意力
        // 掩码天然隔离旧 KV，无需显式归零。
        llama_memory_clear(llama_get_memory(g_ctx), false);
        llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
        for (int j = 0; j < ctx_len; j++) {
            ctx_batch.token[j] = ctx_ids[j]; ctx_batch.pos[j] = j;
            ctx_batch.n_seq_id[j] = 1; ctx_batch.seq_id[j][0] = 0;
        }
        ctx_batch.logits[ctx_len - 1] = 1;
        ctx_batch.n_tokens = ctx_len;
        if (llama_decode(g_ctx, ctx_batch) == 0) {
            g_seq0_gen++;  // seq0 KV 已更新
            float* cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
            if (cl) ctx_logits.assign(cl, cl + vs);
        }
        llama_batch_free(ctx_batch);

        if (ctx_logits.empty()) return;  // decode failed
        // 完整流程自我刷新 prep: 刚 decode 完 seq0 (代次已递增), KV/logits 一致,
        // 保存后同 ctx 的后续 score (翻页/候选窗重建) 全部命中——
        // 否则一次未命中导致代次失配, 后续 score 连锁全部 prep=0 直到下次 commit
        g_prep_gen = g_seq0_gen;
        g_prep_ctx = ctx_ids;
        g_prep_logits = ctx_logits;
        g_prep_ready = true;
        auto ts1_1 = std::chrono::high_resolution_clock::now();
        ms1 = std::chrono::duration<double, std::milli>(ts1_1 - ts1_0).count();
    } else {
        // 预解码命中：直接使用已保存的 logits
        ctx_logits = g_prep_logits;
    }

    // 所有候选的第 1 个 token CE (共享同一 ctx logits -> 归一化只算一次)
    auto ts_ce1_0 = std::chrono::high_resolution_clock::now();
    std::vector<double> ce_sum(n_cands, 0);
    float m0;
    double lse0;
    logits_normalizer(ctx_logits.data(), vs, m0, lse0);
    for (int i = 0; i < n_cands; i++) {
        ce_sum[i] = ce_target(ctx_logits.data(), cands[i][0], m0, lse0);
    }
    auto ts_ce1_1 = std::chrono::high_resolution_clock::now();
    double ms_ce1 =
        std::chrono::duration<double, std::milli>(ts_ce1_1 - ts_ce1_0).count();

    // ---- Step 2: 多 token 候选的首 token 并行 decode（每 seq 1 token）----
    double ms2a = 0, ms2b = 0;
    if (M > 0) {
        auto ts2_0 = std::chrono::high_resolution_clock::now();
        // KV copy ctx (seq 0) → worker seqs 1..M
        for (int s = 0; s < M; s++) {
            llama_memory_seq_cp(llama_get_memory(g_ctx), 0, s + 1, 0, -1);
            cand_to_seq[idx2[s]] = s + 1;
        }
        auto ts2_kv = std::chrono::high_resolution_clock::now();

        llama_batch b2 = llama_batch_init(M, 0, M);
        for (int s = 0; s < M; s++) {
            int ci = idx2[s];
            b2.token[s] = cands[ci][0];
            b2.pos[s] = ctx_len;
            b2.n_seq_id[s] = 1;
            b2.seq_id[s][0] = s + 1;
            b2.logits[s] = 1;
        }
        b2.n_tokens = M;
        if (llama_decode(g_ctx, b2) == 0) {
            for (int s = 0; s < M; s++) {
                int ci = idx2[s];
                float* l = llama_get_logits_ith(g_ctx, s);
                if (l) ce_sum[ci] += cross_entropy(l, vs, cands[ci][1]);
                else   ce_sum[ci] = -1e10;
            }
    } else {
        for (int ci : idx2) ce_sum[ci] = -1e10;
        // 失败自愈：prep 命中路径无 memory_clear，decode 失败多为 KV 耗尽
        // （见下方 worker 清理说明）——置无效强制下次 score 走全流程重建
        g_prep_ready = false;
    }
    llama_batch_free(b2);
        auto ts2_1 = std::chrono::high_resolution_clock::now();
        ms2a = std::chrono::duration<double, std::milli>(ts2_kv - ts2_0).count();
        ms2b = std::chrono::duration<double, std::milli>(ts2_1 - ts2_kv).count();
    }

    // ---- Step 3: 3-token 候选的次 token 并行 decode ----
    double ms3 = 0;
    if (K > 0) {
        auto ts3_0 = std::chrono::high_resolution_clock::now();
        llama_batch b3 = llama_batch_init(K, 0, K);
        for (int s = 0; s < K; s++) {
            int ci = idx3[s];
            int seq_id = cand_to_seq[ci];  // same seq as step 2
            b3.token[s] = cands[ci][1];
            b3.pos[s] = ctx_len + 1;
            b3.n_seq_id[s] = 1;
            b3.seq_id[s][0] = seq_id;
            b3.logits[s] = 1;
        }
        b3.n_tokens = K;
        if (llama_decode(g_ctx, b3) == 0) {
            for (int s = 0; s < K; s++) {
                int ci = idx3[s];
                float* l = llama_get_logits_ith(g_ctx, s);
                if (l) ce_sum[ci] += cross_entropy(l, vs, cands[ci][2]);
                else   ce_sum[ci] = -1e10;
            }
        } else {
            for (int ci : idx3) ce_sum[ci] = -1e10;
            g_prep_ready = false;  // 同 Step2：失败自愈
        }
        llama_batch_free(b3);
        auto ts3_1 = std::chrono::high_resolution_clock::now();
        ms3 = std::chrono::duration<double, std::milli>(ts3_1 - ts3_0).count();
    }

    // ---- worker 序列 KV 清理（2026-09-04 修"推理自停"根因，与源码版同步）----
    // seq_cp 是共享标记非复制：Step2/3 的 decode cell 在评分结束后仍归属
    // seq 1..M。prep 命中路径无 memory_clear，同 ctx 连续评分（退格重打/
    // 改码不换 ctx/失败重试）每轮净耗 M+K cell —— n_ctx=64 约 6~7 轮耗尽
    // → decode 静默失败 → 全哨兵分且 prep_ready 仍真 → 卡死失败循环，
    // 仅 commit 触发 prepare 或重部署可解（非本机实测）。评分尾部立即释放
    // worker 归属：共享 cell 只去掉一个归属方，seq0 与 prep 状态不受影响，
    // prep 命中照常，每次评分净耗归零。
    if (M > 0) {
        auto *mem = llama_get_memory(g_ctx);
        for (int s = 1; s <= M; s++)
            llama_memory_seq_rm(mem, s, 0, -1);
    }

    // ---- 输出分数 ----
    auto ts_sc_0 = std::chrono::high_resolution_clock::now();
    // 4+ token 候选只算了前 3 项 CE: 截断让长词免掉尾部 (负的) CE → 长词被高估。
    // 按平均 CE 外推缺失尾部 (λ=0.6, eval_long_cand 细扫 0.3-0.7:
    // 真实尾部 CE/头部 CE 实测 mean 0.58(len4)/0.62(len5+), 0.5-0.7 平台
    // ~94% 首选一致率, 0.6 方向平衡 up5/down5; 无额外 decode):
    //   score = -ce_sum - (ce_sum/3) * (n_tokens-3) * 0.6
    for (int i = 0; i < n_cands; i++) {
        double score = ce_sum[i] > -1e9 ? -ce_sum[i] : -1e10;
        if (score > -1e9 && (int)cands[i].size() > 3) {
            double avg_ce = ce_sum[i] / 3.0;
            score = -ce_sum[i] - avg_ce * ((int)cands[i].size() - 3) * 0.6;
        }
        scores_out[i] = score;
    }

    // 注意: prep 状态不消耗——同一 ctx 期间可重复命中
    // (代次机制保证 seq0 被覆盖后自动失效, 无需主动清除)

    auto t_end = std::chrono::high_resolution_clock::now();
    double total_ms = std::chrono::duration<double, std::milli>(t_end - t0).count();
    double ms_score =
        std::chrono::duration<double, std::milli>(t_end - ts_sc_0).count();
    // 日志限频: 每 10 次记一次, 慢请求 (总耗时 > 100ms) 始终记录
    // 计时: wait=锁等待 S1=ctx decode(0 on prep) CE1=P(cand0|ctx)
    //       KV=KV copy S2=decode cand0 S3=decode cand1 score=打分+外推
    if (++g_score_log_cnt % 10 == 1 || total_ms > 100)
        log_msg("score: wait=%.0fms S1=%.0fms CE1=%.0fms KV=%.0fms S2=%.0fms "
                "S3=%.0fms score=%.0fms total=%.0fms prep=%d ctx_tok=%d cand=%d",
                wait_ms, ms1, ms_ce1, ms2a, ms2b, ms3, ms_score, total_ms,
                use_prep ? 1 : 0, ctx_len, n_cands);
}

// ============================================================
// 预解码：在 commit 后异步执行 Step 1 + KV copy
// seq 用于跳过过期请求（新的 prepare 已到达，旧的直接放弃）
// ============================================================
static void prepare(const std::vector<llama_token> & ctx_ids, int seq) {
    // 推理进行中（score 持锁）则放弃本轮（2026-09-04，与源码版同步）：
    // prep 只是预解码优化，下次 score 的全流程会自我刷新兜底；阻塞等锁
    // 会让 detached prepare 线程在 g_mutex 上与 score 争用、堆积排队
    std::unique_lock<std::mutex> lock(g_mutex, std::try_to_lock);
    if (!lock.owns_lock()) {
        log_msg("prepare: SKIP score in progress (seq=%d ctx_tok=%d)",
                seq, (int)ctx_ids.size());
        return;
    }

    int ctx_len = (int)ctx_ids.size();

    // 过期请求：新的 prepare 已到来，放弃本次计算
    if (seq != g_prep_seq.load()) {
        log_msg("prepare: SKIP stale seq=%d current=%d ctx_tok=%d", seq, g_prep_seq.load(), ctx_len);
        return;
    }
    log_msg("prepare: start ctx_tok=%d seq=%d", ctx_len, seq);
    int vs = llama_n_vocab(g_vocab);
    auto* mem = llama_get_memory(g_ctx);

    // 清除上次的预解码
    g_prep_ready = false;
    g_prep_ctx.clear();
    g_prep_logits.clear();

    // Step 1: decode ctx → seq 0
    // 同 score_batch：memory_clear 第 2 参 false = 不零化 KV，仅重置元数据
    llama_memory_clear(mem, false);
    llama_batch ctx_batch = llama_batch_init(ctx_len, 0, 1);
    for (int j = 0; j < ctx_len; j++) {
        ctx_batch.token[j] = ctx_ids[j]; ctx_batch.pos[j] = j;
        ctx_batch.n_seq_id[j] = 1; ctx_batch.seq_id[j][0] = 0;
    }
    ctx_batch.logits[ctx_len - 1] = 1;
    ctx_batch.n_tokens = ctx_len;

    if (llama_decode(g_ctx, ctx_batch) != 0) {
        llama_batch_free(ctx_batch);
        return;  // decode 失败，score 时走完整流程
    }
    float* cl = llama_get_logits_ith(g_ctx, ctx_len - 1);
    if (!cl) { llama_batch_free(ctx_batch); return; }
    g_prep_logits.assign(cl, cl + vs);
    llama_batch_free(ctx_batch);

    // 不预复制 KV——n_ctx=64 太小，且 KV copy 本身很快
    // score() 检测 ctx 一致时跳过 Step 1，但仍执行 KV copy + Step 2

    g_seq0_gen++;   // seq0 KV 已更新 (本代)
    g_prep_gen = g_seq0_gen;
    g_prep_ctx = ctx_ids;
    g_prep_ready = true;
    log_msg("prepare: done ctx_tok=%d seq=%d", ctx_len, seq);
}

// ============================================================
// Lua API
// ============================================================
static int lua_prepare(lua_State * L) {
    // 懒加载触发点（2026-08-31 修 model_path 不生效）：加载不在 luaopen
    // 急切启动——那时 lua 侧还没把 schema 的 model_path 写进来，加载线程
    // 会拿默认路径开跑，配置形同虚设。首个触发方是 processor 的 prepare
    //（其 lua 在 require 后、prepare 前已设好 model_path），score 是兜底。
    if (!g_loaded.load()) {
        if (!g_loading.load()) load_model_async();
        lua_pushboolean(L, 0);
        return 1;
    }
    const char * context = luaL_checkstring(L, 1);
    auto ctx_ids = tokenize(context);
    // 上文 token 数 < min_tokens (方案文件 llm_rerank/min_tokens, lua 传入)
    // → 不预解码 (空 ctx 无推理是配置语义, 非 bug)
    if ((int)ctx_ids.size() < g_min_tokens) {
        lua_pushboolean(L, 0);
        return 1;
    }
    if ((int)ctx_ids.size() > g_max_ctx_tokens)
        ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - g_max_ctx_tokens);

    // 递增序列号，之前的过期 prepare 会在获取 mutex 后自行跳过
    int seq = ++g_prep_seq;

    // 异步执行预解码，不阻塞输入法 processor
    std::thread([ctx_ids, seq]() {
        prepare(ctx_ids, seq);
    }).detach();

    lua_pushboolean(L, 1);
    return 1;
}

static int lua_score(lua_State * L) {
    if (!g_loaded.load()) {
        if (!g_loading.load()) load_model_async();
        lua_pushnil(L);
        return 1;
    }

    const char * context = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    std::vector<std::string> cand_texts;
    int n = (int)luaL_len(L, 2);
    if (n < 2) { lua_pushnil(L); return 1; }
    if (n > g_n_seq_max) n = g_n_seq_max;
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 2, i);
        const char * s = lua_tostring(L, -1);
        if (s) cand_texts.push_back(s);
        lua_pop(L, 1);
    }
    if (cand_texts.size() < 2) { lua_pushnil(L); return 1; }

    std::vector<llama_token> ctx_ids = tokenize(context);
    // 上文 token 数 < min_tokens (方案文件 llm_rerank/min_tokens, lua 传入)
    // → 不推理 (空 ctx 无推理是配置语义, 非 bug)
    if ((int)ctx_ids.size() < g_min_tokens) { lua_pushnil(L); return 1; }
    if ((int)ctx_ids.size() > g_max_ctx_tokens)
        ctx_ids.erase(ctx_ids.begin(), ctx_ids.end() - g_max_ctx_tokens);

    std::vector<std::vector<llama_token>> cand_ids;
    for (auto & s : cand_texts) {
        auto ids = tokenize(s.c_str());
        if (ids.empty()) ids.push_back(0);
        cand_ids.push_back(ids);
    }

    std::vector<double> scores;
    try {
        score_batch(ctx_ids, cand_ids, scores);
    } catch (...) {
        log_msg("ERROR: exception in score_batch");
        lua_pushnil(L);
        return 1;
    }

    // 按分数降序排列
    std::vector<int> order(scores.size());
    for (int i = 0; i < (int)order.size(); i++) order[i] = i;
    std::sort(order.begin(), order.end(),
              [&](int a, int b) { return scores[a] > scores[b]; });

    g_last_scores = scores;
    g_last_cands  = cand_texts;

    lua_newtable(L);
    for (int i = 0; i < (int)order.size(); i++) {
        lua_pushstring(L, cand_texts[order[i]].c_str());
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

static int lua_get_scores(lua_State * L) {
    std::lock_guard<std::mutex> lock(g_mutex);
    lua_newtable(L);
    for (size_t i = 0; i < g_last_cands.size(); i++) {
        lua_pushnumber(L, g_last_scores[i]);
        lua_setfield(L, -2, g_last_cands[i].c_str());
    }
    return 1;
}

static int lua_is_ready(lua_State * L) {
    lua_pushboolean(L, g_loaded.load() ? 1 : 0);
    return 1;
}

// 光标上文（三层前两层，2026-09-10）：成功返回 (text, "com"|"uia")，
// 无可用快照返回 nil —— lua 侧回落 commit_history。
// COM/UIA 调用全部在后台线程（本函数只读 mutex 快照 + 前台窗口判定，
// 按键路径零阻塞）
static int lua_llm_context(lua_State * L) {
    ctxlink::ensure_started();
    std::string text;
    const char * src = nullptr;
    if (ctxlink::pick(text, src)) {
        lua_pushstring(L, text.c_str());
        lua_pushstring(L, src);
        return 2;
    }
    lua_pushnil(L);
    return 1;
}

// commit 后触发：立即刷新 COM/UIA 快照（新词已入文档/控件，读链 ~6-13ms
// 异步完成，下一键即有新鲜上文）
static int lua_kick_context(lua_State * L) {
    ctxlink::kick();
    return 0;
}

// 前台进程切换检测（跨应用，2026-09-11）：插件版 lua 无焦点事件，经此
// 让 processor 在跨应用切换后重置历史上文（对齐源码版 focus:switch
// reset 语义——真机踩坑：切新文档首词用旧窗口历史冒充上文标 AI·历史）。
// 比 pid 不比 HWND：同应用内对话框/多文档窗口不误清。进程级单例状态。
static int lua_fg_changed(lua_State * L) {
    static DWORD last_pid = 0;
    DWORD cur = ctxlink::foreground_pid();
    bool changed = (last_pid != 0 && cur != 0 && cur != last_pid);
    last_pid = cur;
    lua_pushboolean(L, changed ? 1 : 0);
    return 1;
}

// ============================================================
// __index / __newindex
// ============================================================
static int lua_index(lua_State * L) {
    const char * key = luaL_checkstring(L, 2);
    if (strcmp(key, "is_ready") == 0)       lua_pushcfunction(L, lua_is_ready);
    else if (strcmp(key, "get_scores") == 0) lua_pushcfunction(L, lua_get_scores);
    else if (strcmp(key, "score") == 0)     lua_pushcfunction(L, lua_score);
    else if (strcmp(key, "prepare") == 0)   lua_pushcfunction(L, lua_prepare);
    else if (strcmp(key, "llm_context") == 0)    lua_pushcfunction(L, lua_llm_context);
    else if (strcmp(key, "kick_context") == 0)   lua_pushcfunction(L, lua_kick_context);
    else if (strcmp(key, "fg_changed") == 0)     lua_pushcfunction(L, lua_fg_changed);
    else if (strcmp(key, "model_path") == 0) lua_pushstring(L, g_model_path.c_str());
    else if (strcmp(key, "max_ctx") == 0)   lua_pushinteger(L, g_max_ctx_tokens);
    else if (strcmp(key, "min_tokens") == 0) lua_pushinteger(L, g_min_tokens);
    else if (strcmp(key, "n_threads") == 0) lua_pushinteger(L, g_n_threads);
    else if (strcmp(key, "n_ctx") == 0)     lua_pushinteger(L, g_n_ctx);
    else if (strcmp(key, "n_seq_max") == 0) lua_pushinteger(L, g_n_seq_max);
    else lua_pushnil(L);
    return 1;
}

static int lua_newindex(lua_State * L) {
    const char * key = luaL_checkstring(L, 2);
    if (strcmp(key, "model_path") == 0) {
        std::string np = luaL_checkstring(L, 3);
        if (np != g_model_path) {
            g_model_path = np;
            // 路径变更：卸载旧模型（等待在途加载有界；free 毫秒级），
            // 下一次 prepare/score 以新路径懒加载
            if (g_loaded.load()) unload_model();
        }
    }
    else if (strcmp(key, "max_ctx") == 0)    g_max_ctx_tokens = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "min_tokens") == 0) g_min_tokens = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "n_threads") == 0)  g_n_threads = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "n_ctx") == 0)      g_n_ctx = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "n_seq_max") == 0)  g_n_seq_max = (int)luaL_checkinteger(L, 3);
    else if (strcmp(key, "log_dir") == 0)    g_log_dir = luaL_checkstring(L, 3);  // RIME 用户目录
    return 0;
}

// ============================================================
// 模块入口
// ============================================================
extern "C" __declspec(dllexport) int luaopen_rime_llm(lua_State * L) {
    lua_newtable(L);

    lua_pushcfunction(L, lua_score);
    lua_setfield(L, -2, "score");

    lua_pushcfunction(L, lua_prepare);
    lua_setfield(L, -2, "prepare");

    lua_pushcfunction(L, lua_is_ready);
    lua_setfield(L, -2, "is_ready");

    // 光标上文旁路（2026-09-10 三层上文前两层）：函数注册与 score/prepare
    // 同款（setfield 直挂，不走 __newindex 属性语义）
    lua_pushcfunction(L, lua_llm_context);
    lua_setfield(L, -2, "llm_context");

    lua_pushcfunction(L, lua_kick_context);
    lua_setfield(L, -2, "kick_context");

    lua_pushcfunction(L, lua_fg_changed);
    lua_setfield(L, -2, "fg_changed");

    // 可写属性（model_path/max_ctx/n_threads/n_ctx/n_seq_max/min_tokens）
    // 严禁在此预填充为原始字段——Lua 的 __newindex 只对表中不存在的键
    // 触发，预填充过的键被赋值时只是 rawset 覆盖，永远到不了 C++ setter
    //（2026-08-31 终审定位：model_path 配置自插件版诞生即被此吞掉，一直
    // 靠默认路径恰好正确掩盖）。读由 __index 动态服务，写走 __newindex。
    lua_newtable(L);
    lua_pushcfunction(L, lua_index);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, lua_newindex);
    lua_setfield(L, -2, "__newindex");
    lua_setmetatable(L, -2);

    // 不在此启动模型加载（2026-08-31）：require 时 model_path 尚未由 lua
    // 写入，急切加载会锁定默认路径——加载改由 prepare/score 懒触发。
    return 1;
}
