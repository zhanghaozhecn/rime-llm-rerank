#!/usr/bin/env python3
"""
ime_context.py — 编辑器上文外挂 (Windows UIAutomation)

问题: RIME 的 LLM 重排"上文"= commit_history (本次输入法会话上屏词),
退格/移动光标后与实际文档光标前文本不符 → LLM 命中率低。
本程序读取**活动编辑窗口光标前的文本**, 写入 %APPDATA%\\Rime\\ime_context.txt,
RIME 侧 (llm_processor.lua) 优先使用该文件作为上文。

文件格式 (TSV):
  <unix_ms 心跳时间戳>\\t<光标前文本(最近 ~200 字符)>
心跳: 文本变化立即写; 无变化每 1s 写心跳。RIME 侧 30s 内无心跳 → 回退 commit_history。

依赖: pip install uiautomation
用法: python ime_context.py [--interval 150] [--max-chars 200]
退出: Ctrl+C (或 taskkill /f /im python.exe 需定位)
"""
import argparse, os, sys, time
from pathlib import Path

import uiautomation as auto

RIME_DIR = Path(os.environ.get("APPDATA", "")) / "Rime"
OUT = RIME_DIR / "ime_context.txt"

_tp_cache = {}  # hwnd → [(element, TextPattern), ts] 候选列表缓存 (ts: 收集时间)
_prefer = {}    # hwnd → 上次成功读取的候选索引 (QQ 输入框 Edit 命中后优先试它, 免遍历 64 候选)
_CACHE_TTL = 60  # 候选列表缓存有效期秒 — 页面加载中收集的列表缺输入框 Edit,
                 # 而 Document 兜底"成功"不会触发自愈 → 定期重建 (最多延迟 60s 恢复)

# 有 selection 语义的控件类型才收集 (Document/Edit/Text), 按钮/标签等 TextPattern 无意义
_TARGET_TYPES = ("Document", "Edit", "Text")
_MAX_CANDIDATES = 64  # VS Code 等大树有数千候选, 上限防卡死; Document 优先保证主文档在首位
_MAX_NODES = 600      # DFS 访问节点上限 (QQ 聊天记录树极大, 防首次收集 4s+)

def _find_text_elements(el, depth=0, out=None, budget=None):
    """DFS 收集支持 TextPattern 且类型为 Document/Edit/Text 的后代元素
    (候选/节点双上限, Document 优先; 不可见/无矩形元素跳过)。
    深度 32: Chromium 内核 (Edge/QQ NT/VS Code) 的 UIA 树极深。
    QQ 等应用有多个文本元素 (聊天记录 Document + 输入框 Edit), 只取一个会错过
    光标所在控件 → 收集候选列表, 由读取方逐个尝试取第一个有效的。"""
    if out is None or budget is None:
        out, budget = [], [_MAX_NODES]
    if depth > 32 or budget[0] <= 0 or len(out) >= _MAX_CANDIDATES:
        return out
    budget[0] -= 1
    try:
        tp = el.GetPattern(auto.PatternId.TextPattern)
        if tp:
            ctrl = getattr(el, "ControlTypeName", "") or ""
            if any(k in ctrl for k in _TARGET_TYPES):
                try:
                    rect = el.BoundingRectangle
                    if rect.right - rect.left < 2 or rect.bottom - rect.top < 2:
                        tp = None  # 不可见元素跳过
                except Exception:
                    tp = None
                if tp is not None:
                    out.append((el, tp))
    except Exception:
        pass
    try:
        for ch in el.GetChildren():
            _find_text_elements(ch, depth + 1, out, budget)
    except Exception:
        pass
    return out

def _ctrl_type(h):
    return getattr(h[0], "ControlTypeName", "") or ""

def _order_hits(hits, hwnd):
    """候选排序: Edit (输入框) > Document (页面/编辑器) > Text (静态文本)。
    浏览器输入框的 sel 属于页面级 Document, 读取"页面开头→光标"含导航垃圾;
    Edit 候选 (搜索框/输入框自身) 的 sel 才是框内文本 → 优先。
    prefer: 上次成功候选是 Edit 才排最前 (QQ 输入框命中后免遍历);
    非 Edit (如页面 Document) 不 prefer——浏览器场景优先找真正的输入框。"""
    pi = _prefer.get(hwnd)
    if pi is not None and 0 <= pi < len(hits) and "Edit" in _ctrl_type(hits[pi]):
        hits.insert(0, hits.pop(pi))
    else:
        hits.sort(key=lambda h: 0 if "Edit" in _ctrl_type(h) else
                  (1 if "Document" in _ctrl_type(h) else 2))

def _read_before_caret(tp, max_chars):
    """用 TextPattern 读取光标前文本 (核心逻辑, 不含缓存管理)"""
    doc = tp.DocumentRange
    sels = tp.GetSelection()
    if not sels:
        return None  # 无光标/选区报告
    rng = sels[0]
    front = doc.Clone()
    front.MoveEndpointByRange(auto.TextPatternRangeEndpoint.End, rng,
                              auto.TextPatternRangeEndpoint.Start)
    if max_chars > 0:
        try:
            front.MoveEndpointByUnit(auto.TextPatternRangeEndpoint.Start,
                                     auto.TextPatternUnit.Character, -max_chars)
        except Exception:
            pass  # 起点已在文档边界 (文本短于 max_chars), 无需移动
    text = front.GetText(-1)
    # 限制返回长度 (保险)
    return text[-max_chars:] if max_chars and len(text) > max_chars else text

# ── UIA 读取光标前文本 ──
def get_text_before_caret(hwnd, max_chars):
    """UIA TextPattern.GetSelection() 定位光标 (应用自行报告, 不依赖系统 caret——
    系统 caret 在应用空闲时被销毁, GetGUIThreadInfo 不可靠)。
    遍历所有 TextPattern 候选 (QQ 等有多文档: 聊天记录+输入框), 取第一个非空读取。
    缓存失效自愈: Chromium (Edge/QQ) 页面刷新/重建时缓存的 UIA element 变 stale
    (COMError RPC_E_CALL_REJECTED), 全失败后清缓存重查一次。"""
    import time as _t
    cached = _tp_cache.get(hwnd)
    if cached is None or _t.time() - cached[1] > _CACHE_TTL:
        hits = _find_text_elements(auto.ControlFromHandle(hwnd), out=[])
        if not hits:
            return None  # 应用不支持 UIA 文本模式
        _order_hits(hits, hwnd)
        _tp_cache[hwnd] = (hits, _t.time())

    for _ in range(2):  # 第一轮走缓存, 第二轮自愈重查
        hits = _tp_cache[hwnd][0]
        for i in range(len(hits)):
            el, tp = hits[i]
            try:
                t = _read_before_caret(tp, max_chars)
                if t:
                    _prefer[hwnd] = i
                    return t
            except Exception:
                continue
        # 全候选失败/为空 → 缓存失效? 清缓存重查一次
        hits = _find_text_elements(auto.ControlFromHandle(hwnd), out=[])
        if not hits:
            return None
        _order_hits(hits, hwnd)
        _tp_cache[hwnd] = (hits, _t.time())
    return None

# ── 单实例互斥 (防止重复启动) ──
def _acquire_single_instance(name="ime_context_mutex"):
    import ctypes
    kernel32 = ctypes.windll.kernel32
    kernel32.CreateMutexW(None, False, name)
    return kernel32.GetLastError() != 183  # ERROR_ALREADY_EXISTS → False (已在运行)

# ── 开机自启: 生成 VBS (复制到启动文件夹即生效, 删文件即卸载) ──
def _make_autostart_vbs():
    """生成 ime_context-开机自启.vbs 到脚本同目录 (pythonw 无窗口运行)"""
    script = os.path.abspath(__file__)
    pyw = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
    exe = pyw if os.path.exists(pyw) else sys.executable
    # VBS: Run "exe" "script", 0=隐藏窗口, False=不等待。VBS 字符串内 "" 转义引号
    body = (f'CreateObject("WScript.Shell").Run """{exe}"" ""{script}""", 0, False\r\n'
            f"' ime_context 编辑器上文外挂开机自启\r\n' 删除本文件即取消自启\r\n")
    out = Path(__file__).resolve().parent / "ime_context-开机自启.vbs"
    out.write_bytes(body.encode("utf-16"))  # UTF-16 LE + BOM, 路径含中文也安全
    return out

def install_autostart():
    vbs = _make_autostart_vbs()
    startup = Path(os.environ.get("APPDATA", "")) / r"Microsoft\Windows\Start Menu\Programs\Startup"
    print(f"已生成: {vbs}")
    print(f"复制到启动文件夹即开机自启: {startup}")
    print("  (Win+R 输入 shell:startup 可快速打开; 删除该 vbs 即取消自启)")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=int, default=150, help="轮询间隔 ms (默认 150)")
    ap.add_argument("--max-chars", type=int, default=200, help="取光标前字符数 (默认 200)")
    ap.add_argument("--once", action="store_true", help="单次读取后打印退出 (调试)")
    ap.add_argument("--install", action="store_true", help="注册开机自启 (无窗口后台运行)")
    ap.add_argument("--uninstall", action="store_true", help="移除开机自启")
    args = ap.parse_args()

    if args.install:
        install_autostart()
        return
    if args.uninstall:
        vbs = Path(__file__).resolve().parent / "ime_context-开机自启.vbs"
        if vbs.exists():
            vbs.unlink()
            print(f"已删除 {vbs.name} (若已复制到启动文件夹, 请手动删除那边的一份)")
        else:
            print("未找到生成的 vbs (可能已删除)")
        return

    import ctypes
    user32 = ctypes.windll.user32

    if args.once:
        hwnd = user32.GetForegroundWindow()
        print(f"foreground hwnd: {hwnd}")
        if hwnd:
            t = get_text_before_caret(hwnd, args.max_chars)
            print(f"text: {repr(t)}")
        return

    if not _acquire_single_instance():
        print("ime_context 已在运行, 无需重复启动")
        return

    # 无窗口模式 (pythonw 启动): stderr → 日志文件
    err_log = OUT.parent / "ime_context.log"
    try:
        sys.stderr = open(err_log, "a", encoding="utf-8", buffering=1)
    except Exception:
        pass
    print(f"ime_context 外挂启动 → {OUT} (日志: {err_log})")
    print(f"轮询 {args.interval}ms, 光标前 {args.max_chars} 字符")
    last_text = None
    last_write = 0.0
    while True:
        try:
            now = time.time()
            t_read = time.time()
            hwnd = user32.GetForegroundWindow()
            text = None
            if hwnd:
                text = get_text_before_caret(hwnd, args.max_chars)
            read_ms = (time.time() - t_read) * 1000
            changed = (text is not None) and text != last_text
            # 心跳: 文本变化立即写; 无变化每 1s 写 (供 RIME 判断外挂存活)
            if changed or now - last_write >= 1.0:
                if text is None:
                    text = ""  # 不可读 → 写空, RIME 回退 commit_history
                OUT.parent.mkdir(parents=True, exist_ok=True)
                tmp = OUT.with_suffix(".tmp")
                tmp.write_text(f"{int(now * 1000)}\t{text}", encoding="utf-8")
                tmp.replace(OUT)
                # 诊断日志: 窗口名 | 耗时ms | 结果长度 | 内容摘要 (仅变化时写)
                if changed:
                    wname = ""
                    try:
                        wname = ctypes.windll.user32.GetWindowTextW(
                            ctypes.c_void_p(hwnd),
                            (b := ctypes.create_unicode_buffer(128)), 128) and b.value or ""
                    except Exception:
                        pass
                    summary = text.replace("\n", "⏎")[:60]
                    ptype = ""
                    try:
                        pi = _prefer.get(hwnd)
                        cached = _tp_cache.get(hwnd)
                        if pi is not None and cached:
                            ptype = _ctrl_type(cached[0][pi]).replace("Control", "")
                    except Exception:
                        pass
                    sys.stderr.write(f"[read] {wname[:24]}|{read_ms:.0f}ms|{len(text)}字|{ptype}|{summary}\n")
                last_text = text if text else last_text
                last_write = now
        except Exception as e:
            sys.stderr.write(f"[err] {e}\n")
        time.sleep(args.interval / 1000)

if __name__ == "__main__":
    main()
