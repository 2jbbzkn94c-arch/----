# 自进化 · 守护：等隔壁训练跑完，自动开始"全流程"（用户 2026-10-03 睡前指令：
#   「我旁边在跑训练，你等他跑完就可以开始，我去睡觉了」）
#
# 判据（为什么不用 RUNNING.lock 单独当判据 —— 实测有 9 个**残留锁**：evo_s7_r1/evo_s11_r1/nm1_Ah/
#   nm1_C/swapall_* 等，那些批早就结束了，只看锁会等到天亮）：
#   ① **无窗口标题的 Godot = 0**（无窗口 = 跑批进程；带标题的是用户自己的编辑器/游戏，不算冲突，也不去碰它）
#   ② `RL\train\results` 下**最近 3 分钟没有任何文件被写**（覆盖"两批之间的空档"）
#   ③ **30 分钟内的新锁** = 0（老锁不算）
#   三条同时成立并**连续 `-QuietPolls` 次**才开跑。
#
# 开跑时给训练器设槽位：`RL_SLOT_MAX=10`（12 核留 2 核给用户）+ 耐心参数（万一隔壁又开批，
#   我的批会**等**而不是整批中止）。
#
# 用法：powershell -File RL\自进化\等空了就跑.ps1 [-Seeds 100] [-Workers 12] [-AceSeeds 32] [-AbSeeds 32]
param(
    [int]$PollSec = 120, [int]$QuietPolls = 3, [int]$MaxWaitMin = 720,
    [int]$Seeds = 100, [int]$Workers = 12, [int]$AceSeeds = 32, [int]$AbSeeds = 32,
    [string]$LogPath = "RL\自进化\等空了就跑.log"
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root

function Say([string]$m) {
    $line = (Get-Date -Format 'MM-dd HH:mm:ss') + '  ' + $m
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

function Get-State {
    $all = @(Get-Process -Name 'Godot*' -ErrorAction SilentlyContinue)
    $batch = @($all | Where-Object { -not $_.MainWindowTitle })
    $win = @($all | Where-Object { $_.MainWindowTitle })
    $recent = @(Get-ChildItem 'RL\train\results' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-3) })
    $freshLock = @(Get-ChildItem 'RL\train\results' -Recurse -Depth 2 -Filter 'RUNNING.lock' -ErrorAction SilentlyContinue |
                   Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt 30 })
    $who = $recent | Group-Object { $_.Directory.Parent.Name } | Sort-Object Count -Descending | Select-Object -First 1
    [pscustomobject]@{
        batch = $batch.Count; win = $win.Count; recent = $recent.Count; lock = $freshLock.Count
        who = $(if ($who) { [string]$who.Name + '(' + $who.Count + ')' } else { '-' })
    }
}

Say ("===== 守护启动（PID " + $PID + "）：等隔壁训练跑完 =====")
Say ("判据：无窗口 Godot=0 · 近 3 分钟无写入 · 30 分钟内无新锁 ⇒ 连续 " + $QuietPolls + " 次（每 " + $PollSec + "s 探一次）")
Say ("跑什么：全流程.ps1 -Seeds " + $Seeds + " -Workers " + $Workers + " -AbSeeds " + $AbSeeds + " -AceSeeds " + $AceSeeds +
     "（预计 3 小时：采数据 " + ($Seeds * 4) + " 局 → 拟合闸门 → A/B " + ($AbSeeds * 4) + " 局 → 验收 " + ($AceSeeds * 4) + " 局）")

$quiet = 0
$t0 = Get-Date
while (((Get-Date) - $t0).TotalMinutes -lt $MaxWaitMin) {
    $s = Get-State
    if ($s.batch -eq 0 -and $s.recent -eq 0 -and $s.lock -eq 0) {
        $quiet++
        Say ("空闲 " + $quiet + "/" + $QuietPolls + "（批进程 0 · 近3分钟写入 0 · 新锁 0 · 你的窗口 " + $s.win + " 个）")
        if ($quiet -ge $QuietPolls) { break }
    } else {
        if ($quiet -gt 0) { Say "又忙起来了 ⇒ 重新计时" }
        $quiet = 0
        Say ("还在忙：批进程 " + $s.batch + " · 近3分钟写入 " + $s.recent + " (" + $s.who + ") · 新锁 " + $s.lock)
    }
    Start-Sleep -Seconds $PollSec
}
if ($quiet -lt $QuietPolls) {
    Say ("等超时（" + $MaxWaitMin + " 分钟）⇒ 今晚不跑，等你回来发话")
    exit 3
}

# 槽位与耐心：12 核留 2 核；隔壁若又开批 ⇒ 我的批等（单轮 60s × 120 轮 = 2 小时耐心）
$env:RL_SLOT_MAX = '10'
$env:RL_SLOT_ROUNDS = '120'
$env:RL_SLOT_SLEEP_S = '60'
Say "机器空了 ⇒ 开始 全流程.ps1（RL_SLOT_MAX=10）"
powershell -NoProfile -ExecutionPolicy Bypass -File "RL\自进化\全流程.ps1" -Seeds $Seeds -Workers $Workers -AceSeeds $AceSeeds -AbSeeds $AbSeeds 2>&1 |
    ForEach-Object { Say ([string]$_) }
Say ("全流程结束（子进程退出码 " + $LASTEXITCODE + "）⇒ 读数见上；账本 RL\自进化\账本.jsonl")
