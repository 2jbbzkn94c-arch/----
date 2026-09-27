# 英雄换一法.ps1 —— 【2026-09-25 新增】英雄**边际贡献**的 A/B 配对批（固定基准队，一格只换一个英雄）。
#
# 干什么 / 为什么：
#   `队伍车轮战.ps1` 给的是**队伍**刻度，而且英雄进哪支队不随机（池子按静态分造）⇒ 从共现读单英雄会被组成混淆
#   （同一个塔盾既在 s 3.07 的队、也在 s 0.10 的队）。本脚本改问一个**干净的单变量**问题：
#     「把基准队里某个位置的英雄 y 换成 X，这支队变强多少？」⇒ 就是 X 相对 y 的**边际贡献**。
#
# 做法（一格一对，成对比较）：
#   · **基准队 6 支**（3 人，跨强弱、避开召唤/慢英雄 —— 召唤局单局能到 300~400s，会把整批拖爆）。
#   · **换入英雄 8 个**：初筛（`RL/reports/英雄平衡_初筛_pool3_20260925.md`）两端离群里挑的
#     偏强 4 个（长角/宿魂/伐木工/超新星）+ 偏弱 4 个（末日/共鸣者/荆棘树人/坠炮手）。
#   · 每个 (基准队, 位置, 换入英雄) 造**两个格子**（角色对调，保证 A 方分数在同一把尺上）：
#       格 1：enemy = 基准队      · player = 换人队
#       格 2：enemy = 换人队      · player = 基准队
#     `${a_side}=1` 恒 = 敌方那支队（fork 权重、生产侧）⇒ Δ = ptsA(格2) − ptsA(格1) = 换人的收益。
#   · `measurement.firsts = @('p','e')`（双先后手）⇒ 每个格子 **2 局**、每对 **4 局**。
#   · 两侧同权重（`-BaseWeights`，默认现行 `噩梦.json`）⇒ 差异只来自"换了哪个英雄"。
#   · **可断点续跑**：与车轮战同一套（Train.ps1 自带 resume；同一 run 名重跑会跳过已测格）。
#
# 用法：
#   & RL\train\英雄换一法.ps1 -OnlyPlan                 # 只列配对，不跑（秒级自检）
#   & RL\train\英雄换一法.ps1 -Workers 5 -Tag swap1     # 正式跑（≈138 对 × 4 局 ≈ 550 局）
#   & RL\train\英雄换一法.ps1 -SkipRuns -Tag swap1      # 只汇总已有结果
#
# 输出：`RL\reports\英雄边际贡献_<Tag>.md` + `RL\train\results\_swap_<Tag>.json`
[CmdletBinding()]
param(
    [int]$Workers = 5,
    [int]$Beam = 100,
    [int]$SeedStart = 21041,          # 与池子/训练批错开的新种子块
    [string]$Tag = 'swap1',
    [string]$BaseWeights = 'RL\weights\噩梦.json',
    [int]$SeedBlock = 1,
    # 【2026-09-25 加】分片并行：同一批切成 $Shards 份、第 $Shard 份自己跑（0 起）。
    #   为什么要：每对 4 局是**串行**跑的（一个格子一个进程）⇒ 不切分的话 135 对要 ~9 小时。
    [string]$SwapHeroes = '',   # 【2026-09-26 加】逗号分隔的换入英雄 id（空 = 用脚本里写死的那 8 个）
    [int]$Shard = 0,
    [int]$Shards = 1,
    [switch]$SkipRuns,
    [switch]$OnlyPlan
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> RL -> 项目根
$train = Join-Path $PSScriptRoot 'Train.ps1'
$results = Join-Path $PSScriptRoot 'results'

# ---------- 基准队（3 人；跨强弱；避开召唤/续航那几个慢英雄）----------
$bases = @(
    @{ id = 'B1'; label = '巨剑+小阴影+古灵精怪'; deck = @('hero_12', 'hero_15', 'hero_28') },
    @{ id = 'B2'; label = '塔盾+嬉皮死神+黄金矿工'; deck = @('hero_11', 'hero_30', 'hero_42') },
    @{ id = 'B3'; label = '烛火+赏金猎人+复仇者'; deck = @('hero_17', 'hero_20', 'hero_23') },
    @{ id = 'B4'; label = '伐木工+毒蛇淑女+圣光'; deck = @('hero_01', 'hero_03', 'hero_22') },
    @{ id = 'B5'; label = '火枪手+大骑士+坠炮手'; deck = @('hero_09', 'hero_24', 'hero_45') },
    @{ id = 'B6'; label = '风语者+医护兵+共鸣者'; deck = @('hero_43', 'hero_06', 'hero_47') }
)

# ---------- 换入英雄（初筛两端离群；id → 名）----------
$swapNames = [ordered]@{
    hero_32 = '长角'; hero_46 = '宿魂'; hero_01 = '伐木工'; hero_21 = '超新星'
    hero_31 = '末日'; hero_47 = '共鸣者'; hero_49 = '荆棘树人'; hero_45 = '坠炮手'
}
$allNames = @{}
foreach ($r in (Get-Content (Join-Path $root 'Data\Hero\Source\角色列表.json') -Raw -Encoding UTF8 | ConvertFrom-Json)) {
    $no = "$($r[0])"; if ($no -notmatch '^\d+$') { continue }
    $allNames['hero_{0:D2}' -f [int]$no] = "$($r[2])"
}
# 【2026-09-26】-SwapHeroes 覆盖：全英雄扫描时用（名字从角色列表查）
if ($SwapHeroes) {
    $swapNames = [ordered]@{}
    foreach ($id in @($SwapHeroes -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $swapNames[$id] = if ($allNames.ContainsKey($id)) { $allNames[$id] } else { $id }
    }
}
function Show-Deck([string[]]$ids) { ($ids | ForEach-Object { $allNames[$_] }) -join '+' }

# ---------- 配对表 ----------
$pairs = @()
foreach ($b in $bases) {
    for ($p = 0; $p -lt $b.deck.Count; $p++) {
        foreach ($x in $swapNames.Keys) {
            if ($b.deck -contains $x) { continue }        # 换入的已经在队里 ⇒ 没有意义
            $swapped = @($b.deck); $swapped[$p] = $x
            $pairs += [pscustomobject]@{
                Base = $b.id; BaseLabel = $b.label; Pos = $p + 1
                Out = $b.deck[$p]; OutName = $allNames[$b.deck[$p]]
                In = $x; InName = $swapNames[$x]
                BaseDeck = $b.deck; SwapDeck = $swapped
            }
        }
    }
}
$allPairs = @($pairs)
if ($Shards -gt 1) {
    $pairs = @()
    for ($i = 0; $i -lt $allPairs.Count; $i++) { if (($i % $Shards) -eq $Shard) { $pairs += $allPairs[$i] } }
}
Write-Host ("[换一法] 基准队 {0} 支 · 换入 {1} 个 · 全批 {2} 对 · 本分片 {3}/{4} 跑 {5} 对（每对 4 局 = {6} 局）" -f `
    $bases.Count, $swapNames.Count, $allPairs.Count, ($Shard + 1), $Shards, $pairs.Count, ($pairs.Count * 4))
if ($OnlyPlan) {
    $pairs | Select-Object -First 12 | ForEach-Object {
        Write-Host ("   {0} 位置{1}: {2} → {3}   （{4}）" -f $_.Base, $_.Pos, $_.OutName, $_.InName, (Show-Deck $_.SwapDeck))
    }
    Write-Host '   …（-OnlyPlan ⇒ 只列前 12 对，不跑对局）'
    exit 0
}

# ---------- 跑：每对两个格子（角色对调）----------
$seedBase = Get-Content (Join-Path $PSScriptRoot 'spec_nmchk.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$noBom = New-Object System.Text.UTF8Encoding($false)
if (-not $SkipRuns) {
    $k = 0
    foreach ($pr in $pairs) {
        $k++
        foreach ($cell in @('a', 'b')) {
            # cell a: enemy = 基准队, player = 换人队 ；cell b: 对调
            $enemyDeck = if ($cell -eq 'a') { $pr.BaseDeck } else { $pr.SwapDeck }
            $playerDeck = if ($cell -eq 'a') { $pr.SwapDeck } else { $pr.BaseDeck }
            $run = '{0}_{1}_p{2}_x{3}_{4}' -f $Tag, $pr.Base, $pr.Pos, $pr.In.Substring(5), $cell
            $specPath = Join-Path $PSScriptRoot ('spec_{0}.json' -f $run)
            $o = [ordered]@{
                base_weights = $BaseWeights
                opponent     = 'base'
                beam         = @{ candidate = $Beam; opponent = $Beam }
                decks        = @{ enemy = ($enemyDeck -join ','); player = ($playerDeck -join ',') }
                seeds        = @{ train = @($seedBase.seeds.train); holdout = @($seedBase.seeds.holdout) }
                measurement  = @{ firsts = @('p', 'e'); asides = @('e') }
                lineups      = $seedBase.lineups
                params       = @{}
                configs      = @(@{ name = 'm'; note = 'hero swap'; theta = @{}; beam = $Beam; beam_opp = $Beam })
            }
            [System.IO.File]::WriteAllText($specPath, ($o | ConvertTo-Json -Depth 12), $noBom)
            Write-Host ("[换一法] {0}/{1} {2} : {3} 位置{4} {5}→{6} [{7}]" -f `
                $k, $pairs.Count, $run, $pr.Base, $pr.Pos, $pr.OutName, $pr.InName, $cell)
            & $train -Task run -Spec $specPath -Run $run -SeedSet train -SeedStart $SeedStart -SeedBlock $SeedBlock -FixedDecks -Workers $Workers |
                Select-String -Pattern 'TOTAL wall|FATAL|ERROR' | ForEach-Object { '   ' + $_.Line }
        }
        Write-Host ("[换一法] === {0} 位置{1} 的 {2} 对打完（{3}）===" -f $pr.Base, $pr.Pos, $swapNames.Count, (Get-Date -Format 'HH:mm'))
    }
}

# ---------- 汇总：Δpts(换入 − 换出) ----------
function Get-PtsA([string]$run) {
    $csv = Join-Path $results (Join-Path $run 'measure.csv')
    if (-not (Test-Path $csv)) { return $null }
    $rows = @(Import-Csv $csv | Where-Object { [string]$_.a_side -eq '1' })
    if ($rows.Count -eq 0) { return $null }
    return [pscustomobject]@{
        Pts = ($rows | Measure-Object ptsA -Average).Average
        W   = @($rows | Where-Object { [string]$_.res -eq 'W' }).Count
        N   = $rows.Count
    }
}
$recs = @()
foreach ($pr in $allPairs) {
    $ra = Get-PtsA ('{0}_{1}_p{2}_x{3}_a' -f $Tag, $pr.Base, $pr.Pos, $pr.In.Substring(5))
    $rb = Get-PtsA ('{0}_{1}_p{2}_x{3}_b' -f $Tag, $pr.Base, $pr.Pos, $pr.In.Substring(5))
    if ($null -eq $ra -or $null -eq $rb) { continue }
    $recs += [pscustomobject]@{
        Base = $pr.Base; BaseLabel = $pr.BaseLabel; Pos = $pr.Pos; Out = $pr.Out; OutName = $pr.OutName
        In = $pr.In; InName = $pr.InName
        PtsBase = [math]::Round($ra.Pts, 2); PtsSwap = [math]::Round($rb.Pts, 2)
        Delta = [math]::Round($rb.Pts - $ra.Pts, 2)
        WinBase = $ra.W; WinSwap = $rb.W; Games = $ra.N + $rb.N
    }
}
if ($recs.Count -eq 0) { Write-Host '[换一法] 没有可汇总的格子（还没跑？）'; exit 0 }

Write-Host ''
Write-Host '=== 每个换入英雄的边际贡献（Δpts = 换入 − 换出；正 = 换上去更强）==='
$byHero = $recs | Group-Object In | ForEach-Object {
    $g = @($_.Group); $d = @($g | ForEach-Object { $_.Delta })
    $m = ($d | Measure-Object -Average).Average
    $sd = if ($d.Count -gt 1) { [math]::Sqrt((($d | ForEach-Object { [math]::Pow($_ - $m, 2) } | Measure-Object -Sum).Sum) / ($d.Count - 1)) } else { 0 }
    $se = if ($d.Count -gt 1) { $sd / [math]::Sqrt($d.Count) } else { 0 }
    [pscustomobject]@{
        英雄 = $_.Name; 名 = $swapNames[$_.Name]; 对数 = $g.Count
        Δ = [math]::Round($m, 2); 下 = [math]::Round($m - 1.96 * $se, 2); 上 = [math]::Round($m + 1.96 * $se, 2)
        胜 = ($g | Measure-Object WinSwap -Sum).Sum; 负 = ($g | Measure-Object WinBase -Sum).Sum
    }
} | Sort-Object Δ -Descending
$byHero | ForEach-Object { "{0,-8} {1,-6} 对数{2,3}  Δ {3,6:n2} [{4,6:n2},{5,6:n2}]  换入胜{6,3} / 换出胜{7,3}" -f $_.英雄, $_.名, $_.对数, $_.Δ, $_.下, $_.上, $_.胜, $_.负 }

Write-Host ''
Write-Host '=== 逐基准队（同一支队里换人的平均收益）==='
$recs | Group-Object Base | ForEach-Object {
    $m = ($_.Group | Measure-Object Delta -Average).Average
    "   {0} {1,-22} Δ {2,6:n2}（{3} 对）" -f $_.Name, $_.Group[0].BaseLabel, $m, $_.Count
}

# 落盘
$recs | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $results ('_swap_{0}.json' -f $Tag)) -Encoding UTF8
$byHero | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $results ('_swap_{0}_hero.json' -f $Tag)) -Encoding UTF8
Write-Host ("[换一法] 已写：RL\train\results\_swap_{0}.json / _swap_{0}_hero.json" -f $Tag)
