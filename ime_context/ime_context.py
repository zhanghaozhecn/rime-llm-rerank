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

实现要点 (2026-08-04 重构):
  - UIA 读取用 comtypes 动态类型库 (GetModule UIAutomationCore.dll),
    不用 uiautomation 库 (其事件订阅依赖线程消息泵, 且 COM 调用
    对 Electron 等窗口可能无限挂起 → 主循环卡死 → 心跳停)。
  - 读取在独立常驻线程 (独立 COM 上下文): 挂起只影响读取线程,
    主循环 wait 超时后重建线程并标记该窗口 60s 跳过 → 心跳永不中断。
  - 输入钩子 (WH_KEYBOARD_LL/WH_MOUSE_LL) 已弃用: 实测导致全局鼠标卡顿
    (鼠标移动事件风暴触发频繁 COM 读取)。
  - 移动光标后立即打字的时序由 RIME 侧驱动: llm_processor 在第 1 码
    (输入空→非空) 写请求文件 → 外挂 ≤20ms 响应立即读取 (唯一驱动,
    无轮询) → 第 2 码 prepare 新上文 → 第 3/4 码重排用新上文。
  - 快速连打 (一码字 "a 空格 a") 的两次请求: pending 标志保持,
    读取线程忙时等待, 完成后补读, 不丢请求。
  - 心跳由每次读取写入的文件时间戳承担: 打词间隔 >30s 时心跳过期,
    RIME 回退 commit_history, 第 1 码请求后第 2 码即恢复 editor 来源。

依赖: pip install comtypes
用法: python ime_context.py [--max-chars 200]
退出: Ctrl+C (或 taskkill /f /im ime_context.exe 需定位)
"""
import argparse, os, subprocess, sys, threading, time
from pathlib import Path

RIME_DIR = Path(os.environ.get("APPDATA", "")) / "Rime"
OUT = RIME_DIR / "ime_context.txt"

# UIA 常量 (UIAutomationCore.h)
_CTL_DOCUMENT = 50030
_CTL_EDIT = 50004
_CTL_TEXT = 50020
_TEXT_PATTERN_ID = 10014
_EP_START = 0  # TextPatternRangeEndpoint.Start
_EP_END = 1    # TextPatternRangeEndpoint.End
_TU_CHAR = 0   # TextUnit.Character
_TS_DESC = 4   # TreeScope.Descendants


# ── comtypes UIA 读取 (线程内独立 COM 上下文) ──
def _read_before_caret(tp, UIA, max_chars):
    """从 TextPattern 读光标前文本。
    返回: 非空文本 / "" (真实空上文) / None (无选区或非退化全选=无焦点)。"""
    doc = tp.DocumentRange
    sels = tp.GetSelection()
    if not sels or sels.Length == 0:
        return None
    rng = sels.GetElement(0)
    # 退化检测: 非退化选区覆盖全文 (Chromium 无焦点"全选") → None
    # 退化选区 (起点==终点) 是真实光标: 空文档/光标在开头 → 正常读取返回 ""
    try:
        same_start = rng.CompareEndpoints(_EP_START, doc, _EP_START)
        same_end = rng.CompareEndpoints(_EP_END, doc, _EP_END)
        sel_degen = rng.CompareEndpoints(_EP_START, rng, _EP_END) == 0
        if same_start == 0 and same_end == 0 and not sel_degen:
            return None
    except Exception:
        pass
    front = doc.Clone()
    front.MoveEndpointByRange(_EP_END, rng, _EP_START)
    if max_chars > 0:
        try:
            front.MoveEndpointByUnit(_EP_START, _TU_CHAR, -max_chars)
        except Exception:
            pass
    text = front.GetText(-1) or ""
    # 排除换行及之前的文本: 只保留光标所在行 (最后一个换行符之后)
    # UIA GetText 行分隔符因应用而异: \n (Chromium) / \r (记事本) / \r\n → 三者都处理
    last_nl = max(text.rfind("\n"), text.rfind("\r"))
    if last_nl >= 0:
        text = text[last_nl + 1:]
    if max_chars and len(text) > max_chars:
        text = text[-max_chars:]
    return text


def _comtypes_read(hwnd, max_chars, UIA=None, cuia=None):
    """在当前线程读取光标前文本 (独立 COM 上下文)。
    返回: 非空文本 / "" (无候选或真实空上文 → 写空回退 commit_history)
          / None (有候选但读取失败/退化 → 调用方保留旧值)。
    UIA/cuia 可传入线程内已创建的实例 (避免每次重建)。"""
    if UIA is None or cuia is None:
        from comtypes.client import GetModule, CreateObject
        UIA = GetModule("UIAutomationCore.dll")
        cuia = CreateObject("{ff48dba4-60ef-4201-aa87-54103eef594e}",
                            interface=UIA.IUIAutomation)
    root = cuia.ElementFromHandle(hwnd)
    # 候选: Document/Edit/Text 控件 (深度遍历), 排序 Edit < Document < Text
    cond = cuia.CreateOrCondition(
        cuia.CreateOrCondition(
            cuia.CreatePropertyCondition(30003, _CTL_EDIT),
            cuia.CreatePropertyCondition(30003, _CTL_DOCUMENT)),
        cuia.CreatePropertyCondition(30003, _CTL_TEXT))
    arr = root.FindAll(_TS_DESC, cond)
    items = []
    for i in range(arr.Length):
        el = arr.GetElement(i)
        ct = el.CurrentControlType
        rank = 0 if ct == _CTL_EDIT else (1 if ct == _CTL_DOCUMENT else 2)
        items.append((rank, el))
    if not items:
        return ""  # 无 TextPattern 候选 (终端/不支持窗口) → 写空
    items.sort(key=lambda x: x[0])
    for rank, el in items:
        try:
            p = el.GetCurrentPattern(_TEXT_PATTERN_ID)
            tp = p.QueryInterface(UIA.IUIAutomationTextPattern)
            t = _read_before_caret(tp, UIA, max_chars)
            if t:
                return t
            if t == "":
                # 最高优先候选确认光标前为空 (空文档/光标在开头):
                # 真实空上文 → 写空。排序保证 Edit 在 Document 前。
                return ""
        except Exception:
            continue  # 退化/COMError → 尝试下一候选
    return None  # 有候选但全部读取失败/退化 → 保留旧值


# ── 常驻读取线程 (独立 COM 上下文, 挂起隔离 + 候选缓存) ──
class ReaderThread:
    """读取线程: 与主循环分离。
    - 挂起隔离: COM 调用对某些窗口 (Electron) 可能无限挂起, 只卡本线程,
      主循环 wait 超时后重建新线程 (旧线程泄漏无害)。
    - 候选缓存 (线程内): 元素列表只在首次/无候选 10s 后重建, 避免每轮
      全树遍历 (100-500ms 占 CPU → 系统卡顿); 缓存内读取仅 ~10ms。
      缓存的 element 在本线程创建使用, 无跨公寓问题。"""

    _CACHE_TTL = 10  # 无候选缓存有效期秒 (有候选缓存不过期, 读取异常自愈重建)

    def __init__(self):
        self._req = threading.Event()   # 有新任务
        self._done = threading.Event()  # 任务完成
        self._result = [None]
        self._state = {"hwnd": 0, "max_chars": 200}
        self._cache = {}  # hwnd → (候选列表, ts) 仅本线程访问
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def busy(self):
        """上一任务未完成 → 主循环跳过本轮 (限流, 避免读取风暴)"""
        return self._req.is_set()

    def submit(self, hwnd, max_chars):
        self._state["hwnd"] = hwnd
        self._state["max_chars"] = max_chars
        self._result[0] = None
        self._done.clear()
        self._req.set()

    def wait_result(self, timeout):
        """返回: 读取结果 (含 ""/None) 或 _TIMEOUT 表示超时 (线程挂起)。"""
        if not self._done.wait(timeout):
            return _TIMEOUT
        return self._result[0]

    def _collect(self, hwnd, cuia):
        """全树遍历收集候选 (Document/Edit/Text, 排序 Edit<Document<Text)。
        仅本线程调用 (缓存内 element 跨线程不可用)。"""
        root = cuia.ElementFromHandle(hwnd)
        cond = cuia.CreateOrCondition(
            cuia.CreateOrCondition(
                cuia.CreatePropertyCondition(30003, _CTL_EDIT),
                cuia.CreatePropertyCondition(30003, _CTL_DOCUMENT)),
            cuia.CreatePropertyCondition(30003, _CTL_TEXT))
        arr = root.FindAll(_TS_DESC, cond)
        items = []
        for i in range(arr.Length):
            el = arr.GetElement(i)
            ct = el.CurrentControlType
            rank = 0 if ct == _CTL_EDIT else (1 if ct == _CTL_DOCUMENT else 2)
            items.append((rank, el))
        items.sort(key=lambda x: x[0])
        return items

    def _loop(self):
        from comtypes import CoInitialize, CoUninitialize
        from comtypes.client import GetModule, CreateObject
        CoInitialize()
        try:
            UIA = GetModule("UIAutomationCore.dll")
            cuia = CreateObject("{ff48dba4-60ef-4201-aa87-54103eef594e}",
                                interface=UIA.IUIAutomation)
        except Exception:
            UIA = cuia = None
        try:
            while True:
                self._req.wait()
                self._req.clear()
                hwnd = self._state["hwnd"]
                max_chars = self._state["max_chars"]
                try:
                    # 候选缓存: 无候选 10s 重建; 有候选不过期 (读取异常自愈重建)
                    cached = self._cache.get(hwnd)
                    if cached is None or (not cached[0]
                                          and time.time() - cached[1] > self._CACHE_TTL):
                        items = self._collect(hwnd, cuia)
                        self._cache[hwnd] = (items, time.time())
                    else:
                        items = cached[0]
                    if not items:
                        self._result[0] = ""  # 无候选 (终端等) → 写空
                    else:
                        t = None
                        for rank, el in items:
                            try:
                                p = el.GetCurrentPattern(_TEXT_PATTERN_ID)
                                tp = p.QueryInterface(UIA.IUIAutomationTextPattern)
                                t = _read_before_caret(tp, UIA, max_chars)
                                if t:
                                    break
                                if t == "":
                                    break  # 最高优先候选真空 → 写空
                            except Exception:
                                t = None  # 异常 (stale) → 下一候选
                        if t == "":
                            self._result[0] = ""
                        elif t is None:
                            # 有候选但全部退化/异常 → 重建缓存 (stale 自愈) + 保留旧值
                            if cached is not None and cached[0]:
                                self._cache.pop(hwnd, None)
                            self._result[0] = None
                        else:
                            self._result[0] = t
                except Exception as e:
                    sys.stderr.write(f"[read-thread] {e}\n")
                    self._result[0] = None
                self._done.set()
        finally:
            CoUninitialize()


_TIMEOUT = object()  # wait_result 超时哨兵


# ── 单实例互斥 (防止重复启动) ──
def _acquire_single_instance(name="ime_context_mutex"):
    import ctypes
    from ctypes import wintypes
    kernel32 = ctypes.windll.kernel32
    kernel32.WaitForSingleObject.argtypes = [ctypes.c_void_p, wintypes.DWORD]
    kernel32.WaitForSingleObject.restype = wintypes.DWORD
    h = kernel32.CreateMutexW(None, False, name)
    if kernel32.GetLastError() != 183:  # 非 ALREADY_EXISTS → 新建成功
        return True
    # 互斥已存在: 探测是否被持有。
    #   0   = WAIT_OBJECT_0   无人持有 → 接管
    #   128 = WAIT_ABANDONED  所有者被强杀/崩溃遗留 (已获所有权) → 接管
    #   258 = WAIT_TIMEOUT    真被持有 (已有实例运行) → 拒绝
    return kernel32.WaitForSingleObject(h, 0) != 258


# ── 双击启动 + 开机自启: 双路径 VBS (无需终端) ──
# 服务代码路径解析顺序:
#   1. vbs 同文件夹 (双击场景: vbs 与 ime_context.py 在一起)
#   2. 生成时写死的原路径 (复制 vbs 到启动文件夹场景: vbs 在启动文件夹,
#      原文件夹路径由 {script_main} 兜底)
_VBS_LINES = [
    "' 编辑器上文服务 - 双击本文件启动; 复制本文件到启动文件夹即开机自启",
    "' 删除本文件即停止服务/取消自启",
    'Set fso = CreateObject("Scripting.FileSystemObject")',
    'base = fso.GetParentFolderName(WScript.ScriptFullName)',
    'script = ""',
    'If fso.FileExists(base & "\\{exe_name}") Then',
    '    script = base & "\\{exe_name}"',
    'ElseIf fso.FileExists("{exe_main}") Then',
    '    script = "{exe_main}"',
    'End If',
    'If script = "" Then',
    '    MsgBox "未找到 {exe_name}，请重新生成本文件", 48, "编辑器上文服务"',
    '    WScript.Quit',
    'End If',
    '{pyw_block}',
    'CreateObject("WScript.Shell").Run {run_cmd}, 0, False',
]
_VBS_TEMPLATE = "\r\n".join(_VBS_LINES) + "\r\n"

def _is_frozen():
    """PyInstaller 打包后 sys.frozen=True, sys.executable = exe 路径"""
    return getattr(sys, "frozen", False)

def _base_dir():
    """exe 版 = exe 所在目录; py 版 = 脚本所在目录"""
    if _is_frozen():
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent

_STOP_VBS_LINES = [
    "' 停止编辑器上文服务 - 双击本文件即结束服务进程",
    "' 服务占用内存 ~60MB, 停止后 LLM 重排回退 commit_history 上文",
    'CreateObject("WScript.Shell").Run "taskkill /f /im ime_context.exe", 0, True',
]

def _make_stop_vbs(target_dir=None):
    """生成 停止-编辑器上文服务.vbs (exe 版): 双击即结束服务进程"""
    target = Path(target_dir) if target_dir else _base_dir()
    out = target / "停止-编辑器上文服务.vbs"
    out.write_bytes(("\r\n".join(_STOP_VBS_LINES) + "\r\n").encode("utf-16"))
    return out

def _make_autostart_vbs(target_dir=None):
    """生成 启动-编辑器上文服务.vbs:
    双击即运行 (无窗口), 复制到启动文件夹即开机自启。
    exe 版: 运行 ime_context.exe (免 Python 依赖); py 版: pythonw 运行 ime_context.py。
    target_dir: vbs 生成目录 (None = exe/脚本同目录); 兜底路径 = target_dir 内的 exe/py。"""
    target = Path(target_dir) if target_dir else _base_dir()
    if _is_frozen():
        exe_name = Path(sys.executable).name
        body = _VBS_TEMPLATE.replace("{exe_name}", exe_name)
        body = body.replace("{exe_main}", str(target / exe_name))
        body = body.replace("{pyw_block}", "rem exe 版无需 pythonw")
        body = body.replace("{run_cmd}", '"""" & script & """"')
    else:
        exe_name = "ime_context.py"
        body = _VBS_TEMPLATE.replace("{exe_name}", exe_name)
        body = body.replace("{exe_main}", str(target / exe_name))
        # py 版: pythonw 探测
        pyw = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
        if not os.path.exists(pyw):
            pyw = sys.executable
        pyw_block = (
            'pyw = ""\r\n'
            'For Each p In Array( _\r\n'
            f'    "{pyw}", _\r\n'
            '    "C:\\Python312\\pythonw.exe", "C:\\Python\\pythonw.exe", _\r\n'
            '    "D:\\Python\\pythonw.exe", "%LOCALAPPDATA%\\Programs\\Python\\Python312\\pythonw.exe")\r\n'
            '    p = fso.BuildPath(fso.GetParentFolderName(p), fso.GetFileName(p))\r\n'
            '    If fso.FileExists(p) Then pyw = p : Exit For\r\n'
            'Next\r\n'
            'If pyw = "" Then\r\n'
            '    MsgBox "未找到 pythonw.exe，请安装 Python 或使用 exe 版", 48, "编辑器上文服务"\r\n'
            '    WScript.Quit\r\n'
            'End If')
        body = body.replace("{pyw_block}", pyw_block)
        body = body.replace("{run_cmd}", '"""" & pyw & """ """ & script & """"')
    out = target / "启动-编辑器上文服务.vbs"
    out.write_bytes(body.encode("utf-16"))  # UTF-16 LE + BOM, 中文提示安全
    return out

def install_autostart(target_dir=None):
    startup = Path(os.environ.get("APPDATA", "")) / r"Microsoft\Windows\Start Menu\Programs\Startup"
    if _is_frozen():
        # exe 版: 无需启动 vbs — 双击 exe 即启动, 复制 exe 到启动文件夹即自启
        stop_vbs = _make_stop_vbs(target_dir)
        print(f"已生成: {stop_vbs}")
        print()
        print("使用方法 (无需终端):")
        print(f"  1. 双击 ime_context.exe        → 立即启动服务")
        print(f"  2. 复制 ime_context.exe 到启动文件夹 → 开机自动启动")
        print(f"     ({startup})")
        print(f"  3. 双击 {stop_vbs.name} → 停止服务")
        print(f"  4. 删除启动文件夹中的 exe 副本 → 取消开机自启")
        print(f"  整个文件夹可以移动到任意位置")
    else:
        vbs = _make_autostart_vbs(target_dir)
        print(f"已生成: {vbs}")
        print()
        print("使用方法 (无需终端, py 版):")
        print(f"  1. 双击 {vbs.name}           → 立即启动服务")
        print(f"  2. 复制该文件到启动文件夹    → 开机自动启动")
        print(f"     ({startup})")
        print(f"  3. 删除该文件                → 停止服务/取消自启")
        print(f"  整个文件夹可以移动到任意位置 (vbs 自动定位 ime_context.py)")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=int, default=0, help="(兼容保留, 已弃用: 请求驱动模式无需轮询)")
    ap.add_argument("--max-chars", type=int, default=200, help="取光标前字符数 (默认 200)")
    ap.add_argument("--once", action="store_true", help="单次读取后打印退出 (调试)")
    ap.add_argument("--install", action="store_true", help="生成启动 vbs (无窗口后台运行)")
    ap.add_argument("--install-to", type=str, default=None,
                    help="vbs 生成到指定目录 (部署用: 服务代码与 vbs 同目录, base 命中)")
    ap.add_argument("--uninstall", action="store_true", help="移除启动 vbs")
    ap.add_argument("--stop", action="store_true",
                    help="停止服务 (exe 版: taskkill ime_context.exe; py 版: 提示用任务管理器)")
    args = ap.parse_args()

    if args.install:
        install_autostart(args.install_to)
        return
    if args.stop:
        if _is_frozen():
            # 异步杀 (含自身进程——Popen 不等待, 自身被杀后 taskkill 继续完成)
            subprocess.Popen(["taskkill", "/f", "/im", "ime_context.exe"])
            time.sleep(0.5)
            os._exit(0)
        else:
            print("py 版请用任务管理器结束 pythonw.exe (含 ime_context.py 的进程)")
        return
    if args.uninstall:
        vbs = Path(__file__).resolve().parent / "启动-编辑器上文服务.vbs"
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
            t = _comtypes_read(hwnd, args.max_chars)
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
    print(f"请求驱动模式, 光标前 {args.max_chars} 字符")
    reader = ReaderThread()
    hang = {}      # hwnd → 挂起跳过截止时间 (time.time)
    last_text = None
    last_write = 0.0
    last_changed_write = 0.0  # 变化写入限流 (打字连续变化合并)
    req_file = OUT.parent / "ime_context_req.txt"  # lua 第 1 码时写 → 立即读取
    pending = False  # 请求待处理: reader 忙时保持, 完成后补读 (快速连打不丢请求)
    while True:
        try:
            # 唯一驱动: RIME 侧 (llm_processor.lua) 第 1 码写入请求文件。
            # 无轮询——打码必然经过第 1 码, 心跳由每次读取写入的文件时间戳承担
            # (打词间隔 >30s 时心跳过期, RIME 回退 commit_history, 第 1 码
            # 请求后第 2 码即恢复 editor 来源)。
            if req_file.exists():
                try:
                    req_file.unlink()
                except OSError:
                    pass
                pending = True
            # pending 且读取线程空闲才读取; reader 忙时保持 pending (不丢请求)
            if not (pending and not reader.busy()):
                time.sleep(0.02)
                continue
            pending = False
            now = time.time()
            t_read = time.time()
            hwnd = user32.GetForegroundWindow()
            text = None
            if hwnd and hang.get(hwnd, 0) <= now:
                reader.submit(hwnd, args.max_chars)
                res = reader.wait_result(0.35)
                if res is _TIMEOUT:
                    # 读取线程挂起 (COM 卡死): 重建线程, 该窗口 60s 内跳过
                    sys.stderr.write(f"[hang] hwnd={hwnd} COM 挂起, 重建读取线程\n")
                    reader = ReaderThread()
                    hang[hwnd] = now + 60
                    text = None
                else:
                    text = res
            read_ms = (time.time() - t_read) * 1000
            # 快速连打 (一码字 "a 空格 a"): 读取完成瞬间若已有新请求
            # → 本次结果作废 (旧光标位置上文已无用), 不写文件, 立即接续读取。
            # wait_result 阻塞期间循环顶不检测请求, 故在写入前即时检查。
            # COM 串行无法打断进行中的调用, 但旧结果不落地 + 新请求零延迟接续。
            if req_file.exists():
                try:
                    req_file.unlink()
                except OSError:
                    pass
                pending = True
                sys.stderr.write("[stale] 读取结果作废 (期间有新请求)\n")
                continue
            # 读不到时的处理:
            #   None (有候选但读取失败/退化/挂起) → 保留上次有效内容
            #   "" (无候选/真实空上文) → 写空, RIME 回退 commit_history
            keep = False
            if text is None:
                text = last_text or ""
                keep = True
            changed = text != last_text
            # 心跳: 文本变化立即写 (限流 100ms, 打字连续变化合并,
            # 减少临时文件写入频率 → 降低 Defender 实时扫描干扰);
            # 无变化每 1s 写 (供 RIME 判断外挂存活)
            if (changed and now - last_changed_write >= 0.1) or now - last_write >= 1.0:
                OUT.parent.mkdir(parents=True, exist_ok=True)
                tmp = OUT.with_suffix(".tmp")
                try:
                    tmp.write_text(f"{int(now * 1000)}\t{text}", encoding="utf-8")
                    tmp.replace(OUT)
                except OSError as e:
                    sys.stderr.write(f"[write] {e}\n")
                # 诊断日志: 窗口名 | 耗时ms | 结果长度 | 类型 | 摘要 (仅变化时写)
                if changed:
                    wname = ""
                    try:
                        wname = ctypes.windll.user32.GetWindowTextW(
                            ctypes.c_void_p(hwnd),
                            (b := ctypes.create_unicode_buffer(128)), 128) and b.value or ""
                    except Exception:
                        pass
                    summary = text.replace("\n", "⏎")[:60]
                    sys.stderr.write(f"[read] {wname[:24]}|{read_ms:.0f}ms|{len(text)}字|{'KEEP ' if keep else ''}{summary}\n")
                last_text = text if text is not None else last_text
                last_write = now
                if changed:
                    last_changed_write = now
        except Exception as e:
            sys.stderr.write(f"[err] {e}\n")
        time.sleep(0.02)  # 20ms 分段: 轮询粒度

if __name__ == "__main__":
    main()
