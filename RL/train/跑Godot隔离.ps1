# 跑Godot隔离.ps1 —— 【2026-09-18 新增】一次性跑一个 Godot（探针 / --check-only / 手工冒烟）时的**安全入口**。
#
# 为什么必须有它（用户 2026-09-18 报告："老是弹 Godot 应用程序错误，该内存不能为 read，影响到我用电脑了"）：
#   1. **user:// 日志冲突 = signal 11 崩溃**：多个 Godot 实例共用同一个 APPDATA 时会争同一个
#      `user://logs/godot<时间戳>.log`，实测直接 `CrashHandlerException: Program crashed with signal 11`
#      （训练器早就为此给每个 worker 分配独立 APPDATA，见 RlTrain.ps1 的 `[par] appdata=`）。
#   2. **崩溃弹窗打断用户**：加 `--disable-crash-handler` ⇒ Godot 不再弹自己的崩溃窗（日志照旧写）。
#   ⇒ 所以**任何**手工起的 Godot 都该走这个脚本，而不是直接调 Godot 可执行文件。
#
# 用法：
#   & RL\train\跑Godot隔离.ps1 -Args '--headless','--path',(Get-Location).Path,'--scene','res://RL/harness/身价探针.tscn'
#   & RL\train\跑Godot隔离.ps1 -Args '--headless','--path',(Get-Location).Path,'--check-only','--script','res://src/BattleAI.gd'
# 返回：Godot 的完整 stdout（字符串数组），退出码放在 $LASTEXITCODE。
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Args,
    [Parameter(Mandatory = $false)][string]$Tag = 'adhoc'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> 项目根
$exe = 'C:\Users\79076\Desktop\Godot_v4.7.1-stable_win64.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw ('Godot 可执行文件不存在: ' + $exe) }

# 独立 APPDATA（每次一个新目录）⇒ 不与其他实例争 user:// 日志
# ⚠️ 例外：`--check-only` **不能**用独立 APPDATA —— 实测会报 `Compile Error: Identifier not found:
#    GameState`（autoload/全局类要靠项目侧 `.godot/global_script_class_cache.cfg` 解析，全新 user 目录会让
#    Godot 先重扫、扫描期间标识符解析不了）⇒ `--check-only` 走默认 APPDATA（串行跑，不会有日志冲突）。
$needIsolation = -not (@($Args) -contains '--check-only')
$sand = Join-Path $env:TEMP ('dsh_godot_adhoc_' + $Tag + '_' + (Get-Random))
if ($needIsolation) { New-Item -ItemType Directory -Force -Path $sand | Out-Null }
$oldApp = $env:APPDATA; $oldLocal = $env:LOCALAPPDATA
if ($needIsolation) { $env:APPDATA = $sand; $env:LOCALAPPDATA = $sand }

# --disable-crash-handler：不弹崩溃窗（日志仍写）
$argv = @('--disable-crash-handler') + $Args
$quoted = ($argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
try {
    $out = cmd /c ('"' + $exe + '" ' + $quoted + ' 2>&1')
    return $out
} finally {
    $env:APPDATA = $oldApp; $env:LOCALAPPDATA = $oldLocal
    if ($needIsolation) { Remove-Item -LiteralPath $sand -Recurse -Force -ErrorAction SilentlyContinue }
}
