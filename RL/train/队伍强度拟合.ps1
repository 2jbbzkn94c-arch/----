# 队伍强度拟合.ps1 —— 【2026-09-22 新增·用户拍板】
#
# 干什么：把"队伍池"的排名从**原始胜率**换成**对手强度校正后的实力值**。
#
# 为什么（用户原话）：「我觉得你打 8 个随机队伍的胜率去确定一个队伍强不强不太靠谱，
#   这 8 个队伍可能非常的烂，你胜率高也不代表强」。实测确实如此：
#   同一批对手里 O5 只赢 19%、O6 赢 69%（差 3.6 倍），而胜率把"赢 O5"和"赢 O6"都只算 1 分。
#
# 做法（只用已有的对战数据，**不需要重跑**）：
#   把 `results/<Tag>_c###_o##/measure.csv` 里每一局看成二部图的一条边
#   （候选 C_i — 对手 O_j，结果 y=1 表示候选赢），拟合 **Bradley-Terry** 模型
#     P(候选 i 赢对手 j) = s_i / (s_i + s_j)
#   用 MM 迭代（Hunter 2004）解出每支候选与每支对手的实力 s；同时给一条
#   **含分差的对照**：最小二乘拟合 `ptsA ≈ μ + a_i − b_j`（用到"赢多少"而不只是"赢没赢"），
#   两条排名做相关对照（结论一致才敢用）。
#
# 输出：
#   ① 候选实力榜（含 Elo 化读数、对局数、原始胜率、声明档位 C001-C040=强 / 041-080=中 / 081-120=歪）
#   ② 对手实力榜（一眼看出哪几支是"没信息量的烂队/怪物"）
#   ③ **声明档位 × 实测档位 的混淆矩阵** —— 直接回答"静态评分排序靠不靠谱"
#   ④ 切档边界带（`-BoundaryBand`）：离切档线 ±N 名的候选 ⇒ 这些就是需要补种子确认的对象
#   ⑤ 数据质量块：每支候选打了几局/几个对手、有没有全胜/全败（样本不足会让拟合虚假自信）
#
# 用法：
#   & RL\train\队伍强度拟合.ps1 -Tag pool3
#   & RL\train\队伍强度拟合.ps1 -Tag pool3 -BoundaryBand 3 -OutMd RL\reports\队伍强度拟合_pool3.md
[CmdletBinding()]
param(
    [string]$Tag = 'pool3',
    # 【2026-09-22 加】多个 tag 一起拟合：边界补种子/复跑必须用**新的 run 名**（同一个 run 目录
    #   换种子会被"版本指纹闸门"把旧行丢掉，见 5_选人策略.md），所以要把几批并起来算。
    #   传了 -Tags 就以它为准（-Tag 只用于报告文件名）。
    [string[]]$Tags = @(),
    [int]$BoundaryBand = 2,
    [string]$OutMd = '',
    [int]$Iters = 800
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> RL -> 项目根
$results = Join-Path $PSScriptRoot 'results'
$tagList = @($Tags | Where-Object { $_ })
if ($tagList.Count -eq 0) { $tagList = @($Tag) }
$tagLabel = ($tagList -join '+')

# ---------- 读对局 ----------
$games = @()
$cells = 0
$cellsIncomplete = 0
foreach ($tg in $tagList) {
foreach ($d in @(Get-ChildItem $results -Directory -Filter ($tg + '_c*') -ErrorAction SilentlyContinue)) {
    if ($d.Name -notmatch '_c(\d+)_o(\d+)') { continue }
    $ci = [int]$matches[1]; $oj = [int]$matches[2]
    $csv = Join-Path $d.FullName 'measure.csv'
    if (-not (Test-Path $csv)) { $cellsIncomplete++; continue }
    $rows = @(Import-Csv $csv | Where-Object { [string]$_.a_side -eq '1' })
    if ($rows.Count -eq 0) { $cellsIncomplete++; continue }
    $cells++
    foreach ($r in $rows) {
        $y = 0.0
        if ([string]$r.res -eq 'W') { $y = 1.0 }
        $games += [pscustomobject]@{
            c = $ci; o = $oj; y = $y; pts = [double]$r.ptsA
            seed = [string]$r.seed; first = [string]$r.first; res = [string]$r.res
        }
    }
}
}
if ($games.Count -eq 0) { throw ("没有可用的对局数据：Tags=" + $tagLabel + "（先跑 队伍车轮战.ps1）") }
Write-Host ("[拟合] Tags={0} · 完成格 {1} · 半成品格 {2} · 有效局 {3}" -f $tagLabel, $cells, $cellsIncomplete, $games.Count)

$cands = @($games | ForEach-Object { $_.c } | Sort-Object -Unique)
$opps  = @($games | ForEach-Object { $_.o } | Sort-Object -Unique)
Write-Host ("[拟合] 候选 {0} 支 × 对手 {1} 支" -f $cands.Count, $opps.Count)

# ---------- Bradley-Terry（MM 迭代 + 弱先验平滑）----------
# ⚠️ 为什么要平滑：只打 1 局就 1 胜 0 负的候选，纯 MM 会给它 Elo 3700+（n=1 撑不起这种读数）。
#   加"半场平局"的伪计数：num 起手 +0.5、den 起手 +1.0（≈ 对一支平均队 0.5 胜 0.5 负）
#   ⇒ 样本越少越被拉回中间，样本多了先验自动被淹没（BT 的标准做法，等价于 MAP 估计）。
$PriorWin = 0.5
$PriorGame = 1.0
$s = @{}                                   # "c12" / "o3" -> 实力
foreach ($c in $cands) { $s["c$c"] = 1.0 }
foreach ($o in $opps)  { $s["o$o"] = 1.0 }
for ($it = 1; $it -le $Iters; $it++) {
    $numC = @{}; $denC = @{}; $numO = @{}; $denO = @{}
    foreach ($c in $cands) { $numC[$c] = $PriorWin; $denC[$c] = $PriorGame }
    foreach ($o in $opps)  { $numO[$o] = $PriorWin; $denO[$o] = $PriorGame }
    foreach ($g in $games) {
        $sc = [double]$s["c$($g.c)"]; $so = [double]$s["o$($g.o)"]
        $p = $sc + $so
        $numC[$g.c] = [double]$numC[$g.c] + [double]$g.y
        $denC[$g.c] = [double]$denC[$g.c] + 1.0 / $p
        $numO[$g.o] = [double]$numO[$g.o] + (1.0 - [double]$g.y)
        $denO[$g.o] = [double]$denO[$g.o] + 1.0 / $p
    }
    $sumLog = 0.0; $nS = 0
    foreach ($c in $cands) {
        $v = 1.0e-6
        if ([double]$denC[$c] -gt 0) { $v = [double]$numC[$c] / [double]$denC[$c] }
        if ($v -lt 1.0e-6) { $v = 1.0e-6 }
        $s["c$c"] = $v; $sumLog += [Math]::Log($v); $nS++
    }
    foreach ($o in $opps) {
        $v = 1.0e-6
        if ([double]$denO[$o] -gt 0) { $v = [double]$numO[$o] / [double]$denO[$o] }
        if ($v -lt 1.0e-6) { $v = 1.0e-6 }
        $s["o$o"] = $v; $sumLog += [Math]::Log($v); $nS++
    }
    # 归一：全体实力的几何平均 = 1（否则每轮整体漂移，读数没有可比性）
    $gm = [Math]::Exp($sumLog / [Math]::Max($nS, 1))
    if ($gm -le 0) { $gm = 1.0 }
    foreach ($c in $cands) { $s["c$c"] = [double]$s["c$c"] / $gm }
    foreach ($o in $opps)  { $s["o$o"] = [double]$s["o$o"] / $gm }
}

# ---------- 对照：含分差的最小二乘（交替迭代 a_i / b_j）----------
# ptsA ≈ mu + a_i − b_j：交替固定一侧求另一侧（每步是简单均值），迭代到稳定。
$mu = 0.0
foreach ($g in $games) { $mu += [double]$g.pts }
$mu = $mu / [Math]::Max($games.Count, 1)
$a = @{}; $b = @{}
foreach ($c in $cands) { $a[$c] = 0.0 }
foreach ($o in $opps)  { $b[$o] = 0.0 }
for ($it = 1; $it -le 200; $it++) {
    $sa = @{}; $na = @{}
    foreach ($c in $cands) { $sa[$c] = 0.0; $na[$c] = 0 }
    foreach ($g in $games) { $sa[$g.c] = [double]$sa[$g.c] + ([double]$g.pts - $mu + [double]$b[$g.o]); $na[$g.c] = $na[$g.c] + 1 }
    foreach ($c in $cands) { if ($na[$c] -gt 0) { $a[$c] = [double]$sa[$c] / $na[$c] } }
    $sb = @{}; $nb = @{}
    foreach ($o in $opps) { $sb[$o] = 0.0; $nb[$o] = 0 }
    foreach ($g in $games) { $sb[$g.o] = [double]$sb[$g.o] + ($mu + [double]$a[$g.c] - [double]$g.pts); $nb[$g.o] = $nb[$g.o] + 1 }
    foreach ($o in $opps) { if ($nb[$o] -gt 0) { $b[$o] = [double]$sb[$o] / $nb[$o] } }
}
# 归一：a 的均值搬到 mu（保持 ptsA 的可解释性）
$meanA = 0.0
foreach ($c in $cands) { $meanA += [double]$a[$c] }
$meanA = $meanA / [Math]::Max($cands.Count, 1)
foreach ($c in $cands) { $a[$c] = [double]$a[$c] - $meanA }
$mu = $mu + $meanA

# ---------- 汇总每一支候选 ----------
$rows = @()
foreach ($c in $cands) {
    $gs = @($games | Where-Object { $_.c -eq $c })
    $w = @($gs | Where-Object { $_.y -eq 1.0 }).Count
    $n = $gs.Count
    $oppN = @($gs | ForEach-Object { $_.o } | Sort-Object -Unique).Count
    $raw = 0.0
    if ($n -gt 0) { $raw = $w / [double]$n }
    $tier = '歪'
    if ($c -le 40) { $tier = '强' } elseif ($c -le 80) { $tier = '中' }
    $rows += [pscustomobject]@{
        idx = $c; tier = $tier
        s = [double]$s["c$c"]
        elo = 1500.0 + 400.0 * [Math]::Log([double]$s["c$c"]) / [Math]::Log(10.0)
        raw = $raw; w = $w; n = $n; oppN = $oppN
        margin = [double]$a[$c]
    }
}
$ranked = @($rows | Sort-Object -Property @{ Expression = 's'; Descending = $true })
$rankRaw = @($rows | Sort-Object -Property @{ Expression = 'raw'; Descending = $true })
$rankMg  = @($rows | Sort-Object -Property @{ Expression = 'margin'; Descending = $true })

# ---------- 排名相关性（Spearman）----------
function Get-Spearman($listA, $listB) {
    # 传入两个"同 id 顺序"的字典：id -> 名次
    $ids = @($listA.Keys | Sort-Object)
    $n = $ids.Count
    if ($n -lt 3) { return 0.0 }
    $d2 = 0.0
    foreach ($i in $ids) { $d = [double]$listA[$i] - [double]$listB[$i]; $d2 += $d * $d }
    return 1.0 - (6.0 * $d2) / ([double]$n * ($n * $n - 1))
}
$posS = @{}; $posRaw = @{}; $posMg = @{}
for ($i = 0; $i -lt $ranked.Count; $i++)  { $posS[$ranked[$i].idx] = $i }
for ($i = 0; $i -lt $rankRaw.Count; $i++) { $posRaw[$rankRaw[$i].idx] = $i }
for ($i = 0; $i -lt $rankMg.Count; $i++)  { $posMg[$rankMg[$i].idx] = $i }

# ---------- 对手实力 ----------
$oppRows = @()
foreach ($o in $opps) {
    $gs = @($games | Where-Object { $_.o -eq $o })
    $winFoe = @($gs | Where-Object { $_.y -eq 0.0 }).Count   # 对手赢的局数
    $oppRows += [pscustomobject]@{
        o = $o; s = [double]$s["o$o"]
        elo = 1500.0 + 400.0 * [Math]::Log([double]$s["o$o"]) / [Math]::Log(10.0)
        n = $gs.Count; foeWin = $winFoe
        foeRate = $(if ($gs.Count -gt 0) { $winFoe / [double]$gs.Count } else { 0.0 })
        margin = [double]$b[$o]
    }
}
$oppRanked = @($oppRows | Sort-Object -Property @{ Expression = 's'; Descending = $true })

# ---------- 混淆矩阵：声明档位 × 实测档位 ----------
$n3 = [int][Math]::Floor($ranked.Count / 3)
$measuredTier = @{}
for ($i = 0; $i -lt $ranked.Count; $i++) {
    $t = '弱'
    if ($i -lt $n3) { $t = '强' } elseif ($i -lt (2 * $n3)) { $t = '中' }
    $measuredTier[$ranked[$i].idx] = $t
}
$conf = @{}
foreach ($r in $rows) {
    $k = $r.tier + '→' + $measuredTier[$r.idx]
    if ($conf.ContainsKey($k)) { $conf[$k] = $conf[$k] + 1 } else { $conf[$k] = 1 }
}

# ---------- 打印 ----------
Write-Host ''
Write-Host '=== ① 候选实力榜（Bradley-Terry；Elo 化为可读读数）==='
$ranked | Select-Object -First 12 idx, tier, elo, s, w, n, oppN, raw, margin | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host '  末尾 12 支：'
$ranked | Select-Object -Last 12 idx, tier, elo, s, w, n, oppN, raw, margin | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

Write-Host '=== ② 对手实力榜（注意：差距越大，越说明"原始胜率"不可比）==='
$oppRanked | Select-Object o, elo, s, n, foeWin, foeRate, margin | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

Write-Host '=== ③ 声明档位 × 实测档位（混淆矩阵；静态评分排序准不准就看它）==='
$conf.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-6} : {1} 支" -f $_.Key, $_.Value) }

Write-Host '=== ④ 排名相关性 ==='
Write-Host ("  Spearman(BT 实力, 原始胜率) = {0:N3}" -f (Get-Spearman $posS $posRaw))
Write-Host ("  Spearman(BT 实力, 含分差实力) = {0:N3}" -f (Get-Spearman $posS $posMg))

Write-Host '=== ⑤ 切档边界带（要补种子确认的就是这些）==='
if ($n3 -ge 1) {
    $band = @()
    # ⚠️ 必须写成 `@($n3, (2 * $n3))`：PowerShell 里**逗号运算符优先级高于算术**
    #   ⇒ `@($n3, 2 * $n3)` 会被解析成 `@($n3, 2) * $n3`（数组重复 $n3 次），
    #   边界带会打出 170 行重复数据（2026-09-22 踩过，已修）。
    foreach ($center in @($n3, (2 * $n3))) {
        for ($i = [Math]::Max(0, $center - $BoundaryBand); $i -le [Math]::Min($ranked.Count - 1, $center + $BoundaryBand); $i++) {
            $r = $ranked[$i]
            $band += [pscustomobject]@{ rank = ($i + 1); idx = $r.idx; tier = $r.tier; elo = [Math]::Round($r.elo, 1); n = $r.n; raw = [Math]::Round($r.raw, 2); near = $center }
        }
    }
    $band | Sort-Object near, rank | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
} else { Write-Host '  （数据太少，切不出三档）' }

Write-Host '=== ⑥ 数据质量 ==='
$nAll = @($rows | ForEach-Object { $_.n })
Write-Host ("  每支候选局数：min {0} · 中位 {1} · max {2}（对手数 min {3}）" -f ($nAll | Measure-Object -Minimum).Minimum, ($nAll | Sort-Object)[[int]($nAll.Count / 2)], ($nAll | Measure-Object -Maximum).Maximum, (@($rows | ForEach-Object { $_.oppN }) | Measure-Object -Minimum).Minimum)
Write-Host ("  全胜 = {0} 支 · 全败 = {1} 支（样本太小时拟合会虚假自信，这些要优先补种子）" -f @($rows | Where-Object { $_.n -gt 0 -and $_.w -eq $_.n }).Count, @($rows | Where-Object { $_.w -eq 0 }).Count)

# ---------- 落盘 ----------
if (-not $OutMd) { $OutMd = Join-Path $root ('RL\reports\队伍强度拟合_' + $Tag + '.md') }
$md = @()
$md += '# 队伍强度拟合（Bradley-Terry）· Tag=' + $Tag
$md += ''
$md += ('> 生成 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' · 完成格 ' + $cells + ' · 半成品格 ' + $cellsIncomplete + ' · 有效局 ' + $games.Count + ' · 候选 ' + $cands.Count + ' × 对手 ' + $opps.Count)
$md += '> 口径：只取 `a_side=1`（候选队扮演敌方 = 生产侧）；P(候选赢) = s_c/(s_c+s_o)，MM 迭代 ' + $Iters + ' 轮，全体实力的几何平均归一到 1；`Elo = 1500 + 400·log10(s)`。'
$md += ''
$md += '## ① 候选实力榜'
$md += ''
$md += '| 序 | 候选 | 声明档 | Elo | 实力 s | 胜/局 | 对手数 | 原始胜率 | 分差实力 |'
$md += '|---|---|---|---|---|---|---|---|---|'
$k = 0
foreach ($r in $ranked) {
    $k++
    $md += ('| {0} | C{1:D3} | {2} | {3:N1} | {4:N3} | {5}/{6} | {7} | {8:P0} | {9:N2} |' -f $k, $r.idx, $r.tier, $r.elo, $r.s, $r.w, $r.n, $r.oppN, $r.raw, $r.margin)
}
$md += ''
$md += '## ② 对手实力榜'
$md += ''
$md += '| 对手列 | Elo | 实力 s | 局数 | 对手胜 | 对手胜率 | 分差实力 |'
$md += '|---|---|---|---|---|---|---|'
foreach ($o in $oppRanked) { $md += ('| O{0} | {1:N1} | {2:N3} | {3} | {4} | {5:P0} | {6:N2} |' -f $o.o, $o.elo, $o.s, $o.n, $o.foeWin, $o.foeRate, $o.margin) }
$md += ''
$md += '## ③ 声明档位 × 实测档位'
$md += ''
$md += '| 声明 → 实测 | 支数 |'
$md += '|---|---|'
foreach ($e in ($conf.GetEnumerator() | Sort-Object Name)) { $md += ('| {0} | {1} |' -f $e.Key, $e.Value) }
$md += ''
$md += ('## ④ 排名相关性：Spearman(BT, 原始胜率) = {0:N3} · Spearman(BT, 含分差) = {1:N3}' -f (Get-Spearman $posS $posRaw), (Get-Spearman $posS $posMg))
$md += ''
$md += '## ⑤ 切档边界带（补种子确认的对象）'
$md += ''
$md += '| 切档线 | 名次 | 候选 | 声明档 | Elo | 局数 | 原始胜率 |'
$md += '|---|---|---|---|---|---|---|'
foreach ($b2 in ($band | Sort-Object near, rank)) { $md += ('| 第{0}名 | {1} | C{2:D3} | {3} | {4:N1} | {5} | {6:P0} |' -f $b2.near, $b2.rank, $b2.idx, $b2.tier, $b2.elo, $b2.n, $b2.raw) }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutMd) | Out-Null
[System.IO.File]::WriteAllLines($OutMd, $md, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('[拟合] 报告已写：' + $OutMd)

# 机器可读：给"补种子"和"写池子"用的排名表
$jsonOut = Join-Path $PSScriptRoot ('results\_fit_' + $Tag + '.json')
$out = [ordered]@{
    _说明 = 'Bradley-Terry 拟合结果（候选实力降序）。rank 从 1 开始；elo = 1500+400*log10(s)。'
    tag = $Tag; 生成时间 = (Get-Date -Format 'yyyy-MM-dd HH:mm'); 有效局 = $games.Count; 完成格 = $cells
    candidates = @($ranked | ForEach-Object { [ordered]@{ rank = 0; idx = $_.idx; tier = $_.tier; elo = [Math]::Round($_.elo, 2); s = [Math]::Round($_.s, 4); w = $_.w; n = $_.n; oppN = $_.oppN; raw = [Math]::Round($_.raw, 4); margin = [Math]::Round($_.margin, 3) } })
    opponents = @($oppRanked | ForEach-Object { [ordered]@{ o = $_.o; elo = [Math]::Round($_.elo, 2); s = [Math]::Round($_.s, 4); n = $_.n; foeRate = [Math]::Round($_.foeRate, 4) } })
    boundary = @($band | ForEach-Object { [ordered]@{ near = $_.near; rank = $_.rank; idx = $_.idx; elo = $_.elo } })
}
$kk = 0
foreach ($c in $out.candidates) { $kk++; $c.rank = $kk }
[System.IO.File]::WriteAllText($jsonOut, ($out | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('[拟合] 排名表已写：' + $jsonOut)
