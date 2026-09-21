# 难度体检.ps1 —— 【2026-09-19 新增】测「简单 / 普通 / 困难 / 噩梦」这条难度梯度**是不是真的**。
#
# 为什么要有它：2026-09-18 用 run `ladder` 测过一次（`RL/reports/难度阶梯.md`），结论是
#   **normal vs hard 打平（Δpts +0.96 [−0.02,+1.94]）、easy vs hard 只弱 1.61 分 [−2.68,−0.53]**；
#   但那次**只有 1 支队伍 × 4 个种子**，而项目自己的规矩是"≤5 队的读数不可信"（已翻车 6 次）。
#   用户 2026-09-19：「你有测试过简单/普通/困难的难度梯度合理吗」⇒ 用 6 队重标一遍。
#
# 口径（关键，和 `ladder` 那次保持一致，只有队伍数变了）：
#   · **基线 = `RL/weights/空白基线.json`（零键）** ⇒ 低档不会被噩梦的键污染（评测的是"档位本身"）
#   · **对手 = 困难档陪练副本**（`opp=base`，beam_opp 恒 200）⇒ 四个臂打**同一个对手**，只差自己的配置
#   · 四臂 = 简单(beam50/jitter±8) · 普通(beam100/jitter±1.5) · **困难(beam200/jitter0，对照)** ·
#            噩梦(beam200/jitter0 **+ 噩梦.json 那 6 个键**：推演层 32/1 + KILL_BONUS=0 + SELF_DEATH_W=0
#            + 两个折减=1.0)
#   · 指标：生产侧(a_side=1)胜率 + **配对 Δpts（各臂 − 困难，同 队伍×种子×先后手）**
#   · 判据：梯度"合理"= Δpts 沿 简单 < 普通 < 困难 < 噩梦 **单调**，且相邻两档的 CI 不跨 0
#
# 用法：& RL\train\难度体检.ps1            （走默认 6 队 × 4 种子）
[CmdletBinding()]
param(
    [string[]]$Decks = @(
        'hero_13,hero_12,hero_18',   # 近战前排：嘲讽/重伤/穿刺
        'hero_24,hero_09,hero_20',   # 远程多
        'hero_42,hero_03,hero_17',   # 矿工/毒蛇/烛火
        'hero_48,hero_14,hero_25',   # 装甲堡垒/古拉/战锤
        'hero_46,hero_11,hero_08',   # 宿魂/塔盾/德鲁伊
        'hero_06,hero_08,hero_43'    # 续航/光环（**故意不用召唤队**：`hero_33,hero_35,hero_05` 单位数会涨，
                                     #   harness 又 `time_budget_ms=0` ⇒ 单步 42 秒、整队 17 分钟，见 `难度体检_6队_20260919.md` §判读4）
    ),
    [int]$Seeds = 4,
    [int]$SeedStart = 80,
    [int]$Workers = 6,
    [string]$Tag = 'r1',
    [string]$Base = 'RL\weights\空白基线.json',
    [ValidateSet('tiers', 'tiers2', 'weak', 'ruleb', 'weakp', 'weakp2', 'pull', 'nlf')][string]$Mode = 'tiers'   # tiers = 难度四档；tiers2 = 噩梦/噩梦+ 对困难（用户 2026-09-20 点名）；weak = 削弱项候选；weakp/weakp2 = 概率性弱化 p 剂量；pull = 进圈拉力剂量；thr = 位移威胁剂量
)
$ErrorActionPreference = 'Stop'
$train = Join-Path $PSScriptRoot 'Train.ps1'
$results = Join-Path $PSScriptRoot 'results'

# 四档：名字 → (基线文件, 自己 beam, theta)。beam_opp 恒 200（困难陪练）。
# ⚠️ 噩梦档为什么单独一组基线：`KILL_BONUS` / `SELF_DEATH_W` / `VALUE_STUN_FOLD` / `VALUE_SILENCE_FOLD`
#    是训练器的**冻结键**（theta 里点名会被硬拒 —— 第一次跑就是这么全军覆没的），它们的值只能来自
#    基线文件 ⇒ 噩梦档直接拿 `噩梦.json` 当 base、theta 留空。低三档必须用**零键基线**（否则会被噩梦的键污染）。
$TIERS = [ordered]@{
    'easy'   = @{ base = 'RL\weights\空白基线.json'; beam = 50;  theta = @{} }   # 【2026-09-20】JITTER 与 LOW_TIER_ENGINE 都已删 ⇒ 低档在生产里的难度只由 WEAK_* 承担；本表的 50/100 是 spec 自己注入的 beam（用来量「窄 beam 值多少分」），不是难度映射
    'normal' = @{ base = 'RL\weights\空白基线.json'; beam = 100; theta = @{} }
    'hard'   = @{ base = 'RL\weights\空白基线.json'; beam = 200; theta = @{} }   # 对照臂
    'nmare'  = @{ base = 'RL\weights\噩梦.json';     beam = 200; theta = @{} }   # = 噩梦档口径（6 键来自该文件）
}
# 按 base 分组跑（一个 spec 只能有一个 base_weights）
$GROUPS = @(
    @{ slug = 'A'; base = 'RL\weights\空白基线.json'; tiers = @('easy', 'normal', 'hard') },
    @{ slug = 'B'; base = 'RL\weights\噩梦.json';     tiers = @('nmare') }
)
$OPP_BEAM = 200

# ---- 模式 B：「削弱项」候选（决定"简单 / 普通"怎么定义）----
# 全部 beam 200 / 对手困难 200 ⇒ 只差 theta 里那几个"能力开关"，基线同一份零键文件。
# 【2026-09-20 改造】原 `noThreat`（`THREAT_INCOMING_W=0`）两条臂**已作废**：那个键随 ⑦ 合并从引擎删除。
#   现在真在跑的"削弱项"只剩两条：① 关集火合力（历史唯一承重键）② 概率性弱化引擎（WEAK_*）。
$WEAK_ARMS = [ordered]@{
    'hard'     = @{ theta = @{} }                                                     # 对照
    'noFocus'  = @{ theta = @{ FOCUS_FIRE_WEIGHT = 0.0 } }                             # 不做集火合力（历史唯一承重键）
    'gfire50'  = @{ theta = @{ WEAK_MODE = 5; WEAK_P = 0.50; WEAK_SEED = 0 } }         # 贪心+关集火 · 满血 50%
    'gfire70'  = @{ theta = @{ WEAK_MODE = 5; WEAK_P = 0.70; WEAK_SEED = 0 } }         # 贪心+关集火 · 满血 30%
}
if ($Mode -eq 'weak') {
    $TIERS = [ordered]@{}
    foreach ($k in $WEAK_ARMS.Keys) { $TIERS[$k] = @{ base = $Base; beam = 200; theta = $WEAK_ARMS[$k].theta } }
    $GROUPS = @(@{ slug = 'W'; base = $Base; tiers = @($WEAK_ARMS.Keys) })
}

# ---- 【已删 2026-09-20】原「模式 C：抖动剂量」：`JITTER` 键随抖动机制一起从引擎删除
#   （用户实测"把抖动做大"对棋力无剂量-响应、且用全局 randf 不可复现；低档难度现由 WEAK_* 承担）。

# ---- 模式 D：「规则 B 的落点可接受伤害阈值」（用户 2026-09-19 回忆起来的那一项）----
# 用户原话：「之前不是有 移动后评估下回合会被打多少的评分吗？」
# 就是 `MOVE_ACCEPT_DAMAGE`：`max(落点预期挨打 − 阈值, 0) × HP_VALUE_W(1.0)` —— **全价计费**，
# 而现役的 `THREAT_INCOMING_W` 只有 0.12/血点（打 8 折）；它还会把危险落点挤出候选前 16 名。
# 坑：`_rule_b_score` 开头 `if thr <= 0 and ev == 0 and nx == 0: return 0.0` ⇒ **阈值 0 = 整条规则关**，最小有效值 1。
# 算例（为什么值得测）：阈值 1 时，落点预期挨打 4 点 ⇒ 罚 (4-1)x1.0 = 3.0 分，而"退一格"的压上拉力只有 1.2 分
#   ⇒ **第一次出现"退比进便宜"的算术**（现役 0.12 那支只罚 0.48 ⇒ 进比退便宜 0.72）。
$RB_ARMS = [ordered]@{ 'rb0' = 0.0; 'rb1' = 1.0; 'rb2' = 2.0; 'rb4' = 4.0 }
if ($Mode -eq 'ruleb') {
    $TIERS = [ordered]@{}
    foreach ($k in $RB_ARMS.Keys) {
        $th = @{}
        if ([double]$RB_ARMS[$k] -ne 0.0) { $th = @{ MOVE_ACCEPT_DAMAGE = [double]$RB_ARMS[$k] } }
        $TIERS[$k] = @{ base = $Base; beam = 200; theta = $th }
    }
    $GROUPS = @(@{ slug = 'R'; base = $Base; tiers = @($RB_ARMS.Keys) })
}

# ---- 【已删 2026-09-20】原「模式 E：终选抽签剂量」：`LOTTERY_*` 四个键随 `_lottery_pick()` 一起从引擎删除
#   （用户实测「设置 L 和 T 没让 AI 变弱，反倒胜率还增加了」⇒ 当难度旋钮无效）。

# ---- 模式 F：「概率性弱化」难度档（用户 2026-09-19 设计）----
# 用户原话：「我希望简单难度和普通难度也有概率可以打出最好的操作。就是概率的多少问题」。
# `WEAK_P` = 这一回合走弱化引擎的概率 ⇒ **满血概率 = 1 − p**。
# 为什么这条与 beam/jitter/抽签本质不同：那些都在"评分分不出来的并列区"动手脚（实测全部无效），
# 这一条是**两个强度不同的引擎按概率混合** ⇒ 期望棋力 = p×满血 + (1−p)×弱化，p 单调。
# 全部 beam 200 / 对手困难陪练 200 / 同一份零键基线 ⇒ 只差这两个键。
$WP_ARMS = [ordered]@{
    'hard'    = @{ mode = 0; p = 0.0 }     # 对照（困难口径）—— wp2 重跑一次，兼作"新键默认关 ⇒ 逐位不变"的自证
    'gfire25' = @{ mode = 5; p = 0.25 }    # 贪心+关集火 · 满血 75%
    'gfire50' = @{ mode = 5; p = 0.50 }    # 贪心+关集火 · 满血 50%（拟定的「普通」档）
}
if ($Mode -eq 'weakp') {
    $TIERS = [ordered]@{}
    foreach ($k in $WP_ARMS.Keys) {
        $th = @{}
        if ([int]$WP_ARMS[$k].mode -gt 0) {
            $th = @{ WEAK_MODE = [int]$WP_ARMS[$k].mode; WEAK_P = [double]$WP_ARMS[$k].p; WEAK_SEED = 0 }
        }
        $TIERS[$k] = @{ base = $Base; beam = 200; theta = $th }
    }
    $GROUPS = @(@{ slug = 'P'; base = $Base; tiers = @($WP_ARMS.Keys) })
}

# ---- 模式 G：判负线硬闸门（`NO_LOSS_FILTER` 0/1）—— 核实"开给生产三档"的强度影响 ----
# 用户 2026-09-19 批准把 `NO_LOSS_FILTER` 的**生产默认值**改成 1（属修 bug：AI 不再走"我方全灭 = 直接判负"的线）。
# 这里用 **theta 双臂**（不改任何代码）量化它：理论上它只**删除**最坏的那一类线 ⇒ 期望"不变弱、只是不再送输"。
# 基线 = 零键（困难口径）；对手 = 困难陪练副本；候选 beam 200。
$NLF_ARMS = [ordered]@{
    'nlf0' = @{ v = 0 }   # 旧行为（= fork 的代码默认，对照臂）
    'nlf1' = @{ v = 1 }   # 新生产默认（丢弃判负线）
}
if ($Mode -eq 'nlf') {
    $TIERS = [ordered]@{}
    foreach ($k in $NLF_ARMS.Keys) {
        $TIERS[$k] = @{ base = $Base; beam = 200; theta = @{ NO_LOSS_FILTER = [int]$NLF_ARMS[$k].v } }
    }
    $GROUPS = @(@{ slug = 'W2'; base = $Base; tiers = @($NLF_ARMS.Keys) })
}
# ---- 模式 H（位移技能威胁 `DISPLACE_THREAT_W` 剂量）已于 2026-09-20 **整块删除** ----
# 原因：那条链在引擎里**没有任何调用点**（`_incoming_damage_on()` 引擎内 0 个调用者）⇒ 这个键设成任何值
#   都不会改变出招，剂量扫描量不到东西（历次"键是活的"读数其实来自探针直接调那个函数）。
#   键 + 函数一族已删：见 src/BattleAI.gd 顶部「整族已删」与 RL/progress_tracking/1_通用策略.md §四 / T12。
#   旧读数留在 RL/reports/ 里作历史。

# ---- 模式 I：「进圈拉力」剂量（`ENGAGE_PULL_PER_CELL`，2026-09-20 用户要求解 const 后才可调）----
# 量纲 = **每格前进值多少分**。现役 1.2 分/格，而"下回合挨 1 点血"只值 `THREAT_INCOMING_W` = 0.12 分 ⇒ **1:8**，
#   这正是用户实测「开局 AI 不顾一切往前冲」的算术原因（推进 5 格 +6.0 vs 站进射程挨 6 点 −0.72）。
# `2.4` = 更爱压上（应当更冲）；`0.6` = 更谨慎（可能缩）。读三样：**挨打量**（该降）、**打出量**（不该塌）、**配对 Δpts**（不该显著为负）。
$PULL_ARMS = [ordered]@{
    'pull06' = @{ v = 0.6 }
    'pull12' = @{ v = 1.2 }   # 对照（= 现役默认，兼作"解 const 后默认档逐位不变"的自证）
    'pull24' = @{ v = 2.4 }
}
if ($Mode -eq 'pull') {
    $TIERS = [ordered]@{}
    foreach ($k in $PULL_ARMS.Keys) {
        $TIERS[$k] = @{ base = $Base; beam = 200; theta = @{ ENGAGE_PULL_PER_CELL = [double]$PULL_ARMS[$k].v } }
    }
    $GROUPS = @(@{ slug = 'PL'; base = $Base; tiers = @($PULL_ARMS.Keys) })
}

# ---- 模式 J：「概率性弱化」的 p 剂量（用户 2026-09-20 定的低档配方：简单 = 好操作 30% / 普通 = 60%）----
# ⚠️ 口径：用户说的 p = **打出好操作的概率** = 1 − `WEAK_P` ⇒ `gfire70` = 弱化 70%（简单档）、`gfire40` = 弱化 40%（普通档）。
# 两臂都配 `WEAK_MODE=5`（贪心 + 关集火 = 两档现在的弱法）。已有参照点（同口径）：gfire25 = −2.28（测不出）· gfire50 = −10.96 · gfire85 = −15.44。
$WP2_ARMS = [ordered]@{
    'hard'    = @{ mode = 0; p = 0.0 }     # 对照（困难口径）
    'gfire40' = @{ mode = 5; p = 0.40 }    # 普通档（弱化 40% / 好操作 60%）
    'gfire70' = @{ mode = 5; p = 0.70 }    # 简单档（弱化 70% / 好操作 30%）
}
if ($Mode -eq 'weakp2') {
    $TIERS = [ordered]@{}
    foreach ($k in $WP2_ARMS.Keys) {
        $th = @{}
        if ([int]$WP2_ARMS[$k].mode -gt 0) {
            $th = @{ WEAK_MODE = [int]$WP2_ARMS[$k].mode; WEAK_P = [double]$WP2_ARMS[$k].p; WEAK_SEED = 0 }
        }
        $TIERS[$k] = @{ base = $Base; beam = 200; theta = $th }
    }
    $GROUPS = @(@{ slug = 'P2'; base = $Base; tiers = @($WP2_ARMS.Keys) })
}
# ---- 模式 K（`tiers2`）：「噩梦 现在对困难的胜率」—— 用户 2026-09-20 点名 → 当天改为四档后同步 ----
# 为什么要单开一个模式：`tiers` 模式里只有 `nmare` 一条噩梦臂，而且它的基线是**旧的 6 键口径**；
#   用户要的是**现在线上跑的那一档**（噩梦 = `噩梦.json`，**通用键 + hero_XX 英雄段在同一份文件里**）。
# 两组（一份 spec 只能有一个 `base_weights` ⇒ 每档必须单独一组）：
#   · `hard`  = `RL\weights\空白基线.json`（零键 = 困难档口径）⇒ 既是对照，又是配对的基准
#   · `nmare` = `RL\weights\噩梦.json`（难度 3 = 困难 + 训练权重 + 英雄段）
# 对手恒为**困难档陪练副本**（`opp=base`，beam_opp 200）⇒ 读数的字面意义就是"这一档打困难的胜率"。
# ⚠️ 【2026-09-20 用户拍板】**第 5 档「噩梦+」已删除**（英雄段并进 `噩梦.json`）⇒ 原来的 `nplus` 臂
#   与 `造噩梦+评测权重.ps1` / `评测_噩梦+合并.json` 一并作废，这里不再列。
$TIER2_ARMS = [ordered]@{
    'hard'  = 'RL\weights\空白基线.json'
    'nmare' = 'RL\weights\噩梦.json'
}
if ($Mode -eq 'tiers2') {
    $TIERS = [ordered]@{}
    $g = @(); $gi = 0
    foreach ($k in $TIER2_ARMS.Keys) {
        $gi++
        $TIERS[$k] = @{ base = $TIER2_ARMS[$k]; beam = 200; theta = @{} }
        $g += @{ slug = ('T{0}' -f $gi); base = $TIER2_ARMS[$k]; tiers = @($k) }
    }
    $GROUPS = $g
}

function New-LadderSpec([string]$deck, [string]$deckSlug, [string]$groupBase, [string[]]$groupTiers) {
    $o = [ordered]@{
        base_weights = $groupBase
        opponent     = 'base'          # 对手 = 困难档陪练副本（各臂同一个对手）
        beam         = @{ candidate = 200; opponent = $OPP_BEAM }
        decks        = @{ enemy = $deck; player = $deck }
        seeds        = @{ train = @(); holdout = @() }
        measurement  = @{ firsts = @('p', 'e'); asides = @('e') }
        lineups      = @{ version = 'v2'; pool_size = 49; slots = 12 }
        params       = @{}
        configs      = @()
    }
    $base = Get-Content (Join-Path $PSScriptRoot 'spec_nmchk.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $o.seeds.train = @($base.seeds.train)
    $o.seeds.holdout = @($base.seeds.holdout)
    $o.lineups = $base.lineups
    $cfgs = @()
    foreach ($k in $groupTiers) {
        $cfgs += @{ name = $k; note = "难度档 $k"; theta = $TIERS[$k].theta
                    beam = $TIERS[$k].beam; beam_opp = $OPP_BEAM }
    }
    $o.configs = $cfgs
    $f = Join-Path $PSScriptRoot ("spec_ladder_{0}.json" -f $deckSlug)
    [System.IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    return $f
}

$rows = @()
$deckIdx = 0
foreach ($deck in $Decks) {
    $deckIdx++
    foreach ($grp in $GROUPS) {
        $slug = ('L{0}{1}' -f $deckIdx, $grp.slug)
        $spec = New-LadderSpec $deck $slug $grp.base $grp.tiers
        $run = ('ladder6_{0}_{1}' -f $Tag, $slug)
        & $train -Task run -Spec $spec -Run $run -SeedSet train -SeedStart $SeedStart -SeedBlock $Seeds -FixedDecks -Workers $Workers | Out-Null
        $csv = Join-Path (Join-Path $results $run) 'measure.csv'
        if (-not (Test-Path $csv)) { Write-Warning ("没有产出 measure.csv：run=$run"); continue }
        $rr = @(Import-Csv $csv | Where-Object { [string]$_.a_side -eq '1' })
        foreach ($r in $rr) {
            # 废格过滤（资产导入竞态会让整格"没打"：0 伤害 0 阵亡记成和局）
            if ([int]$r.dmgA -eq 0 -and [int]$r.dmgB -eq 0 -and [int]$r.killsA -eq 0 -and [int]$r.killsB -eq 0) { continue }
            $rows += [pscustomobject]@{
                deck = $deck; arm = $r.config; seed = $r.seed; first = $r.first
                res = $r.res; ptsA = [double]$r.ptsA; rounds = [int]$r.rounds
                dmgA = [int]$r.dmgA; dmgB = [int]$r.dmgB
                killsA = [int]$r.killsA; killsB = [int]$r.killsB
            }
        }
        Write-Host ("[deck] {0} [{1}组 base={2}] | rows={3}" -f $deck, $grp.slug, (Split-Path $grp.base -Leaf), $rr.Count)
    }
}

# ---------------- 汇总：各档 vs 困难 ----------------
Write-Host ''
Write-Host '[档位] easy = beam50 ／ normal = beam100 ／ hard = beam200（对照）／ nmare = 困难 + 噩梦.json（通用键 + hero 段）'   # 【2026-09-20】JITTER 键已删 ⇒ 低档差异只剩 beam（真正的难度由 WEAK_* 承担）
if ($Mode -eq 'tiers2') {
    Write-Host '[档位·tiers2] hard = 零键基线（= 困难口径，对照）／ nmare = 噩梦.json（通用键 + hero_XX 英雄段，同一份文件）；对手恒为困难陪练副本'
    Write-Host ("[基线 sha12] nmare = {0}" -f `
        (Get-FileHash (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'RL\weights\噩梦.json') -Algorithm SHA256).Hash.Substring(0,12))
}
$key = @{}
foreach ($r in $rows) { $key["$($r.arm)|$($r.deck)|$($r.seed)|$($r.first)"] = $r }
$ctl = 'hard'
$out = @()
foreach ($k in $TIERS.Keys) {
    $a = @($rows | Where-Object { $_.arm -eq $k })
    if ($a.Count -eq 0) { continue }
    $w = @($a | Where-Object { $_.res -eq 'W' }).Count
    $l = @($a | Where-Object { $_.res -eq 'L' }).Count
    $d = @(); $fw = 0; $fl = 0
    foreach ($c in $a) {
        $o = $key["$ctl|$($c.deck)|$($c.seed)|$($c.first)"]
        if ($null -eq $o) { continue }
        $d += ([double]$c.ptsA - [double]$o.ptsA)
        if ($c.res -eq 'W' -and $o.res -ne 'W') { $fw++ }
        if ($c.res -ne 'W' -and $o.res -eq 'W') { $fl++ }
    }
    $dm = if ($d.Count) { ($d | Measure-Object -Average).Average } else { 0.0 }
    $lo = 0.0; $hi = 0.0
    if ($d.Count -gt 1) {
        $sd = [math]::Sqrt((($d | ForEach-Object { [math]::Pow($_ - $dm, 2) }) | Measure-Object -Sum).Sum / ($d.Count - 1))
        $se = $sd / [math]::Sqrt($d.Count)
        $lo = $dm - 1.96 * $se; $hi = $dm + 1.96 * $se
    }
    $out += [pscustomobject]@{
        档 = $k; 局 = $a.Count; 胜 = $w; 负 = $l
        生产侧胜率 = [math]::Round($w / [double]([Math]::Max($w + $l, 1)), 4)
        Δpts_vs_困难 = [math]::Round($dm, 2)
        CI = ("[{0:N2},{1:N2}]" -f $lo, $hi)
        翻盘 = ("{0}胜/{1}负" -f $fw, $fl)
        配对n = $d.Count
    }
}
$out | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host '[判读] 梯度"合理"= Δpts 沿 简单 < 普通 < 困难(=0) < 噩梦 单调，且相邻两档 CI 不跨 0'
