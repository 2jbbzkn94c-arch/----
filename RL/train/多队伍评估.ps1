<#
  多队伍评估.ps1 —— 一套权重必须在【多个队伍】上评估，输出【平均胜率】与【平均优势分】。

  为什么要有它（用户 2026-09-17 指出）：
    · 单队伍镜像只能证明"在那套阵容上更强"，不能外推（THREAT_MOVE_DISCOUNT 的效应尤其依赖移动力/射程组合）；
    · 训练器 -FixedDecks 只认 spec 级的 decks.enemy/player（RlTrain.ps1:1746/2548），不支持按臂/按种子换队伍
      ⇒ 多队伍 = 每队一个 spec（spec_teamX.json），跑完后在这里聚合。

  用法：
    & RL\train\多队伍评估.ps1 -Runs mt3,teamB,teamC,teamD,teamE -Control r2_ctrl `
        -Treatments r2_f45,r2_f60,... -OutMd RL\reports\多队伍_xxx.md

  配对口径：同一 (run=队伍, seed, first, a_side) 上，treatment 与 control 各取一行做配对差；
            只有两边都测过的 tuple 才计入（与 Train.ps1 -Task compare 同一口径）。
  聚合口径：① **平均胜率** = 各队胜率的加权平均（权重=该队配对数），并给出跨队合并的 Wilson 区间；
            ② **平均优势分** = 全部配对 Δpts 的均值 + 95% CI（同时列出每队自己的 Δpts，看离散度）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Runs,
    [Parameter(Mandatory = $true)][string]$Control,
    [Parameter(Mandatory = $false)][string[]]$Treatments = @(),
    [Parameter(Mandatory = $false)][string]$OutMd = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> 项目根
$resRoot = Join-Path $root 'RL\train\results'

function Read-Run([string]$run) {
    $csv = Join-Path (Join-Path $resRoot $run) 'measure.csv'
    if (-not (Test-Path $csv)) { return @() }
    return @(Import-Csv $csv)
}
function Wilson([int]$w, [int]$n) {
    if ($n -le 0) { return @(0.0, 0.0) }
    $z = 1.959963985; $ph = $w / $n
    $d = 1 + $z * $z / $n
    $c = $ph + $z * $z / (2 * $n)
    $m = $z * [Math]::Sqrt($ph * (1 - $ph) / $n + $z * $z / (4 * $n * $n))
    return @([Math]::Max(0.0, ($c - $m) / $d), [Math]::Min(1.0, ($c + $m) / $d))
}

$rows = @()
foreach ($run in $Runs) {
    foreach ($r in (Read-Run $run)) {
        $rows += [pscustomobject]@{
            Run = $run; Config = [string]$r.config; Seed = [string]$r.seed
            First = [string]$r.first; Aside = [string]$r.a_side
            Res = [string]$r.res; PtsA = [double]$r.ptsA
        }
    }
}
if ($rows.Count -eq 0) { throw '多队伍评估：没有任何 measure.csv 行' }
$allCfg = @($rows | ForEach-Object { $_.Config } | Select-Object -Unique)
if (-not $Treatments -or $Treatments.Count -eq 0) { $Treatments = @($allCfg | Where-Object { $_ -ne $Control }) }

$lines = @()
$lines += '# 多队伍评估（平均胜率 + 平均优势分）'
$lines += ''
$lines += ('生成时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$lines += ''
$lines += ('- 队伍（= run）：`' + ($Runs -join '`, `') + '`')
$lines += ('- 控制臂：`' + $Control + '`   ·   处理臂：`' + ($Treatments -join '`, `') + '`')
$lines += '- 配对：同 (队伍, seed, first, a_side) 上 treatment 与 control 各一行'
$lines += '- **平均胜率** = 各队胜率按配对数加权；**平均优势分** = 全部配对 Δpts 的均值（含 95% CI）'
$lines += ''

# 控制臂在各队的胜率（应≈0.5，用于验证镜像对称性）
$ctrlRate = @{}
foreach ($run in $Runs) {
    $cr = @($rows | Where-Object { $_.Run -eq $run -and $_.Config -eq $Control })
    if ($cr.Count -gt 0) { $ctrlRate[$run] = [pscustomobject]@{ W = @($cr | Where-Object Res -eq 'W').Count; N = $cr.Count } }
}
$lines += '## 控制臂自检（镜像应 ≈ 0.50）'
$lines += ''
$lines += '| 队伍 | 控制臂 N | 控制臂胜率 |'
$lines += '|---|---|---|'
foreach ($run in $Runs) {
    if ($ctrlRate.ContainsKey($run)) {
        $x = $ctrlRate[$run]
        $lines += ('| `' + $run + '` | ' + $x.N + ' | ' + ('{0:N4}' -f ($x.W / $x.N)) + ' |')
    }
}
$lines += ''

$lines += '## 汇总（每臂一行：跨队伍平均，CI 按【种子】聚类）'
$lines += ''
$lines += '> 口径（用户 2026-09-17 定）：**(队伍, 权重, 种子) 只打先后手各 1 把**（同一 first 下两侧是同一局的两个视角 → 冗余），'
$lines += '> **每队每权重 4 个种子**，预算优先给"更多权重 × 更多队伍"。'
$lines += '> ⚠️ **CI 必须按种子聚类**：同一种子的两把高度相关（同阵容同地形），把"把"当独立样本会把区间算小约 2 倍。'
$lines += '> · **平均胜率(等权)** = 队内先按种子取均值 → 每队一个胜率 → 对**队伍**取算术平均（每队 1 票）'
$lines += ''
$lines += '| 臂 | 队伍 | 种子 | **平均胜率(等权)** | 种子聚类95%CI | **平均优势分(等权)** | 优势分聚类95%CI | 各队胜率 |'
$lines += '|---|---|---|---|---|---|---|---|'

foreach ($t in $Treatments) {
    $teamRate = @(); $teamPts = @(); $teamVarRate = @(); $teamVarPts = @(); $seedTot = 0; $perTeamStr = @()
    foreach ($run in $Runs) {
        $c = @{}; $x = @{}
        foreach ($r in ($rows | Where-Object { $_.Run -eq $run })) {
            $k = ($r.Seed + '|' + $r.First + '|' + $r.Aside)
            if ($r.Config -eq $Control) { $c[$k] = $r }
            elseif ($r.Config -eq $t) { $x[$k] = $r }
        }
        $perSeed = @{}
        foreach ($k in $x.Keys) {
            if (-not $c.ContainsKey($k)) { continue }
            $sd = $x[$k].Seed
            if (-not $perSeed.ContainsKey($sd)) { $perSeed[$sd] = [pscustomobject]@{ W = 0; N = 0; D = 0.0 } }
            $perSeed[$sd].N++
            if ($x[$k].Res -eq 'W') { $perSeed[$sd].W++ }
            $perSeed[$sd].D += ($x[$k].PtsA - $c[$k].PtsA)
        }
        if ($perSeed.Count -eq 0) { continue }
        $rates = @(); $ptss = @()
        foreach ($sd in $perSeed.Keys) { $rates += ($perSeed[$sd].W / $perSeed[$sd].N); $ptss += ($perSeed[$sd].D / $perSeed[$sd].N) }
        $rm = ($rates | Measure-Object -Average).Average
        $pm = ($ptss | Measure-Object -Average).Average
        $rv = 0.0; $pv = 0.0
        if ($rates.Count -gt 1) {
            $rv = ((($rates | ForEach-Object { ($_ - $rm) * ($_ - $rm) }) | Measure-Object -Sum).Sum) / ($rates.Count - 1) / $rates.Count
            $pv = ((($ptss | ForEach-Object { ($_ - $pm) * ($_ - $pm) }) | Measure-Object -Sum).Sum) / ($ptss.Count - 1) / $ptss.Count
        }
        $teamRate += $rm; $teamPts += $pm; $teamVarRate += $rv; $teamVarPts += $pv
        $seedTot += $perSeed.Count
        $perTeamStr += ('{0:N3}({1})' -f $rm, $run)
    }
    if ($teamRate.Count -eq 0) { continue }
    $nTeam = $teamRate.Count
    $eqRate = ($teamRate | Measure-Object -Average).Average
    $eqPts = ($teamPts | Measure-Object -Average).Average
    $varR = 0.0; $varP = 0.0
    for ($i = 0; $i -lt $nTeam; $i++) { $varR += $teamVarRate[$i] / ($nTeam * $nTeam); $varP += $teamVarPts[$i] / ($nTeam * $nTeam) }
    $ciR = 1.959963985 * [Math]::Sqrt($varR)
    $ciP = 1.959963985 * [Math]::Sqrt($varP)
    $lines += ('| `' + $t + '` | ' + $T + ' | ' + $seedTot + ' | **' + ('{0:N4}' -f $eqRate) + '** | [' +
               ('{0:N4}' -f ($eqRate - $ciR)) + ', ' + ('{0:N4}' -f ($eqRate + $ciR)) + '] | **' + ('{0:N2}' -f $eqPts) +
               '** | [' + ('{0:N2}' -f ($eqPts - $ciP)) + ', ' + ('{0:N2}' -f ($eqPts + $ciP)) + '] | ' + (($perTeamStr | Sort-Object) -join ' / ') + ' |')
}
$lines += '## 生产侧胜率（候选打**敌方**侧 = `a_side=1`）—— 镜像臂**唯一可解释**的胜率口径'
$lines += ''
$lines += '> **为什么必须单独看这一半**：`RL/harness/对局.gd:106` 写明 `a_side` = **候选扮演的阵营**'
$lines += '> （`DataRegistry.Faction { PLAYER=0, ENEMY=1 }`），而 `res` = **候选视角**的胜负；每格 2 行 = 候选分别打'
$lines += '> 敌方(`a_side=1`) / 玩家方(`a_side=0`) 的**两局**。镜像同队伍时这两局互为镜像 ⇒'
$lines += '> **两半合并的胜率恒 ≈0.5（只反映和棋，量不出强弱）**；而生产里 AI 永远打敌方 ⇒ 只取 `a_side=1`。'
$lines += '> 口径：队内先按种子取均值（`W/(W+L)`，和棋不进分母）→ 每队一票 → 跨队等权平均；CI 按种子离散度聚类。'
$lines += ''
$lines += '| 臂 | 队伍 | 种子 | **生产侧胜率** | 种子聚类95%CI | 和棋局数 | **配对Δ(候选−控制)** | 各队生产侧胜率 |'
$lines += '|---|---|---|---|---|---|---|---|'

foreach ($t in $Treatments) {
    $teamRate2 = @(); $teamVar2 = @(); $seedTot2 = 0; $drawTot = 0; $perTeamStr2 = @(); $teamCtrlRate = @()
    foreach ($run in $Runs) {
        $perSeed2 = @{}
        $ctrlRows = @{}
        foreach ($r in ($rows | Where-Object { $_.Run -eq $run -and $_.Config -eq $Control -and [string]$_.Aside -eq '1' })) {
            $ctrlRows[($r.Seed + '|' + $r.First)] = $r
        }
        foreach ($r in ($rows | Where-Object { $_.Run -eq $run -and $_.Config -eq $t -and [string]$_.Aside -eq '1' })) {
            $sd = $r.Seed
            if (-not $perSeed2.ContainsKey($sd)) { $perSeed2[$sd] = [pscustomobject]@{ W = 0; L = 0; D = 0 } }
            if ($r.Res -eq 'W') { $perSeed2[$sd].W++ } elseif ($r.Res -eq 'L') { $perSeed2[$sd].L++ } else { $perSeed2[$sd].D++; $drawTot++ }
        }
        # 控制臂在**同一队、同一 a_side=1** 下的生产侧胜率（只用于"逐队差值"，不自造配对口径）
        $cw = 0; $cl = 0
        foreach ($cr in $ctrlRows.Values) { if ($cr.Res -eq 'W') { $cw++ } elseif ($cr.Res -eq 'L') { $cl++ } }
        if (($cw + $cl) -gt 0) { $teamCtrlRate += ($cw / [double]($cw + $cl)) }
        if ($perSeed2.Count -eq 0) { continue }
        $rates2 = @()
        foreach ($sd in $perSeed2.Keys) {
            $x = $perSeed2[$sd]
            if (($x.W + $x.L) -gt 0) { $rates2 += ($x.W / [double]($x.W + $x.L)) }
        }
        if ($rates2.Count -eq 0) { continue }
        $rm2 = ($rates2 | Measure-Object -Average).Average
        $rv2 = 0.0
        if ($rates2.Count -gt 1) { $rv2 = ((($rates2 | ForEach-Object { ($_ - $rm2) * ($_ - $rm2) }) | Measure-Object -Sum).Sum) / ($rates2.Count - 1) / $rates2.Count }
        $teamRate2 += $rm2; $teamVar2 += $rv2; $seedTot2 += $perSeed2.Count
        $perTeamStr2 += ('{0:N3}({1})' -f $rm2, $run)
    }
    if ($teamRate2.Count -eq 0) { continue }
    $nT = $teamRate2.Count
    $eq2 = ($teamRate2 | Measure-Object -Average).Average
    $var2 = 0.0
    for ($i = 0; $i -lt $nT; $i++) { $var2 += $teamVar2[$i] / ($nT * $nT) }
    $ci2 = 1.959963985 * [Math]::Sqrt($var2)
    $dTxt = if ($teamCtrlRate.Count -gt 0) { ('{0:+0.000;-0.000;0.000}' -f ($eq2 - (($teamCtrlRate | Measure-Object -Average).Average))) } else { 'n/a' }
    $lines += ('| `' + $t + '` | ' + $T + ' | ' + $seedTot2 + ' | **' + ('{0:N4}' -f $eq2) + '** | [' +
               ('{0:N4}' -f ($eq2 - $ci2)) + ', ' + ('{0:N4}' -f ($eq2 + $ci2)) + '] | ' + $drawTot + ' | **' +
               $dTxt + '** | ' + (($perTeamStr2 | Sort-Object) -join ' / ') + ' |')
}
$lines += ''

$lines += '## 每臂逐队明细'
$lines += ''
$lines += '| 臂 | 队伍 | 配对 | 胜率 | Δpts |'
$lines += '|---|---|---|---|---|'
foreach ($t in $Treatments) {
    foreach ($run in $Runs) {
        $c = @{}; $x = @{}
        foreach ($r in ($rows | Where-Object { $_.Run -eq $run })) {
            $k = ($r.Seed + '|' + $r.First + '|' + $r.Aside)
            if ($r.Config -eq $Control) { $c[$k] = $r } elseif ($r.Config -eq $t) { $x[$k] = $r }
        }
        $n = 0; $w = 0; $dsum = 0.0
        foreach ($k in $x.Keys) { if ($c.ContainsKey($k)) { $n++; if ($x[$k].Res -eq 'W') { $w++ }; $dsum += ($x[$k].PtsA - $c[$k].PtsA) } }
        if ($n -gt 0) { $lines += ('| `' + $t + '` | `' + $run + '` | ' + $n + ' | ' + ('{0:N4}' -f ($w / $n)) + ' | ' + ('{0:N2}' -f ($dsum / $n)) + ' |') }
    }
}

if ($OutMd) { [System.IO.File]::WriteAllLines((Join-Path $root $OutMd), $lines, [System.Text.UTF8Encoding]::new($false)) }
$lines | ForEach-Object { Write-Host $_ }
