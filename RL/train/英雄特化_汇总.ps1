# 英雄特化_汇总.ps1 —— 【2026-09-19】把某个英雄某一轮的**所有队伍**跑批结果汇总成一张表。
#
# 为什么需要它：`英雄特化搜索.ps1` 每支队伍各打一次（`hs_<hero>_<tag>_d<N>_<slug>`），
# 用户口径是「以测试权重和不同队伍为主」⇒ 判定必须**跨队伍合并**，而不是看单队那一张表。
#
# 它给三样东西：
#   ① 每个臂的**生产侧胜率**（a_side=1 = 候选打敌方 = 生产里 AI 真正扮演的一侧）
#   ② **配对 Δpts**（臂 − 对照臂 a01，按 队伍×种子×先后手 配对）＋ 95%CI（按 队伍 聚类）
#   ③ **键活性**：同格里该臂的那一行与对照臂**是否逐字节相同**（引擎是确定性的 ⇒
#      完全相同 = 这个键在这局里**一次都没改变决策**）。活性 ≈ 0 的臂说明键是死的，
#      再怎么调都不会有效果 —— 这条比胜率更早给出结论。
#
# 用法：& RL\train\英雄特化_汇总.ps1 -Hero hero_03 -Tag r2
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Hero,
    [Parameter(Mandatory = $true)][string]$Tag
)
$ErrorActionPreference = 'Stop'
$results = Join-Path $PSScriptRoot 'results'
$pat = "hs_{0}_{1}_*" -f $Hero, $Tag
$dirs = @(Get-ChildItem $results -Directory -Filter $pat -ErrorAction SilentlyContinue)
if ($dirs.Count -eq 0) { throw "没有找到 run 目录：$pat" }

$rows = @()
$bad = @()
foreach ($d in $dirs) {
    $csv = Join-Path $d.FullName 'measure.csv'
    if (-not (Test-Path $csv)) { continue }
    foreach ($r in (Import-Csv $csv)) {
        if ([string]$r.a_side -ne '1') { continue }
        # 【2026-09-19 加】**废格过滤**：资产导入竞态（新建 PNG 还没有 .import）会让 Godot 编译不过
        # `src/BoardView.gd` → `Battle.gd` → harness，于是那一格**根本没打**：search_ms_max=0、
        # 双方 0 伤害、0 阵亡、40 回合、记成"和局"、ptsA=−12。这种行必须当"没测"而不是"和局"，
        # 否则会被当成 0.5 胜掺进统计（真实案例：2026-09-19 17:18 用户新建 `道具移动.png`，
        # 17:20 才生成 .import ⇒ 这 2 分钟里起的 Godot 全废，正好毁掉矿工第 3 队整段对照臂）。
        if ([int]$r.dmgA -eq 0 -and [int]$r.dmgB -eq 0 -and [int]$r.killsA -eq 0 -and [int]$r.killsB -eq 0) {
            $bad += [pscustomobject]@{ deck = $d.Name; arm = $r.config }
            continue
        }
        $rows += [pscustomobject]@{
            deck = $d.Name; arm = $r.config; seed = $r.seed; first = $r.first
            res = $r.res; ptsA = [double]$r.ptsA; rounds = [int]$r.rounds
            killsA = [int]$r.killsA; killsB = [int]$r.killsB
            dmgA = [int]$r.dmgA; dmgB = [int]$r.dmgB; hpA = [int]$r.hpA; hpB = [int]$r.hpB
        }
    }
}
if ($bad.Count -gt 0) {
    Write-Warning ("废格（没打成的局，已剔除）：{0} 个 → {1}" -f $bad.Count,
        (($bad | Group-Object deck, arm | ForEach-Object { "{0} ×{1}" -f $_.Name, $_.Count }) -join ' · '))
}
if ($rows.Count -eq 0) { throw "run 目录里没有 a_side=1 的有效行" }
$decks = @($rows | Group-Object deck).Count
Write-Host ("[汇总] {0} · tag={1} · 队伍 {2} 支 · 生产侧行 {3}" -f $Hero, $Tag, $decks, $rows.Count)

$ctl = 'a01'
$key = @{}
foreach ($r in $rows) { $key["$($r.arm)|$($r.deck)|$($r.seed)|$($r.first)"] = $r }

# 图例：从任意一支队伍的 spec 里读配置名 → 注释（theta 才是真正的键值）
$spec = Get-ChildItem $PSScriptRoot -Filter ("spec_hs_{0}_d1_*.json" -f $Hero) -ErrorAction SilentlyContinue | Select-Object -First 1
if ($spec) {
    $sc = Get-Content $spec.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host '[臂图例]'
    foreach ($c in $sc.configs) {
        $th = ($c.theta.PSObject.Properties | ForEach-Object { "{0}={1}" -f $_.Name, $_.Value }) -join ' ; '
        if (-not $th) { $th = '(空 = 与上一代完全相同)' }
        Write-Host ("  {0} = {1}" -f $c.name, $th)
    }
}

Write-Host ''
Write-Host '臂   局数  胜  负  生产侧胜率  Δpts(配对,vs a01)  CI95            Δ胜率   键活性(改过决策的格/总格)'
$out = @()
foreach ($g in ($rows | Group-Object arm | Sort-Object Name)) {
    $a = @($g.Group)
    $w = @($a | Where-Object { $_.res -eq 'W' }).Count
    $l = @($a | Where-Object { $_.res -eq 'L' }).Count
    $n = $w + $l
    $rate = if ($n -gt 0) { $w / [double]$n } else { 0.5 }
    # 配对 Δ + 活性
    $d = @(); $live = 0; $tot = 0
    foreach ($c in $a) {
        $o = $key["$ctl|$($c.deck)|$($c.seed)|$($c.first)"]
        if ($null -eq $o) { continue }
        $tot++
        $d += ([double]$c.ptsA - [double]$o.ptsA)
        $same = ($c.res -eq $o.res -and $c.ptsA -eq $o.ptsA -and $c.rounds -eq $o.rounds -and
                 $c.killsA -eq $o.killsA -and $c.killsB -eq $o.killsB -and
                 $c.hpA -eq $o.hpA -and $c.hpB -eq $o.hpB)
        if (-not $same) { $live++ }
    }
    $dm = if ($d.Count) { ($d | Measure-Object -Average).Average } else { 0.0 }
    $dlo = 0.0; $dhi = 0.0
    if ($d.Count -gt 1) {
        $dsd = [math]::Sqrt((($d | ForEach-Object { [math]::Pow($_ - $dm, 2) }) | Measure-Object -Sum).Sum / ($d.Count - 1))
        $dse = $dsd / [math]::Sqrt($d.Count)
        $dlo = $dm - 1.96 * $dse; $dhi = $dm + 1.96 * $dse
    }
    # 配对Δ胜率（W=1 / L=0 / 和=0.5）
    $sn = 0.0
    foreach ($c in $a) {
        $o = $key["$ctl|$($c.deck)|$($c.seed)|$($c.first)"]
        if ($null -eq $o) { continue }
        $cv = if ($c.res -eq 'W') { 1.0 } elseif ($c.res -eq 'L') { 0.0 } else { 0.5 }
        $ov = if ($o.res -eq 'W') { 1.0 } elseif ($o.res -eq 'L') { 0.0 } else { 0.5 }
        $sn += ($cv - $ov)
    }
    $dr = if ($tot -gt 0) { $sn / $tot } else { 0.0 }
    $out += [pscustomobject]@{
        臂 = $g.Name; 局数 = $n; 胜 = $w; 负 = $l
        生产侧胜率 = [math]::Round($rate, 4)
        Δpts = [math]::Round($dm, 2); CI = ("[{0:N2},{1:N2}]" -f $dlo, $dhi)
        Δ胜率 = [math]::Round($dr, 4); 活性 = ("{0}/{1}" -f $live, $tot)
    }
}
$out | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
