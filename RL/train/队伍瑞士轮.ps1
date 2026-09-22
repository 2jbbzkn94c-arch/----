# 队伍瑞士轮.ps1 —— 【2026-09-22 新增·用户拍板"③ 再加一轮瑞士轮自对抗"】
#
# 干什么：让**候选队伍互相打**（瑞士制：每轮按当前战绩把名次相近的配对），得到一份
#   **不依赖外部对手**的相对强度排名 —— 用来和第二套证据（车轮战的 8 支固定对手 + Bradley-Terry
#   拟合，见 队伍强度拟合.ps1）交叉验证：
#     用户原话：「我觉得你打 8 个随机队伍的胜率去确定一个队伍强不强不太靠谱，这 8 个队伍可能
#     非常的烂，你胜率高也不代表强」⇒ 两套口径都同意的候选才进池子。
#
# 口径：
#   · 候选 = **车轮战那一批**（从 `-DumpCandidates` 导出的 json 读，保证两处生成器不漂移）。
#   · 每轮：排序（累计胜场 desc → 累计 pts desc → 候选序号 asc）→ **相邻配对**（瑞士制），
#     **不重赛**（打过的对子跳过、往后找；实在找不到就放宽允许重赛）。
#   · **换边**：奇数轮 A 当敌方、偶数轮对调（否则"谁当敌方"这一侧别优势会污染名次）。
#   · 每轮共用一个种子（index = `-SeedStart + 轮次 − 1`）：同一张盘面上所有配对一起打 ⇒ 配对公平；
#     不同轮换盘面 ⇒ 降低"单张盘面"偏差。
#   · 断点续跑：`results/<Tag>_r<轮>_p<序>/measure.csv` 存在即跳过（Train.ps1 自带 resume）。
#   · 轮间**必须同步**（下一轮的配对依赖本轮全部结果）⇒ 本脚本自己按 `-Groups` 分块并用
#     `Start-Process` 起子进程，**轮询等齐**再进下一轮（`Wait-Process` 在本项目的沙箱里会被拒绝）。
#
# 用法：
#   & RL\train\队伍瑞士轮.ps1 -Rounds 6 -Groups 8            # 跑 6 轮、每轮 8 路并行
#   & RL\train\队伍瑞士轮.ps1 -StandingsOnly                # 只按已有结果排名，不跑
#   & RL\train\队伍瑞士轮.ps1 -Tag swiss1 -SeedStart 60
#
# 输出：每轮一张名次表 + `results\_swiss_<Tag>_standings.json`（给写池子用）。
[CmdletBinding()]
param(
    [string]$CandFile = 'RL\train\results\_cands_pool3.json',
    [string]$Tag = 'swiss1',
    [int]$Rounds = 6,
    [int]$Groups = 8,
    [int]$SeedStart = 60,
    [int]$Beam = 100,
    [int]$TimeoutSec = 3600,
    # 并发槽位：`Train.ps1` 的 `Wait-GodotSlot` 默认只放行 **1** 个无窗口 Godot
    # （`RL_SLOT_MAX` 没设 = 1）⇒ 每轮 8 个子进程会互相干等 10 分钟然后放弃（已踩）。
    # 这里按"同时跑几个子进程"传给它；跑批期间若还有别的批在跑，记得调小或先把那边停掉。
    [int]$MaxSlots = 8,
    [string]$BaseWeights = 'RL\weights\噩梦.json',
    [switch]$StandingsOnly
)
$ErrorActionPreference = 'Stop'
# 槽位与轮询间隔：子进程会继承这两个环境变量（见上方 -MaxSlots 说明）。
$env:RL_SLOT_MAX = [string][Math]::Max(1, $MaxSlots)
$env:RL_SLOT_SLEEP_S = '5'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> RL -> 项目根
$results = Join-Path $PSScriptRoot 'results'
$candPath = if ([System.IO.Path]::IsPathRooted($CandFile)) { $CandFile } else { Join-Path $root $CandFile }
if (-not (Test-Path $candPath)) {
    throw ('找不到候选文件 ' + $candPath + '：先跑  & RL\train\队伍车轮战.ps1 -Cands 120 -DeckSize 3 -Tag pool3 -DumpCandidates RL\train\results\_cands_pool3.json')
}
$cand = Get-Content $candPath -Raw -Encoding UTF8 | ConvertFrom-Json
$decks = @($cand.candidates | ForEach-Object { , (@($_.deck) -join ',') })
$nCand = $decks.Count
Write-Host ("[瑞士] 候选 {0} 支（来自 {1}）· 轮数 {2} · 每轮并行 {3} · 种子 index {4}..{5}" -f `
    $nCand, (Split-Path -Leaf $candPath), $Rounds, $Groups, $SeedStart, ($SeedStart + $Rounds - 1))

# ---------- 读某个 run 的胜负（只看 a_side=1 = 生产侧那一局）----------
function Get-CellResult([string]$Run) {
    $csv = Join-Path (Join-Path $results $Run) 'measure.csv'
    if (-not (Test-Path $csv)) { return $null }
    $rows = @(Import-Csv $csv | Where-Object { [string]$_.a_side -eq '1' })
    if ($rows.Count -eq 0) { return $null }
    $w = 0; $pts = 0.0
    foreach ($r in $rows) {
        if ([string]$r.res -eq 'W') { $w += 1 }
        $pts += [double]$r.ptsA
    }
    return @{ n = $rows.Count; w = $w; pts = $pts }
}

# ---------- 已打过的对子（跨轮累积，用于"不重赛"）----------
$pairLog = Join-Path $results ('_swisspairs_' + $Tag + '.json')
$played = @{}
if (Test-Path $pairLog) {
    $old = Get-Content $pairLog -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in @($old.pairs)) { $played[[string]$p] = $true }
    Write-Host ("[瑞士] 已有对局记录 {0} 对（续跑）" -f $played.Count)
}

# ---------- 名次结算（扫已落盘结果，可重入）----------
# 为什么要抽成函数：原来这段只写在"每轮开打前"，落盘用的也是当时那份 `$order` ⇒
#   `_swiss_<tag>_<rr>.json` 实际是**本轮开打前**的快照（比文件名少一轮），
#   而且末轮那份 `_final.json` 会整轮丢失第 6 轮的结果（2026-09-22 发现）。
#   现在"每轮开打前"与"收尾"都调它 ⇒ 收尾那份是**全量重算**。
function Get-Standings {
    param([int]$MaxRound)
    $st = @()
    for ($i = 0; $i -lt $nCand; $i++) { $st += [pscustomobject]@{ idx = ($i + 1); w = 0; n = 0; pts = 0.0 } }
    for ($r2 = 1; $r2 -le $MaxRound; $r2++) {
        $rr2 = '{0:D2}' -f $r2
        for ($p = 1; $p -le [int][Math]::Ceiling($nCand / 2); $p++) {
            $pp = '{0:D2}' -f $p
            $run = '{0}_r{1}_p{2}' -f $Tag, $rr2, $pp
            $meta = Join-Path $results ('_swissmeta_' + $run + '.json')
            if (-not (Test-Path $meta)) { continue }
            $m = Get-Content $meta -Raw -Encoding UTF8 | ConvertFrom-Json
            $res = Get-CellResult $run
            if ($null -eq $res) { continue }
            # ⚠️ 结算口径（2026-09-22 修）：本批 `asides=@('e')` ⇒ 只认 a_side=1 那一局，
            #    而 **A = `decks.enemy` 那一支**（见 _瑞士轮单批.ps1 的 spec 与 对局.gd:106），
            #    `res` 又是 **A 视角**（对局.gd:138「统一按 A 方视角打印」）。
            #    谁当敌方**每轮对调**（奇数轮 a 当敌方、偶数轮 b）⇒ 必须认 meta 的 enemy/player，
            #    不能把 `res.w` 想当然记到 a 头上（记反的话偶数轮名次整体反过来）。
            $en = [int]$m.enemy; $pl = [int]$m.player
            $st[$en - 1].n += $res.n; $st[$pl - 1].n += $res.n
            $st[$en - 1].w += $res.w; $st[$pl - 1].w += ($res.n - $res.w)
            $st[$en - 1].pts += $res.pts
            $st[$pl - 1].pts += (-1.0 * $res.pts)
        }
    }
    return @($st | Sort-Object -Property @{ Expression = 'w'; Descending = $true }, @{ Expression = 'pts'; Descending = $true }, @{ Expression = 'idx'; Descending = $false })
}
function Write-Standings([object[]]$order, [int]$round, [string]$path) {
    $out = [ordered]@{
        _说明 = '瑞士轮名次。w=胜场、n=局数、pts=配对分差累计（对手视角取负）。每轮那份是**该轮开打前**的快照；`_final.json` 是全量重算。'
        tag = $Tag; 轮次 = $round; 生成时间 = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        rows = @($order | ForEach-Object { [ordered]@{ idx = $_.idx; w = $_.w; n = $_.n; pts = [Math]::Round($_.pts, 2); deck = $decks[$_.idx - 1] } })
    }
    [System.IO.File]::WriteAllText($path, ($out | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
}

# ---------- 逐轮 ----------
for ($round = 1; $round -le $Rounds; $round++) {
    $rr = '{0:D2}' -f $round
    # 1) 名次：累计（所有已完成轮次）
    # 2) 瑞士配对：按名次相邻配，跳过打过的对子
    $order = Get-Standings -MaxRound $Rounds
    $used = @{}
    $pairs = @()
    for ($i = 0; $i -lt $order.Count; $i++) {
        if ($used.ContainsKey($i)) { continue }
        $j = $i + 1
        while ($j -lt $order.Count) {
            if (-not $used.ContainsKey($j)) {
                $a0 = [Math]::Min($order[$i].idx, $order[$j].idx); $b0 = [Math]::Max($order[$i].idx, $order[$j].idx)
                if (-not $played.ContainsKey("$a0|$b0")) { break }
            }
            $j++
        }
        if ($j -ge $order.Count) {   # 找不到没打过的 ⇒ 放宽（允许重赛）
            $j = $i + 1
            while ($j -lt $order.Count -and $used.ContainsKey($j)) { $j++ }
        }
        if ($j -lt $order.Count) {
            $used[$i] = $true; $used[$j] = $true
            $pairs += , @($order[$i].idx, $order[$j].idx)
        }
    }
    Write-Host ("[瑞士] 第 {0} 轮：{1} 对（本轮种子 index {2}）" -f $round, $pairs.Count, ($SeedStart + $round - 1))

    if (-not $StandingsOnly) {
        # 3) 写计划分块（每块一个子进程串行跑）
        $chunks = @()
        for ($g = 0; $g -lt $Groups; $g++) { $chunks += , @() }
        for ($p = 0; $p -lt $pairs.Count; $p++) { $chunks[$p % $Groups] += , $pairs[$p] }
        $kids = @()
        for ($g = 0; $g -lt $Groups; $g++) {
            if ($chunks[$g].Count -eq 0) { continue }
            $items = @()
            for ($k = 0; $k -lt $chunks[$g].Count; $k++) {
                $pp = '{0:D2}' -f ($g + 1 + $k * $Groups)
                $a = [int]$chunks[$g][$k][0]; $b = [int]$chunks[$g][$k][1]
                # 换边：奇数轮 a 当敌方；偶数轮对调
                $enemy = $a; $player = $b
                if ($round % 2 -eq 0) { $enemy = $b; $player = $a }
                $run = '{0}_r{1}_p{2}' -f $Tag, $rr, $pp
                $items += [ordered]@{
                    run = $run; a = $a; b = $b
                    enemy = $enemy; player = $player
                    deckEnemy = $decks[$enemy - 1]; deckPlayer = $decks[$player - 1]
                    seedIndex = ($SeedStart + $round - 1)
                }
                $playedKey = [Math]::Min($a, $b).ToString() + '|' + [Math]::Max($a, $b).ToString()
                $played[$playedKey] = $true
            }
            $planPath = Join-Path $results ('_swissplan_{0}_r{1}_g{2:D2}.json' -f $Tag, $rr, ($g + 1))
            [System.IO.File]::WriteAllText($planPath, (($items | ConvertTo-Json -Depth 8)), (New-Object System.Text.UTF8Encoding($false)))
            $worker = Join-Path $PSScriptRoot '_瑞士轮单批.ps1'
            $argline = '-NoProfile -ExecutionPolicy Bypass -File "' + $worker + '" -Plan "' + $planPath + '" -Beam ' + $Beam + ' -BaseWeights "' + $BaseWeights + '"'
            $kids += Start-Process -FilePath 'powershell' -ArgumentList $argline -PassThru -WindowStyle Hidden
        }
        Write-Host ("[瑞士] 第 {0} 轮：起了 {1} 个子进程，等齐…" -f $round, $kids.Count)
        $t0 = Get-Date
        while ($true) {
            $alive = @($kids | Where-Object { Get-Process -Id $_.Id -ErrorAction SilentlyContinue })
            if ($alive.Count -eq 0) { break }
            Start-Sleep -Seconds 120
            Write-Host ("[瑞士]   第 {0} 轮：还剩 {1}/{2} 个子进程（已 {3:N1} 分钟）" -f $round, $alive.Count, $kids.Count, ((Get-Date) - $t0).TotalMinutes)
        }
        Write-Host ("[瑞士] 第 {0} 轮完成（{1:N1} 分钟）" -f $round, ((Get-Date) - $t0).TotalMinutes)
    }

    # 4) 本轮名次表 + 落盘
    $shown = @($order | Select-Object -First 10)
    Write-Host ("[瑞士] 第 {0} 轮后名次（前 10）：" -f $round)
    $shown | ForEach-Object { Write-Host ("    C{0:D3}  {1}胜/{2}局  pts {3:N1}" -f $_.idx, $_.w, $_.n, $_.pts) }
    $standPath = Join-Path $results ('_swiss_{0}_{1}.json' -f $Tag, $rr)
    Write-Standings -order $order -round $round -path $standPath
    # 对局记录（续跑用）
    $pl = @($played.Keys | Sort-Object)
    [System.IO.File]::WriteAllText($pairLog, ([ordered]@{ tag = $Tag; pairs = $pl } | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}

# ---------- 末轮名次表：**按全部已落盘结果重算**（不能直接拷第 Rounds 轮那份，它少一轮）----------
$final = Join-Path $results ('_swiss_{0}_final.json' -f $Tag)
$orderFinal = Get-Standings -MaxRound $Rounds
Write-Standings -order $orderFinal -round $Rounds -path $final
Write-Host ('[瑞士] 完成：末轮名次表 ' + $final + '（全量重算）')
$top = @($orderFinal | Select-Object -First 10)
$top | ForEach-Object { Write-Host ("    C{0:D3}  {1}胜/{2}局  pts {3:N1}" -f $_.idx, $_.w, $_.n, $_.pts) }
