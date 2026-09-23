# 依次跑「待办 B 类」剂量批 —— 先等前一个批（默认 poison / T25）跑完，再逐个模式串行跑。
# 为什么串行：`难度体检` 每次开 6 个 Godot worker 已经把机器吃满，两个批并行只会互相拖慢、
#   而且两批都写 `RL\train\results` ⇒ 读数会互相污染。
#
# ⚠️ 2026-09-24 踩过的坑（第一版因此提前开跑、与 T25 撞在一起）：判断"前一批还在不在写"时，
#   **不能**用 `Get-ChildItem -Path '<目录>\前缀_*' -Recurse -File` —— PowerShell 5.1 这个组合
#   会**返回 0 个文件**（通配符路径 + `-Recurse -File`），于是每一分钟都判定"无写入"、
#   10 分钟后误判"前一批已停"。⇒ 必须先列目录、再逐个 `-Recurse -File`（见下面 `Get-LatestWrite`），
#   并且再加一道"还有 headless Godot 在跑就不抢"的闸门。
#
# 用法：& RL\train\待办批_顺序跑.ps1            # 跑默认那 7 个模式
#       & RL\train\待办批_顺序跑.ps1 -Modes dedup,shield
# 每个模式的完整输出同时存到 RL\train\results\chain_<模式>.log。
param(
    [string[]]$Modes = @('dedup', 'shield', 'taunt', 'apply', 'split', 'spread', 'hpacc'),
    [string]$WaitPath = '',                    # 等这个**文件**（相对 RL\train\results）出现；空 = 退回用 $WaitFor 的 measure.csv
    [string]$WaitFor = 'ladder6_pois2_L6PO',   # 等这个 run 的 measure.csv 出现（= 前一批最后一组跑完）
    [string]$WatchPrefix = 'ladder6_pois2_',   # 盯这个前缀的目录，看还有没有新写入
    [int]$StallMin = 25,                       # 连续这么多分钟没有任何写入 ⇒ 才判定"前一批已停"
    [int]$WaitMaxMin = 240
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$res = Join-Path $root 'RL\train\results'

# 稳健取"最近一次写入时间"（避开上面记的那个 PowerShell 5.1 坑）
function Get-LatestWrite([string]$dir, [string]$prefix) {
    $latest = $null
    foreach ($d in @(Get-ChildItem $dir -Directory -Filter ($prefix + '*') -ErrorAction SilentlyContinue)) {
        foreach ($f in @(Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($null -eq $latest -or $f.LastWriteTime -gt $latest) { $latest = $f.LastWriteTime }
        }
    }
    return $latest
}
function Get-HeadlessGodotCount() {
    return @(Get-Process -Name 'Godot*' -ErrorAction SilentlyContinue |
        Where-Object { [string]::IsNullOrEmpty($_.MainWindowTitle) }).Count
}

# 【2026-09-24 修】等什么：优先 `-WaitPath` 指定的哨兵文件（相对 RL\train\results）。
#   为什么加它：等 `L6PO\measure.csv` 有个竞态 —— T25 的第 6 组**可能因为组级硬超时没产出 measure.csv**
#   （2026-09-24 实测：第 2 组撞 `-TimeoutSec 300 ⇒ 组级预算 300×2+300 = 900s` 被砍掉一半工人、
#   `refusing to merge` ⇒ 那一组没有表），这时链会在"停写 25 分钟 + 无 headless Godot"那一刻
#   **抢跑**，正好撞上我随后补跑那几组的进程 ⇒ 12 个 worker 抢 12 核。哨兵文件把"T25 真的补完了"
#   这件事变成显式信号，人（我）补完再落这个文件。
$waitPath = if ($WaitPath) { Join-Path $res $WaitPath } else { Join-Path $res ($WaitFor + '\measure.csv') }
$t0 = Get-Date
Write-Host ('[chain] 启动 ' + $t0.ToString('HH:mm:ss') + ' · 等 `' + $waitPath + '`（上限 ' + $WaitMaxMin + ' 分钟；停写 ' + $StallMin + ' 分钟且无 headless Godot 才判停）')
while ($true) {
    if (Test-Path $waitPath) { Write-Host '[chain] 前一批已完成 ✓'; break }
    if (((Get-Date) - $t0).TotalMinutes -gt $WaitMaxMin) { Write-Host '[chain] ⚠️ 等太久 ⇒ 直接开始'; break }
    $latest = Get-LatestWrite $res $WatchPrefix
    $idle = if ($null -eq $latest) { 999.0 } else { ((Get-Date) - $latest).TotalMinutes }
    $gd = Get-HeadlessGodotCount
    if ($idle -gt $StallMin -and $gd -eq 0) {
        Write-Host ('[chain] ⚠️ 前一批停写 {0:N0} 分钟（最后写入 {1}）且无 headless Godot ⇒ 判定已停，直接开始' -f $idle, $(if ($null -eq $latest) { '无' } else { $latest.ToString('HH:mm:ss') }))
        break
    }
    Start-Sleep -Seconds 60
}
foreach ($m in $Modes) {
    $tag = 'b' + $m
    $log = Join-Path $res ('chain_' + $m + '.log')
    Write-Host ('[chain] ===== 开始 -Mode ' + $m + ' -Tag ' + $tag + '  @ ' + (Get-Date).ToString('HH:mm:ss') + ' =====')
    # ⚠️ `-TimeoutSec 900` **必须显式给**：`难度体检` 默认 300，而组级硬预算是 `TimeoutSec*2+300` = 900s
    #   ⇒ 慢牌组（如 hero_03,hero_24,hero_09 实测每组要 ~1300s）会在半途被砍、`refusing to merge`，
    #   那一组**没有 measure.csv**（T25 第 2 组就是这么丢的）。900 ⇒ 组级 2100s，留足余量。
    & (Join-Path $PSScriptRoot '难度体检.ps1') -Mode $m -Tag $tag -TimeoutSec 900 *>&1 | Tee-Object -FilePath $log | Out-Null
    Write-Host ('[chain] ===== 结束 -Mode ' + $m + '  @ ' + (Get-Date).ToString('HH:mm:ss') + '（输出：' + $log + '）=====')
}
Write-Host ('[chain] 全部模式跑完 @ ' + (Get-Date).ToString('HH:mm:ss'))