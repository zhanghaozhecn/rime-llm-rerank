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
#include <functional>
#include <cmath>
#include <array>
#include <cstring>
#include <cstdarg>
#include <cstdlib>
#include <algorithm>
#include <regex>

// N-gram 组句器（2026-11-23 整句模式第②段；算法 = 研究库
// eval/tools/sentence_gen_gram.py 的生产移植）
#include "ngram.h"

// ============================================================
// 配置默认值
// ============================================================
// 默认模型路径 = RIME 用户目录根\Qwen...gguf（2026-08-31 用户澄清定案：
// "用户文件夹"= 小狼毫右键的用户文件夹 %APPDATA%\Rime——方案配置所在
// 处，模型直接放根目录、不套子文件夹；8-27 曾误用 %USERPROFILE%\
// gguf_models\。自定义位置用 schema model_path 显式指向。便携模式小狼毫
// 的用户目录不在 %APPDATA%\Rime，此类部署需显式配置 model_path）
// 默认模型 = Qwen3-0.6B-Base-Q4_K_M（2026-11-19 用户定案 0.6B base：
// 研究帕累托最优 100ms/3.78%、预填充 79ms；2026-11-22 补齐此处内置默认
// ——定案当时只改了真机方案节的显式 model_path，C++ 默认仍指
// qwen2.5-0.5b-instruct，无 model_path 的方案（如 GUI 接入的朙月拼音，
// 模板注释该行）会加载不存在的文件 → failed to load model 死循环，
// 每键 skip=model_loading 无推理，真机排查发现）。
// 前身 2026-11-16 的 qwen2.5-0.5b-instruct（base→instruct 切换：聚合
// 与 base 无差异、下载直连快）；更旧 2026-11-14 Qwen2.5-0.5B（base）、
// Qwen3.5-0.8B）
static std::string default_model_path() {
  const char *ad = getenv("APPDATA");
  if (ad && *ad)
    return std::string(ad) + "\\Rime\\Qwen3-0.6B-Base-Q4_K_M.gguf";
  return "Qwen3-0.6B-Base-Q4_K_M.gguf";
}
static std::string  g_model_path      = default_model_path();
static int          g_min_tokens      = 1;
static int          g_max_ctx_tokens  = 10; // tok=10 准确率 93.4%，10→17 收益仅 +1.1pp 但延迟翻倍
static int          g_n_threads       = 4;  // 默认=GGML 默认; 可用 bench_threads 实测后配置
static int          g_n_ctx           = 512; // 3-token 与整句 CE 共用同一 context（2026-11-23 合并）：
                                              //   短路径 11 seq × (ctx10+cand2) = 132；
                                              //   整句 1 ctx + 5 × (ctx10+cand48) ≈ 300
                                              //   512 两者都够，且整句可直接复用 seq0 的 prep
                                              // 历史：128 为 3-token 单独口径（64 时 S2 恒 ~100ms
                                              //   vs 128 的 ~40ms，真机日志实证）
static int          g_n_seq_max       = 20;  // 模板 seq 0 + worker seq（2026-11-26:
                                             //   CE 预算 12 时不同首 token 行 ≤12，
                                             //   改 20 留余量；KV cell 与 seq 数无关）

// CE 位置权重（2026-09-16 采纳，首项归一规范形；与 (1.15,1.30,0.70) 排序等价、
// ce2 判别力最强（同时携带上下文契合 + 词内连贯），ce3 已深入词内部、上下文
// 影响衰减属噪声源降权；4+ token 词只算前三项——外推证伪删除（λ 0→1 端到端
// 命中率单调递减，λ=0 最优；旧 λ=0.6 标定用"与全量 CE 一致率"口径，与端
// 指标分道扬镳）。胜出变体 conf 91.82→92.13（+0.31pp，平台非尖峰）。
// v3 2026-11-06 六维联合标定 (w2×w3×β×τ×γ×λ 68,640 点, 用户域标定 →
// wiki 平台内就近): (1.0, 1.05, 0.45); 旧值 (1.0, 1.13, 0.61) 出自
// 2026-09-16 20% 前缀标定。
// 2026-11-14 默认模型改 Qwen2.5-0.5B 后重标定（用户域 34k + wiki 池化
// 180k 网格 w2×w3×β, 偶半选→奇半验四半区一致）: (1.0, 1.10, 0.60)
// + β 12→14（calibrate_model_05b, τ=400 词频侧与模型无关不动）。
static constexpr double kCeW1 = 1.0, kCeW2 = 1.10, kCeW3 = 0.60;

// ============================================================
// 模型状态
// ============================================================
static llama_model        * g_model   = nullptr;
static llama_context      * g_ctx     = nullptr;  // 3-token 与整句 CE 共用（2026-11-23 合并）
static const llama_vocab  * g_vocab   = nullptr;
static std::mutex           g_mutex;
static std::atomic<bool>    g_loaded{false};
static std::atomic<bool>    g_loading{false};
static std::vector<double>      g_last_scores;
static std::vector<std::string> g_last_cands;
static std::vector<std::array<double, 3>> g_last_ce3;  // 与 g_last_cands 对齐的 CE 三分量（调试 get_ce3）
static std::vector<std::string> g_last_seg;   // 与 g_last_cands 对齐的 token 边界段显（调试 get_seg，协议 v7）
static bool                     g_last_prep_hit = false;  // 上次 score 的预解码命中（调试）

// ============================================================
// 预解码状态：prepare() 在 commit 后异步执行 Step 1 + KV copy
// score() 检测 ctx 一致时直接跳到 Step 2
// ============================================================
static std::vector<llama_token> g_prep_ctx;     // 预解码的上下文 token
static std::vector<float>       g_prep_logits;  // ctx_last logits
static float                    g_prep_m = 0;   // ctx_last logits 的 softmax max（随 prep 缓存，命中路径免 O(vocab) 重扫）
static double                   g_prep_lse = 0; // ctx_last logits 的 logsumexp（同上）
static bool                      g_prep_ready = false; // prepare() 已完成
static std::atomic<int>         g_prep_seq{0};  // 请求序列号，跳过过期请求
static long                      g_seq0_gen = 0; // seq0 KV 代次: 任何覆盖 seq0 的 decode 递增
static long                      g_prep_gen = 0; // prepare 完成时的代次

// 2026-11-18：prepare 撞上推理锁（try_lock 失败）时不再静默丢弃——
// 记下这次请求，score 结束（释放锁）后自动补跑一次。
static std::mutex                g_prep_pending_mu;
static std::vector<llama_token>  g_prep_pending_ctx;
static int                       g_prep_pending_seq = -1;
static void request_prepare_retry(const std::vector<llama_token> & ids,
                                  int seq) {
    {
        std::lock_guard<std::mutex> lk(g_prep_pending_mu);
        g_prep_pending_ctx = ids;
        g_prep_pending_seq = seq;
    }
}
static bool take_prepare_retry(std::vector<llama_token> & out, int & seq) {
    std::lock_guard<std::mutex> lk(g_prep_pending_mu);
    if (g_prep_pending_seq < 0) return false;
    out = std::move(g_prep_pending_ctx);
    seq = g_prep_pending_seq;
    g_prep_pending_ctx.clear();
    g_prep_pending_seq = -1;
    return true;
}

static int g_score_log_cnt = 0;  // score 日志限频计数器

// ============================================================
// 轻量日志
// 目录: Lua 侧设置 log_dir (RIME 用户目录); 未设置则回退 %TEMP%
// ============================================================
static std::string g_log_dir;

static void log_msg(const char * fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    // 2026-11-17 记录重构：DLL 日志并入 rime_llm_debug.txt（只保留
    // corpus + debug 两个记录文件），按 debug 协议发 X 行（force：错误
    // 即使在 debug_fusion 关闭时也保留，避免静默失败）。
    for (char *p = buf; *p; ++p) {
        if (*p == '|') *p = '/';
        else if (*p == '\n' || *p == '\r') *p = ' ';
    }
    char path[MAX_PATH];
    if (!g_log_dir.empty() && g_log_dir.size() < MAX_PATH - 32) {
        strcpy_s(path, g_log_dir.c_str());
        strcat_s(path, "\\rime_llm_debug.txt");
    } else {
        GetTempPathA(sizeof(path), path);
        strcat_s(path, sizeof(path), "rime_llm_debug.txt");
    }
    static std::string header_path;
    if (header_path != path) {
        header_path = path;
        FILE *rf = fopen(path, "rb");
        bool ok = false;
        if (rf) {
            char first[256] = {0};
            ok = fgets(first, sizeof(first), rf) &&
                 strncmp(first, "#RIME_DEBUG|v2|", 15) == 0;
            fclose(rf);
        } else {
            FILE *hf = fopen(path, "ab");
            if (hf) {
                SYSTEMTIME st; GetLocalTime(&st);
                fprintf(hf,
                        "#RIME_DEBUG|v2|%04d-%02d-%02d %02d:%02d:%02d|plugin\n",
                        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute,
                        st.wSecond);
                fclose(hf);
                ok = true;
            }
        }
        if (!ok) return;
    }
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (GetFileAttributesExA(path, GetFileExInfoStandard, &fa) &&
        ((((unsigned long long)fa.nFileSizeHigh << 32) |
          (unsigned long long)fa.nFileSizeLow) > 10ull * 1024 * 1024)) {
        std::string oldp = std::string(path) + ".old";
        DeleteFileA(oldp.c_str());
        MoveFileA(path, oldp.c_str());
    }
    FILE * f = fopen(path, "ab");
    if (f) {
        fprintf(f, "-|X|scope=dll|msg=%s\n", buf);
        fclose(f);
    }
}


// ============================================================
// 实时调试管道 rime_llm_live（2026-11-10）：lua live_write(line) 把调试
// 行广播给外部查看器（本仓库 debug\llm_debug_view.ps1）。行协议见查看器
// 头部注释（V/L/C/S/E/R 六类，| 分隔 UTF-8 文本行）。设计约束：
//   - 懒启动：首次 live_write 才起接纳线程（debug_fusion 关时 lua 不调用
//     → 零线程零开销；无连接时广播 = 一次 mutex + 空列表遍历）
//   - 广播在 lua 调用线程（= 按键同步路径）上做，但带 50ms 超时
//     （overlapped WriteFile）——查看器卡死/断开即踢，绝不阻塞打字
//   - DLL 随 WeaselServer 进程生命周期加载后不卸载，接纳线程不设停机
static const char *kLivePipeName = "\\\\.\\pipe\\rime_llm_live";
static const char *kLiveProtoDate = "2026-11-10";

static std::mutex g_live_mu;
static std::vector<HANDLE> g_live_clients;   // 已连接查看器的管道句柄
static std::atomic<bool> g_live_started{false};

// 单句柄单次写：overlapped + 50ms 超时（超时/失败由调用方踢客户端）
static bool live_write_raw(HANDLE h, const std::string &s) {
    OVERLAPPED ov = {};
    ov.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ov.hEvent) return false;
    bool ok = false;
    BOOL pending = WriteFile(h, s.data(), (DWORD)s.size(), NULL, &ov);
    if (pending || GetLastError() == ERROR_IO_PENDING) {
        DWORD written = 0;
        // GetOverlappedResultEx = 带超时等待（Win8+；本机 Win10 起步）
        if (GetOverlappedResultEx(h, &ov, &written, 50, FALSE))
            ok = true;
        else
            CancelIo(h);   // 超时：放弃本次写，句柄由调用方关闭
    }
    CloseHandle(ov.hEvent);
    return ok;
}

static void live_drop_client(HANDLE h) {
    DisconnectNamedPipe(h);
    CloseHandle(h);
}

// 接纳线程：每次建一个管道实例阻塞等连接，连上即推 V 行（协议版本+
// 版本标识）并加入客户端列表，随后建下一实例。上限 8 个并发查看器。
static void live_thread_proc() {
    for (;;) {
        HANDLE h = CreateNamedPipeA(kLivePipeName,
                                    PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED,
                                    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                                    8, 64 * 1024, 64 * 1024, 0, NULL);
        if (h == INVALID_HANDLE_VALUE) {
            Sleep(2000);   // 管道名被占等罕见情形：慢重试，不占 CPU
            continue;
        }
        OVERLAPPED ov = {};
        ov.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (!ov.hEvent) {
            CloseHandle(h);
            Sleep(2000);
            continue;
        }
        BOOL conn = ConnectNamedPipe(h, &ov);
        if (!conn && GetLastError() == ERROR_IO_PENDING)
            conn = WaitForSingleObject(ov.hEvent, INFINITE) == WAIT_OBJECT_0;
        BOOL connected = conn || GetLastError() == ERROR_PIPE_CONNECTED;
        CloseHandle(ov.hEvent);
        if (!connected) {
            CloseHandle(h);
            Sleep(500);
            continue;
        }
        std::string hello = std::string("V|rime-llm-live|1|plugin|") +
                            kLiveProtoDate + "\n";
        if (live_write_raw(h, hello)) {
            std::lock_guard<std::mutex> lk(g_live_mu);
            g_live_clients.push_back(h);
        } else {
            live_drop_client(h);
        }
    }
}

static void live_ensure_started() {
    bool f = false;
    if (g_live_started.compare_exchange_strong(f, true))
        std::thread(live_thread_proc).detach();
}

// 行广播（lua 调用线程上）：无客户端 = 空遍历；有客户端 = 逐个带超时写，
// 失败/超时即断开踢除
static void live_broadcast(const std::string &line) {
    live_ensure_started();
    std::string s = line + "\n";
    std::lock_guard<std::mutex> lk(g_live_mu);
    for (auto it = g_live_clients.begin(); it != g_live_clients.end(); ) {
        if (live_write_raw(*it, s))
            ++it;
        else {
            live_drop_client(*it);
            it = g_live_clients.erase(it);
        }
    }
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
//  comctx 同源实现已真机验证）。单后台线程 STA：2s 周期 + kick（commit
// 后 / 编辑键 / 点击，kick 唤醒统一延迟 ~50ms 再读）刷新；编辑键/点击
// 经 edit_reset 先失效再 kick（2026-09-12 信号层统一——快照制对非
// commit 编辑事件原本是盲区，旧快照 2.5s 新鲜窗内冒充真文）。
// lua 调用线程经 mutex 快照消费，COM/UIA 调用绝不在按键同步路径。
// ============================================================
// 前向声明：快照发布后触发预解码（定义见 prepare 之后）
static void prepare_from_published_text(const std::string & text);

namespace ctxlink {

// 2026-11-18：commit 后"快照刷新完成即预解码"（修 prepare 与 score 的 ctx 不同源）。
// kick 之后快照要 ~50ms 才更新；若 prepare 在按键路径立刻用旧快照/历史兜底，
// 拿到的是缺"刚上屏的词"的 ctx → 满码 score 必 miss。改为：commit 时置位，
// ctxlink 线程下次发布新鲜快照时用**同一份文本**发起预解码。
static std::atomic<int> g_prep_after_publish{0};
static bool take_prep_after_publish() {
    return g_prep_after_publish.exchange(0) > 0;
}

static std::mutex g_mu;
static std::string g_com_text;                 // UTF-8
static unsigned long long g_com_stamp = 0;
static std::wstring g_com_title;               // 发布时的前台标题（消费端指纹）
static std::string g_uia_text;                 // UTF-8
static unsigned long long g_uia_stamp = 0;
static DWORD g_uia_pid = 0;                    // 快照来源焦点元素进程
static std::wstring g_uia_title;               // 发布时的前台标题（消费端指纹）

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

// BSTR → UTF-8（COM 两读链与 UIA 读链共用；失败时 out 不变返回 false）
static bool bstr_to_utf8(BSTR s, std::string & out) {
    if (!s) return false;
    int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0,
                                nullptr, nullptr);
    if (n <= 0) return false;
    out.resize(n - 1);
    if (n > 1)
        WideCharToMultiByte(CP_UTF8, 0, s, -1, &out[0], n,
                            nullptr, nullptr);
    return true;
}

static void wlower(wchar_t * s) {
    for (; *s; ++s)
        if (*s >= L'A' && *s <= L'Z') *s = *s + 32;
}

// 文档名 ⊂ 前台标题校验（WPS 统一标签页防串档，2026-09-11 真机两轮定案）：
// WPS 多组件标签共用单一框架窗口，前台类名恒为 OpusApp（实测演示标签激活
// 仍 OpusApp、标题变"演示文稿1 - WPS Office"）——类名门控区分不了活动
// 组件。帧标题随活动标签文档名变，组件模型的 ActiveDocument.Name /
// ActivePresentation.Name 固定指本组件自己的活动文档：名字（全名与去
// 扩展名两种形态）都不在前台标题中 = 活动标签是另一组件（或前台是微软
// Office 而后台 WPS 同开），本组件读出的文本不属于当前光标处，判
// TAB_IDLE 落下一层。锚点不可用 Window.Caption——实测带修改标记尾缀
// " *" 且无扩展名剥不掉（"文字文稿1 *" ⊄ "文字文稿1 - WPS Office"）恒
// 误杀。名字取不到/去扩展名后过短（单字符易误配）→ 保守放行。
static bool name_matches_fg_title(const VARIANT & vname) {
    if (vname.vt != VT_BSTR || !vname.bstrVal || !*vname.bstrVal)
        return true;
    wchar_t full[128] = {0}, stem[128] = {0};
    const wchar_t * base = wcsrchr(vname.bstrVal, L'\\');
    base = base ? base + 1 : vname.bstrVal;
    wcsncpy_s(full, base, _TRUNCATE);
    wcsncpy_s(stem, base, _TRUNCATE);
    wchar_t * dot = wcsrchr(stem, L'.');
    if (dot && dot != stem) *dot = 0;
    if (wcslen(stem) < 2) return true;
    HWND fg = GetForegroundWindow();
    wchar_t title[256] = {0};
    if (!fg || GetWindowTextW(fg, title, 256) <= 0)
        return true;  // 标题取不到（罕见），保守放行
    wlower(full);
    wlower(stem);
    wlower(title);
    return wcsstr(title, full) != nullptr || wcsstr(title, stem) != nullptr;
}

enum class ComRead { OK, NO_DOC, DEAD, TAB_IDLE };

// 活动标签判定（不依赖文件名，2026-09-11 三轮真机定案）：文字组件视图
// 窗口（_WwB 类，ActiveWindow.Hwnd）的根窗口 == 前台窗口 && 视图可见
// = 文字标签/文字窗口活动。统一标签页：视图随活动标签显隐（实测即时
// 翻转）；多独立窗口：视图都可见，但只有活动窗口的根 == 前台（他窗/
// 他应用前台时根不等——微软 Word 前台场景由此天然排除，无需名字）。
// 句柄取不到 = UNKNOWN（回落名字校验兜底）。
enum class TabActive { YES, NO, UNKNOWN };
static TabActive writer_tab_active(IDispatch * app_w) {
    if (!app_w) return TabActive::UNKNOWN;
    VARIANT vwin, vh;
    VariantInit(&vwin); VariantInit(&vh);
    long long h = 0;
    if (SUCCEEDED(disp_get(app_w, L"ActiveWindow", &vwin)) &&
        vwin.vt == VT_DISPATCH && vwin.pdispVal &&
        SUCCEEDED(disp_get(vwin.pdispVal, L"Hwnd", &vh))) {
        if (vh.vt == VT_I4)      h = vh.lVal;
        else if (vh.vt == VT_I8) h = vh.llVal;
        else if (vh.vt == VT_R8) h = (long long)vh.dblVal;
    }
    VariantClear(&vwin); VariantClear(&vh);
    if (!h) return TabActive::UNKNOWN;
    HWND root = GetAncestor((HWND)(LONG_PTR)h, GA_ROOT);
    HWND fg = GetForegroundWindow();
    if (!root || !fg) return TabActive::UNKNOWN;
    if (root != fg) return TabActive::NO;
    return IsWindowVisible((HWND)(LONG_PTR)h) ? TabActive::YES : TabActive::NO;
}

static ComRead com_read_chain(IDispatch * app, std::string & out,
                              TabActive wta) {
    VARIANT vwin, vsel, vstart, vdoc, vrng, vtxt, vname;
    VariantInit(&vwin); VariantInit(&vsel); VariantInit(&vstart);
    VariantInit(&vdoc); VariantInit(&vrng); VariantInit(&vtxt);
    VariantInit(&vname);
    auto vt_ok = [](const VARIANT & v) {
        return v.vt == VT_DISPATCH && v.pdispVal;
    };
    HRESULT hr;
    auto cleanup = [&]() {
        VariantClear(&vwin); VariantClear(&vsel); VariantClear(&vstart);
        VariantClear(&vdoc); VariantClear(&vrng); VariantClear(&vtxt);
        VariantClear(&vname);
    };
    // 串档拦截①：视图窗口判定非活动（统一标签页切走/他窗前台）——
    // 不依赖文件名，同基名文档也能正确区分
    if (wta == TabActive::NO) {
        cleanup();
        return ComRead::TAB_IDLE;
    }
    if (FAILED(hr = disp_get(app, L"ActiveWindow", &vwin)) || !vt_ok(vwin)) {
        cleanup();
        if (hr == DISP_E_EXCEPTION || hr == DISP_E_MEMBERNOTFOUND)
            return ComRead::NO_DOC;
        return ComRead::DEAD;
    }
    // ActiveDocument 前移：名字校验（串档拦截②兜底）与下方 Range 共用
    if (FAILED(hr = disp_get(app, L"ActiveDocument", &vdoc)) ||
        !vt_ok(vdoc)) {
        cleanup();
        if (hr == DISP_E_EXCEPTION || hr == DISP_E_MEMBERNOTFOUND)
            return ComRead::NO_DOC;
        return ComRead::DEAD;
    }
    if (wta == TabActive::UNKNOWN) {
        // 视图句柄取不到时回落名字校验（YES 时有 root==fg 硬判据，跳过
        // 免受标题格式差异影响——Caption 轮误杀的教训）
        disp_get(vdoc.pdispVal, L"Name", &vname);
        if (!name_matches_fg_title(vname)) {
            cleanup();
            return ComRead::TAB_IDLE;
        }
    }
    if (FAILED(hr = disp_get(vwin.pdispVal, L"Selection", &vsel)) ||
        !vt_ok(vsel) ||
        FAILED(hr = disp_get(vsel.pdispVal, L"Start", &vstart)) ||
        vstart.vt != VT_I4) {
        cleanup();
        if (hr == DISP_E_EXCEPTION || hr == DISP_E_MEMBERNOTFOUND)
            return ComRead::NO_DOC;
        return ComRead::DEAD;
    }
    long pos = vstart.lVal, from = pos - 64;
    if (from < 0) from = 0;
    ComRead res = ComRead::OK;
    do {
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
        bstr_to_utf8(vtxt.bstrVal, out);
    } while (false);
    cleanup();
    return res;
}

// ---- 演示读链（WPP/PowerPoint，2026-09-11 本机实测验证）----
// app.ActiveWindow.Selection.Type==3(文本编辑) 时：start = TextRange.Start
//（框内 1-based 偏移）；前文 = ShapeRange.TextFrame.TextRange.Characters(
// max(1,start-64), min(64, start-1)).Text。Type!=3 → NO_DOC 语义
//（无文本编辑：形状/幻灯片选择态）。表格 XLMAIN 不在此链（编辑态盲区）。
static ComRead ppt_read_chain(IDispatch * app, std::string & out,
                              TabActive wta) {
    VARIANT vwin, vsel, vtype, vstart, vshape, vframe, vrng, vtxt;
    VARIANT vpres, vname;
    VariantInit(&vwin); VariantInit(&vsel); VariantInit(&vtype);
    VariantInit(&vstart); VariantInit(&vshape); VariantInit(&vframe);
    VariantInit(&vrng); VariantInit(&vtxt);
    VariantInit(&vpres); VariantInit(&vname);
    auto vt_ok = [](const VARIANT & v) {
        return v.vt == VT_DISPATCH && v.pdispVal;
    };
    HRESULT hr;
    auto cleanup = [&]() {
        VariantClear(&vwin); VariantClear(&vsel); VariantClear(&vtype);
        VariantClear(&vstart); VariantClear(&vshape); VariantClear(&vframe);
        VariantClear(&vrng); VariantClear(&vtxt);
        VariantClear(&vpres); VariantClear(&vname);
    };
    // 串档拦截①：文字视图判定活动 = 活动标签必是文字（演示/表格都不是）
    if (wta == TabActive::YES) {
        cleanup();
        return ComRead::TAB_IDLE;
    }
    if (FAILED(hr = disp_get(app, L"ActiveWindow", &vwin)) || !vt_ok(vwin)) {
        cleanup();
        if (hr == DISP_E_EXCEPTION) return ComRead::NO_DOC;
        return ComRead::DEAD;
    }
    // 串档拦截②：演示无窗口句柄（WPP Window.Hwnd/HWND 均空，实测），
    // 名字校验是演示链主判据——挡表格标签/微软 Office 前台；同基名文档
    // 场景由拦截①的 wta 覆盖
    if (FAILED(hr = disp_get(app, L"ActivePresentation", &vpres)) ||
        !vt_ok(vpres)) {
        cleanup();
        if (hr == DISP_E_EXCEPTION) return ComRead::NO_DOC;
        return ComRead::DEAD;
    }
    disp_get(vpres.pdispVal, L"Name", &vname);
    if (!name_matches_fg_title(vname)) {
        cleanup();
        return ComRead::TAB_IDLE;
    }
    if (FAILED(hr = disp_get(vwin.pdispVal, L"Selection", &vsel)) ||
        !vt_ok(vsel) ||
        FAILED(hr = disp_get(vsel.pdispVal, L"Type", &vtype)) ||
        vtype.vt != VT_I4) {
        cleanup();
        if (hr == DISP_E_EXCEPTION) return ComRead::NO_DOC;
        return ComRead::DEAD;
    }
    if (vtype.lVal != 3) {  // ppSelectionText = 3：非文本编辑态
        cleanup();
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
        bstr_to_utf8(vtxt.bstrVal, out);
    } while (false);
    cleanup();
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
                        ret = bstr_to_utf8(txt, out);
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
    if (!uia_ok && !has_kwps && !has_kwpp) {
        CoUninitialize();  // 与 CoInitializeEx 配对（无任何通道，极罕见）
        return;
    }

    // 双组件持久附着 + 探读（2026-09-11 串档修复）：WPS 统一标签页的框架
    // 类名不随活动标签组件变（真机实测演示标签激活仍 OpusApp），旧"前台
    // 类名选单附着"设计失效——文字附着会一直读出文字文档全文冒充演示上
    // 文。改为 Kwps/KWPP 双附着，每轮按"前台类型对位优先、另一组件兜底"
    // 顺序读，由读链标题校验（TAB_IDLE）裁决哪个组件的活动文档才是当前
    // 光标处。DEAD（宿主退出）单独释放该组件下轮懒重附；双双无产出 →
    // 清缓存（消费端落 UIA/历史），未附着时 500ms 快速重试不变。
    IDispatch * app_w = nullptr;  // Kwps.Application（文字）
    IDispatch * app_p = nullptr;  // KWPP.Application（演示）
    bool logged_w = false, logged_p = false;
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
        // kick 统一延迟 ~50ms 再读（2026-09-12 信号层统一）：编辑键/点击
        // 的 kick 若立即读会赶在应用处理完退格/点击之前拿到旧文本；commit
        // kick 的文档更新同量级。下一键远晚于 100ms（人手速度），统一延迟
        // 无感。连续 kick 在 sleep 期间再次置位 g_kick，下一轮 1ms 即醒，
        // 自然合并不叠加。
        if (woken_by_kick) Sleep(50);

        // COM：前台 Office 才读（读端门控省后台空转；切标签/切窗由发布
        // 标题指纹在消费端即刻拦截，kick/周期兜住换新）
        if (has_kwps || has_kwpp) {
            OfficeKind fg = foreground_office();
            if (fg != OfficeKind::NONE) {
                // 文字附着先行：ActiveWindow.Hwnd 的视图窗口判定是活动
                // 标签主信号（无文字文档时 UNKNOWN 回落名字校验）
                if (has_kwps && !app_w) {
                    IUnknown * punk = nullptr;
                    if (SUCCEEDED(GetActiveObject(clsid_kwps, nullptr,
                                                  &punk)) &&
                        punk) {
                        punk->QueryInterface(IID_IDispatch, (void **)&app_w);
                        punk->Release();
                        if (app_w && !logged_w) {
                            log_msg("ctx probe: com attached (Kwps.Application)");
                            logged_w = true;
                        }
                    }
                }
                TabActive wta = writer_tab_active(app_w);
                if (wta == TabActive::NO && app_w) {
                    // 跨进程标签切换重附（2026-09-11 四轮真机定案）：新建
                    // 文档/演示标签各起新 wps.exe、各持帧窗口，仅活动标签
                    // 所属进程的帧可见——旧附着实例的视图 root≠前台恒 NO。
                    // 实测 GetActiveObject 返回最新激活实例（sees 跟随活动
                    // 标签切换），重附一次即取到活动实例，仍 NO 才真非活动
                    //（表格标签/他应用前台）。GetActiveObject 微秒级，每轮
                    // 至多重附一次。
                    app_w->Release();
                    app_w = nullptr;
                    if (has_kwps) {
                        IUnknown * punk = nullptr;
                        if (SUCCEEDED(GetActiveObject(clsid_kwps, nullptr,
                                                      &punk)) &&
                            punk) {
                            punk->QueryInterface(IID_IDispatch,
                                                 (void **)&app_w);
                            punk->Release();
                        }
                    }
                    wta = writer_tab_active(app_w);
                }
                OfficeKind order[2] = {
                    fg, (fg == OfficeKind::WRITER) ? OfficeKind::PPT
                                                   : OfficeKind::WRITER};
                bool published = false;
                for (int i = 0; i < 2 && !published; i++) {
                    bool is_p = (order[i] == OfficeKind::PPT);
                    if (is_p ? !has_kwpp : !has_kwps) continue;
                    IDispatch *& app = is_p ? app_p : app_w;
                    bool & logged = is_p ? logged_p : logged_w;
                    if (!app) {
                        IUnknown * punk = nullptr;
                        if (SUCCEEDED(GetActiveObject(
                                is_p ? clsid_kwpp : clsid_kwps, nullptr,
                                &punk)) &&
                            punk) {
                            punk->QueryInterface(IID_IDispatch, (void **)&app);
                            punk->Release();
                        }
                        if (app && !logged) {
                            log_msg("ctx probe: com attached (%s)",
                                    is_p ? "KWPP.Application"
                                         : "Kwps.Application");
                            logged = true;
                        }
                    }
                    if (!app) continue;
                    std::string txt;
                    ComRead r = is_p ? ppt_read_chain(app, txt, wta)
                                     : com_read_chain(app, txt, wta);
                    if (r == ComRead::OK) {
                        wchar_t wt[256] = {0};
                        HWND fh = GetForegroundWindow();
                        if (fh) GetWindowTextW(fh, wt, 256);
                        {
                            std::lock_guard<std::mutex> lk(g_mu);
                            g_com_text = txt;
                            g_com_stamp = GetTickCount64();
                            g_com_title = wt;  // 消费端指纹：标题变=切标签/切窗
                            published = true;
                        }
                        // 新鲜快照已发布：若本次刷新由 commit 触发（kick 带 1），
                        // 立刻用**这份文本**预解码（与 score 同源，避免 miss）
                        if (take_prep_after_publish())
                            prepare_from_published_text(txt);
                    } else if (r == ComRead::DEAD) {
                        bool & logged = is_p ? logged_p : logged_w;
                        if (logged) {
                            log_msg("ctx probe: office app gone, "
                                    "will re-attach");
                            logged = false;
                        }
                        app->Release();
                        app = nullptr;
                    }
                    // NO_DOC（文档全关/演示非文本编辑态）与 TAB_IDLE（活动
                    // 标签非本组件）：保留附着，试另一组件
                }
                if (!published) {
                    std::lock_guard<std::mutex> lk(g_mu);
                    g_com_text.clear();
                    g_com_stamp = 0;
                    g_com_title.clear();
                }
            } else {
                std::lock_guard<std::mutex> lk(g_mu);
                g_com_text.clear();
                g_com_stamp = 0;  // 前台非 Office：COM 缓存即刻失效
                g_com_title.clear();
            }
            com_pending = (fg != OfficeKind::NONE) && !app_w && !app_p;
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
                wchar_t ut[256] = {0};
                HWND ufh = GetForegroundWindow();
                if (ufh) GetWindowTextW(ufh, ut, 256);
                {
                    std::lock_guard<std::mutex> lk(g_mu);
                    g_uia_text = txt;
                    g_uia_stamp = GetTickCount64();
                    g_uia_pid = pid;
                    g_uia_title = ut;  // 消费端指纹：同进程多窗/标签切换即变
                }
                if (take_prep_after_publish())
                    prepare_from_published_text(txt);
            } else {
                std::lock_guard<std::mutex> lk(g_mu);
                g_uia_text.clear();
                g_uia_stamp = 0;
                g_uia_pid = 0;
                g_uia_title.clear();
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

// 任何"光标前文本可能变了"的已知信号（编辑键/点击，2026-09-12 信号层
// 统一）：成对执行 (a) 快照失效 (b) kick 延迟重读。失效保证 50ms 读回
// 窗口内旧快照不冒充（pick 拒用 → lua 落历史）；kick 保证应用处理完编辑
// 后读到新真文。缺失效则读早竞态冒充，缺 kick 则退格后首词无上文。
// 点击候选窗选词场景：click 信号废掉 commit kick 刚刷新的正确快照，
// 但随后的 kick 读回同样正确的文本（点击已处理完、含新上屏词），自愈。
static void edit_reset() {
    {
        std::lock_guard<std::mutex> lk(g_mu);
        g_com_text.clear();
        g_com_stamp = 0;
        g_com_title.clear();
        g_uia_text.clear();
        g_uia_stamp = 0;
        g_uia_pid = 0;
        g_uia_title.clear();
    }
    kick();
}

// lua 调用线程消费：三层前两层判定（历史兜底由 lua 侧完成）。
// 返回 true 时 text/src 有效（src = "com" | "uia"）。
static bool pick(std::string & text, const char *& src) {
    unsigned long long now = GetTickCount64();
    if (foreground_office() != OfficeKind::NONE) {
        // 标题指纹：发布后前台标题变了（WPS 切标签/切窗即换标题）→ 旧快照
        // 属于旧标签，拒用——挡住 ≤2s 轮询间隙的串档（commit kick 会立刻
        // 换上新标签文本）。任一侧标题取不到 → 保守放行
        wchar_t t[256] = {0};
        HWND fh = GetForegroundWindow();
        bool title_ok =
            (!fh || GetWindowTextW(fh, t, 256) <= 0);
        std::lock_guard<std::mutex> lk(g_mu);
        if (g_com_stamp && now - g_com_stamp <= 2500 && !g_com_text.empty() &&
            (title_ok || g_com_title.empty() || g_com_title == t)) {
            text = g_com_text;
            src = "com";
            return true;
        }
    }
    {
        // UIA 快照：新鲜 && 前台进程 == 快照来源进程（防切窗残留文本误用）
        // + 标题指纹（2026-09-12）：pid 校验挡不住同进程多窗/多标签（Chrome
        // 双窗、Win11 记事本标签同 pid）——发布后标题变 = 已切窗/标签 →
        // 拒用，与 COM 同款；任一侧取不到标题 → 保守放行
        DWORD fg = foreground_pid();
        wchar_t t[256] = {0};
        HWND fh = GetForegroundWindow();
        bool title_ok = (!fh || GetWindowTextW(fh, t, 256) <= 0);
        std::lock_guard<std::mutex> lk(g_mu);
        if (g_uia_stamp && now - g_uia_stamp <= 2500 && !g_uia_text.empty() &&
            g_uia_pid != 0 && g_uia_pid == fg &&
            (title_ok || g_uia_title.empty() || g_uia_title == t)) {
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
        // 锁页（2026-11-28 P1）：mmap + VirtualLock 常驻物理内存，消久闲后
        // 页被逐出的首键尖峰（代价：常驻 +~0.4GB）；锁失败 llama 内部告警、
        // 按普通 mmap 行为继续。A/B：RIME_LLM_MLOCK=0 回纯 mmap。
        {
            const char *mlk = getenv("RIME_LLM_MLOCK");
            mparams.load_mode = (mlk && mlk[0] == '0')
                                    ? LLAMA_LOAD_MODE_MMAP
                                    : LLAMA_LOAD_MODE_MMAP_MLOCK;
        }

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
        // KV 统一池（2026-11-28）：llama 默认 kv_unified=false 把多 seq 批
        // 逐序列拆成独立 ubatch，每行独立付一遍全部权重（实测 marginal
        // 9.1ms/行）；unified 后 6.2ms/行（5 线程）、4.5ms/行（8 线程），
        // 且 KV 分配从 n_seq_max×n_ctx（20×512 ≈ 1.14GB）降到 1×n_ctx
        // （≈58MB）。本机限频下算力受限是根源（gemm 行数效率：1 行
        // 75 → 6 行 180 → 20 行 333 GFLOPS）。CE 位级一致性已验
        // （prof_s2 --ce-check：42 候选 × split/unified × 5/8 线程
        // Δ=0、排序零翻转、prep 重复零漂移）。A/B：RIME_LLM_KV_UNIFIED=0
        // 回分裂式。
        {
            const char *kvu = getenv("RIME_LLM_KV_UNIFIED");
            cparams.kv_unified = !(kvu && kvu[0] == '0');
        }

        g_ctx = llama_init_from_model(g_model, cparams);
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

// 推理用上文尾部文本（2026-11-12 调试窗口协议 v4，灰显用）：截尾保留的
// ids 逐 token 拼 piece —— 字节级 BPE 的各 token piece 恰好等于原文中
// 连续字节段，拼接 = 精确尾部（真实 token 边界，非字符数估算）；
// 未截尾（全文 ≤ max_ctx）时推理用全文。token 不足 min_tokens → 空
//（无推理）。
static std::string g_last_ctx_used;

static std::string tokens_piece(const std::vector<llama_token> & ids) {
    std::string s;
    char buf[256];
    for (auto id : ids) {
        int n = llama_token_to_piece(g_vocab, id, buf, sizeof(buf), 0, true);
        if (n > 0) s.append(buf, n);
    }
    return s;
}

// 候选词 token 边界段显（2026-11-21 调试窗口协议 v7，"词"列；源码版
// llm_filter.cc 同款实现）：逐 token 拼 piece，每个 token 结束时若已拼出
// 完整 UTF-8 字符则封一段——分隔符只落在 token 边界 ∩ 字符边界：单 token
// 含多字不劈（标志/测试 在 Qwen3-0.6B 为单 token → 原样显示），一个字由
// 2 token 拼成 → 合并成一段（不劈字），多 token 词按真实边界分段
//（错事=[错][事] → 错/事，cmak=[cm][ak] → cm/ak）。段间 '/'。
// 拼接结果 = 原词文本（字节级 BPE 的 piece 拼接恰好还原原文）。
// ⚠ 字符完整性判定（2026-11-21 踩坑修正）：UTF-8 多字节字符**以续字节
// 结尾**（错 = E9 94 99，末字节 0x99 是续字节）——"末字节非续字节"判定
// 是反的，会让 CJK 永不封段、整词并一段（曾据此误报 错事/标志 等全为
// 单 token；评分路径 ce2 有值才暴露）。正确做法 = 用 lead 字节推断期望
// 长度、数续字节凑齐才算完整。
static std::string token_seg_display(const std::vector<llama_token> & ids) {
    std::string out, cur;
    char buf[256];
    int remain = 0;  // 当前字符还差的续字节数（0 = 处于字符边界）
    for (auto id : ids) {
        int n = llama_token_to_piece(g_vocab, id, buf, sizeof(buf), 0, true);
        for (int k = 0; k < n; k++) {
            unsigned char b = (unsigned char)buf[k];
            cur += (char)b;
            if (remain > 0) {
                remain--;
            } else if (b < 0x80) {
                // ASCII：自身即完整字符，remain 保持 0
            } else if ((b & 0xE0) == 0xC0) {
                remain = 1;   // 2 字节字符（还差 1 续字节）
            } else if ((b & 0xF0) == 0xE0) {
                remain = 2;   // 3 字节字符（CJK 常态）
            } else {
                remain = 3;   // 4 字节字符（扩展区）
            }
        }
        if (remain == 0 && !cur.empty()) {  // token 结束且字符完整 → 封段
            if (!out.empty()) out += '/';
            out += cur;
            cur.clear();
        }
    }
    if (!cur.empty()) {  // 末段残字节（正常不可达）原样收尾，不丢字
        if (!out.empty()) out += '/';
        out += cur;
    }
    return out;
}

// CE 上文锚（2026-11-28，两版同构）：Qwen3-0.6B 在裸单词（1 token）上文时
// 预测退化为先验序——wiki 分条首句大样本配对实测（2994 句，0.6B）：bare n=1
// top1 命中 0.0%、句号锚后 6.71%，ΔCE −6.10 nats（win/lose 2808/186，z=47.9）；
// 「英雄」后事迹 14.3 败于「世纪」8.4 即此。垫「。」把输入还原成训练分布内
// 的句中形态（attention sink/文档边界文献支持）。n=2 专项验证（3000 新句配
// 对）：句号锚 ΔCE −0.0096、z=−0.15 = 零效应（n=2 bare 已健康 top1 12.5%）
// ——故规则收窄为**仅 n=1 垫锚**。0.5B 同效；0.8B 不需要但无害。A/B：
// RIME_LLM_CTX_ANCHOR=0。
static const llama_vocab  * g_anchor_vocab = nullptr;  // 锚 token 随词表代缓存
static int                  g_anchor_tok  = -1;
static std::vector<llama_token> ctx_ids_for_ce(std::vector<llama_token> ids,
                                               bool *anchored = nullptr) {
    static const bool kOn = !(getenv("RIME_LLM_CTX_ANCHOR") &&
                              getenv("RIME_LLM_CTX_ANCHOR")[0] == '0');
    // 仅恰 1 token（==1）垫锚；空上文（=0）不垫（生产不给空上文算 CE，
    // 此守卫纯对齐研究侧 sim_rerank 口径）。*anchored = 本窗实际垫锚
    //（W 行 flags=anchor 语料标记用，2026-11-28）。
    if (!kOn || ids.size() != 1) {
        if (anchored) *anchored = false;
        return ids;
    }
    if (g_anchor_vocab != g_vocab) {
        auto t = tokenize("。");
        g_anchor_tok = t.empty() ? -1 : (int)t[0];
        g_anchor_vocab = g_vocab;
    }
    if (g_anchor_tok >= 0) {
        ids.insert(ids.begin(), g_anchor_tok);
        if (anchored) *anchored = true;
    } else if (anchored) {
        *anchored = false;
    }
    return ids;
}

// 上文 token 化 + min_tokens/max_ctx 截尾（prepare/score 入口共用）。
// token 数不足 min_tokens（方案 llm_rerank/min_tokens，lua 传入）→ 返回空
//（空 ctx 无推理是配置语义, 非 bug）。
static std::vector<llama_token> ctx_token_ids(const char * context,
                                              bool *anchored = nullptr) {
    auto ids = tokenize(context);
    if ((int)ids.size() < g_min_tokens) { g_last_ctx_used.clear(); if (anchored) *anchored = false; return {}; }
    if ((int)ids.size() > g_max_ctx_tokens) {
        ids.erase(ids.begin(), ids.end() - g_max_ctx_tokens);
        g_last_ctx_used = tokens_piece(ids);
    } else {
        g_last_ctx_used = context ? context : "";
    }
    return ctx_ids_for_ce(std::move(ids));  // 1 token 裸单词上文垫「。」锚（与源码版同构）
}

// ============================================================
// Softmax CE 辅助：-log(softmax(x)[target])
// 通用优化（2026-11-06，两版同步；不依赖特定指令集、不改评分语义）：
// ① 尾部跳过：与 max 相差 > kLseSkipNat 的项不做 exp——单项贡献
//    < e^-20 ≈ 2.1e-9，全词表（26 万封顶）总贡献 < 5.5e-4，即 lse 偏差
//    < 0.0006 nats，比候选间典型 CE 差（≥0.01）小一个数量级以上；
//    真实分布高度集中，跳过量通常 >90%（近乎均匀的病态分布退化为原速）。
// ② exp 用 float 版 expf（标量运算，无 SIMD 依赖），求和仍 double 累加。
// 实测（13900H 锁频）：单次全词表归一化 ~2ms → ~0.1ms；prep 命中路径
// 配合归一化量缓存（见 score_batch）CE1 段 ~0ms。
// ============================================================
static const float kLseSkipNat = 20.0f;  // 尾部跳过阈值（nats，误差界见上）

static double cross_entropy(const float * logits, int vs, int target_id) {
    float m = -1e30f;
    for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    const float cut = m - kLseSkipNat;
    double se = 0;
    for (int k = 0; k < vs; k++)
        if (logits[k] >= cut) se += expf(logits[k] - m);
    return -((double)(logits[target_id] - m) - log(se));
}

// 归一化 (max, logsumexp) 一次计算, 多目标 CE 共享复用:
// Step 1 所有候选对同一 ctx logits 打分, 原实现对每个候选重扫
// O(vocab) (5 候选取 5 次 -> 实测 CE1 段 ~6ms), 共享后一次扫描 + 查表
// (-> ~2ms)。2026-11-06 再叠加尾部跳过 + expf，且归一化量随 prep 状态
// 缓存——prep 命中路径完全免扫（CE1 段 ~0ms）。
static void logits_normalizer(const float * logits, int vs, float & m, double & lse) {
    m = -1e30f;
    for (int k = 0; k < vs; k++) if (logits[k] > m) m = logits[k];
    const float cut = m - kLseSkipNat;
    double se = 0;
    for (int k = 0; k < vs; k++)
        if (logits[k] >= cut) se += expf(logits[k] - m);
    lse = log(se);
}
static double ce_target(const float * logits, int target_id, float m, double lse) {
    return -((double)(logits[target_id] - m) - lse);
}

// 上文 + 组合区已确认前缀（2026-11-23）：上文按 max_ctx 截断，前缀完整追加。
// 语义 = "当前词的完整上下文"——已确认词是确定 token，不能像旧上文一样被
// 截断挤掉；g_last_ctx_used 也带上前缀（调试端"推理实际使用"口径）。
static std::vector<llama_token> ctx_ids_with_prefix(const char * context,
                                                    const char * prefix,
                                                    bool *anchored = nullptr) {
    auto ids = ctx_token_ids(context, anchored);
    if (prefix && *prefix) {
        auto pids = tokenize(prefix);
        if (!pids.empty()) {
            ids.insert(ids.end(), pids.begin(), pids.end());
            g_last_ctx_used += prefix;
        }
    }
    return ids;
}

// （2026-11-28 P0-2 第 2 段注：CE 后处理已改走镜像 ggml CE_LSE op 的图内
//  标量抽取——llama_get_ce_lse，宿主扫描与并行池双双退役，数值逐位不变。）

// ctx KV 就绪（调用方持 g_mutex）：返回 ctx 末位 logits（指向 g_prep_logits）
// 与归一化量；失败返回 nullptr。三条路径（2026-11-23）：
//   ① prep 完全命中（ctx 相同）→ 零成本
//   ② 前缀延伸（新 ctx = 旧 prep ctx + 新增 token）→ 只 decode 增量：
//      确认前缀 P 后 ctx = 上文 + P，上文部分的 KV 原样保留（§11.8 协同）
//   ③ 否则全量重建（memory_clear + decode）
static const float * ensure_ctx_kv(const std::vector<llama_token> & ctx_ids,
                                   int vs, float & m, double & lse) {
    if (g_prep_ready && ctx_ids == g_prep_ctx && g_seq0_gen == g_prep_gen) {
        m = g_prep_m;
        lse = g_prep_lse;
        return g_prep_logits.data();
    }
    int from = 0;
    bool extend = g_prep_ready && g_seq0_gen == g_prep_gen
                  && ctx_ids.size() > g_prep_ctx.size()
                  && std::equal(g_prep_ctx.begin(), g_prep_ctx.end(),
                                ctx_ids.begin());
    if (extend) {
        from = (int)g_prep_ctx.size();
    } else {
        llama_memory_clear(llama_get_memory(g_ctx), false);
    }
    const int ctx_len = (int)ctx_ids.size();
    // 增量是稀有路径（确认前缀后才发生），只在这里留痕（全量不打，免日志膨胀）
    if (extend)
        log_msg("ctx_kv: extend from=%d ctx=%d prep=%d gen=%ld",
                from, ctx_len, (int)g_prep_ctx.size(), g_seq0_gen);
    llama_batch b = llama_batch_init(ctx_len - from, 0, 1);
    int row = 0;
    for (int j = from; j < ctx_len; j++, row++) {
        b.token[row] = ctx_ids[j];
        b.pos[row] = j;
        b.n_seq_id[row] = 1;
        b.seq_id[row][0] = 0;
        b.logits[row] = (j + 1 == ctx_len) ? 1 : 0;
    }
    b.n_tokens = row;
    bool ok = llama_decode(g_ctx, b) == 0;
    llama_batch_free(b);
    if (!ok) {
        if (extend) {
            // 增量失败（KV 耗尽等）：置无效并回退全量重建一次（递归深度 1）
            g_prep_ready = false;
            return ensure_ctx_kv(ctx_ids, vs, m, lse);
        }
        return nullptr;
    }
    g_seq0_gen++;
    const float * cl = llama_get_logits_ith(g_ctx, ctx_len - from - 1);
    if (!cl) return nullptr;
    g_prep_logits.assign(cl, cl + vs);
    g_prep_gen = g_seq0_gen;
    g_prep_ctx = ctx_ids;
    logits_normalizer(g_prep_logits.data(), vs, g_prep_m, g_prep_lse);
    g_prep_ready = true;
    m = g_prep_m;
    lse = g_prep_lse;
    return g_prep_logits.data();
}

// ============================================================
// 核心评分：ctx 仅 1 次 decode + KV copy + 多序列分层并行候选 decode
//
// Step 1: decode ctx → 保存 logits → 所有候选的第 1 个 token CE 从此计算
// Step 2: KV copy ctx → worker seq，并行 decode 候选首 token → 第 2 token CE
//         （2026-11-07 前缀去重：step2 行按首 token 去重，共享行上每个
//          候选读各自的 CE 目标——CE 数学不变，省重复行）
// Step 3: 次 token 并行 decode → 第 3 token CE
//         （step3 行按 (首token, 次token) 对去重；同首 token 的后续对
//          seq_cp 出新 seq 携带 [ctx, c0] KV）
//
// 原理：P(tok_i0|ctx) 对所有 i 共享同一个 ctx_last hidden state
//       多 token 候选每个 seq 仅 1 个新 token，SSM 跨序列干扰可忽略
//       ith = batch 数组索引（不是 logits 标记序号）
// ============================================================
// 返回 true = 评分完成（结果可发布）；false = 中途取消（异步评分器代次
// 变化——新 submit 覆盖 / cancel，结果整体丢弃）。中断检查点 = 拿锁后 /
// CE1 后(Step2 前) / Step2 后(Step3 前)：批 decode 单步 ~10-25ms，Step
// 粒度中断足够（2026-11-22 异步基建，两版同构）。同步调用（lua_score/
// 冒烟）传缺省 nullptr/0，恒走完。
static bool score_batch(const std::vector<llama_token> & ctx_ids,
                         const std::vector<std::vector<llama_token>> & cands,
                         std::vector<double> & scores_out,
                         std::vector<std::array<double, 3>> * ce3_out = nullptr,
                         bool * prep_hit_out = nullptr,
                         const std::atomic<long> * cancel_gen = nullptr,
                         long my_gen = 0) {
    scores_out.assign(cands.size(), -1e10);
    if (ce3_out)  // 三分量初值 NaN（缺 token / 失败位 → 调试端显示空）
        ce3_out->assign(cands.size(), {NAN, NAN, NAN});
    if (prep_hit_out) *prep_hit_out = false;
    int n_cands = (int)cands.size();
    if (n_cands == 0) return true;

    auto cancelled = [&]() {
        return cancel_gen &&
               cancel_gen->load(std::memory_order_relaxed) != my_gen;
    };

    auto t0 = std::chrono::high_resolution_clock::now();
    std::unique_lock<std::mutex> lock(g_mutex);
    // 拿锁后先查一次：等待锁期间任务可能已被覆盖（白跑整段 Step1）
    if (cancelled()) return false;
    auto t1 = std::chrono::high_resolution_clock::now();
    double wait_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();


    int ctx_len = (int)ctx_ids.size();
    int vs = llama_vocab_n_tokens(g_vocab);

    // 按 token 数分组
    std::vector<int> idx2, idx3;
    for (int i = 0; i < n_cands; i++) {
        if (cands[i].size() >= 2) idx2.push_back(i);
        if (cands[i].size() >= 3) idx3.push_back(i);
    }
    int M = (int)idx2.size();
    int K = (int)idx3.size();

    // 检测预解码状态：ctx 完全匹配 且 seq0 未被其他 decode 覆盖 → 跳过 Step 1
    // 代次匹配防止: 完整流程 score 覆盖 seq0 后, 旧 prep 状态被误用 (KV 与 logits 不一致)
    bool use_prep = g_prep_ready && ctx_ids == g_prep_ctx && g_seq0_gen == g_prep_gen;
    if (prep_hit_out) *prep_hit_out = use_prep;
    float m0 = 0;
    double lse0 = 0;
    double ms1 = 0;
    // ---- Step 1 ctx KV：prep 命中零成本 / 前缀延伸只 decode 增量 / 否则全量 ----
    // memory_clear 第 2 参：true=零化整个 KV cache（40 万次 decode 的
    // benchmark 会拖慢吞吐）；false=仅重置元数据。新序列的因果注意力
    // 掩码天然隔离旧 KV，无需显式归零。
    auto ts1_0 = std::chrono::high_resolution_clock::now();
    const float * ctx_logits = ensure_ctx_kv(ctx_ids, vs, m0, lse0);
    auto ts1_1 = std::chrono::high_resolution_clock::now();
    ms1 = std::chrono::duration<double, std::milli>(ts1_1 - ts1_0).count();
    if (!ctx_logits) return true;  // decode failed（结果全哨兵照常发布）

    // 所有候选的第 1 个 token CE (共享同一 ctx logits -> 归一化只算一次;
    // 2026-11-06 归一化量随 prep 缓存, 命中路径连扫描也免)
    auto ts_ce1_0 = std::chrono::high_resolution_clock::now();
    std::vector<double> ce_sum(n_cands, 0);
    for (int i = 0; i < n_cands; i++) {
        double c1 = ce_target(ctx_logits, cands[i][0], m0, lse0);
        ce_sum[i] = kCeW1 * c1;
        if (ce3_out) (*ce3_out)[i][0] = c1;  // 原始分量（未乘权重，调试展开用）
    }
    auto ts_ce1_1 = std::chrono::high_resolution_clock::now();
    double ms_ce1 =
        std::chrono::duration<double, std::milli>(ts_ce1_1 - ts_ce1_0).count();

    // 中断检查（Step2 前）：此时未分配 worker seq，无 KV 泄漏
    if (cancelled()) return false;

    // ---- Step 2/3: 前缀去重批量 decode（2026-11-07，两版同步）----
    // 行按"已解码前缀"分组：step2 行 = 候选首 token（去重）；step3 行 =
    // (首token, 次token) 对（去重）。同一行上的多个候选从同一 logits 行
    // 读各自的 CE 目标——CE 数学与逐候选行完全一致，只省掉重复行的
    // decode 与 head 计算（标定语料实测 20.3% 行共享首 token、34.1% 窗
    // 省 ≥1 行）。seq 分配：每个 step2 行一条 worker seq（seq_cp 0→s）；
    // step3 对里该首 token 的第一个对复用 step2 seq，同首 token 的后续
    // 对 seq_cp(step2 seq→新 seq) 携带 [ctx, c0] KV——worker seq 总数 =
    // 不同前缀路径数 ≤ 候选数 ≤ max_candidates ≤ n_seq_max-1，天然不越界。
    double ms2a = 0, ms2b = 0, ms3 = 0;
    int seq_top = 0;  // 使用的最大 worker seq（尾部清理用）
    // step2 行：按首 token 去重（线性扫描，候选数 ≤ max_candidates）
    std::vector<llama_token> r2_tok;
    std::vector<std::vector<int>> r2_cands;
    for (int ci : idx2) {
        size_t u = 0;
        while (u < r2_tok.size() && r2_tok[u] != cands[ci][0]) u++;
        if (u == r2_tok.size()) {
            r2_tok.push_back(cands[ci][0]);
            r2_cands.emplace_back();
        }
        r2_cands[u].push_back(ci);
    }
    const int U = (int)r2_tok.size();
    // step3 行：按 (首token, 次token) 对去重
    struct Row3 { int base; llama_token tok1; std::vector<int> cands; int seq; };
    std::vector<Row3> rows3;
    for (int ci : idx3) {
        int base = -1;
        for (int u = 0; u < U; u++)
            if (r2_tok[u] == cands[ci][0]) { base = u; break; }
        int v = 0;
        while (v < (int)rows3.size() &&
               !(rows3[v].base == base && rows3[v].tok1 == cands[ci][1])) v++;
        if (v == (int)rows3.size()) rows3.push_back({base, cands[ci][1], {}, 0});
        rows3[v].cands.push_back(ci);
    }

    bool step2_ok = false;
    if (U > 0) {
        auto ts2_0 = std::chrono::high_resolution_clock::now();
        // KV copy ctx (seq 0) → 每个 step2 行一条 worker seq
        for (int u = 0; u < U; u++)
            llama_memory_seq_cp(llama_get_memory(g_ctx), 0, u + 1, 0, -1);
        seq_top = U;
        auto ts2_kv = std::chrono::high_resolution_clock::now();

        llama_batch b2 = llama_batch_init(U, 0, U);
        for (int u = 0; u < U; u++) {
            b2.token[u] = r2_tok[u];
            b2.pos[u] = ctx_len;
            b2.n_seq_id[u] = 1;
            b2.seq_id[u][0] = u + 1;
            b2.logits[u] = 1;
        }
        b2.n_tokens = U;
        step2_ok = llama_decode(g_ctx, b2) == 0;
        if (step2_ok) {
            // CE 标量抽取（2026-11-28 P0-2 第 2 段）：归一化 (max,lse) 在图内
            // 算好（ggml CE_LSE op，镜像 patch），宿主只做 O(1) 查表——无扫描
            // 无并行池。数值逐位同宿主扫描（同循环序 + 同 CRT expf/log）。
            for (int u = 0; u < U; u++) {
                const double* cl = llama_get_ce_lse(g_ctx, u);
                float* l = llama_get_logits_ith(g_ctx, u);
                if (!cl || !l) {
                    for (int ci : r2_cands[u]) ce_sum[ci] = -1e10;
                    if (ce3_out) for (int ci : r2_cands[u]) (*ce3_out)[ci] = {NAN, NAN, NAN};
                    continue;
                }
                const float rm = (float)cl[0];    // float max 的 double 精确投影，还原 = 原值
                const double rlse = cl[1];
                for (int ci : r2_cands[u]) {
                    double c2 = -((double)(l[cands[ci][1]] - rm) - rlse);
                    ce_sum[ci] += kCeW2 * c2;
                    if (ce3_out) (*ce3_out)[ci][1] = c2;
                }
            }
        } else {
            for (int ci : idx2) ce_sum[ci] = -1e10;
            if (ce3_out) for (int ci : idx2) (*ce3_out)[ci] = {NAN, NAN, NAN};
            log_msg("WARN: step2 decode failed");
            // 失败自愈：prep 命中路径无 memory_clear，decode 失败多为 KV 耗尽
            // （见下方 worker 清理说明）——置无效强制下次 score 走全流程重建
            g_prep_ready = false;
        }
        llama_batch_free(b2);
        auto ts2_1 = std::chrono::high_resolution_clock::now();
        ms2a = std::chrono::duration<double, std::milli>(ts2_kv - ts2_0).count();
        ms2b = std::chrono::duration<double, std::milli>(ts2_1 - ts2_kv).count();
    }

    // ---- Step 3: 前缀 (c0,c1) 去重 decode ----
    const int V = (int)rows3.size();
    if (V > 0 && step2_ok) {
        // 中断检查（Step3 前）：step2 worker seq 已分配，先释放再退出
        if (cancelled()) {
            auto *mem0 = llama_get_memory(g_ctx);
            for (int s = 1; s <= seq_top; s++)
                llama_memory_seq_rm(mem0, s, 0, -1);
            return false;
        }
        auto ts3_0 = std::chrono::high_resolution_clock::now();
        // seq 分配：每个首 token 的第一个对复用 step2 seq；后续对
        // seq_cp(step2 seq → 新 seq)——拷贝发生在 step3 decode 的 update
        // 阶段，取的是 step2 后（ctx+c0）的状态，c1 尚未 decode
        {
            std::vector<int> base_cnt(U, 0);
            int fresh = U;
            for (auto& r : rows3) {
                if (r.base < 0) continue;  // 理论不可达（idx3 ⊆ idx2），防御
                if (++base_cnt[r.base] == 1) {
                    r.seq = r.base + 1;    // 复用 step2 seq
                } else {
                    r.seq = ++fresh;
                    llama_memory_seq_cp(llama_get_memory(g_ctx),
                                        r.base + 1, r.seq, 0, -1);
                }
            }
            seq_top = fresh;
        }
        llama_batch b3 = llama_batch_init(V, 0, V);
        for (int v = 0; v < V; v++) {
            b3.token[v] = rows3[v].tok1;
            b3.pos[v] = ctx_len + 1;
            b3.n_seq_id[v] = 1;
            b3.seq_id[v][0] = rows3[v].seq;
            b3.logits[v] = 1;
        }
        b3.n_tokens = V;
        if (llama_decode(g_ctx, b3) == 0) {
            for (int v = 0; v < V; v++) {
                const double* cl = llama_get_ce_lse(g_ctx, v);
                float* l = llama_get_logits_ith(g_ctx, v);
                if (!cl || !l) {
                    for (int ci : rows3[v].cands) ce_sum[ci] = -1e10;
                    if (ce3_out) for (int ci : rows3[v].cands) (*ce3_out)[ci] = {NAN, NAN, NAN};
                    continue;
                }
                const float rm = (float)cl[0];
                const double rlse = cl[1];
                for (int ci : rows3[v].cands) {
                    double c3 = -((double)(l[cands[ci][2]] - rm) - rlse);
                    ce_sum[ci] += kCeW3 * c3;
                    if (ce3_out) (*ce3_out)[ci][2] = c3;
                }
            }
        } else {
            for (auto& r : rows3)
                for (int ci : r.cands) ce_sum[ci] = -1e10;
            if (ce3_out)
                for (auto& r : rows3)
                    for (int ci : r.cands) (*ce3_out)[ci] = {NAN, NAN, NAN};
            log_msg("WARN: step3 decode failed");
            g_prep_ready = false;  // 同 Step2：失败自愈
        }
        llama_batch_free(b3);
        auto ts3_1 = std::chrono::high_resolution_clock::now();
        ms3 = std::chrono::duration<double, std::milli>(ts3_1 - ts3_0).count();
    } else if (V > 0) {
        // step2 失败：idx3 候选直接置哨兵（旧实现跟随一次必败 decode，结果相同）
        for (auto& r : rows3)
            for (int ci : r.cands) ce_sum[ci] = -1e10;
        if (ce3_out)
            for (auto& r : rows3)
                for (int ci : r.cands) (*ce3_out)[ci] = {NAN, NAN, NAN};
    }

    // ---- worker 序列 KV 清理（2026-09-04 修"推理自停"根因，与源码版同步）----
    // seq_cp 是共享标记非复制：Step2/3 的 decode cell 在评分结束后仍归属
    // worker seq。prep 命中路径无 memory_clear，同 ctx 连续评分（退格重打/
    // 改码不换 ctx/失败重试）每轮净耗 cell —— n_ctx=64 约 6~7 轮耗尽
    // → decode 静默失败 → 全哨兵分且 prep_ready 仍真 → 卡死失败循环，
    // 仅 commit 触发 prepare 或重部署可解（非本机实测）。评分尾部立即释放
    // worker 归属：共享 cell 只去掉一个归属方，seq0 与 prep 状态不受影响，
    // prep 命中照常，每次评分净耗归零。2026-11-07 起清理 1..seq_top
    // （= 不同前缀路径数，含 step3 分叉的新 seq）。
    if (seq_top > 0) {
        auto *mem = llama_get_memory(g_ctx);
        for (int s = 1; s <= seq_top; s++)
            llama_memory_seq_rm(mem, s, 0, -1);
    }

    // ---- 输出分数 ----
    auto ts_sc_0 = std::chrono::high_resolution_clock::now();
    // 加权 CE 和取负（kCeW1/2/3 见配置区注释；4+ token 候选只算前三项，
    // 尾部外推 2026-09-16 证伪删除：λ=0 全曲线最优，取消零损失）
    for (int i = 0; i < n_cands; i++) {
        scores_out[i] = ce_sum[i] > -1e9 ? -ce_sum[i] : -1e10;
    }

    // 注意: prep 状态不消耗——同一 ctx 期间可重复命中
    // (代次机制保证 seq0 被覆盖后自动失效, 无需主动清除)

    auto t_end = std::chrono::high_resolution_clock::now();
    double total_ms = std::chrono::duration<double, std::milli>(t_end - t0).count();
    double ms_score =
        std::chrono::duration<double, std::milli>(t_end - ts_sc_0).count();
    // 日志限频: 每 10 次记一次, 慢请求 (总耗时 > 100ms) 始终记录
    // 计时: wait=锁等待 S1=ctx decode(0 on prep) CE1=P(cand0|ctx)
    //       KV=KV copy S2=decode cand0 S3=decode cand1 score=加权求和
    if (++g_score_log_cnt % 10 == 1 || total_ms > 100)
        log_msg("score: wait=%.0fms S1=%.0fms CE1=%.0fms KV=%.0fms S2=%.0fms "
                "S3=%.0fms score=%.0fms total=%.0fms prep=%d ctx_tok=%d cand=%d "
                "r2=%d r3=%d",
                wait_ms, ms1, ms_ce1, ms2a, ms2b, ms3, ms_score, total_ms,
                use_prep ? 1 : 0, ctx_len, n_cands, U, V);
    return true;
}

// ============================================================
// 整句 CE 打分（2026-11-23 研究→生产；同日与 3-token 路径合并）
//
// 5 个**句子候选**从 N-gram 组句器来（max_sentences=1 的 poet 不出多句），
// 生产 3-token 路径只看到句首，不能用于整句重排。本函数算完整候选 token
// 的条件 CE 和，与 3-token 路径**共用 g_ctx / seq0 / prep**：
//   Step 1: ctx 就绪——prep 命中（同 ctx，seq0 的 KV+logits 已在）则零成本；
//           否则 decode 到 seq0 并刷新 prep（判据与 score_batch Step 1 一致）
//   Step 2: seq_cp(0→i+1) 后把 5 个候选的全部 token 放进**一个 batch**
//           一次 forward，CE 只做查表/归一化
// 整句跑完只清 worker seq（1..n），seq0 与 prep 状态保持有效——下一次
// score_batch 仍命中 prep（合并原独立 g_full_ctx 的收益：省掉每次一条
// 重复的 ctx forward + O(vocab) 归一化）。
// 返回 sum（正 CE 和，越小越可能）与 ntok；max_tokens 上限 48。
// ============================================================
static bool score_full_batch(const std::vector<llama_token> & ctx_ids,
                             const std::vector<std::vector<llama_token>> & cands,
                             std::vector<double> & sum_out,
                             std::vector<int> & ntok_out,
                             int max_tokens = 48) {
    int n = (int)cands.size();
    sum_out.assign(n, 0.0);
    ntok_out.assign(n, 0);
    if (n == 0 || n > 5 || ctx_ids.empty()) return false;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_loaded.load() || !g_ctx) return false;
    const int ctx_len = (int)ctx_ids.size();
    const int vs = llama_vocab_n_tokens(g_vocab);
    int max_len = 0;
    for (const auto & c : cands) max_len = (std::max)(max_len, (int)c.size());
    // 每 seq 预算：总 KV 扣掉 ctx 后 n 条 worker 均分（每条需 ctx_len+候选长度）
    int budget = (g_n_ctx - ctx_len) / n - ctx_len - 1;
    max_len = (std::min)(max_len, (std::min)(max_tokens, budget));
    if (max_len <= 0) return false;

    // ---- ctx KV：prep 命中零成本 / 前缀延伸只 decode 增量 / 否则全量 ----
    // （与 score_batch Step 1 同一套 ensure_ctx_kv，2026-11-23 合并）
    float m0 = 0;
    double lse0 = 0;
    const float * cl = ensure_ctx_kv(ctx_ids, vs, m0, lse0);
    if (!cl) return false;  // ctx decode 失败：本轮回 nil，下次全流程兜底

    // 首 token CE（共享 ctx 末位 logits，须在候选 decode 之前算完）
    for (int i = 0; i < n; i++) {
        if (!cands[i].empty()) {
            sum_out[i] = ce_target(cl, cands[i][0], m0, lse0);
            ntok_out[i] = 1;
        }
    }
    // ctx KV → 每个候选 seq（先清目的 seq：prep 命中路径不清整个 KV，
    // 上一轮残留会让 seq_cp 叠加出脏 KV）
    auto * mem0 = llama_get_memory(g_ctx);
    for (int i = 0; i < n; i++) {
        llama_memory_seq_rm(mem0, i + 1, 0, -1);
        llama_memory_seq_cp(mem0, 0, i + 1, 0, -1);
    }

    // ---- 一次性 decode 全部候选 token（每候选一条 seq，ctx KV 已 copy）----
    // 逐步 decode（每 token 一次 forward）在 0.6B 上每步约 20ms，15 步 ≈ 300ms；
    // 这里把所有候选 token 放进**同一个 batch**、一次 forward 取全位置 logits，
    // CE 只做查表/归一化——同一数学，forward 次数从 N 降到 1。
    std::vector<int> base(n, -1);
    std::vector<int> lens(n, 0);
    int total = 0;
    for (int i = 0; i < n; i++) {
        lens[i] = (std::min)((int)cands[i].size(), max_len);
        total += lens[i];
    }
    if (total <= 0) {
        for (int i = 0; i < n; i++)
            llama_memory_seq_rm(mem0, i + 1, 0, -1);
        return true;
    }
    llama_batch b = llama_batch_init(total, 0, n);
    int row = 0;
    for (int i = 0; i < n; i++) {
        base[i] = row;
        int len = lens[i];
        for (int j = 0; j < len; j++, row++) {
            b.token[row] = cands[i][j];
            b.pos[row] = ctx_len + j;
            b.n_seq_id[row] = 1;
            b.seq_id[row][0] = i + 1;
            // 该 token 的 logits 预测下一个 token；最后一个不用
            b.logits[row] = (j + 1 < len) ? 1 : 0;
        }
    }
    b.n_tokens = row;
    bool ok = llama_decode(g_ctx, b) == 0;
    if (ok) {
        for (int i = 0; i < n; i++) {
            int len = lens[i];
            for (int j = 1; j < len; j++) {
                float * l = llama_get_logits_ith(g_ctx, base[i] + j - 1);
                if (!l) { sum_out[i] = 1e10; break; }
                float m; double lse;
                logits_normalizer(l, vs, m, lse);
                sum_out[i] += ce_target(l, cands[i][j], m, lse);
                ntok_out[i] = j + 1;
            }
        }
    } else {
        // 失败自愈：prep 命中路径不清 KV，decode 失败可能是 KV 耗尽——
        // 置无效强制下一次走全流程重建（同 score_batch Step2/3）
        g_prep_ready = false;
    }
    llama_batch_free(b);
    // worker seq 清理（seq0 与 prep 保留，3-token 路径仍可命中）
    for (int i = 0; i < n; i++)
        llama_memory_seq_rm(mem0, i + 1, 0, -1);
    return true;
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
        // 2026-11-18：不再静默丢弃——登记 pending，score 结束后补跑
        //（lua 侧的去重记的是"调用过"，丢弃后再也不会重试，满码必付 S1）
        request_prepare_retry(ctx_ids, seq);
        log_msg("prepare: DEFER score in progress (seq=%d ctx_tok=%d)",
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
    int vs = llama_vocab_n_tokens(g_vocab);
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

    // 不预复制 KV——score 的 KV copy 本身很快（n_ctx=128 下微秒级），
    // score() 检测 ctx 一致时跳过 Step 1，但仍执行 KV copy + Step 2

    g_seq0_gen++;   // seq0 KV 已更新 (本代)
    g_prep_gen = g_seq0_gen;
    g_prep_ctx = ctx_ids;
    // 归一化量随 prep 一并算好（2026-11-06）：score 的 prep 命中路径
    // 直接取用，省一次 O(vocab) 扫描（实测 CE1 段 2ms → ~0ms）。
    // 放在 g_prep_ready 置位前、锁内完成，无 torn state。
    logits_normalizer(g_prep_logits.data(), vs, g_prep_m, g_prep_lse);
    g_prep_ready = true;
    log_msg("prepare: done ctx_tok=%d seq=%d", ctx_len, seq);
}

// 快照刷新完成后预解码（2026-11-18）：从 ctxlink 线程调用，文本即
// consume 端（llm_context）会读到的那一份，保证 prepare 与 score 同源。
static void prepare_from_published_text(const std::string & text) {
    if (!g_loaded.load()) return;
    std::string t;
    t.reserve(text.size());
    for (char c : text) {
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
        t.push_back(c);
    }
    auto ids = ctx_token_ids(t.c_str());
    if (ids.empty()) return;
    int seq = ++g_prep_seq;
    std::thread([ids, seq]() { prepare(ids, seq); }).detach();
    log_msg("prepare: auto after snapshot ctx_tok=%d seq=%d",
            (int)ids.size(), seq);
}

// score 释放锁后补跑被延迟的 prepare（2026-11-18）
static void retry_pending_prepare() {
    std::vector<llama_token> ids;
    int seq = -1;
    if (!take_prepare_retry(ids, seq)) return;
    if (!g_loaded.load() || ids.empty()) return;
    if (seq != g_prep_seq.load()) return;      // 已有更新的请求
    std::thread([ids, seq]() { prepare(ids, seq); }).detach();
    log_msg("prepare: retry deferred ctx_tok=%d seq=%d", (int)ids.size(), seq);
}

// ============================================================
// 异步评分器（2026-11-22 异步基建，两版同构）
// 同步路径零 LLM：filter 每键 async_submit 投递，评分在持久工作线程执行；
// 字词模式 async_submit(immediate) + async_wait = 与既有同步评分等价的
// 行为（当前词重排零回归），整句模式 submit 不等待（0 LLM 打字流畅），
// 评分结果经 async_poll 在后续 query 收割回填。
// 任务槽覆盖式 + 代次中断（submit/cancel 递增 g_async_gen，score_batch
// 每 Step 边界检查）+ 40ms 去抖（非 immediate 任务，等编码稳定才开跑）。
// 指纹 = 上文 \x1f 候选 \x1e 拼接原串（lua 缓存键与 DLL 同构，无哈希冲突面；
// 上文/候选变化自然失效，无需维护失效链）。结果槽只存最近完成一份。
// ============================================================
static std::atomic<long> g_async_gen{1};
static std::mutex              g_async_mu;
static std::condition_variable g_async_cv;
static std::thread             g_async_thread;
static std::atomic<bool>       g_async_started{false};

static constexpr int kAsyncDebounceMs = 40;

struct AsyncTask {
    bool valid = false;
    long gen = 0;                 // 提交时的代次（中断判定基准）
    bool immediate = false;       // wait 模式：跳过去抖立即开跑
    std::string fingerprint;
    std::string context;          // 上文原串（worker 内 token 化 + ctx_used）
    // 组合区已确认前缀（2026-11-23）：前缀软确认后追加在上文之后（完整不截断），
    // 上文部分 KV 可增量复用（§11.8 协同）
    std::string prefix;
    std::vector<std::string> cand_texts;
    // 子词（PM，部分覆盖候选）清单（2026-11-23）：整句模式才有；只做 token
    // 前缀复用评分（零 decode）与指纹绑定，不进评分窗
    std::vector<std::string> pm_texts;
    std::chrono::steady_clock::time_point enq_at;
};
static AsyncTask g_async_task;

struct AsyncRes {
    bool valid = false;
    std::string fingerprint;
    std::vector<std::string> cand_texts;            // 原顺序
    std::vector<double> scores;
    std::vector<std::array<double, 3>> ce3;
    std::vector<std::string> segs;
    std::vector<std::string> pm_texts;   // 子词文本（提交序）
    std::vector<double> pm_scores;       // 子词复用分（-1e10 = 无前缀匹配）
    bool prep_hit = false;
    bool ctx_anchored = false;           // 本窗评分垫了「。」锚（W flags=anchor）
    std::string ctx_used;
    double ev_ms = 0;
};
static AsyncRes g_async_result;

static std::string async_fingerprint(const char * context,
                                     const std::vector<std::string> & cands,
                                     const std::vector<std::string> & pm,
                                     const char * prefix = nullptr) {
    std::string fp = context ? context : "";
    // 已确认前缀（2026-11-23）：拼在上文后、候选前——确认前后上文相同但前缀
    // 不同，指纹必须区分（与 lua make_fp 同构，分隔符 \x1c）
    if (prefix && *prefix) {
        fp.push_back('\x1c');
        fp += prefix;
    }
    fp.push_back('\x1f');
    for (size_t i = 0; i < cands.size(); i++) {
        if (i) fp.push_back('\x1e');
        fp += cands[i];
    }
    // 子词清单也绑进指纹（2026-11-23）：子词复用分与候选集属同一快照，
    // 否则同 FM 不同 PM 的 query 会错命中缓存（与 lua make_fp 同构）
    if (!pm.empty()) {
        fp.push_back('\x1d');
        for (size_t i = 0; i < pm.size(); i++) {
            if (i) fp.push_back('\x1e');
            fp += pm[i];
        }
    }
    return fp;
}

static void pack_async_result(lua_State * L, const AsyncRes & r) {
    lua_newtable(L);
    lua_pushstring(L, r.fingerprint.c_str());
    lua_setfield(L, -2, "fp");
    lua_createtable(L, (int)r.cand_texts.size(), 0);
    for (size_t i = 0; i < r.cand_texts.size(); i++) {
        lua_pushstring(L, r.cand_texts[i].c_str());
        lua_rawseti(L, -2, (int)i + 1);
    }
    lua_setfield(L, -2, "cands");
    lua_createtable(L, 0, (int)r.cand_texts.size());
    for (size_t i = 0; i < r.cand_texts.size(); i++) {
        lua_pushnumber(L, r.scores[i]);
        lua_setfield(L, -2, r.cand_texts[i].c_str());
    }
    lua_setfield(L, -2, "scores");
    // CE 三分量（NaN / 哨兵位不设 = nil，与 get_ce3 语义一致）
    lua_createtable(L, 0, (int)r.cand_texts.size());
    for (size_t i = 0; i < r.cand_texts.size(); i++) {
        lua_createtable(L, 3, 0);
        for (int k = 0; k < 3; k++) {
            double v = r.ce3[i][k];
            if (v == v && v > -1e9) {
                lua_pushnumber(L, v);
                lua_rawseti(L, -2, k + 1);
            }
        }
        lua_setfield(L, -2, r.cand_texts[i].c_str());
    }
    lua_setfield(L, -2, "ce3");
    lua_createtable(L, 0, (int)r.cand_texts.size());
    for (size_t i = 0; i < r.cand_texts.size(); i++) {
        lua_pushstring(L, r.segs[i].c_str());
        lua_setfield(L, -2, r.cand_texts[i].c_str());
    }
    lua_setfield(L, -2, "segs");
    // 子词复用分（2026-11-23）：text → score，无前缀匹配者不设（= nil）
    lua_createtable(L, 0, (int)r.pm_texts.size());
    for (size_t i = 0; i < r.pm_texts.size() && i < r.pm_scores.size(); i++) {
        if (r.pm_scores[i] <= -1e9) continue;
        lua_pushnumber(L, r.pm_scores[i]);
        lua_setfield(L, -2, r.pm_texts[i].c_str());
    }
    lua_setfield(L, -2, "pm");
    lua_pushboolean(L, r.prep_hit ? 1 : 0);
    lua_setfield(L, -2, "prep");
    lua_pushboolean(L, r.ctx_anchored ? 1 : 0);
    lua_setfield(L, -2, "anchor");
    lua_pushstring(L, r.ctx_used.c_str());
    lua_setfield(L, -2, "ctx_used");
    lua_pushnumber(L, r.ev_ms);
    lua_setfield(L, -2, "ev_ms");
}

// 子词（PM，比等长词短的词典词）的零成本评分（2026-11-23 用户定案）：
// 复用满覆盖（FM）评分窗已算好的 token 前缀 CE——PM 的前 k 个 token 与某个
// FM 候选的前 k 个 token 逐位相同（k = min(PM token 数, 3)）时，其条件概率
// 与 FM 的同位置分量完全相同（同一上文 + 同一前缀），直接取加权和即可，
// 全程零 decode。无匹配（典型 = 单字 PM 而 FM 首 token 是多字 token）→
// 哨兵 -1e10，子词块这些条目保引擎序殿后（不参与排序）。
static void reuse_pm_scores(
    const std::vector<std::vector<llama_token>> & fm_ids,
    const std::vector<std::array<double, 3>> & fm_ce3,
    const std::vector<std::string> & pm_texts,
    std::vector<double> & out) {
    static constexpr double W[3] = {1.0, 1.10, 0.60};  // 与 kCeW 同值
    out.assign(pm_texts.size(), -1e10);
    for (size_t p = 0; p < pm_texts.size(); p++) {
        auto ids = tokenize(pm_texts[p].c_str());
        if (ids.empty()) continue;
        size_t need = ids.size() < 3 ? ids.size() : 3;
        for (size_t f = 0; f < fm_ids.size(); f++) {
            const auto & fm = fm_ids[f];
            if (fm.size() < need) continue;
            size_t k = 0;
            for (; k < need; k++)
                if (fm[k] != ids[k]) break;
            if (k < need) continue;          // 前缀不同：不可复用
            double s = 0;
            bool ok = true;
            for (size_t j = 0; j < need; j++) {
                double v = fm_ce3[f][j];
                if (!(v == v) || v <= -1e9) { ok = false; break; }
                s += W[j] * v;
            }
            if (ok) { out[p] = -s; break; }  // 同前缀的 FM 分量相同，取首个
        }
    }
}

static void async_worker_loop() {
    for (;;) {
        AsyncTask task;
        {
            std::unique_lock<std::mutex> lk(g_async_mu);
            g_async_cv.wait(lk, [] { return g_async_task.valid; });
            task = g_async_task;
            g_async_task.valid = false;          // 领走
            // 去抖：非 immediate 任务等 40ms 无更新才开跑；期间新任务到达
            //（notify 唤醒）则换新任务重新等。immediate（字词 wait 路径）跳过。
            if (!task.immediate) {
                for (;;) {
                    auto deadline = task.enq_at +
                        std::chrono::milliseconds(kAsyncDebounceMs);
                    bool updated = g_async_cv.wait_until(lk, deadline, [&] {
                        return g_async_task.valid &&
                               g_async_task.enq_at > task.enq_at;
                    });
                    if (!updated) break;
                    task = g_async_task;
                    g_async_task.valid = false;
                }
            }
        }
        // 领取后已被覆盖/取消（gen 前进）：丢弃，回到等待
        if (task.gen != g_async_gen.load(std::memory_order_relaxed)) continue;

        // 模型懒加载触发（与 lua_score 同语义：不在此等待加载——加载中任务
        // 直接发布失败结果，wait 路径上层 skip not_ready；processor 每键
        // prepare 与本触发点都会启动加载，就绪后后续任务正常评分）
        if (!g_loaded.load()) {
            if (!g_loading.load()) load_model_async();
            std::lock_guard<std::mutex> lk(g_async_mu);
            g_async_result = AsyncRes{};
            g_async_cv.notify_all();
            continue;
        }

        AsyncRes res;
        res.fingerprint = task.fingerprint;
        res.cand_texts = task.cand_texts;
        // token 化（模型已就绪）：候选 + 上文
        std::vector<std::vector<llama_token>> cand_ids;
        cand_ids.reserve(task.cand_texts.size());
        res.segs.reserve(task.cand_texts.size());
        for (auto & s : task.cand_texts) {
            auto ids = tokenize(s.c_str());
            if (ids.empty()) ids.push_back(0);
            res.segs.push_back(token_seg_display(ids));
            cand_ids.push_back(std::move(ids));
        }
        bool ctx_anchored = false;
        std::vector<llama_token> ctx_ids =
            ctx_ids_with_prefix(task.context.c_str(), task.prefix.c_str(),
                                &ctx_anchored);
        res.ctx_anchored = ctx_anchored;  // W flags=anchor（语料口径标记）
        if ((int)ctx_ids.size() < g_min_tokens) ctx_ids.clear();
        // g_last_ctx_used 已由 ctx_token_ids 写（调试 getter 兼容；跨线程
        // 写与既有 prepare 线程同风险面，字段仅调试显示用）
        res.ctx_used = g_last_ctx_used;

        if (ctx_ids.empty() || (int)cand_ids.size() < 2) {
            std::lock_guard<std::mutex> lk(g_async_mu);
            g_async_result = AsyncRes{};         // 失败发布（valid=false）
            g_async_cv.notify_all();
            continue;
        }

        auto t0 = std::chrono::high_resolution_clock::now();
        std::vector<double> scores;
        bool done = false;
        try {
            done = score_batch(ctx_ids, cand_ids, res.scores, &res.ce3,
                               &res.prep_hit, &g_async_gen, task.gen);
        } catch (...) {
            log_msg("ERROR: exception in async score_batch");
        }
        // 评分线程锁已释放：补跑被延迟的 prepare（原 lua_score 收尾动作）
        retry_pending_prepare();
        auto t1 = std::chrono::high_resolution_clock::now();
        res.ev_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        if (done) {
            // 子词复用评分（2026-11-23）：只用已算好的 FM token/CE 做前缀
            // 匹配，零 decode——必须先于发布（面板/缓存统一读快照）
            if (!task.pm_texts.empty()) {
                reuse_pm_scores(cand_ids, res.ce3, task.pm_texts,
                                res.pm_scores);
                res.pm_texts = task.pm_texts;
            }
            res.valid = true;
            std::lock_guard<std::mutex> lk(g_async_mu);
            g_async_result = std::move(res);
            // "最近一次评分"快照（get_scores/get_ce3/get_seg/get_ctx_used
            // getter 兼容——假服务端/冒烟/研究路径仍可用）
            g_last_scores = g_async_result.scores;
            g_last_cands  = g_async_result.cand_texts;
            g_last_ce3    = g_async_result.ce3;
            g_last_seg    = g_async_result.segs;
            g_last_prep_hit = g_async_result.prep_hit;
            g_async_cv.notify_all();
        }
        // 中断（done=false）：不发布，结果槽留给新任务
    }
}

static int lua_async_submit(lua_State * L) {
    const char * context = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    int immediate = lua_toboolean(L, 3);
    int n = (int)luaL_len(L, 2);
    if (n > 96) n = 96;   // 2026-11-26：候选输入上限与 seq 上限解耦（预算在过滤侧选）
    std::vector<std::string> cands;
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 2, i);
        const char * s = lua_tostring(L, -1);
        if (s && *s) cands.push_back(s);
        lua_pop(L, 1);
    }
    // 第 4 参（可选，2026-11-23）：子词（PM）文本表——只做 token 前缀复用
    // 评分（零 decode）与指纹绑定；字词模式不传（指纹格式保持不变）
    std::vector<std::string> pm;
    if (lua_istable(L, 4)) {
        int pn = (int)luaL_len(L, 4);
        if (pn > g_n_seq_max) pn = g_n_seq_max;
        for (int i = 1; i <= pn; i++) {
            lua_rawgeti(L, 4, i);
            const char * s = lua_tostring(L, -1);
            if (s && *s) pm.push_back(s);
            lua_pop(L, 1);
        }
    }
    // 第 5 参（可选，2026-11-23）：组合区已确认前缀（完整追加，不参与上文截断）
    const char * prefix = luaL_optstring(L, 5, "");
    // 2026-11-24：空上文 + 非空前缀 = 有临时上文（确认过 phrase），任务成立
    // ——ctx_ids_with_prefix 会把前缀拼进 ctx（旧判据只看 context 会误拒，
    // 使"选一次 phrase 后就能算 CE"失效）。
    if ((int)cands.size() < 2 ||
        ((!context || !*context) && (!prefix || !*prefix))) {
        lua_pushnil(L);   // 任务不成立（调用方走层1 序）
        return 1;
    }
    if (!g_async_started.load()) {
        std::lock_guard<std::mutex> lk(g_async_mu);
        if (!g_async_started.load()) {
            g_async_thread = std::thread(async_worker_loop);
            g_async_thread.detach();     // 进程内常驻，随进程退出
            g_async_started.store(true);
        }
    }
    std::string fp;
    {
        std::lock_guard<std::mutex> lk(g_async_mu);
        long gen = g_async_gen.fetch_add(1, std::memory_order_relaxed) + 1;
        g_async_task = AsyncTask{};
        g_async_task.valid = true;
        g_async_task.gen = gen;
        g_async_task.immediate = immediate != 0;
        g_async_task.fingerprint = fp = async_fingerprint(context, cands, pm, prefix);
        g_async_task.context = context;
        g_async_task.prefix = prefix ? prefix : "";
        g_async_task.cand_texts = std::move(cands);
        g_async_task.pm_texts = std::move(pm);
        g_async_task.enq_at = std::chrono::steady_clock::now();
    }
    g_async_cv.notify_all();
    lua_pushstring(L, fp.c_str());
    return 1;
}

// 字词模式：阻塞等待指纹匹配的评分结果（与既有同步评分等价的延迟面）。
// 超时返回 nil（模型加载中 / 评分未完成——上层 skip not_ready，评分线程
// 继续跑完发布，后续 query 可经 poll 收割）。
static int lua_async_wait(lua_State * L) {
    const char * fp = luaL_checkstring(L, 1);
    int timeout_ms = (int)luaL_optinteger(L, 2, 250);
    std::unique_lock<std::mutex> lk(g_async_mu);
    bool got = g_async_cv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                                   [&] {
        return g_async_result.valid && g_async_result.fingerprint == fp;
    });
    if (!got) { lua_pushnil(L); return 1; }
    pack_async_result(L, g_async_result);
    g_async_result.valid = false;                // 取走即清（lua 侧有缓存）
    return 1;
}

// 整句模式：非阻塞收割最近完成的评分结果（连同其指纹——收割方按指纹回填
// 缓存与语料挂账）。无就绪结果返回 nil。
static int lua_async_poll(lua_State * L) {
    std::lock_guard<std::mutex> lk(g_async_mu);
    if (!g_async_result.valid) { lua_pushnil(L); return 1; }
    pack_async_result(L, g_async_result);
    g_async_result.valid = false;
    return 1;
}

// 代次递增 + 清任务槽：提交/上下文变化后中断在跑的评分（省 CPU 与锁占用）。
// 结果槽保留——完成的评分成果仍可被后续 poll 收割回填。
static int lua_async_cancel(lua_State * L) {
    g_async_gen.fetch_add(1, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lk(g_async_mu);
        g_async_task = AsyncTask{};
    }
    return 0;
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
    // 上文 token 数 < min_tokens → 不预解码（空 ctx 无推理是配置语义）
    auto ctx_ids = ctx_ids_with_prefix(context, luaL_optstring(L, 2, ""));
    if (ctx_ids.empty()) {
        lua_pushboolean(L, 0);
        return 1;
    }

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
    if (n > 96) n = 96;   // 2026-11-26：候选输入上限与 seq 上限解耦
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 2, i);
        const char * s = lua_tostring(L, -1);
        if (s) cand_texts.push_back(s);
        lua_pop(L, 1);
    }
    if (cand_texts.size() < 2) { lua_pushnil(L); return 1; }

    std::vector<llama_token> ctx_ids =
        ctx_ids_with_prefix(context, luaL_optstring(L, 3, ""));
    if (ctx_ids.empty()) { lua_pushnil(L); return 1; }

    std::vector<std::vector<llama_token>> cand_ids;
    std::vector<std::string> cand_segs;  // token 边界段显（协议 v7 调试）
    cand_segs.reserve(cand_texts.size());
    for (auto & s : cand_texts) {
        auto ids = tokenize(s.c_str());
        if (ids.empty()) ids.push_back(0);
        cand_ids.push_back(ids);
        cand_segs.push_back(token_seg_display(ids));
    }

    std::vector<double> scores;
    std::vector<std::array<double, 3>> ce3;
    bool prep_hit = false;
    try {
        score_batch(ctx_ids, cand_ids, scores, &ce3, &prep_hit);
    } catch (...) {
        log_msg("ERROR: exception in score_batch");
        lua_pushnil(L);
        return 1;
    }
    // 锁已释放：补跑被延迟的 prepare（2026-11-18）
    retry_pending_prepare();

    // 按分数降序排列
    std::vector<int> order(scores.size());
    for (int i = 0; i < (int)order.size(); i++) order[i] = i;
    std::sort(order.begin(), order.end(),
              [&](int a, int b) { return scores[a] > scores[b]; });

    g_last_scores = scores;
    g_last_cands  = cand_texts;
    g_last_ce3    = ce3;
    g_last_seg    = std::move(cand_segs);
    g_last_prep_hit = prep_hit;

    lua_newtable(L);
    for (int i = 0; i < (int)order.size(); i++) {
        lua_pushstring(L, cand_texts[order[i]].c_str());
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

// llm.score_full(ctx, cands) → {{sum_ce=.., mean_ce=.., ntok=..}, ...}
// 整句 CE（完整候选 token），输入顺序对应输出；失败返回 nil。
static int lua_score_full(lua_State * L) {
    if (!g_loaded.load()) {
        if (!g_loading.load()) load_model_async();
        lua_pushnil(L);
        return 1;
    }
    const char * context = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    int n = (int)luaL_len(L, 2);
    if (n < 1) { lua_pushnil(L); return 1; }
    if (n > 5) n = 5;  // g_ctx: seq0（共享 prep）+ 5 条候选 seq
    std::vector<std::string> texts;
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 2, i);
        const char * s = lua_tostring(L, -1);
        if (s) texts.push_back(s);
        lua_pop(L, 1);
    }
    if (texts.empty()) { lua_pushnil(L); return 1; }
    auto ctx_ids = ctx_ids_with_prefix(context, luaL_optstring(L, 3, ""));
    if (ctx_ids.empty()) { lua_pushnil(L); return 1; }
    std::vector<std::vector<llama_token>> cand_ids;
    for (auto & s : texts) {
        auto ids = tokenize(s.c_str());
        if (ids.empty()) ids.push_back(0);
        cand_ids.push_back(std::move(ids));
    }
    std::vector<double> sums;
    std::vector<int> ntok;
    bool ok = false;
    try {
        ok = score_full_batch(ctx_ids, cand_ids, sums, ntok, 48);
    } catch (...) {
        log_msg("ERROR: exception in score_full_batch");
    }
    if (!ok) { lua_pushnil(L); return 1; }
    lua_newtable(L);
    for (int i = 0; i < (int)sums.size(); i++) {
        lua_newtable(L);
        lua_pushnumber(L, sums[i]);
        lua_setfield(L, -2, "sum_ce");
        lua_pushnumber(L, ntok[i] > 0 ? sums[i] / ntok[i] : 0.0);
        lua_setfield(L, -2, "mean_ce");
        lua_pushinteger(L, ntok[i]);
        lua_setfield(L, -2, "ntok");
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

// 墙钟毫秒（研究/基准用；steady_clock 单调，差值有效）
static int lua_now_ms(lua_State * L) {
    auto t = std::chrono::steady_clock::now().time_since_epoch();
    lua_pushnumber(L, std::chrono::duration<double, std::milli>(t).count());
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

// 上次推理实际使用的上文尾部（2026-11-12 协议 v4，调试窗口灰显）
static int lua_get_ctx_used(lua_State * L) {
    std::lock_guard<std::mutex> lock(g_mutex);
    lua_pushstring(L, g_last_ctx_used.c_str());
    return 1;
}

// 上次 score 的 CE 三分量（2026-11-11 调试窗口协议 v2）：text → {c1, c2, c3}
// ——未乘 kCeW 权重的原始分量；缺 token / 评分失败位 = nil（lua 侧显示空）
static int lua_get_ce3(lua_State * L) {
    std::lock_guard<std::mutex> lock(g_mutex);
    lua_newtable(L);
    for (size_t i = 0; i < g_last_cands.size(); i++) {
        const auto & t = g_last_ce3[i];
        lua_createtable(L, 3, 0);
        for (int k = 0; k < 3; k++) {
            if (t[k] == t[k] && t[k] > -1e9) {   // NaN / 哨兵 → 不设（nil）
                lua_pushnumber(L, t[k]);
                lua_rawseti(L, -2, k + 1);
            }
        }
        lua_setfield(L, -2, g_last_cands[i].c_str());
    }
    return 1;
}

// 上次 score 的候选 token 边界段显（2026-11-21 调试窗口协议 v7）：
// text → "cm/ak"——段只落在 token 边界 ∩ 字符边界（单 token 多字不劈，
// 字内多 token 合并不劈字）；旧 DLL 无此函数时 lua 侧静默缺省
//（"词"列显示原词）。
static int lua_get_seg(lua_State * L) {
    std::lock_guard<std::mutex> lock(g_mutex);
    lua_newtable(L);
    for (size_t i = 0; i < g_last_cands.size(); i++) {
        lua_pushstring(L, g_last_seg[i].c_str());
        lua_setfield(L, -2, g_last_cands[i].c_str());
    }
    return 1;
}

// llm.tok_count(texts) → { [text] = ntok }：只算 token 数（不 decode），
// 2026-11-26：过滤侧按 CE 预算选候选用（1-token 候选免费）。
static int lua_tok_count(lua_State * L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    int n = (int)luaL_len(L, 1);
    if (n > 96) n = 96;
    lua_newtable(L);
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 1, i);
        const char *s = lua_tostring(L, -1);
        lua_pop(L, 1);
        int nt = 0;
        if (s && *s) {
            auto ids = tokenize(s);
            nt = (int)ids.size();
        }
        const char *key = (s && *s) ? s : "";
        lua_pushstring(L, key);
        lua_pushinteger(L, nt);
        lua_settable(L, -3);
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
// 异步完成，下一键即有新鲜上文）。
// 2026-11-18：带参数 1 时同时登记"快照刷新后立刻预解码"——kick 到快照更新
// 之间 ~50ms，按键路径此刻读到的还是旧文本，用它 prepare 会与满码 score 的
// ctx 不同源（真机 4 连 miss 的根因）。登记后由 ctxlink 线程在发布新鲜快照
// 的那一刻用同一份文本预解码。
static int lua_kick_context(lua_State * L) {
    ctxlink::kick();
    if (lua_toboolean(L, 1)) {
        ctxlink::g_prep_after_publish++;
    }
    return 0;
}

// 编辑键/点击信号（2026-09-12 信号层统一）：失效 COM/UIA 快照 + kick
// 延迟重读（语义见 ctxlink::edit_reset）。processor 在编辑键与点击检测
// 分支调用——快照制的失效信号不再只有 commit。
static int lua_edit_reset_context(lua_State * L) {
    ctxlink::ensure_started();
    ctxlink::edit_reset();
    return 0;
}

// 前台窗口切换检测（跨应用，2026-09-11）：插件版 lua 无焦点事件，经此
// 让 processor 在切换后重置历史上文（对齐源码版 focus:switch reset 语义
// ——真机踩坑：切新文档首词用旧窗口历史冒充上文标 AI·历史）。
// pid+HWND 双比对（2026-09-12）：仅比 pid 挡不住同应用多窗/多标签切换
// （Chrome 双窗、Win11 记事本标签，pid 相同），旧窗历史照样冒充；HWND
// 级对齐源码版 TSF prevFocus!=focus。候选窗不抢前台，打字中不误触。
static int lua_fg_changed(lua_State * L) {
    static DWORD last_pid = 0;
    static HWND last_hwnd = nullptr;
    DWORD cur_pid = ctxlink::foreground_pid();
    HWND cur_hwnd = GetForegroundWindow();
    bool changed = (last_pid != 0 && cur_pid != 0 &&
                    (cur_pid != last_pid || cur_hwnd != last_hwnd));
    last_pid = cur_pid;
    last_hwnd = cur_hwnd;
    lua_pushboolean(L, changed ? 1 : 0);
    return 1;
}

// 鼠标点击检测（2026-09-11 深夜用户定案：鼠标移动主要靠点击检测——
// 任何点击=光标可能移动→清历史上文兜底，不做例外排除——候选窗/工具
// 栏点击也清，上下文宁可变短不可错）。2026-09-12 起 processor 在点击
// 分支同时调 edit_reset_context 失效快照+重读（真文快照也是旧时刻的，
// 点击移光标后同样冒充）。
// GetAsyncKeyState LSB=自本进程上次查询以来按下过，专为轮询设计；
// 首次调用建立基线防进程历史点击误报。
static int lua_click_happened(lua_State * L) {
    static bool inited = false;
    short b = GetAsyncKeyState(VK_LBUTTON) | GetAsyncKeyState(VK_RBUTTON) |
              GetAsyncKeyState(VK_MBUTTON);
    bool clicked = inited && (b & 1);
    inited = true;
    lua_pushboolean(L, clicked ? 1 : 0);
    return 1;
}

// ============================================================
// 编码模式匹配（2026-09-30 取代 min_code_len/max_code_len 区间）
// ============================================================
// match_code(pattern, code) -> bool
//   全串匹配（与 Rime 自身 speller/auto_select_pattern 的语义一致，
//   其实现为 boost::regex_match）。这里用 std::regex（MSVC 标准库，
//   零新依赖）承载同一套 ECMAScript 语法——用户写的 .{4} / .{4,} /
//   .{3,4} / [abcde]{4} 在 boost 与 std::regex 下等价。
//   语义约定：
//     - 模式为空或 nil → 视为「总是匹配」（回退默认 .{4} 由调用方决定）
//     - 模式非法（编译异常）→ 回退默认模式并记日志，不抛给 lua
//     - 匹配对象是**输入编码串**（非候选词）
//   性能：仅当模式字符串变化时重新编译（用户改配置才触发）。
static const char *kDefaultCodePattern = ".{4}";  // 恰 4 码 = 原 min_code_len=4

// ensure_dir(path) -> bool（2026-11-21）：rime-lua 无 mkdir，lua 侧记录
// 文件收进用户文件夹 llm_rerank 子目录后，迁移/首写前用它建目录。
// 已存在 = true（幂等）。函数注册 setfield 直挂（同 match_code）。
static int lua_ensure_dir(lua_State * L) {
    const char *dir = luaL_checkstring(L, 1);
    if (!dir || !*dir || strlen(dir) >= MAX_PATH) {
        lua_pushboolean(L, 0);
        return 1;
    }
    BOOL ok = CreateDirectoryA(dir, nullptr);
    lua_pushboolean(L, (ok || GetLastError() == ERROR_ALREADY_EXISTS) ? 1 : 0);
    return 1;
}

static int lua_match_code(lua_State * L) {
    const char * pat = luaL_optstring(L, 1, NULL);
    const char * code = luaL_optstring(L, 2, "");
    if (!pat || !*pat) {          // 空模式 = 总是匹配
        lua_pushboolean(L, 1);
        return 1;
    }
    static std::string  last_pat;
    static std::regex   re;
    static bool         re_valid = false;
    if (last_pat != pat || (!re_valid && last_pat.empty())) {
        last_pat = pat;
        try {
            re = std::regex(pat, std::regex::ECMAScript);
            re_valid = true;
        } catch (const std::regex_error & e) {
            log_msg("[match_code] invalid pattern '%s' (%s) -> fallback '%s'",
                    pat, e.what(), kDefaultCodePattern);
            try {
                last_pat = kDefaultCodePattern;
                re = std::regex(kDefaultCodePattern, std::regex::ECMAScript);
                re_valid = true;
            } catch (...) {
                re_valid = false;
            }
        }
    }
    bool ok = false;
    if (re_valid) {
        try {
            ok = std::regex_match(std::string(code), re);
        } catch (...) {
            ok = false;
        }
    }
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

// ============================================================
// 实时调试行广播（2026-11-10）：live_write(line) — lua 侧拼好一行协议
// 文本（V/L/C/S/E/R），C++ 只负责管道广播。旧 DLL 无此函数时 lua 侧
// type 检查容错跳过（向后兼容）。
// ============================================================
static int lua_live_write(lua_State * L) {
    const char * line = luaL_optstring(L, 1, NULL);
    if (line && *line)
        live_broadcast(line);
    return 0;
}

// ============================================================
// __index / __newindex
// ============================================================
static int lua_index(lua_State * L) {
    const char * key = luaL_checkstring(L, 2);
    if (strcmp(key, "is_ready") == 0)       lua_pushcfunction(L, lua_is_ready);
    else if (strcmp(key, "get_scores") == 0) lua_pushcfunction(L, lua_get_scores);
    else if (strcmp(key, "get_ce3") == 0)    lua_pushcfunction(L, lua_get_ce3);
    else if (strcmp(key, "get_seg") == 0)    lua_pushcfunction(L, lua_get_seg);
    else if (strcmp(key, "get_ctx_used") == 0) lua_pushcfunction(L, lua_get_ctx_used);
    else if (strcmp(key, "prep_hit") == 0)   lua_pushboolean(L, g_last_prep_hit ? 1 : 0);
    else if (strcmp(key, "score") == 0)     lua_pushcfunction(L, lua_score);
    else if (strcmp(key, "prepare") == 0)   lua_pushcfunction(L, lua_prepare);
    else if (strcmp(key, "llm_context") == 0)    lua_pushcfunction(L, lua_llm_context);
    else if (strcmp(key, "kick_context") == 0)   lua_pushcfunction(L, lua_kick_context);
    else if (strcmp(key, "edit_reset_context") == 0) lua_pushcfunction(L, lua_edit_reset_context);
    else if (strcmp(key, "fg_changed") == 0)     lua_pushcfunction(L, lua_fg_changed);
    else if (strcmp(key, "click_happened") == 0) lua_pushcfunction(L, lua_click_happened);
    else if (strcmp(key, "live_write") == 0)     lua_pushcfunction(L, lua_live_write);
    else if (strcmp(key, "async_submit") == 0)   lua_pushcfunction(L, lua_async_submit);
    else if (strcmp(key, "async_wait") == 0)     lua_pushcfunction(L, lua_async_wait);
    else if (strcmp(key, "async_poll") == 0)     lua_pushcfunction(L, lua_async_poll);
    else if (strcmp(key, "async_cancel") == 0)   lua_pushcfunction(L, lua_async_cancel);
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
    else if (strcmp(key, "log_dir") == 0) {
        g_log_dir = luaL_checkstring(L, 3);  // RIME 用户目录 llm_rerank 子目录
        // 2026-11-21 记录文件收进子目录：设置目录时顺手确保存在（已存在
        // 无害），dll 侧 debug 写入不致因目录缺失回退 %TEMP%
        if (!g_log_dir.empty() && g_log_dir.size() < MAX_PATH)
            CreateDirectoryA(g_log_dir.c_str(), nullptr);
    }
    return 0;
}

// ============================================================
// N-gram 组句器（2026-11-23 整句模式第②段）
// ============================================================
// 词表 = 方案词典（码）+ essay.txt（词频），模型 = 万象 LTS `.gram`。
// lua 侧负责路径解析（rime_api.get_shared_data_dir / get_user_data_dir），
// DLL 只加载一次（路径组合不变则跳过），生成走内部互斥。
namespace {
std::mutex g_ngram_mu;
rime_llm::ngram::Engine *g_ngram = nullptr;
std::string g_ngram_sig;

double ngram_opt_num(lua_State *L, int idx, const char *key, double def) {
  lua_getfield(L, idx, key);
  const double v = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : def;
  lua_pop(L, 1);
  return v;
}

int lua_ngram_load(lua_State *L) {
  const char *gram = luaL_optstring(L, 1, "");
  const char *dict_dir = luaL_checkstring(L, 2);
  const char *essay = luaL_optstring(L, 4, "");
  const char *cache = luaL_optstring(L, 5, "");
  std::vector<std::string> files;
  if (lua_istable(L, 3)) {
    const int n = (int)luaL_len(L, 3);
    for (int i = 1; i <= n; ++i) {
      lua_geti(L, 3, i);
      const char *s = lua_tostring(L, -1);
      if (s && *s) files.push_back(s);
      lua_pop(L, 1);
    }
  }
  if (files.empty()) {
    lua_pushboolean(L, 0);
    lua_pushliteral(L, "dict_files empty");
    return 2;
  }
  std::string sig = gram;
  sig += '\x1f';
  sig += dict_dir;
  sig += '\x1f';
  sig += essay;
  sig += '\x1f';
  sig += cache;
  for (size_t i = 0; i < files.size(); ++i) {
    sig += '\x1e';
    sig += files[i];
  }
  std::lock_guard<std::mutex> lk(g_ngram_mu);
  if (g_ngram && sig == g_ngram_sig) {
    lua_pushboolean(L, 1);
    return 1;
  }
  if (!g_ngram) g_ngram = new rime_llm::ngram::Engine();
  if (!g_ngram->Load(gram, dict_dir, files, essay, cache)) {
    g_ngram_sig.clear();
    lua_pushboolean(L, 0);
    lua_pushstring(L, g_ngram->error().c_str());
    return 2;
  }
  g_ngram_sig = sig;
  lua_pushboolean(L, 1);
  return 1;
}

int lua_ngram_status(lua_State *L) {
  std::lock_guard<std::mutex> lk(g_ngram_mu);
  lua_pushstring(L, g_ngram ? g_ngram->status().c_str() : "");
  return 1;
}

// ngram_sentences[_cached] 共用：参数表解析 + 结果压栈。
rime_llm::ngram::Params ngram_parse_params(lua_State *L, int idx) {
  rime_llm::ngram::Params p;
  if (lua_istable(L, idx)) {
    p.topk = (int)ngram_opt_num(L, idx, "topk", p.topk);
    p.beam = (int)ngram_opt_num(L, idx, "beam", p.beam);
    p.ctx_tail = (int)ngram_opt_num(L, idx, "ctx_tail", p.ctx_tail);
    p.max_len = (int)ngram_opt_num(L, idx, "max_len", p.max_len);
    p.min_len = (int)ngram_opt_num(L, idx, "min_len", p.min_len);
    p.collocation_penalty =
        ngram_opt_num(L, idx, "collocation_penalty", p.collocation_penalty);
    p.non_collocation_penalty =
        ngram_opt_num(L, idx, "non_collocation_penalty",
                      p.non_collocation_penalty);
    p.weak_collocation_penalty =
        ngram_opt_num(L, idx, "weak_collocation_penalty",
                      p.weak_collocation_penalty);
    p.rear_penalty = ngram_opt_num(L, idx, "rear_penalty", p.rear_penalty);
    p.min_weight = ngram_opt_num(L, idx, "min_weight", p.min_weight);
    p.max_edges = (int)ngram_opt_num(L, idx, "max_edges", p.max_edges);
  }
  return p;
}

int ngram_push_sentences(lua_State *L,
                         const std::vector<rime_llm::ngram::Sentence> &out) {
  lua_newtable(L);
  int n = 0;
  for (size_t i = 0; i < out.size(); ++i) {
    const rime_llm::ngram::Sentence &s = out[i];
    lua_newtable(L);
    lua_pushlstring(L, s.text.c_str(), s.text.size());
    lua_setfield(L, -2, "text");
    lua_pushnumber(L, s.score);
    lua_setfield(L, -2, "score");
    lua_newtable(L);
    for (size_t w = 0; w < s.words.size(); ++w) {
      lua_newtable(L);
      lua_pushlstring(L, s.words[w].word.c_str(), s.words[w].word.size());
      lua_setfield(L, -2, "w");
      lua_pushinteger(L, s.words[w].code_end);
      lua_setfield(L, -2, "e");
      lua_seti(L, -2, (lua_Integer)w + 1);
    }
    lua_setfield(L, -2, "words");
    if (!s.words.empty()) {
      lua_pushlstring(L, s.words[0].word.c_str(), s.words[0].word.size());
      lua_setfield(L, -2, "lead");
      lua_pushinteger(L, s.words[0].code_end);
      lua_setfield(L, -2, "lead_end");
    }
    lua_seti(L, -2, (lua_Integer)(++n));
  }
  return 1;
}

int lua_ngram_sentences(lua_State *L) {
  const char *code = luaL_checkstring(L, 1);
  const char *ctx = luaL_optstring(L, 2, "");
  const rime_llm::ngram::Params p = ngram_parse_params(L, 3);
  std::vector<rime_llm::ngram::Sentence> out;
  {
    std::lock_guard<std::mutex> lk(g_ngram_mu);
    if (!g_ngram) {
      lua_pushnil(L);
      return 1;
    }
    out = g_ngram->Generate(code, ctx, p);
  }
  return ngram_push_sentences(L, out);
}

// 增量组句：跨键复用逐码位剪枝 beam，结果与 Generate 逐位一致（见
// ngram.cpp 的 GenerateCached 注释）。有效性不满足自动回落全量。
int lua_ngram_sentences_cached(lua_State *L) {
  const char *code = luaL_checkstring(L, 1);
  const char *ctx = luaL_optstring(L, 2, "");
  const rime_llm::ngram::Params p = ngram_parse_params(L, 3);
  std::vector<rime_llm::ngram::Sentence> out;
  {
    std::lock_guard<std::mutex> lk(g_ngram_mu);
    if (!g_ngram) {
      lua_pushnil(L);
      return 1;
    }
    out = g_ngram->GenerateCached(code, ctx, p);
  }
  return ngram_push_sentences(L, out);
}
}  // namespace

// ============================================================
// 模块入口
// ============================================================
extern "C" __declspec(dllexport) int luaopen_rime_llm(lua_State * L) {
    lua_newtable(L);

    lua_pushcfunction(L, lua_score);
    lua_setfield(L, -2, "score");

    lua_pushcfunction(L, lua_score_full);
    lua_setfield(L, -2, "score_full");

    lua_pushcfunction(L, lua_now_ms);
    lua_setfield(L, -2, "now_ms");

    lua_pushcfunction(L, lua_prepare);
    lua_setfield(L, -2, "prepare");

    lua_pushcfunction(L, lua_is_ready);
    lua_setfield(L, -2, "is_ready");
    lua_pushcfunction(L, lua_tok_count);
    lua_setfield(L, -2, "tok_count");

    // 光标上文旁路（2026-09-10 三层上文前两层）：函数注册与 score/prepare
    // 同款（setfield 直挂，不走 __newindex 属性语义）
    lua_pushcfunction(L, lua_llm_context);
    lua_setfield(L, -2, "llm_context");

    lua_pushcfunction(L, lua_kick_context);
    lua_setfield(L, -2, "kick_context");

    lua_pushcfunction(L, lua_edit_reset_context);
    lua_setfield(L, -2, "edit_reset_context");

    lua_pushcfunction(L, lua_fg_changed);
    lua_setfield(L, -2, "fg_changed");

    lua_pushcfunction(L, lua_click_happened);
    lua_setfield(L, -2, "click_happened");

    // 实时调试行广播（2026-11-10）：函数注册同款（setfield 直挂，
    // 不走 __newindex 属性语义——可写属性预填充禁令不适用于函数）
    lua_pushcfunction(L, lua_live_write);
    lua_setfield(L, -2, "live_write");

    // 异步评分器（2026-11-22 异步基建）：submit/wait/poll/cancel 直挂
    lua_pushcfunction(L, lua_async_submit);
    lua_setfield(L, -2, "async_submit");
    lua_pushcfunction(L, lua_async_wait);
    lua_setfield(L, -2, "async_wait");
    lua_pushcfunction(L, lua_async_poll);
    lua_setfield(L, -2, "async_poll");
    lua_pushcfunction(L, lua_async_cancel);
    lua_setfield(L, -2, "async_cancel");

    // N-gram 组句器（2026-11-23 整句模式第②段）：load/sentences/status
    lua_pushcfunction(L, lua_ngram_load);
    lua_setfield(L, -2, "ngram_load");
    lua_pushcfunction(L, lua_ngram_sentences);
    lua_setfield(L, -2, "ngram_sentences");
    lua_pushcfunction(L, lua_ngram_sentences_cached);
    lua_setfield(L, -2, "ngram_sentences_cached");
    lua_pushcfunction(L, lua_ngram_status);
    lua_setfield(L, -2, "ngram_status");

    // 目录确保（2026-11-21）：llm_rerank 子目录收纳记录文件，lua 侧
    // 迁移/首写前调用（rime-lua 无 mkdir）
    lua_pushcfunction(L, lua_ensure_dir);
    lua_setfield(L, -2, "ensure_dir");

    // 编码模式匹配（2026-09-30）：取代 min_code_len/max_code_len 区间，
    // 与 Rime 自身 auto_select_pattern 同语义（全串匹配）
    lua_pushcfunction(L, lua_match_code);
    lua_setfield(L, -2, "match_code");
    lua_pushstring(L, kDefaultCodePattern);
    lua_setfield(L, -2, "default_code_pattern");

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
