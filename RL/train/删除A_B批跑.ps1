# 删除A_B批跑.ps1 -- A/B for the 2026-09-20 (third round) deletion of the "next-turn incoming damage
# allocation family" (THREAT_ALLOC_W / RISK_W / RISK_CORE_POW + their code).
#
#   arm NEW = the fork as it is now  (allocation family deleted; 15 "dead fold" re-based on the
#             hit-sum ruler; log field 下回合挨打 removed)
#   arm OLD = RL/ai/_prev_fork.gd / _prev_orig.gd  (the build right before the deletion)
#
# Both arms share the SAME weights (RL/weights/噩梦.json, theta empty) and the same 5 team specs
# (spec_del_ab_d1..d5 = spec_merge_alloc_d1..d5 with a single identity config), seeds 10097..10099
# (train index 96), firsts p+e, asides e, beam 200/200, opponent = base at difficulty 2 (困难).
#
# Pairing unit = (seed, first, seq) -- the same convention Get-ConfigPairedDiff uses.
# Only the fork/orig file changes between the two phases; the new files are restored at the end.
#
# Usage:  & RL\train\删除A_B批跑.ps1 -Workers 2 -Teams 5 -MaxSeeds 3
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][int]$Workers = 2,
    [Parameter(Mandatory = $false)][int]$Teams = 5,
    [Parameter(Mandatory = $false)][int]$SeedStart = 96,
    [Parameter(Mandatory = $false)][int]$MaxSeeds = 3,
    [Parameter(Mandatory = $false)][int]$TimeoutSec = 1800,
    [Parameter(Mandatory = $false)][string]$OutMd = 'RL\reports\删除分摊族_AB读数.md'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> project root
$train = Join-Path $root 'RL\train\Train.ps1'
$aiDir = Join-Path $root 'RL\ai'
$fork = Join-Path $aiDir 'AI_Battle.gd'
$orig = Join-Path $aiDir 'AI_Battle_原版.gd'
$savedFork = Join-Path $aiDir '_delnew_fork.gd'
$savedOrig = Join-Path $aiDir '_delnew_orig.gd'
$prevFork = Join-Path $aiDir '_prev_fork.gd'
$prevOrig = Join-Path $aiDir '_prev_orig.gd'

function Get-Sha12([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.Substring(0, 12).ToUpper()
}

function Invoke-Build([string]$Tag) {
    for ($n = 1; $n -le $Teams; $n++) {
        $spec = Join-Path $root ('RL\train\spec_del_ab_d' + $n + '.json')
        $run = 'del' + $Tag + '_d' + $n
        Write-Host ('=== [' + $Tag + '] ' + $run + ' (fork ' + (Get-Sha12 $fork) + ') ===')
        $cmd = ("& '" + $train + "' -Task run -Run " + $run + " -Spec '" + $spec +
                "' -Configs a01 -SeedSet train -SeedStart " + $SeedStart + " -MaxSeeds " + $MaxSeeds +
                " -Firsts p,e -Asides e -Workers " + $Workers + " -TimeoutSec " + $TimeoutSec + " -FixedDecks")
        & powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd
        if ($LASTEXITCODE -ne 0) { Write-Warning ('run ' + $run + ' exit code ' + $LASTEXITCODE + ' (continuing)') }
    }
}

Write-Host ('[A/B] fork(new)=' + (Get-Sha12 $fork) + '  prev(old)=' + (Get-Sha12 $prevFork))
Copy-Item -LiteralPath $fork -Destination $savedFork -Force
Copy-Item -LiteralPath $orig -Destination $savedOrig -Force

# OLD arm FIRST on purpose: the new build is restored at the end of this phase, so if the batch dies
# halfway the tree is still left holding the NEW fork (never the old one).
Write-Host '[A/B] swapping in the pre-deletion build for the OLD arm'
Copy-Item -LiteralPath $prevFork -Destination $fork -Force
Copy-Item -LiteralPath $prevOrig -Destination $orig -Force
Invoke-Build 'old'

Write-Host '[A/B] restoring the new build'
Copy-Item -LiteralPath $savedFork -Destination $fork -Force
Copy-Item -LiteralPath $savedOrig -Destination $orig -Force
Write-Host ('[A/B] fork restored = ' + (Get-Sha12 $fork))

Invoke-Build 'new'

# ---- aggregate: paired NEW - OLD on (seed, first, seq) ----
. (Join-Path $root 'RL\train\RlTrain.ps1')
$diffs = New-Object System.Collections.Generic.List[double]
$rowsAll = @()
$perTeam = @()
for ($n = 1; $n -le $Teams; $n++) {
    $csvNew = Join-Path $root ('RL\train\results\delnew_d' + $n + '\measure.csv')
    $csvOld = Join-Path $root ('RL\train\results\delold_d' + $n + '\measure.csv')
    if (-not (Test-Path $csvNew) -or -not (Test-Path $csvOld)) {
        Write-Warning ('team d' + $n + ': missing measure.csv, skipped')
        continue
    }
    $pick = @{}
    foreach ($r in (Import-Csv $csvNew)) {
        $k = ('{0}|{1}|{2}' -f $r.seed, ([string]$r.first).ToUpper(), $r.seq)
        if (-not $pick.ContainsKey($k)) { $pick[$k] = @{} }
        $pick[$k]['new'] = $r
    }
    foreach ($r in (Import-Csv $csvOld)) {
        $k = ('{0}|{1}|{2}' -f $r.seed, ([string]$r.first).ToUpper(), $r.seq)
        if (-not $pick.ContainsKey($k)) { $pick[$k] = @{} }
        $pick[$k]['old'] = $r
    }
    $dw = New-Object System.Collections.Generic.List[double]
    $nWin = 0.0; $oWin = 0.0; $pairs = 0
    foreach ($k in $pick.Keys) {
        $e = $pick[$k]
        if (-not ($e.ContainsKey('new') -and $e.ContainsKey('old'))) { continue }
        $pairs++
        $dn = [double]$e['new'].ptsA - [double]$e['new'].ptsB
        $do = [double]$e['old'].ptsA - [double]$e['old'].ptsB
        $d = $dn - $do
        $diffs.Add($d); $dw.Add($d)
        if ([string]$e['new'].res -eq 'W') { $nWin += 1.0 } elseif ([string]$e['new'].res -eq 'D') { $nWin += 0.5 }
        if ([string]$e['old'].res -eq 'W') { $oWin += 1.0 } elseif ([string]$e['old'].res -eq 'D') { $oWin += 0.5 }
        $rowsAll += [pscustomobject]@{ Team = ('d' + $n); Seed = $e['new'].seed; First = $e['new'].first; Seq = $e['new'].seq
                                       OldPts = $do; NewPts = $dn; D = $d; OldRes = $e['old'].res; NewRes = $e['new'].res }
    }
    if ($pairs -gt 0) {
        $m = 0.0; foreach ($v in $dw) { $m += $v }; $m = $m / $pairs
        $perTeam += [pscustomobject]@{ Team = ('d' + $n); Pairs = $pairs; OldRate = ($oWin / $pairs); NewRate = ($nWin / $pairs); DPts = $m }
    }
}

# 【2026-09-21 修】原来这里参数名 $V + 循环变量 $v —— PowerShell 变量名**不区分大小写** ⇒ $v 就是 $V，
#   循环一开就把 List 覆盖成 Double，后面 `foreach ($v in $V)` 直接炸（实测 exit 1、批跑本体全绿只是汇总挂）。
#   另：PS 5.1 的 Measure-Object **没有** -StandardDeviation（那是 PS 6+），所以这里手算均值/方差。
function Format-Stats([double[]]$vals) {
    $k = @($vals).Count
    if ($k -eq 0) { return [pscustomobject]@{ n = 0; mean = [double]::NaN; lo = [double]::NaN; hi = [double]::NaN; sd = [double]::NaN } }
    $sum = 0.0; foreach ($x in $vals) { $sum += $x }
    $mean = $sum / $k
    if ($k -lt 2) { return [pscustomobject]@{ n = $k; mean = $mean; lo = [double]::NaN; hi = [double]::NaN; sd = [double]::NaN } }
    $var = 0.0; foreach ($x in $vals) { $var += ($x - $mean) * ($x - $mean) }
    $sd = [Math]::Sqrt($var / ($k - 1))
    $tc = Get-TCrit -Df ($k - 1)
    $se = $sd / [Math]::Sqrt([double]$k)
    return [pscustomobject]@{ n = $k; mean = $mean; lo = ($mean - $tc * $se); hi = ($mean + $tc * $se); sd = $sd }
}

$st = Format-Stats @($diffs)
foreach ($r in $perTeam) { $oldRateAll += $r.OldRate * $r.Pairs; $newRateAll += $r.NewRate * $r.Pairs; $pairAll += $r.Pairs }
if ($pairAll -gt 0) { $oldRateAll = $oldRateAll / $pairAll; $newRateAll = $newRateAll / $pairAll }

$lines = @()
$lines += '# 删掉「下回合挨打」分摊族 —— A/B 棋力读数'
$lines += ''
$lines += ('生成时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$lines += ''
$lines += '- **A 臂（本版）**：分摊族已删（`THREAT_ALLOC_W` / `RISK_W` / `RISK_CORE_POW` 三个键 + `_threat_alloc_vec` 一族 + 日志平摊数）；⑮只剩必死折（判据＝「挨打合计」）'
$lines += '- **B 臂（删前版）**：`RL/ai/_prev_fork.gd` / `_prev_orig.gd`（含分摊族，`THREAT_ALLOC_W=2.0` / `RISK_W=8.0` / `RISK_CORE_POW=1.0`）'
$lines += ('- 两臂**权重完全相同**（`RL/weights/噩梦.json`，theta 空）· 队伍 = spec_del_ab_d1..d' + $Teams + ' · 种子 10097+ · firsts p+e · asides e · beam 200/200 · 对手 = 困难（base）')
$lines += ('- 配对单元 = (seed, first, seq)；**Δpts = 新 − 旧**（ptsA−ptsB 之差再相减）· 总配对数 ' + $st.n)
$lines += ''
$lines += '## 总读数'
$lines += ''
$lines += '| 项 | 旧版（B） | 本版（A） | Δ |'
$lines += '|---|---|---|---|'
$lines += ('| 平均胜率 | ' + [Math]::Round($oldRateAll, 4) + ' | ' + [Math]::Round($newRateAll, 4) + ' | ' + [Math]::Round($newRateAll - $oldRateAll, 4) + ' |')
$lines += ('| 平均优势分 Δpts | — | — | **' + [Math]::Round($st.mean, 2) + '**，95% CI [' + [Math]::Round($st.lo, 2) + ', ' + [Math]::Round($st.hi, 2) + ']，sd ' + [Math]::Round($st.sd, 1) + ' |')
$lines += ''
$lines += '## 逐队'
$lines += ''
$lines += '| 队 | 配对 | 旧胜率 | 新胜率 | Δpts（新−旧） |'
$lines += '|---|---|---|---|---|'
foreach ($r in $perTeam) {
    $lines += ('| ' + $r.Team + ' | ' + $r.Pairs + ' | ' + [Math]::Round($r.OldRate, 4) + ' | ' + [Math]::Round($r.NewRate, 4) + ' | ' + [Math]::Round($r.DPts, 2) + ' |')
}
$lines += ''
$lines += ('CI 跨 0 ⇒ **棋力层中性**（与 §14#174 对 `THREAT_ALLOC_W` 的剂量批结论一致）；CI 排除 0 且为负 ⇒ 应当回滚。')
$lines += ''
$lines += ('分辨率提示：n=' + $st.n + ' 配对，sd ' + [Math]::Round($st.sd, 1) + ' ⇒ CI 约 ±' + [Math]::Round(($st.hi - $st.lo) / 2.0, 1) + ' 分/局，测不出更小的差别。')

$outPath = Join-Path $root $OutMd
if (-not (Test-Path (Split-Path -Parent $outPath))) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null }
[System.IO.File]::WriteAllLines($outPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ('[A/B] written ' + $outPath)
$lines | ForEach-Object { Write-Host $_ }
