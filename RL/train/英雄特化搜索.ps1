# 英雄特化搜索.ps1 —— 【2026-09-19 新增】按用户口径做"英雄特化"的**世代对抗训练**驱动。
#
# 用户口径（2026-09-19）：
#   「被训练的队伍用噩梦+最新权重，陪练队伍用噩梦+上一个权重。只要最新的权重对上一个权重胜率能不断增加，
#     最终到达一个边界，是不是就能找到相对更强的权重？」
#   「训练某个英雄的时候，其他英雄不要被正在训练的权重影响了，要控制变量」
#   「预设几个带需要特化的英雄的随机队伍…训练权重…算平均优势分」
#
# 因此本脚本做三件事，别的都不做：
#   ① **单变量**：一次只动**一个英雄**的键（其他英雄的键 = 上一代的，不动）；同一个英雄可以一次试多个"臂"
#      （臂 = 一组键值，用来同时优化"键的种类"和"数值"）。
#   ② **候选 vs 上一代**：A 方（候选）= 上一代权重 + 本臂改动；B 方（陪练）= **上一代权重**
#      ⇒ 由 `league.checkpoint` + `self_play_fraction=1.0` 实现（harness 的 `wB` 通道）。
#      镜像同队伍 ⇒ 双方唯一差别就是"这一个英雄的这几个键"。
#   ③ **指标**：A 方（候选）在那个对局里的 `ptsA` 与胜负 ⇒ 直接就是"新 vs 旧"的配对优势分/胜率，
#      **不需要额外的对照臂**。聚合只取 `a_side=1`（候选扮演敌方 = 生产侧），CI 按种子聚类。
#
# 用法：
#   & RL\train\英雄特化搜索.ps1 -Hero hero_42 -Decks @('hero_42,hero_03,hero_17', 'hero_42,hero_14,hero_26') `
#       -Arms @('GOLD_ATK_DECAY=1.0', 'GOLD_KILL_GATE=1', 'GOLD_ATK_DECAY=1.0;GOLD_ENDGAME_MULT=0.3') `
#       -Tag r1 -Beam 100 -Workers 6
# 返回：每个臂一行结果（生产侧胜率 / 平均 ptsA / 95%CI），并在最后打印"建议接受哪个臂"。
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Hero,
    [Parameter(Mandatory = $true)][string[]]$Decks,
    [Parameter(Mandatory = $true)][string[]]$Arms,
    [string]$GenPath = 'RL\weights\英雄世代.json',
    [string]$Tag = 'r1',
    [int]$Beam = 100,
    [int]$Workers = 6,
    [int]$Seeds = 4,
    [int]$SeedStart = 80,
    [string]$SeedSet = 'train'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$train = Join-Path $PSScriptRoot 'Train.ps1'
$results = Join-Path $PSScriptRoot 'results'

function Parse-Arm([string]$arm) {
    $th = @{}
    foreach ($kv in ($arm -split ';')) {
        if (-not $kv.Trim()) { continue }
        $p = $kv -split '=', 2
        if ($p.Count -ne 2) { throw "臂格式应为 KEY=VALUE 或 KEY=V;KEY2=V2 ：$arm" }
        $th[$p[0].Trim()] = [double]$p[1].Trim()
    }
    return $th
}

function New-SpecPath([string]$deck, [object[]]$cfgList, [string]$deckSlug) {
    # 一个**队伍**一份 spec：镜像同队伍 + 候选=上一代+臂 + 陪练=上一代，所有臂作为多个 config 并排跑
    # （同一个 spec 里的 config 共享种子/格子 ⇒ 天然配对，且 worker 并行度用满）。
    $o = [ordered]@{
        base_weights = $GenPath
        opponent     = 'base'          # 名字保留给训练器；真正决定陪练的是下面的 league 段
        beam         = @{ candidate = $Beam; opponent = $Beam }
        league       = @{ enabled = $true; self_play_fraction = 1.0; checkpoint = $GenPath; base_opp_beam = $Beam }
        decks        = @{ enemy = $deck; player = $deck }
        seeds        = @{ train = @(); holdout = @() }
        measurement  = @{ firsts = @('p', 'e'); asides = @('e') }
        lineups      = @{ version = 'v2'; pool_size = 49; slots = 12 }
        params       = @{}
        configs      = @()
    }
    # 种子表：训练器要求 ≥2 个英雄出现次数等覆盖检查 -> 直接抄 spec_nmchk 的完整训练种子
    $base = Get-Content (Join-Path $PSScriptRoot 'spec_nmchk.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $o.seeds.train = @($base.seeds.train)
    $o.seeds.holdout = @($base.seeds.holdout)
    $o.lineups = $base.lineups
    # ⚠️ 配置名必须是纯 ASCII [A-Za-z0-9_-]（训练器会校验）⇒ 臂名统一编成 a01/a02…，
    #    真正的键值放 theta 里，末尾打印图例。
    $cfgObjs = @()
    foreach ($c in $cfgList) {
        $cfgObjs += @{ name = $c.name; note = "hero-spec $Hero arm"; theta = $c.theta; beam = $Beam; beam_opp = $Beam }
    }
    $o.configs = $cfgObjs
    $f = Join-Path $PSScriptRoot ("spec_hs_{0}_{1}.json" -f $Hero, $deckSlug)
    [System.IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    return $f
}

# 臂 → 配置名（a01/a02…）+ 图例
$legend = [ordered]@{}
$cfgList = @()
$armIdx = 0
foreach ($arm in $Arms) {
    $armIdx++
    $cfgName = ('a{0:d2}' -f $armIdx)
    $legend[$cfgName] = $arm
    $cfgList += @{ name = $cfgName; theta = (Parse-Arm $arm) }
}

$rows = @()
$deckIdx = 0
foreach ($deck in $Decks) {
    $deckIdx++
    # ⚠️ 2026-09-19 修：deck slug 截断到 8 字符后**两支队伍可能撞成同一个名字**（hero42he），
    #    于是第二支队伍会往同一个 run 里追加 → 冻结守卫报"两个版本混进一份 measure.csv"。
    #    现在 slug 带序号：d1_hero42 / d2_hero42。
    $deckSlug = ('d{0}_{1}' -f $deckIdx, (($deck -replace '[^A-Za-z0-9]', '')))
    if ($deckSlug.Length -gt 14) { $deckSlug = $deckSlug.Substring(0, 14) }
    $spec = New-SpecPath $deck $cfgList $deckSlug
    $run = ('hs_{0}_{1}_{2}' -f $Hero, $Tag, $deckSlug)
    & $train -Task run -Spec $spec -Run $run -SeedSet $SeedSet -SeedStart $SeedStart -SeedBlock $Seeds -FixedDecks -Workers $Workers | Out-Null
    $csv = Join-Path (Join-Path $results $run) 'measure.csv'
    if (-not (Test-Path $csv)) { Write-Warning ("没有产出 measure.csv：run=$run"); continue }
    $rr = @(Import-Csv $csv | Where-Object { [string]$_.a_side -eq '1' })
    foreach ($r in $rr) {
        $rows += [pscustomobject]@{
            arm = $r.config; deck = $deck; seed = $r.seed; first = $r.first
            res = $r.res; ptsA = [double]$r.ptsA; rounds = [int]$r.rounds
            myDead = [int]$r.killsB; foeDead = [int]$r.killsA
        }
    }
    Write-Host ("[deck] {0} | rows={1}" -f $deck, $rr.Count)
}

# ---------------- 聚合：每个臂 = 生产侧胜率 + 平均 ptsA（按种子聚类 95%CI） ----------------
Write-Host '[臂图例]'
foreach ($k in $legend.Keys) { Write-Host ("  {0} = {1}" -f $k, $legend[$k]) }
$out = @()
foreach ($g in ($rows | Group-Object arm)) {
    $a = @($g.Group)
    $w = @($a | Where-Object { $_.res -eq 'W' }).Count
    $l = @($a | Where-Object { $_.res -eq 'L' }).Count
    $rate = if (($w + $l) -gt 0) { $w / [double]($w + $l) } else { 0.5 }
    # 按种子聚类：同一种子的多格先平均
    $perSeed = @{}
    foreach ($x in $a) { if (-not $perSeed.ContainsKey($x.seed)) { $perSeed[$x.seed] = @() }; $perSeed[$x.seed] += $x.ptsA }
    $seedMeans = @($perSeed.Values | ForEach-Object { ($_ | Measure-Object -Average).Average })
    $m = ($seedMeans | Measure-Object -Average).Average
    $sd = if ($seedMeans.Count -gt 1) { [math]::Sqrt((($seedMeans | ForEach-Object { [math]::Pow($_ - $m, 2) }) | Measure-Object -Sum).Sum / ($seedMeans.Count - 1)) } else { 0.0 }
    $se = if ($seedMeans.Count -gt 0) { $sd / [math]::Sqrt($seedMeans.Count) } else { 0.0 }
    $out += [pscustomobject]@{
        arm = $g.Name; n = $a.Count; w = $w; l = $l
        rate = [math]::Round($rate, 4); pts = [math]::Round($m, 3)
        lo = [math]::Round($m - 1.96 * $se, 3); hi = [math]::Round($m + 1.96 * $se, 3)
    }
}
$out | Sort-Object pts -Descending | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

# ---------------- 配对：各臂 − 第一个臂（按约定 a01 = 恒等对照） ----------------
# 为什么必须配对：同一 (seed, first) 下两个臂打的是**同一批对手/同一张图**，只有键不同。
# 直接比两臂的绝对 pts 会被"这一批种子整体偏难/偏易"吞掉；配对差才是"这个键值带来的变化"。
$ctl = 'a01'
if ($legend.Contains($ctl)) {
    $key = @{}
    foreach ($r in $rows) { $key["$($r.arm)|$($r.seed)|$($r.first)|$($r.deck)"] = $r }
    Write-Host ("[配对] Δ = 臂 − {0}（{1}），同 种子×先后手×队伍" -f $ctl, $legend[$ctl])
    foreach ($k in $legend.Keys) {
        if ($k -eq $ctl) { continue }
        $d = @(); $fw = 0; $fl = 0
        foreach ($c in ($rows | Where-Object { $_.arm -eq $ctl })) {
            $o = $key["$k|$($c.seed)|$($c.first)|$($c.deck)"]
            if ($null -eq $o) { continue }
            $d += ([double]$o.ptsA - [double]$c.ptsA)
            if ($o.res -eq 'W' -and $c.res -ne 'W') { $fw++ }
            if ($o.res -ne 'W' -and $c.res -eq 'W') { $fl++ }
        }
        if ($d.Count -lt 2) { continue }
        $dm = ($d | Measure-Object -Average).Average
        $dsd = [math]::Sqrt((($d | ForEach-Object { [math]::Pow($_ - $dm, 2) }) | Measure-Object -Sum).Sum / ($d.Count - 1))
        $dse = $dsd / [math]::Sqrt($d.Count)
        $sig = if (($dm - 1.96 * $dse) -gt 0 -or ($dm + 1.96 * $dse) -lt 0) { '显著' } else { '不显著' }
        Write-Host ("  {0} ({1})：n={2} Δpts={3:N2} CI=[{4:N2},{5:N2}] {6} | 翻盘 {7}胜/{8}负" -f `
            $k, $legend[$k], $d.Count, $dm, ($dm - 1.96 * $dse), ($dm + 1.96 * $dse), $sig, $fw, $fl)
    }
}

$best = $out | Sort-Object pts -Descending | Select-Object -First 1
Write-Host ("[建议] 接受臂: {0}  生产侧胜率={1} 平均优势分={2} CI=[{3},{4}]" -f $best.arm, $best.rate, $best.pts, $best.lo, $best.hi)
