# 把某个批次的**已完成组**即时汇总成配对表（不用等整批跑完）。
#
# 为什么需要它：`难度体检` 自己的汇总表要等 6 个牌组**全部**跑完才打；
#   而它每个组的 `measure.csv` 其实是**逐组落盘**的 ⇒ 想提前看方向就得自己配对求和。
#   本脚本只读 `RL\train\results\<Run>*\measure.csv`，不跑 Godot、不改任何东西。
#
# 口径（与 `难度体检` 内部一致）：
#   · 只取 `a_side = 1` 的行（候选扮演敌方那一侧）；顺带滤掉"资产导入竞态"造成的废格
#     （`dmgA = dmgB = killsA = killsB = 0` 且记成和局的那些）
#   · 配对键 = `(seed, first, 牌组)`；Δpts = 该臂 `ptsA` − 对照臂 `ptsA`
#   · 95% CI 用配对差的 t 近似（n 很小时只当参考；`难度体检` 用 1.96×se）
#
# 用法：
#   & RL\train\读数汇总.ps1 -Run ladder6_pois2 -Ctl p25t4
#   & RL\train\读数汇总.ps1 -Run ladder6_bdedup -Ctl d1
#   & RL\train\读数汇总.ps1 -Run ladder6_pois2 -Ctl p25t4 -PerDeck     # 另打逐组明细
param(
    [Parameter(Mandatory = $true)][string]$Run,   # run 名前缀，例如 ladder6_pois2（会匹配 <Run>*_L*）
    [Parameter(Mandatory = $true)][string]$Ctl,   # 对照臂名，例如 p25t4 / d1 / s4
    [switch]$PerDeck                              # 是否逐组打印
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$res = Join-Path $root 'RL\train\results'
$csvs = @(Get-ChildItem $res -Recurse -Filter 'measure.csv' -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -like ($Run + '*') })
if ($csvs.Count -eq 0) {
    Write-Host ("[读数汇总] 没有找到 '{0}*' 的 measure.csv（批次还没落盘？）" -f $Run)
    exit 0
}
$rows = @()
foreach ($c in $csvs) {
    $deck = $c.Directory.Name
    foreach ($r in (Import-Csv $c.FullName)) {
        if ([string]$r.a_side -ne '1') { continue }
        if ([int]$r.dmgA -eq 0 -and [int]$r.dmgB -eq 0 -and [int]$r.killsA -eq 0 -and [int]$r.killsB -eq 0) { continue }
        $rows += [pscustomobject]@{
            deck = $deck; arm = $r.config; seed = $r.seed; first = $r.first
            res = $r.res; pts = [double]$r.ptsA; rounds = [int]$r.rounds
            dmgA = [int]$r.dmgA; dmgB = [int]$r.dmgB
        }
    }
}
Write-Host ("[读数汇总] run~'{0}*' · 已落盘 {1} 个组 · 有效行 {2} · 对照臂 = {3}" -f $Run, $csvs.Count, $rows.Count, $Ctl)
$arms = @($rows | Group-Object arm | Sort-Object Name | ForEach-Object { $_.Name })
if ($arms -notcontains $Ctl) { Write-Host ("[读数汇总] ⚠️ 对照臂 '{0}' 在已完成组里没有行 ⇒ 只能打印各臂原始均值" -f $Ctl) }
$index = @{}
foreach ($r in $rows) { $index["$($r.arm)|$($r.deck)|$($r.seed)|$($r.first)"] = $r }

function Show-Table([object[]]$subset, [string]$title) {
    Write-Host ''
    Write-Host $title
    Write-Host ('{0,-10} {1,4} {2,4} {3,4} {4,9} {5,18} {6,10} {7,9} {8,9} {9,7}' -f '臂','局','胜','负','Δpts(对照)','95%CI','翻盘','挨打/局','打出/局','回合')
    foreach ($a in $arms) {
        $g = @($subset | Where-Object { $_.arm -eq $a })
        if ($g.Count -eq 0) { continue }
        $w = @($g | Where-Object { $_.res -eq 'W' }).Count
        $l = @($g | Where-Object { $_.res -eq 'L' }).Count
        $dA = if ($g.Count) { ($g | Measure-Object dmgB -Average).Average } else { 0 }
        $dD = if ($g.Count) { ($g | Measure-Object dmgA -Average).Average } else { 0 }
        $rd = if ($g.Count) { ($g | Measure-Object rounds -Average).Average } else { 0 }
        if ($a -eq $Ctl) {
            Write-Host ('{0,-10} {1,4} {2,4} {3,4} {4,9} {5,18} {6,10} {7,9:N1} {8,9:N1} {9,7:N1}' -f $a,$g.Count,$w,$l,'对照','—','—',$dA,$dD,$rd)
            continue
        }
        $d = @(); $fw = 0; $fl = 0
        foreach ($c in $g) {
            $o = $index["$Ctl|$($c.deck)|$($c.seed)|$($c.first)"]
            if ($null -eq $o) { continue }
            $d += ($c.pts - $o.pts)
            if ($c.res -eq 'W' -and $o.res -ne 'W') { $fw++ }
            if ($c.res -ne 'W' -and $o.res -eq 'W') { $fl++ }
        }
        if ($d.Count -lt 2) {
            Write-Host ('{0,-10} {1,4} {2,4} {3,4} {4,9} {5,18} {6,10} {7,9:N1} {8,9:N1} {9,7:N1}' -f $a,$g.Count,$w,$l,"(配对$($d.Count))",'—','—',$dA,$dD,$rd)
            continue
        }
        $m = ($d | Measure-Object -Average).Average
        $sd = [Math]::Sqrt((($d | ForEach-Object { [Math]::Pow($_ - $m, 2) } | Measure-Object -Sum).Sum) / ($d.Count - 1))
        $se = $sd / [Math]::Sqrt($d.Count)
        Write-Host ('{0,-10} {1,4} {2,4} {3,4} {4,9:N2} {5,18} {6,10} {7,9:N1} {8,9:N1} {9,7:N1}' -f `
            $a,$g.Count,$w,$l,$m,("[{0:N2},{1:N2}]" -f ($m - 1.96 * $se), ($m + 1.96 * $se)),("$fw" + '胜/' + "$fl" + '负'),$dA,$dD,$rd)
    }
}
Show-Table $rows ("=== 合计（{0} 个组）===" -f $csvs.Count)
if ($PerDeck) {
    foreach ($c in ($csvs | Sort-Object Name)) {
        Show-Table @($rows | Where-Object { $_.deck -eq $c.Directory.Name }) ("=== 逐组：" + $c.Directory.Name + " ===")
    }
}
Write-Host ''
Write-Host '[读法] Δpts 为正 = 该臂比对照臂**多赚分**；CI 跨 0 = 未达显著（本项目判据）；翻盘 = 该臂赢而对照没赢的格数'
