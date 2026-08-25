# repair_tsf.ps1 — TSF 注册修复（输入法图标消失/无法切中文时使用）
# 症状：语言列表里小狼毫消失或选中无效；HKLM\...\CLSID\{A3F4CDED...}\InprocServer32
# 缺失；System32/SysWOW64 weasel.dll 缺失。
# 原理：weasel TSF 注册 = CLSID 键(指向 DLL+Apartment) + MSCTF 的 CTF\TIP 树。
#   WeaselSetup /u 删除注册后 /i 偶发静默失败（System32 DLL 被占用）→ 变砖；
#   regsvr32 / 嵌套脚本传参失败都会触发 DllRegisterServer 整体回滚（把刚写好
#   的注册删掉——回滚是注册失败时 DllUnregisterServer 的连锁，务必让注册成功）。
#   可靠做法：补复制 DLL + STA 宿主直接调 DllRegisterServer，DLL 路径烤进
#   生成的脚本（无参数传递），对应位数用对应 powershell.exe。
# 用法：右键"使用 PowerShell 运行"或双击（自动请求管理员权限）。
$ErrorActionPreference = "Continue"
$clsid = "{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}"

# 自动提权
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`""
  exit
}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$log = Join-Path $env:TEMP "llm_repair_tsf.log"
function Log([string]$t) { Write-Host $t; $t | Out-File $log -Append -Encoding utf8 }
"=== repair_tsf $(Get-Date) ===" | Out-File $log -Encoding utf8

# 定位小狼毫安装目录
$instDir = $null
foreach ($p in @("C:\Program Files\Rime\weasel-0.17.4",
                 "C:\Program Files (x86)\Rime\weasel-0.17.4",
                 "C:\Program Files\Rime\weasel-0.18.0",
                 "C:\Program Files (x86)\Rime\weasel-0.18.0")) {
  if (Test-Path (Join-Path $p "rime.dll")) { $instDir = $p; break }
}
if (-not $instDir) { Log "[错误] 未找到小狼毫安装目录"; Read-Host "按回车关闭"; exit 1 }
Log "安装目录: $instDir"

Log "[1/3] 补复制 TSF DLL"
if (-not (Test-Path "C:\Windows\System32\weasel.dll")) {
  Copy-Item (Join-Path $instDir "weaselx64.dll") "C:\Windows\System32\weasel.dll" -Force
  Log "  + System32\weasel.dll"
}
if (-not (Test-Path "C:\Windows\SysWOW64\weasel.dll")) {
  Copy-Item (Join-Path $instDir "weasel.dll") "C:\Windows\SysWOW64\weasel.dll" -Force
  Log "  + SysWOW64\weasel.dll"
}

# STA 宿主注册脚本模板（纯 ASCII；DLL 路径字符串替换烤入，无参数传递）
$regCode = @'
$ErrorActionPreference = "Continue"
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class RegSvrX {
  [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr LoadLibraryW(string path);
  [DllImport("kernel32", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr GetProcAddress(IntPtr h, string name);
  [DllImport("kernel32")]
  public static extern bool FreeLibrary(IntPtr h);
  public delegate int DRS();
  public static int Call(string p) {
    IntPtr h = LoadLibraryW(p);
    if (h == IntPtr.Zero) return -1;
    IntPtr fp = GetProcAddress(h, "DllRegisterServer");
    if (fp == IntPtr.Zero) { FreeLibrary(h); return -2; }
    int hr = Marshal.GetDelegateForFunctionPointer<DRS>(fp)();
    FreeLibrary(h); return hr;
  }
}
"@
exit ([RegSvrX]::Call("REPLACEDLL") -band 0xFFFF)
'@
function Invoke-RegDll([string]$dll, [bool]$wow64) {
  $tmp = Join-Path $env:TEMP ("llm_reg_" + [IO.Path]::GetFileName($dll) + ".ps1")
  [IO.File]::WriteAllText($tmp, $regCode.Replace("REPLACEDLL", $dll), [Text.Encoding]::ASCII)
  $exe = if ($wow64) { "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" }
         else { "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
  $p = Start-Process -FilePath $exe -ArgumentList @("-NoProfile","-STA","-ExecutionPolicy","Bypass","-File",("`"" + $tmp + "`"")) -Wait -PassThru -WindowStyle Hidden
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  return $p.ExitCode
}

Log "[2/3] 注册 (STA 宿主 DllRegisterServer)"
$r64 = Invoke-RegDll "C:\Windows\System32\weasel.dll" $false
Log ("  64 位退出码: " + $r64 + $(if ($r64 -eq 0) { " (成功)" } else { " (失败——注册未写入, 若曾存在会被回滚删除)" }))
$r32 = Invoke-RegDll "C:\Windows\SysWOW64\weasel.dll" $true
Log ("  32 位退出码: " + $r32 + $(if ($r32 -eq 0) { " (成功)" } else { " (失败)" }))

Log "[3/3] 验证"
$k64 = reg query "HKLM\SOFTWARE\Classes\CLSID\$clsid\InprocServer32" /ve 2>&1
$k32 = reg query "HKLM\SOFTWARE\Classes\WOW6432Node\CLSID\$clsid\InprocServer32" /ve 2>&1
$ok64 = ($k64 | Out-String) -match "weasel"
$ok32 = ($k32 | Out-String) -match "weasel"
Log ("  64 位注册: " + $(if ($ok64) { "OK" } else { "仍缺失" }))
Log ("  32 位注册: " + $(if ($ok32) { "OK" } else { "仍缺失" }))

if ($ok64) {
  # 挂回语言列表（weasel 固定 profile GUID = c_guidProfile，源自 WeaselTSF/Globals.cpp）
  $guid = "{3D02CAB6-2B8E-4781-BA20-1C9267529467}"
  $tip = "0804:$clsid$guid"
  Log "  挂回语言列表: $tip"
  try {
    $list = Get-WinUserLanguageList
    $zh = $list | Where-Object { $_.LanguageTag -like "zh*" } | Select-Object -First 1
    if (-not $zh) {
      # 中文语言本身被移除时先加回
      $zh = New-Object Microsoft.InternationalSettings.Commands.WinUserLanguageList("zh-Hans-CN")[0]
      $list.Add($zh)
      Log "  + 已添加中文语言 zh-Hans-CN"
    }
    if (-not ($zh.InputMethodTips -contains $tip)) {
      $zh.InputMethodTips = @($zh.InputMethodTips + $tip)
      Set-WinUserLanguageList $list -Force
      Log "  已挂回小狼毫"
    } else { Log "  语言列表已含" }
  } catch { Log ("  [提示] 语言列表设置失败: " + $_.Exception.Message + "（可手动：设置→语言→中文→添加键盘→小狼毫）") }
  Log "修复完成。若无图标：注销重登一次，或 设置→语言→中文→添加键盘→小狼毫"
} else {
  Log "修复失败：请把 %TEMP%\llm_repair_tsf.log 发给开发者"
}
Read-Host "按回车关闭"
