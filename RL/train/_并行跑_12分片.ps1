# _并行跑_12分片.ps1 —— 【2026-09-25】把两个批切成 12 条分片并行跑（12 核跑满）。
#
# 为什么需要它：
#   `队伍车轮战.ps1` 与 `英雄换一法.ps1` 都是**一次一个格子**地串行调用 `Train.ps1`
#   （一个格子只有 1~2 局 ⇒ `-Workers 6` 实际只起 1 个 worker）。实测串行速率约 1~2 分钟/格：
#     · pool4 960 格 ⇒ 约 20~30 小时；`英雄换一法` 135 对 × 2 格 ⇒ 约 9 小时。
#   两条脚本都自带 resume（同一 run 名重跑会跳过已测格）⇒ 直接切分片并行是安全的。
#
# 切法：
#   · 池子批用自带的 `-OnlyOpp k`（1..8）：每条链只跑"第 k 个对手"那一列 = 120 格。
#   · 换一法用 `-Shard k -Shards 4`：轮转切片 ⇒ 每个分片都覆盖全部 8 个换入英雄。
#   ⇒ 8 + 4 = 12 个进程，与 12 个逻辑核一一对应。
#
# ⚠️ 池子批**不要**写生产池：每条链只看到 8 个对手里的 1 个（排名是半成品）。
#   ⇒ 每条链写到 `_pool4_part_o<k>.json`（临时），等全跑完再
#     `队伍车轮战.ps1 -Tag pool4 -SkipRuns -WritePool -PoolOut <目标>` 统一排名。
#
# ⚠️ 用 `Start-Process` 而不是 `Start-Job`：本机沙箱禁命名管道，`Start-Job` 的子宿主起不来
#   （实测 12 个 job「已启动」但一个 godot 都没起来、CPU 15%）。
#
# 用法：& RL\train\_并行跑_12分片.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> RL -> 项目根
Set-Location $root
$res = Join-Path $root 'RL\train\results'

function Start-Shard([string]$name, [string]$argline) {
    $out = Join-Path $res ("_log_{0}.txt" -f $name)
    $err = Join-Path $res ("_log_{0}.err.txt" -f $name)
    $p = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass ' + $argline)
    Write-Host ("[并行] {0} 已起 pid={1}" -f $name, $p.Id)
    return $p
}

$procs = @()
foreach ($k in 1..8) {
    $arg = ('-File "{0}" -Cands 120 -Tag pool4 -Workers 1 -Beam 100 -SeedStart 10041 -OnlyOpp {1} -PoolOut "RL\train\results\_pool4_part_o{1}.json"' -f `
        (Join-Path $root 'RL\train\队伍车轮战.ps1'), $k)
    $procs += Start-Shard ("pool4_o{0}" -f $k) $arg
}
foreach ($k in 0..3) {
    $arg = ('-File "{0}" -Workers 1 -Tag swap1 -Shard {1} -Shards 4' -f `
        (Join-Path $root 'RL\train\英雄换一法.ps1'), $k)
    $procs += Start-Shard ("swap1_s{0}" -f $k) $arg
}
Write-Host ("[并行] 共 {0} 个分片；日志 {1}\_log_*.txt" -f $procs.Count, $res)
while ($true) {
    $alive = @($procs | Where-Object { -not $_.HasExited })
    if ($alive.Count -eq 0) { break }
    Start-Sleep -Seconds 300
    Write-Host ("[并行] {0}/{1} 仍在跑（{2}）" -f $alive.Count, $procs.Count, (Get-Date -Format 'HH:mm'))
}
Write-Host '[并行] 全部分片结束'
