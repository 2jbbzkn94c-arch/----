# 排名可靠性自检.ps1 —— 【2026-09-22 新增】给"这套排名到底有多少是真信号"一个数。
#
# 干什么：**折半信度**（split-half reliability）——把同一批数据按"互不相干的两半"各拟一套
#   队伍强度，再看两套名次的 Spearman。两半都只用到全局信息的一半，所以：
#     · 折半相关高（≳0.7）⇒ 名次主要是信号，缩小样本也稳；
#     · 折半相关低（≲0.4）⇒ 名次里噪音占大头，**别拿它去切档**（要么加数据、要么只信两端极端）。
#   对照基准：n=120 的**纯随机**名次之间 Spearman ≈ 0，标准差 ≈ 1/√(n−1) ≈ 0.09
#   ⇒ 观测值减去这个量级才是"真"一致性。
#
# 两套口径各切两半：
#   · 固定对手那批（`队伍车轮战.ps1` 的池子 run）：按**对手编号奇偶**切（O01/O03/O05/O07 vs O02/O04/O06/O08）
#     —— 两半的对手集合完全不同，是最严格的独立切法。
#   · 瑞士轮：按**轮次奇偶**切（1/3/5 vs 2/4/6）——两半用不同种子（不同盘面）。
#
# 用法：
#   & RL\train\排名可靠性自检.ps1 -PoolTag pool3 -SwissTag swiss1
#   & RL\train\排名可靠性自检.ps1 -PoolTag pool3 -PoolTagB pool3b -SwissTag swiss1    # 主批+补种子一起切
[CmdletBinding()]
param(
    [string]$PoolTag = 'pool3',
    [string]$PoolTagB = '',                  # 可选的第二段池子 run（补种子那批），两段一起用
    [string]$SwissTag = 'swiss1',
    [int]$Iters = 400,
    [string]$Out = 'RL\train\results\_reliability.json'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$results = Join-Path $PSScriptRoot 'results'

# ---------- 工具：MM 拟合（与 队伍强度拟合.ps1 同一套估计量）----------
function Fit-BT {
    param([object[]]$Games, [int[]]$Ids, [int]$Iters)
    $PriorWin = 0.5; $PriorGame = 1.0
    $s = @{}
    foreach ($i in $Ids) { $s[$i] = 1.0 }
    for ($it = 1; $it -le $Iters; $it++) {
        $num = @{}; $den = @{}
        foreach ($i in $Ids) { $num[$i] = $PriorWin; $den[$i] = $PriorGame }
        foreach ($g in $Games) {
            $p = [double]$s[$g.a] + [double]$s[$g.b]
            if ($p -le 0) { $p = 1.0e-9 }
            $num[$g.a] = [double]$num[$g.a] + [double]$g.y
            $den[$g.a] = [double]$den[$g.a] + 1.0 / $p
            $num[$g.b] = [double]$num[$g.b] + (1.0 - [double]$g.y)
            $den[$g.b] = [double]$den[$g.b] + 1.0 / $p
        }
        $sumLog = 0.0
        foreach ($i in $Ids) {
            $v = 1.0e-6
            if ([double]$den[$i] -gt 0) { $v = [double]$num[$i] / [double]$den[$i] }
            if ($v -lt 1.0e-6) { $v = 1.0e-6 }
            $s[$i] = $v; $sumLog += [Math]::Log($v)
        }
        $gm = [Math]::Exp($sumLog / [Math]::Max($Ids.Count, 1))
        if ($gm -le 0) { $gm = 1.0 }
        foreach ($i in $Ids) { $s[$i] = [double]$s[$i] / $gm }
    }
    return $s
}
function Fit-Ranks {
    param([object[]]$Games, [int[]]$Ids, [int]$Iters)
    $s = Fit-BT -Games $Games -Ids $Ids -Iters $Iters
    $rows = @($Ids | ForEach-Object { [pscustomobject]@{ idx = $_; s = [double]$s[$_] } })
    $ord = @($rows | Sort-Object -Property @{ Expression = 's'; Descending = $true }, @{ Expression = 'idx'; Descending = $false })
    $r = @{}
    for ($i = 0; $i -lt $ord.Count; $i++) { $r[[int]$ord[$i].idx] = $i + 1 }
    return $r
}
function Spearman {
    param([hashtable]$A, [hashtable]$B)
    $keys = @($A.Keys | Where-Object { $B.ContainsKey($_) })
    $n = $keys.Count
    if ($n -lt 3) { return [double]::NaN }
    $d2 = 0.0
    foreach ($k in $keys) { $d = [double]$A[$k] - [double]$B[$k]; $d2 += $d * $d }
    return (1.0 - (6.0 * $d2) / ($n * ($n * $n - 1)))
}

# ---------- 读池子那批（候选 × 固定对手）----------
$poolGames = @()
foreach ($tg in @($PoolTag, $PoolTagB | Where-Object { $_ })) {
    if (-not $tg) { continue }
    foreach ($d in @(Get-ChildItem $results -Directory -Filter ($tg + '_c*') -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '_c(\d+)_o(\d+)') { continue }
        $ci = [int]$matches[1]; $oj = [int]$matches[2]
        $csv = Join-Path $d.FullName 'measure.csv'
        if (-not (Test-Path $csv)) { continue }
        $rows = @(Import-Csv $csv | Where-Object { [string]$_.a_side -eq '1' })
        foreach ($r in $rows) {
            $y = 0.0
            if ([string]$r.res -eq 'W') { $y = 1.0 }
            # 统一用 a/b 两个字段（Fit-BT 只认 a/b）：池子那批的"被测方"永远是候选 ⇒ a=候选、b=对手
            $poolGames += [pscustomobject]@{ a = $ci; b = (1000 + $oj); y = $y; odd = ($oj % 2) }
        }
    }
}
$poolIds = @($poolGames | ForEach-Object { $_.a; $_.b } | Sort-Object -Unique)
$res = [ordered]@{}

if ($poolGames.Count -gt 0) {
    $oddG = @($poolGames | Where-Object { $_.odd -eq 1 })
    $evenG = @($poolGames | Where-Object { $_.odd -eq 0 })
    $rOdd = Fit-Ranks -Games $oddG -Ids $poolIds -Iters $Iters
    $rEven = Fit-Ranks -Games $evenG -Ids $poolIds -Iters $Iters
    $rho = Spearman -A $rOdd -B $rEven
    Write-Host ('[可靠] 固定对手批（{0}）· 局 {1} → 按对手奇偶折半：Spearman = {2}' -f $PoolTag, $poolGames.Count, [Math]::Round($rho, 3))
    $res['pool'] = [ordered]@{ tag = $PoolTag; games = $poolGames.Count; split = '对手编号奇偶'; spearman = [Math]::Round($rho, 3); halfA = $oddG.Count; halfB = $evenG.Count }
}

# ---------- 读瑞士轮（候选 × 候选）----------
$swGames = @()
foreach ($f in @(Get-ChildItem $results -File -Filter ('_swissmeta_' + $SwissTag + '_r*_p*.json') -ErrorAction SilentlyContinue)) {
    if ($f.Name -notmatch '_r(\d+)_p') { continue }
    $rd = [int]$matches[1]
    $m = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $csv = Join-Path (Join-Path $results ([string]$m.run)) 'measure.csv'
    if (-not (Test-Path $csv)) { continue }
    $rows = @(Import-Csv $csv | Where-Object { [string]$_.a_side -eq '1' })
    foreach ($r in $rows) {
        $y = 0.0
        if ([string]$r.res -eq 'W') { $y = 1.0 }
        $swGames += [pscustomobject]@{ a = [int]$m.enemy; b = [int]$m.player; y = $y; odd = ($rd % 2) }
    }
}
if ($swGames.Count -gt 0) {
    $swIds = @($swGames | ForEach-Object { $_.a; $_.b } | Sort-Object -Unique)
    $oddG = @($swGames | Where-Object { $_.odd -eq 1 })
    $evenG = @($swGames | Where-Object { $_.odd -eq 0 })
    $rOdd = Fit-Ranks -Games $oddG -Ids $swIds -Iters $Iters
    $rEven = Fit-Ranks -Games $evenG -Ids $swIds -Iters $Iters
    $rho = Spearman -A $rOdd -B $rEven
    Write-Host ('[可靠] 瑞士轮（{0}）· 局 {1} → 按轮次奇偶折半：Spearman = {2}' -f $SwissTag, $swGames.Count, [Math]::Round($rho, 3))
    $res['swiss'] = [ordered]@{ tag = $SwissTag; games = $swGames.Count; split = '轮次奇偶'; spearman = [Math]::Round($rho, 3); halfA = $oddG.Count; halfB = $evenG.Count }
}

# ---------- 两条口径之间（全量）----------
$fA = Join-Path $results ('_fit_' + $PoolTag + '.json')
$fB = Join-Path $results ('_swissfit_' + $SwissTag + '.json')
if ((Test-Path $fA) -and (Test-Path $fB)) {
    $a = Get-Content $fA -Raw -Encoding UTF8 | ConvertFrom-Json
    $b = Get-Content $fB -Raw -Encoding UTF8 | ConvertFrom-Json
    $ra = @{}; foreach ($c in $a.candidates) { $ra[[int]$c.idx] = [int]$c.rank }
    $rb = @{}; foreach ($c in $b.candidates) { $rb[[int]$c.idx] = [int]$c.rank }
    $rho = Spearman -A $ra -B $rb
    Write-Host ('[可靠] 两套口径（全量）：Spearman = {0}' -f [Math]::Round($rho, 3))
    $res['cross'] = [ordered]@{ fitA = (Split-Path -Leaf $fA); fitB = (Split-Path -Leaf $fB); spearman = [Math]::Round($rho, 3) }
}

$res['_说明'] = '折半信度：把数据按互不相干的两半各拟合一次 BT，看两套名次的 Spearman。n=120 的纯随机名次 ≈ 0（SD ≈ 0.09）⇒ 观测值越大越说明名次主要是信号。'
$res['生成时间'] = (Get-Date -Format 'yyyy-MM-dd HH:mm')
$outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $root $Out }
[System.IO.File]::WriteAllText($outPath, ($res | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('[可靠] 写好 ' + $outPath)
