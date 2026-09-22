# 队伍车轮战.ps1 —— 【2026-09-21 新增·用户拍板"普通模式 L1+L2+L3"的 L2】
#
# 干什么：离线海选一批"候选队伍"，让**每一支候选都打同一批固定的 8 支对手**（配对设计 ? 排名公平），
#   按胜率排名 ? 切成 三档（强/中/弱）? 写 `RL/weights/队伍池.json`，供 `src/Battle.gd` 的
#   `_load_pick_pool()` 按难度取档（简单→弱 · 普通→中 · 困难/噩梦→强）。
#
# 口径（重要）：
#   · 候选队**统一 5 人**（保证可比）；落地时游戏里读到的就是这 5 人（部署取前 3，其余进替补席）。
#   · 每支队**最多 1 个"慢英雄"**（召唤/续航那几类，单局能拖到 100 秒 ? 会把整批时长拉爆）。
#   · 底座 = `RL/weights/英雄世代.json`（= 当前噩梦的通用键 + 已接受英雄段，**且 ROLLOUT_TOPK 已关**）。
#   · 每个候选×对手只跑 **1 局有效**：`-Firsts p -Asides e` ? 1 个格子，但 harness 每格自带一场
#     **镜像局**（a_side=0，那次是"对手的牌 + 陪练权重"）? 只取 a_side=1（= 候选队扮演敌方 = 生产侧）。
#   · **可断点续跑**：Train.ps1 自带 resume，同一 run 名重跑会跳过已测格子 ? 中断了直接再跑本脚本。
#
# 用法：
#   & RL\train\队伍车轮战.ps1                      # 96 候选 × 8 对手（默认，约 6 小时 @6 workers）
#   & RL\train\队伍车轮战.ps1 -OnlyPlan            # 只生成候选与对手、打印出来，不跑对局（秒级自检）
#   & RL\train\队伍车轮战.ps1 -Cands 24 -SkipRuns  # 小样跑（先验流程）
#   & RL\train\队伍车轮战.ps1 -WritePool           # 只按已有结果排名 + 写队伍池
#   & RL\train\队伍车轮战.ps1 -SkipRuns -PoolOut RL\weights\队伍池_候选.json
#                                                # 排名 + 写到"候选池"（**不生效**：游戏只读 队伍池.json）
[CmdletBinding()]
param(
    [int]$Cands = 96,
    [int]$PerGroup = 0,          # 每组多少支（0 ? 按 Cands/3 自动）
    [int]$Seed = 20260921,
    [int]$Workers = 6,
    [int]$Beam = 100,
    [int]$SeedStart = 10041,     # 训练种子块起点（与其它批跑错开，避免"同一局面反复用"）
    [string]$BaseWeights = 'RL\weights\英雄世代.json',
    [string]$Tag = 'pool1',
    [string]$DeckSize = 5,
    [int]$OnlyOpp = 0,          # >0 = 只跑这一个对手列（1..8）：把 768 格切成 8 条并行链
    [string]$PoolOut = '',      # 写到哪里（默认 = RL\weights\队伍池.json = 生产路径）。
                                #   2026-09-21 深夜加：用户要求"池子先不生效"时用它写到别处
                                #   （例如 RL\weights\队伍池_候选.json —— 游戏只读生产路径那个文件名）。
    [switch]$OnlyPlan,
    [switch]$SkipRuns,
    [string]$DumpCandidates = '',  # 【2026-09-22 加】把这一批"候选队伍 + 对手"导出成 JSON
                                   #   （给 队伍瑞士轮.ps1 用：它要拿同一批候选互相打，
                                   #    不能自己再生成一遍 —— 两边生成器一旦不一致，瑞士轮的名次
                                   #    就对不上车轮战的排名）。导出即退出，不跑对局。
    [switch]$WritePool
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> RL -> 项目根
$train = Join-Path $PSScriptRoot 'Train.ps1'
$results = Join-Path $PSScriptRoot 'results'
$poolPath = Join-Path $root 'RL\weights\队伍池.json'
if ($PoolOut) {
    # 相对路径按项目根解析；绝对路径原样用。
    $poolPath = if ([System.IO.Path]::IsPathRooted($PoolOut)) { $PoolOut } else { Join-Path $root $PoolOut }
}

# ---------- 读角色列表（PS 侧实现一份最小版"静态评分"，与 DataRegistry.hero_strength 同口径优先取"总评分"）----------
$jsonPath = Join-Path $root '英雄相关\角色列表.json'
$rows = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$heroes = @()      # 每项: id / name / atk / hp / score / role / slow
foreach ($r in $rows) {
    $no = "$($r[0])"
    if ($no -notmatch '^\d+$') { continue }
    $id = 'hero_{0:D2}' -f [int]$no
    $trait = "$($r[5])"
    $role = '输出'
    if ($trait -match '替补') { $role = '替补' }
    elseif ($trait -match '后勤') { $role = '功能' }
    elseif ($trait -match '嘲讽') { $role = '坦克' }
    $total = 0.0
    try { $total = [double]"$($r[16])" } catch { $total = 0.0 }
    if ($total -le 0) {
        # 回退：与 DataRegistry.hero_strength 的公式同形（没有"总评分"列时用）
        $total = [double]"$($r[3])" * 2.2 + [double]"$($r[4])" * 0.45
        if ($trait -match '远程') { $total += 2.5 }
        if ($trait -match '嘲讽') { $total += 0.8 }
        if ($trait -match '疾行') { $total += 1.0 }
        if ($trait -match '后勤') { $total += 0.5 }
    }
    $slow = @('hero_33', 'hero_05', 'hero_35', 'hero_06', 'hero_08', 'hero_43') -contains $id
    $heroes += [pscustomobject]@{ id = $id; name = "$($r[2])"; atk = [int]"$($r[3])"; hp = [int]"$($r[4])"; score = [double]$total; role = $role; slow = $slow }
}
if ($heroes.Count -lt 20) { throw "角色列表解析异常：只拿到 $($heroes.Count) 个英雄" }
$byScore = @($heroes | Sort-Object -Property score -Descending)

# ---------- 确定性 RNG（System.Random + 固定种子 ? 同一批候选/对手可复现；PS 的 int64 乘法会溢出，别用 LCG）----------
$script:rng = New-Object System.Random($Seed)
function Next-Rand([int]$max) {
    if ($max -le 0) { return 0 }
    return $script:rng.Next($max)
}

# ---------- 造一支队：pool = 可选英雄；needTank 要求至少 1 坦克、needDps 至少 1 输出；每队 ≤1 慢英雄 ----------
function New-Deck([object[]]$pool, [bool]$needTank, [bool]$needDps, [int]$size) {
    for ($try = 0; $try -lt 60; $try++) {
        $pick = @()
        $slowUsed = 0
        $guard = 0
        while ($pick.Count -lt $size -and $guard -lt 400) {
            $guard++
            $cand = $pool[(Next-Rand $pool.Count)]
            if ($pick -contains $cand.id) { continue }
            if ($cand.slow -and $slowUsed -ge 1) { continue }
            $pick += $cand.id
            if ($cand.slow) { $slowUsed++ }
        }
        if ($pick.Count -lt $size) { continue }
        if ($needTank -and @($pick | ForEach-Object { ($heroes | Where-Object { $_.id -eq $_ })[0].role } | Where-Object { $_ -eq '坦克' }).Count -lt 1) { continue }
        if ($needDps -and @($pick | ForEach-Object { ($heroes | Where-Object { $_.id -eq $_ })[0].role } | Where-Object { $_ -eq '输出' }).Count -lt 1) { continue }
        return $pick
    }
    return $null
}

# 职能查询（上面那句 Where-Object 里用了 $_ 会被内层覆盖 ? 单独写个查表函数更稳）
$roleOf = @{}
foreach ($h in $heroes) { $roleOf[$h.id] = $h.role }
function Count-Role([object[]]$ids, [string]$role) {
    $n = 0
    foreach ($i in $ids) { if ($roleOf[[string]$i] -eq $role) { $n++ } }
    return $n
}

# 重写造队（用 Count-Role，避免嵌套 $_ 的坑）
function New-Deck2([object[]]$pool, [bool]$needTank, [bool]$needDps, [int]$size) {
    for ($try = 0; $try -lt 200; $try++) {
        $pick = @(); $slowUsed = 0; $guard = 0
        while ($pick.Count -lt $size -and $guard -lt 500) {
            $guard++
            $c = $pool[(Next-Rand $pool.Count)]
            if ($pick -contains $c.id) { continue }
            if ($c.slow -and $slowUsed -ge 1) { continue }
            $pick += $c.id
            if ($c.slow) { $slowUsed++ }
        }
        if ($pick.Count -lt $size) { continue }
        if ($needTank -and (Count-Role $pick '坦克') -lt 1) { continue }
        if ($needDps -and (Count-Role $pick '输出') -lt 1) { continue }
        return $pick
    }
    return $null
}

$per = $PerGroup
if ($per -le 0) { $per = [int][Math]::Floor($Cands / 3) }

# ============ 【2026-09-21 重写·用户「参与海选的队伍也不能瞎选」+「训练首发队伍，挑出强中弱 3 人首发」】============
# 旧做法（已废）：从池子里**随机抽** size 个，只保证"至少 1 坦克 + 至少 1 输出"⇒ 强弱全靠运气，海选出来一堆废物队。
# 新做法（**确定性、按规则枚举、同一 Seed 可复现**）：
#   ① 首发池 = 全部英雄 **剔除 `<替补>` 标签**（`hero_role_name()` 里的"替补"）：那类英雄的技能只在**替补登场**时
#      触发，游戏里 `Battle._enemy_deploy()` 明确不会让它们首发 ⇒ 放进首发池等于白占一个位置。
#   ② **枚举**首发池里所有 3 人组合，用一套写死的规则打分（单体总评分之和 + 职能配比 + 慢英雄惩罚）；
#   ③ 按分数名次取：强档候选 = 最好的那批 · 中档 = 中间 · 歪档 = 最差的那批；**每支候选/对手内部的英雄复用有上限**
#      （cap）⇒ 避免"十支队都是同一批 3 个人"。
#   ④ 8 支对手用同一套规则生成（2 强 + 4 中 + 2 歪，**对每个候选都相同** ⇒ 配对公平）。
#   ⑤ 分数只用来**取样**（保证候选质量分布），真正的强弱仍由**实测胜率**排名决定（见文件末尾的排名/切档）。
$slowSet = @('hero_33', 'hero_05', 'hero_35', 'hero_06', 'hero_08', 'hero_43')   # 慢英雄（召唤/续航那几类，单局能拖到 100 秒）
$fieldHeroes = @($heroes | Where-Object { $roleOf[$_.id] -ne '替补' })
if ($fieldHeroes.Count -lt 20) { throw "首发池异常：只剩 $($fieldHeroes.Count) 个英雄（替补标签剔除后）" }

function Score-Lineup([string[]]$ids) {
    $s = 0.0
    foreach ($i in $ids) {
        $hit = @($heroes | Where-Object { $_.id -eq $i })
        if ($hit.Count -eq 0) { return -999.0 }
        $s += [double]$hit[0].score
    }
    if ((Count-Role $ids '坦克') -ge 1) { $s += 2.0 } else { $s -= 4.0 }
    if ((Count-Role $ids '输出') -ge 1) { $s += 1.0 } else { $s -= 2.5 }
    if ((Count-Role $ids '功能') -ge 1) { $s += 0.5 }
    $slowN = 0
    foreach ($i in $ids) { if ($slowSet -contains $i) { $slowN++ } }
    if ($slowN -ge 2) { $s -= 3.0 * ($slowN - 1) }
    return $s
}

$allCombos = New-Object System.Collections.Generic.List[object]
for ($a = 0; $a -lt $fieldHeroes.Count; $a++) {
    for ($b = $a + 1; $b -lt $fieldHeroes.Count; $b++) {
        for ($c = $b + 1; $c -lt $fieldHeroes.Count; $c++) {
            $ids = @([string]$fieldHeroes[$a].id, [string]$fieldHeroes[$b].id, [string]$fieldHeroes[$c].id)
            $allCombos.Add([pscustomobject]@{ ids = $ids; sc = (Score-Lineup $ids) })
        }
    }
}
$combos = @($allCombos | Sort-Object -Property @{ Expression = 'sc'; Descending = $true }, @{ Expression = { ($_.ids -join ',') }; Descending = $false })
Write-Host ("[池] 首发池 {0} 个英雄（已剔除<替补>标签）· 枚举出 {1} 个 3 人组合 · 分数区间 [{2:N1}, {3:N1}]" -f $fieldHeroes.Count, $combos.Count, $combos[$combos.Count - 1].sc, $combos[0].sc)

# 从排好序的组合里挑 count 支：每位英雄最多出现 cap 次（保证多样性），从第 skip 个开始扫
function Pick-Lineups([object[]]$sorted, [int]$count, [int]$cap, [int]$skip) {
    $out = New-Object System.Collections.Generic.List[object]
    $use = @{}
    $i = $skip
    $guard = 0
    while ($out.Count -lt $count -and $i -lt $sorted.Count -and $guard -lt 100000) {
        $guard++
        $c = $sorted[$i]; $i++
        $ok = $true
        foreach ($h in $c.ids) { if ([int]$use[[string]$h] -ge $cap) { $ok = $false; break } }
        if (-not $ok) { continue }
        foreach ($h in $c.ids) { $use[[string]$h] = [int]$use[[string]$h] + 1 }
        $out.Add(@{ tier = ''; deck = @($c.ids); sc = $c.sc })
    }
    return $out.ToArray()
}

$n3 = [int][Math]::Floor($combos.Count / 3)
$capCand = 4          # 候选里每位英雄最多出现 4 次
$capOpp = 2           # 对手里每位英雄最多出现 2 次
# 歪档用**倒序**（从最差往上取）：否则"后 1/3 的正序"取的其实是那一档里最好的 ⇒ 歪得不够歪。
$weakBand = @($combos | Select-Object -Skip (2 * $n3))
[array]::Reverse($weakBand)
$candidates = @()
foreach ($pair in @(@('强', $combos, 0), @('中', $combos, $n3), @('歪', $weakBand, 0))) {
    $band = [string]$pair[0]; $pool2 = $pair[1]; $skip = [int]$pair[2]
    $got = @(Pick-Lineups $pool2 $per $capCand $skip)
    # 第一遍被"每位英雄最多 4 次"卡住时，**从更深处再扫一遍**（skip 往后挪，避免又是同一批组合）
    if ($got.Count -lt $per) {
        $got2 = @(Pick-Lineups $pool2 ($per - $got.Count + 8) ($capCand * 3) ($skip + 1500))
        foreach ($g in $got2) {
            if ($got.Count -ge $per) { break }
            if (-not ($got | Where-Object { ($_.deck -join ',') -eq ($g.deck -join ',') })) { $got += $g }
        }
        Write-Host ("[池] {0} 档：上限 {1} 只凑到一部分 ⇒ 从 +1500 处放宽到 {2}，补到 {3}/{4}" -f $band, $capCand, ($capCand * 3), $got.Count, $per)
    }
    foreach ($g in $got) { $g.tier = $band }
    $candidates += $got
}
if ($candidates.Count -lt $Cands) { Write-Host ("[池] !! 候选只凑到 {0}/{1}" -f $candidates.Count, $Cands) }

# ---------- 固定的 8 支对手：2 强 + 4 中 + 2 歪（**对每个候选都相同** ⇒ 配对公平）----------
# 取法刻意做成**确定性且互不重复**：在同一份"按分数排好序"的组合表上取几个**相距很远的固定下标** ⇒
#   ① 三档之间不可能撞车（第一版撞过：歪档取到了强档那几支）② 同一 Seed 永远同一批对手、可复现。
#   （候选那边用的是"英雄复用上限"来保证多样性，对手只有 8 支、直接按下标取更简单可靠。）
$oppIndex = @(
    @{ tier = '强'; list = $combos;    i = 2 },
    @{ tier = '强'; list = $combos;    i = 40 },
    @{ tier = '中'; list = $combos;    i = $n3 + 5 },
    @{ tier = '中'; list = $combos;    i = $n3 + 60 },
    @{ tier = '中'; list = $combos;    i = $n3 + 160 },
    @{ tier = '中'; list = $combos;    i = $n3 + 320 },
    @{ tier = '歪'; list = $weakBand;  i = 0 },
    @{ tier = '歪'; list = $weakBand;  i = 60 }
)
# 【2026-09-22 加·用户「换两个队伍」】**对手也最多 1 个慢英雄、且 8 支互不重复**（与候选同一条规矩）。
#   起因：歪档原来抽到 `德鲁伊/死灵法师/风语者`、`末日/死灵法师/风语者` 两支**召唤+奶**的队，
#   单局能拖 3~5 倍 —— 实测 O7 只跑到 **0.26 格/分**、而 O3 是 1.23 ⇒ 整批被这两列拖到 **7 小时**。
#   两趟做法（保证 O1~O6 与历史/已测数据**逐字不变**）：
#     ① 原下标直取：只要"慢英雄 ≤1 且不与前面重复"就照旧（O1~O6 全部走这条 ⇒ 已测的格不作废）
#     ② 不合格的（慢英雄 ≥2 / 撞车）才补位：**先在同档列表里找 0 慢英雄**、找不到再退 ≤1 慢，且不重复。
$opponents = @()
$usedKey = @{}
foreach ($o in $oppIndex) {
    $lst = $o.list
    $idx = [int]$o.i
    if ($idx -ge $lst.Count) { $opponents += $null; continue }
    $ids = @($lst[$idx].ids)
    $slowN2 = 0
    foreach ($h in $ids) { if ($slowSet -contains $h) { $slowN2++ } }
    $key0 = ($ids | Sort-Object) -join ','
    if ($slowN2 -ge 2 -or $usedKey.ContainsKey($key0)) { $opponents += $null; continue }
    $usedKey[$key0] = $true
    $opponents += @{ tier = [string]$o.tier; deck = $ids; sc = $lst[$idx].sc }
}
for ($oi = 0; $oi -lt $oppIndex.Count; $oi++) {
    if ($null -ne $opponents[$oi]) { continue }
    $o = $oppIndex[$oi]
    $lst = $o.list
    $found = $null
    foreach ($maxSlow in @(0, 1)) {
        if ($found) { break }
        for ($k = [int]$o.i; $k -lt $lst.Count; $k++) {
            $ids2 = @($lst[$k].ids)
            $slowN3 = 0
            foreach ($h2 in $ids2) { if ($slowSet -contains $h2) { $slowN3++ } }
            if ($slowN3 -gt $maxSlow) { continue }
            $key2 = ($ids2 | Sort-Object) -join ','
            if ($usedKey.ContainsKey($key2)) { continue }
            $found = @{ tier = [string]$o.tier; deck = $ids2; sc = $lst[$k].sc; idx = $k; maxSlow = $maxSlow }
            break
        }
    }
    if ($found) {
        $usedKey[(($found.deck) | Sort-Object) -join ','] = $true
        Write-Host ("[池] 对手 {0} 原下标 {1} 不合格（慢英雄 ≥2 / 撞车）⇒ 改用下标 {2}（慢英雄 ≤{3}）" -f $o.tier, $o.i, $found.idx, $found.maxSlow)
        $opponents[$oi] = @{ tier = [string]$found.tier; deck = @($found.deck); sc = $found.sc }
    } else {
        Write-Host ("[池] !! 对手 {0} @{1} 在同档列表里找不到合格替身" -f $o.tier, $o.i)
    }
}
$opponents = @($opponents | Where-Object { $null -ne $_ })

# ---------- 【2026-09-22】导出这一批"候选 + 对手"（给 队伍瑞士轮.ps1 用，导出即退出）----------
if ($DumpCandidates) {
    $outPath = if ([System.IO.Path]::IsPathRooted($DumpCandidates)) { $DumpCandidates } else { Join-Path $root $DumpCandidates }
    $dump = [ordered]@{
        _说明 = '队伍车轮战生成器导出的候选/对手（同一 Seed ⇒ 与车轮战那批逐字一致）。供 队伍瑞士轮.ps1 复用，避免两处生成器漂移。'
        生成时间 = (Get-Date -Format 'yyyy-MM-dd HH:mm'); tag = $Tag; 候选数 = $candidates.Count
        deck_size = $DeckSize; seed = $Seed
        candidates = @($candidates | ForEach-Object { [ordered]@{ tier = $_.tier; deck = @($_.deck) } })
        opponents = @($opponents | ForEach-Object { [ordered]@{ tier = $_.tier; deck = @($_.deck) } })
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
    [System.IO.File]::WriteAllText($outPath, ($dump | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("[池] 已导出候选/对手：{0}（候选 {1} · 对手 {2}）" -f $outPath, $candidates.Count, $opponents.Count)
    exit 0
}


function Show-Deck($deck) {
    $names = @()
    foreach ($i in $deck) { $names += ($heroes | Where-Object { $_.id -eq $i })[0].name }
    return ($names -join '/')
}

Write-Host ("[池] 候选 {0} 支（每组 {1}：强/中/歪）· 对手固定 {2} 支 · 底座 {3} · beam={4} · workers={5}" -f $candidates.Count, $per, $opponents.Count, $BaseWeights, $Beam, $Workers)
Write-Host '[池] 固定的 8 支对手：'
for ($j = 0; $j -lt $opponents.Count; $j++) {
    Write-Host ("   O{0} [{1}] {2}" -f ($j + 1), $opponents[$j].tier, (Show-Deck $opponents[$j].deck))
}
Write-Host '[池] 候选取样（前 3 支 + 最后 3 支）：'
$show = @(0, 1, 2, ($candidates.Count - 3), ($candidates.Count - 2), ($candidates.Count - 1)) | Sort-Object -Unique
foreach ($k in $show) {
    Write-Host ("   C{0:D3} [{1}] {2}" -f ($k + 1), $candidates[$k].tier, (Show-Deck $candidates[$k].deck))
}

if ($OnlyPlan) { Write-Host '[池] -OnlyPlan ? 只打印，不跑对局'; exit 0 }

# ---------- 跑：每个 候选 × 对手 = 一个 spec（decks.enemy = 候选, decks.player = 对手）----------
$seedBase = Get-Content (Join-Path $PSScriptRoot 'spec_nmchk.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$noBom = New-Object System.Text.UTF8Encoding($false)
$totalPairs = $candidates.Count * $opponents.Count
$pairIdx = 0
if (-not $SkipRuns) {
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        for ($j = 0; $j -lt $opponents.Count; $j++) {
            $pairIdx++
            if ($OnlyOpp -gt 0 -and ($j + 1) -ne $OnlyOpp) { continue }
            $run = '{0}_c{1:D3}_o{2:D2}' -f $Tag, ($i + 1), ($j + 1)
            $specPath = Join-Path $PSScriptRoot ('spec_{0}.json' -f $run)
            $o = [ordered]@{
                base_weights = $BaseWeights
                opponent     = 'base'
                beam         = @{ candidate = $Beam; opponent = $Beam }
                decks        = @{ enemy = ($candidates[$i].deck -join ','); player = ($opponents[$j].deck -join ',') }
                seeds        = @{ train = @($seedBase.seeds.train); holdout = @($seedBase.seeds.holdout) }
                measurement  = @{ firsts = @('p'); asides = @('e') }
                lineups      = $seedBase.lineups
                params       = @{}
                configs      = @(@{ name = 'm'; note = 'deck trial'; theta = @{}; beam = $Beam; beam_opp = $Beam })
            }
            [System.IO.File]::WriteAllText($specPath, ($o | ConvertTo-Json -Depth 12), $noBom)
            Write-Host ("[池] {0}/{1} {2} : 候选 C{3:D3} vs 对手 O{4:D2}" -f $pairIdx, $totalPairs, $run, ($i + 1), ($j + 1))
            & $train -Task run -Spec $specPath -Run $run -SeedSet train -SeedStart $SeedStart -SeedBlock 1 -FixedDecks -Workers $Workers |
                Select-String -Pattern 'TOTAL wall|FATAL|ERROR' | ForEach-Object { '   ' + $_.Line }
        }
        Write-Host ("[池] === 候选 C{0:D3} 的 8 场打完（{1}）===" -f ($i + 1), (Get-Date -Format 'HH:mm'))
    }
}

# ---------- 排名：每个候选的 8 场里赢了几场（只看 a_side=1 = 候选队扮演敌方 = 生产侧）----------
# 【2026-09-21 加·版本一致性统计】修好表头的 measure.csv 每行 audit 末尾带着
#   `scripts[cand=<fork sha12> base=<陪练 sha12> duel=… skil=…]`，用它数"这 768 格里有几格是
#   用**现在这套代码**测出来的"。池子是**跨版本拼接**的（一天里引擎改了很多次，每改一次
#   fork/陪练的哈希就变），所以排名带一点系统偏差（对手强度随版本漂移）—— 这里如实记进 meta，
#   不假装整批跑在同一版引擎上。
$curFork = (Get-FileHash (Join-Path $root 'RL\ai\AI_Battle.gd') -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
$curBase = (Get-FileHash (Join-Path $root 'RL\ai\AI_Battle_原版.gd') -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
$verNow = 0; $verOld = 0; $verUnknown = 0
$score = @()
for ($i = 0; $i -lt $candidates.Count; $i++) {
    $w = 0; $l = 0; $d = 0; $pts = 0.0
    for ($j = 0; $j -lt $opponents.Count; $j++) {
        $run = '{0}_c{1:D3}_o{2:D2}' -f $Tag, ($i + 1), ($j + 1)
        $csv = Join-Path (Join-Path $results $run) 'measure.csv'
        if (-not (Test-Path $csv)) { continue }
        foreach ($r in (Import-Csv $csv)) {
            if ([string]$r.a_side -ne '1') { continue }
            $mv = [regex]::Match([string]$r.audit, 'scripts\[cand=([0-9a-f]+) base=([0-9a-f]+)')
            if ($mv.Success) {
                if (($mv.Groups[1].Value -eq $curFork) -and ($mv.Groups[2].Value -eq $curBase)) { $verNow++ } else { $verOld++ }
            } else { $verUnknown++ }
            if ([string]$r.res -eq 'W') { $w++ } elseif ([string]$r.res -eq 'L') { $l++ } else { $d++ }
            $pts += [double]$r.ptsA
        }
    }
    $n = $w + $l + $d
    $rate = 0.0
    if ($n -gt 0) { $rate = $w / [double]$n }
    $score += [pscustomobject]@{
        idx = $i + 1; tier = $candidates[$i].tier; deck = ($candidates[$i].deck -join ',')
        names = (Show-Deck $candidates[$i].deck); n = $n; w = $w; l = $l; d = $d
        rate = [Math]::Round($rate, 4); pts = [Math]::Round($pts, 2)
    }
}
$ranked = @($score | Where-Object { $_.n -gt 0 } | Sort-Object -Property @{ Expression = 'rate'; Descending = $true }, @{ Expression = 'pts'; Descending = $true })
Write-Host ("[池] 有结果可排名的候选 = {0}/{1}" -f $ranked.Count, $candidates.Count)
$ranked | Select-Object -First 12 | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host '[池] 末尾 6 支：'
$ranked | Select-Object -Last 6 | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

if ($ranked.Count -lt 6) { Write-Host '[池] 有效结果太少 ? 不写池子（先把批次跑完）'; exit 0 }

# ---------- 切三档（按名次）：前 1/3 强 · 中 1/3 中 · 后 1/3 弱 ----------
$n3 = [int][Math]::Floor($ranked.Count / 3)
$strong = @($ranked | Select-Object -First $n3)
$mid = @($ranked | Select-Object -Skip $n3 | Select-Object -First $n3)
$weak = @($ranked | Select-Object -Skip (2 * $n3))
$pool = [ordered]@{
    _说明 = '标准单机敌方"队伍池"（离线车轮战排出来的队）。src/Battle.gd 的 _load_pick_pool() 按 GameState.ai_difficulty 取档：0=weak(弱) 1=mid(中) 2/3=strong(强)；⚠️ 档位键**必须是 ASCII**（weak/mid/strong，与 Battle.PICK_POOL_TIER 对齐；中文键会让 _load_pick_pool() 一个档都对不上 ⇒ 池子静默失效）；文件缺失或档位为空 ? 自动回退到"按评分加权随机组队"。'
    _口径 = '每支候选队打同一批固定 8 支对手（配对），只取 a_side=1（候选队扮演敌方=生产侧）的那一局有效；候选统一 5 人；每队至多 1 个慢英雄。⚠️ 本批是**跨引擎版本拼接**（见 meta.引擎版本一致）：每格记录了自己当时的 fork/陪练 sha12，排名把不同版本的格子一视同仁 ⇒ 只当粗筛用。'
    _回退 = '删掉本文件即可（立刻回到旧行为）。'
    meta = [ordered]@{
        生成时间 = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        引擎sha12 = (Get-FileHash (Join-Path $root 'src\BattleAI.gd') -Algorithm SHA256).Hash.Substring(0, 12)
        权重sha12 = (Get-FileHash (Join-Path $root $BaseWeights) -Algorithm SHA256).Hash.Substring(0, 12)
        tag = $Tag; 候选 = $candidates.Count; 对手 = $opponents.Count; 有效局数 = $ranked[0].n
        beam = $Beam; 种子起点 = $SeedStart
        引擎版本一致 = ('当前版本 ' + $verNow + ' 格 / 旧版本 ' + $verOld + ' 格 / 无记录 ' + $verUnknown + ' 格（每格 audit 里记着当时的 fork/陪练 sha12；只有"当前版本"那些格的对手与候选是现在这套代码）')
    }
    # 【2026-09-21 修】档位键必须是 ASCII：`src/Battle.gd::PICK_POOL_TIER` = {0:weak, 1:mid, 2:strong, 3:strong}，
    #   这里原来写的是中文键（强/中/弱）⇒ `_load_pick_pool()` 一个档都对不上 ⇒ 池子**静默失效**
    #   （游戏照旧按评分随机组队，看不出错）。跑一次静态自检就能发现：读 `Battle.PICK_POOL_TIER`
    #   的三个值，与本文件顶层键比对。
    weak = @($weak | ForEach-Object { , @($_.deck -split ',') })
    mid = @($mid | ForEach-Object { , @($_.deck -split ',') })
    strong = @($strong | ForEach-Object { , @($_.deck -split ',') })
}
[System.IO.File]::WriteAllText($poolPath, ($pool | ConvertTo-Json -Depth 8), $noBom)
# 写完立刻自检：三个 ASCII 档位键都在、且每支队伍都是非空字符串数组（键写错 = 池子在游戏里无效）。
$chk = Get-Content $poolPath -Raw -Encoding UTF8 | ConvertFrom-Json
$missing = @(@('weak', 'mid', 'strong') | Where-Object { -not ($chk.PSObject.Properties.Name -contains $_) })
if ($missing.Count -gt 0) { throw ('队伍池写坏了：缺档位键 ' + ($missing -join ',')) }
foreach ($t in @('weak', 'mid', 'strong')) {
    $bad = @($chk.$t | Where-Object { @($_).Count -lt 3 })
    if ($bad.Count -gt 0) { throw ('队伍池写坏了：档 ' + $t + ' 里有 ' + $bad.Count + ' 支队伍不足 3 人') }
}
Write-Host ("[池] 已写 {0}：strong {1} · mid {2} · weak {3}（ASCII 档位键自检通过）" -f $poolPath, $strong.Count, $mid.Count, $weak.Count)
Write-Host '[池] 各档前列：'
foreach ($pair in @(@('强', $strong), @('中', $mid), @('弱', $weak))) {
    $tagName = $pair[0]
    $arr = $pair[1]
    Write-Host ("  [{0}] {1}" -f $tagName, (($arr | Select-Object -First 5 | ForEach-Object { $_.names + '(' + $_.rate + ')' }) -join ' | '))
}
