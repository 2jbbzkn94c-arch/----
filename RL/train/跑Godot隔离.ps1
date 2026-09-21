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
    [Parameter(Mandatory = $false)][string]$Tag = 'adhoc',
    [Parameter(Mandatory = $false)][int]$TimeoutSec = 900
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> 项目根

# 【2026-09-19 改·用户批准"自动"】Godot 可执行**自动探测**（原来写死桌面路径；用户把 Godot
#   移到 Documents 后这里直接抛"不存在"）。顺序：环境变量 → 常见位置（顶层 exe 与其同名子目录里的 exe）
#   → 排除 *_console.exe → 文件名倒序取最新版本。找不到才抛错（提示可用环境变量指定）。
function Find-GodotExe {
    foreach ($v in @($env:DSH_GODOT_EXE, $env:GODOT_EXE)) {
        if ($v -and (Test-Path -LiteralPath $v)) { return (Resolve-Path -LiteralPath $v).Path }
    }
    $roots = @("$env:USERPROFILE\Documents", "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", 'D:\Software', 'C:\', 'D:\')
    $hits = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $hits += @(Get-ChildItem -LiteralPath $r -Filter 'Godot*.exe' -File -ErrorAction SilentlyContinue)
        $hits += @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Filter 'Godot*.exe' -File -ErrorAction SilentlyContinue })
    }
    $cand = @($hits | Where-Object { $_.Name -notlike '*_console*' } | Sort-Object Name -Descending)
    if ($cand.Count -gt 0) { return $cand[0].FullName }
    return $null
}
$exe = Find-GodotExe
if (-not $exe) { throw '找不到 Godot 可执行文件；可用环境变量 DSH_GODOT_EXE 指定绝对路径。' }
Write-Host ('[跑Godot隔离] Godot = ' + $exe)

# 独立 APPDATA（每次一个新目录）⇒ 不与其他实例争 user:// 日志
# ⚠️ 例外：`--check-only` **不能**用独立 APPDATA —— 实测会报 `Compile Error: Identifier not found:
#    GameState`（autoload/全局类要靠项目侧 `.godot/global_script_class_cache.cfg` 解析，全新 user 目录会让
#    Godot 先重扫、扫描期间标识符解析不了）⇒ `--check-only` 走默认 APPDATA。
$needIsolation = -not (@($Args) -contains '--check-only')
$sand = Join-Path $env:TEMP ('dsh_godot_adhoc_' + $Tag + '_' + (Get-Random))
if ($needIsolation) { New-Item -ItemType Directory -Force -Path $sand | Out-Null }
$oldApp = $env:APPDATA; $oldLocal = $env:LOCALAPPDATA
if ($needIsolation) { $env:APPDATA = $sand; $env:LOCALAPPDATA = $sand }

# 【2026-09-20 修·负控实测发现】**总是显式给 `--log-file`**。
#   踩的坑：用户游戏开着时（check-only 必须共用默认 APPDATA，见上），Godot 在**启动阶段**就报
#     `ERROR: Failed to open 'user://logs/godot<时间戳>.log'.`（dir_access.cpp:429 的日志轮转）
#   然后**直接退出** —— 一个字节都不打印 ⇒ `--check-only` 退化成"**永远通过**"的假仪器
#   （我拿一份故意写坏的脚本当负控，它照样报 0 问题；加 --log-file 后立刻报出 Parse Error）。
#   显式 --log-file 绕开 user://logs 的轮转 ⇒ 自检才真的跑到解析那一步。
if (-not (@($Args) -contains '--log-file')) {
    $logPath = if ($needIsolation) { Join-Path $sand 'godot_run.log' }
               else { Join-Path $env:TEMP ('dsh_godot_' + $Tag + '_' + (Get-Random) + '.log') }
    $Args = @('--log-file', $logPath) + $Args
}

# --disable-crash-handler：不弹崩溃窗（日志仍写）
$argv = @('--disable-crash-handler') + $Args
$quoted = ($argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
# 【2026-09-19 重写·硬超时 + 可拿到输出】三种写法实测对比（同一台机、同一受限环境）：
#   · `cmd /c "exe … 2>&1"`（调用运算符，同步）           → ✅ 2~4 秒返回、输出正常（原版就是这么干的）
#   · `Start-Job { cmd /c … }` + `Wait-Job -Timeout`      → ✅ 同上，且**能限时**
#   · `Start-Process -RedirectStandardOutput/-PassThru`   → ❌ 进程没起来/立刻返回，`Wait-Process` 抛错，
#                                                            输出一个字节都拿不到（实测踩了三次）
#   ⇒ 用 **Start-Job**：既能拿到输出，又能到点停。Godot 的 Windows 主程序是 GUI 子系统程序，
#     只有"继承到控制台"时才输出 ⇒ 里面仍走 `cmd /c`。
$timedOut = $false
$tout = if ($PSBoundParameters.ContainsKey('TimeoutSec')) { [int]$TimeoutSec } else { 900 }
try {
    $job = Start-Job -ScriptBlock {
        param($exePath, $argLine, $sandDir, $isolate)
        if ($isolate -and $sandDir) { $env:APPDATA = $sandDir; $env:LOCALAPPDATA = $sandDir }
        & cmd /c ('"' + $exePath + '" ' + $argLine + ' 2>&1')
    } -ArgumentList $exe, $quoted, $sand, $needIsolation
    if (Wait-Job $job -Timeout $tout) {
        $lines = @(Receive-Job $job)
    } else {
        $timedOut = $true
        Stop-Job $job -ErrorAction SilentlyContinue
        # 任务里的 cmd 被杀，Godot 不一定跟着死 ⇒ 按"没有窗口标题"把 headless Godot 收拾干净
        # （绝不碰用户带窗口的编辑器/游戏；今晚我已经误杀过一个编辑器窗口，这条判据就是为此加的）。
        foreach ($g in @(Get-Process -Name 'Godot*' -ErrorAction SilentlyContinue)) {
            if (-not ($g.MainWindowTitle -and ([string]$g.MainWindowTitle).Length -gt 0)) {
                try { Stop-Process -Id $g.Id -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        Write-Warning ("[跑Godot隔离] 超时 {0}s：已停掉任务及其 headless Godot（下面附 Godot 自己的日志）" -f $tout)
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($timedOut) {
        $logs = @()
        if ($needIsolation -and $sand -and (Test-Path -LiteralPath $sand)) {
            $logs = @(Get-ChildItem -LiteralPath $sand -Recurse -Filter 'godot*.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
        }
        if ($logs.Count -gt 0) {
            $lines += ('--- godot.log: ' + $logs[0].FullName + ' ---')
            $lines += [System.IO.File]::ReadAllLines($logs[0].FullName, [System.Text.Encoding]::UTF8)
        } else {
            $lines += '(超时且找不到 godot.log)'
        }
    }
    return $lines
} finally {
    $env:APPDATA = $oldApp; $env:LOCALAPPDATA = $oldLocal
    if ($needIsolation -and $sand -and (Test-Path -LiteralPath $sand)) {
        if ($timedOut) { Write-Warning ('[跑Godot隔离] 超时：保留现场目录 ' + $sand) }
        else { Remove-Item -LiteralPath $sand -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
