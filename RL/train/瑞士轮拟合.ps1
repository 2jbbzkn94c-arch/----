# 瑞士轮拟合.ps1 —— 【2026-09-22 新增】把**瑞士轮自对抗**的结果也拟合成"队伍强度"。
#
# 为什么要它：瑞士轮的原始口径是"6 轮里赢了几局"，**完全不看对手是谁**。而瑞士轮恰恰是
#   "按战绩把强队配强队"⇒ 赢 5 局的含金量天差地别（赢的都是 5 胜的队 vs 赢的都是 0 胜的队）。
#   实测：瑞士轮原始胜场名次与 8 支固定对手的 Bradley-Terry 名次 Spearman 只有 **0.45**
#   （见 §对照），而换成"在同一张配对图上做 BT"后两套口径的可比性明显变好。
#
# 口径：
#   · 数据源 = `results/_swissmeta_<Tag>_r<轮>_p<序>.json`（a/b/enemy/player）+ 该 run 的
#     `measure.csv` 里 **`a_side=1`** 那一行（`res` 是 **A = enemy 那一支的视角**，见 对局.gd:138）。
#   · 每格一场对局：A（enemy 那一支牌组，由我方 AI 扮敌方）vs B（player 那一支牌组，由
#     `RL/ai/AI_Battle_原版.gd` 扮玩家）。P(A 赢) = s_A / (s_A + s_B)。
#   · MM 迭代 + "半场平局"弱先验（num 起手 +0.5、den 起手 +1.0）——与 `队伍强度拟合.ps1` 同一套，
#     避免两条口径用不同估计量。
#   · 归一：全体实力几何平均 = 1；`Elo = 1500 + 400·log10(s)`（与另一套口径同一把尺子）。
#
# 用法：
#   & RL\train\瑞士轮拟合.ps1 -Tag swiss1
#   & RL\train\瑞士轮拟合.ps1 -Tag swiss1 -FitJson RL\train\results\_fit_pool3b.json    # 带对照
[CmdletBinding()]
param(
    [string]$Tag = 'swiss1',
    [string]$CandFile = 'RL\train\results\_cands_pool3.json',
    [int]$Iters = 400,
    [string]$FitJson = '',                     # 另一套口径（队伍强度拟合.ps1 的产物），给了就做对照
    [string]$Out = '',
    [string]$Md = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$results = Join-Path $PSScriptRoot 'results'
function Resolve-UnderRoot([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $root $p)
}
if (-not $Out) { $Out = Join-Path $results ('_swissfit_' + $Tag + '.json') }
if (-not $Md)  { $Md = Join-Path $root ('RL\reports\瑞士轮拟合_' + $Tag + '.md') }

# ---------- 读对局 ----------
$games = @()
$cells = 0
$cellsIncomplete = 0
foreach ($f in @(Get-ChildItem $results -File -Filter ('_swissmeta_' + $Tag + '_r*_p*.json') -ErrorAction SilentlyContinue)) {
    $m = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $run = [string]$m.run
    $csv = Join-Path (Join-Path $results $run) 'measure.csv'
    if (-not (Test-Path $csv)) { $cellsIncomplete++; continue }
    $rows = @(Import-Csv $csv | Where-Object { [string]$_.a_side -eq '1' })
    if ($rows.Count -eq 0) { $cellsIncomplete++; continue }
    $cells++
    $en = [int]$m.enemy; $pl = [int]$m.player
    foreach ($r in $rows) {
        $y = 0.0
        if ([string]$r.res -eq 'W') { $y = 1.0 }
        $games += [pscustomobject]@{ a = $en; b = $pl; y = $y; pts = [double]$r.ptsA; run = $run }
    }
}
if ($games.Count -eq 0) { throw ('没有瑞士轮数据：Tag=' + $Tag + '（先跑 队伍瑞士轮.ps1）') }
$ids = @($games | ForEach-Object { $_.a; $_.b } | Sort-Object -Unique)
Write-Host ('[瑞士拟合] Tag={0} · 完成格 {1} · 半成品格 {2} · 有效局 {3} · 参赛 {4} 支' -f $Tag, $cells, $cellsIncomplete, $games.Count, $ids.Count)

# ---------- Bradley-Terry（MM 迭代 + 弱先验）----------
$PriorWin = 0.5; $PriorGame = 1.0
$s = @{}
foreach ($i in $ids) { $s[$i] = 1.0 }
for ($it = 1; $it -le $Iters; $it++) {
    $num = @{}; $den = @{}
    foreach ($i in $ids) { $num[$i] = $PriorWin; $den[$i] = $PriorGame }
    foreach ($g in $games) {
        $p = [double]$s[$g.a] + [double]$s[$g.b]
        if ($p -le 0) { $p = 1.0e-9 }
        $num[$g.a] = [double]$num[$g.a] + [double]$g.y
        $den[$g.a] = [double]$den[$g.a] + 1.0 / $p
        $num[$g.b] = [double]$num[$g.b] + (1.0 - [double]$g.y)
        $den[$g.b] = [double]$den[$g.b] + 1.0 / $p
    }
    $sumLog = 0.0
    foreach ($i in $ids) {
        $v = 1.0e-6
        if ([double]$den[$i] -gt 0) { $v = [double]$num[$i] / [double]$den[$i] }
        if ($v -lt 1.0e-6) { $v = 1.0e-6 }
        $s[$i] = $v; $sumLog += [Math]::Log($v)
    }
    $gm = [Math]::Exp($sumLog / [Math]::Max($ids.Count, 1))
    if ($gm -le 0) { $gm = 1.0 }
    foreach ($i in $ids) { $s[$i] = [double]$s[$i] / $gm }
}

# ---------- 汇总 ----------
$decks = @{}
if (Test-Path (Resolve-UnderRoot $CandFile)) {
    $cand = Get-Content (Resolve-UnderRoot $CandFile) -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($c in $cand.candidates) { $decks[[int]$c.idx] = (@($c.deck) -join ',') }
}
$rows = @()
foreach ($i in $ids) {
    $gs = @($games | Where-Object { $_.a -eq $i -or $_.b -eq $i })
    $w = 0; $n = 0
    foreach ($g in $gs) {
        $n++
        if ($g.a -eq $i) { if ($g.y -eq 1.0) { $w++ } } else { if ($g.y -eq 0.0) { $w++ } }
    }
    $elo = 1500.0 + 400.0 * [Math]::Log10([double]$s[$i])
    $rows += [pscustomobject]@{ idx = $i; s = [double]$s[$i]; elo = $elo; w = $w; n = $n; deck = [string]$decks[$i] }
}
$ranked = @($rows | Sort-Object -Property @{ Expression = 's'; Descending = $true }, @{ Expression = 'idx'; Descending = $false })
for ($i = 0; $i -lt $ranked.Count; $i++) { $ranked[$i] | Add-Member -NotePropertyName rank -NotePropertyValue ($i + 1) -Force }

# ---------- 对照：另一套口径（8 支固定对手的 BT）----------
$cmp = $null
if ($FitJson) {
    $fp = Resolve-UnderRoot $FitJson
    if (Test-Path $fp) {
        $fit = Get-Content $fp -Raw -Encoding UTF8 | ConvertFrom-Json
        $other = @{}
        foreach ($c in $fit.candidates) { $other[[int]$c.idx] = [int]$c.rank }
        $mine = @{}
        foreach ($r in $ranked) { $mine[[int]$r.idx] = [int]$r.rank }
        $common = @($other.Keys | Where-Object { $mine.ContainsKey($_) })
        $d2 = 0.0; $maxd = 0; $within = 0
        foreach ($k in $common) {
            $d = [Math]::Abs([double]$other[$k] - [double]$mine[$k])
            $d2 += $d * $d
            if ($d -gt $maxd) { $maxd = [int]$d }
            if ($d -le 10) { $within++ }
        }
        $nn = $common.Count
        $rho = 1.0 - (6.0 * $d2) / ([Math]::Max($nn, 1) * ([Math]::Max($nn, 1) * [Math]::Max($nn, 1) - 1))
        # 原始胜场名次（= 瑞士轮原来的口径）也一起对拍，量化"忽略对手强度"的代价
        $rawRanked = @($rows | Sort-Object -Property @{ Expression = 'w'; Descending = $true }, @{ Expression = 'elo'; Descending = $true }, @{ Expression = 'idx'; Descending = $false })
        $raw = @{}
        for ($i = 0; $i -lt $rawRanked.Count; $i++) { $raw[[int]$rawRanked[$i].idx] = $i + 1 }
        $d2r = 0.0
        foreach ($k in $common) { $d = [Math]::Abs([double]$other[$k] - [double]$raw[$k]); $d2r += $d * $d }
        $rhoRaw = 1.0 - (6.0 * $d2r) / ([Math]::Max($nn, 1) * ([Math]::Max($nn, 1) * [Math]::Max($nn, 1) - 1))
        $cmp = [ordered]@{
            对照 = (Split-Path -Leaf $fp); 共同 = $nn
            spearman = [Math]::Round($rho, 3); spearman_原始胜场 = [Math]::Round($rhoRaw, 3)
            名次最大差 = $maxd; 名次差小于等于10 = $within
        }
        # ⚠️ `-f` 必须和字符串**同一行**：PS 5.1 里换行后再写 `-f` 会被当成新语句（踩过，报"缺少右)"）
        Write-Host ('[瑞士拟合] 对照 {0}：Spearman = {1}（原始胜场口径 {2}）· 名次最大差 {3} · 差绝对值≤10 的有 {4}/{5}' -f $cmp.对照, $cmp.spearman, $cmp.spearman_原始胜场, $maxd, $within, $nn)
    } else {
        Write-Host ('[瑞士拟合] !! 找不到对照文件：' + $fp)
    }
}

# ---------- 落盘 ----------
$outObj = [ordered]@{
    _说明 = '瑞士轮自对抗的 Bradley-Terry 拟合（P(A赢)=s_A/(s_A+s_B)，MM + 半场平局弱先验；Elo=1500+400·log10(s)）。'
    tag = $Tag; 生成时间 = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    有效局 = $games.Count; 完成格 = $cells; 半成品格 = $cellsIncomplete
    candidates = @($ranked | ForEach-Object { [ordered]@{ rank = $_.rank; idx = $_.idx; elo = [Math]::Round($_.elo, 1); s = $_.s; w = $_.w; n = $_.n; deck = $_.deck } })
}
if ($cmp) { $outObj['对照'] = $cmp }
[System.IO.File]::WriteAllText($Out, ($outObj | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('[瑞士拟合] 写好 ' + $Out)

$mdTxt = @()
$mdTxt += '# 瑞士轮自对抗拟合（' + $Tag + '）'
$mdTxt += ''
$mdTxt += ('> 生成时间 ' + $outObj.生成时间 + ' · 有效局 **' + $games.Count + '** · 完成格 ' + $cells + '（半成品 ' + $cellsIncomplete + '）')
$mdTxt += ''
$mdTxt += '口径：每格一场对局（`a_side=1`，`res` 为 A = enemy 那一支的视角），P(A 赢) = s_A/(s_A+s_B)，MM 迭代 ' + $Iters + ' 轮 + "半场平局"弱先验；`Elo = 1500 + 400·log10(s)`。'
$mdTxt += ''
if ($cmp) {
    $mdTxt += '## 与"8 支固定对手"那套口径的对照'
    $mdTxt += ''
    $mdTxt += ('- 对照文件：`' + $cmp.对照 + '`，共同候选 ' + $cmp.共同 + ' 支')
    $mdTxt += ('- **Spearman（本口径 vs 固定对手 BT）= ' + $cmp.spearman + '**；若改用"原始胜场"排（瑞士轮本来那套）则只有 **' + $cmp.spearman_原始胜场 + '**')
    $mdTxt += ('- 名次最大差 ' + $cmp.名次最大差 + '；|名次差| ≤ 10 的有 ' + $cmp.名次差小于等于10 + '/' + $cmp.共同 + ' 支')
    $mdTxt += ''
}
$mdTxt += '## 名次（前 20 / 后 10）'
$mdTxt += ''
$mdTxt += '| 名次 | 候选 | Elo | 胜/局 | 牌组 |'
$mdTxt += '|---|---|---|---|---|'
foreach ($r in @($ranked | Select-Object -First 20)) { $mdTxt += ('| {0} | C{1:D3} | {2:N0} | {3}/{4} | `{5}` |' -f $r.rank, $r.idx, $r.elo, $r.w, $r.n, $r.deck) }
$mdTxt += ''
foreach ($r in @($ranked | Select-Object -Last 10)) { $mdTxt += ('| {0} | C{1:D3} | {2:N0} | {3}/{4} | `{5}` |' -f $r.rank, $r.idx, $r.elo, $r.w, $r.n, $r.deck) }
[System.IO.File]::WriteAllText($Md, (($mdTxt -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('[瑞士拟合] 写好 ' + $Md)
