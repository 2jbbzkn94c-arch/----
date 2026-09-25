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
    # 【2026-09-24 用户拍板·跑批默认牌组去掉慢组】原话：「你做训练的队伍可以把慢去掉啊，以后不要加进来，
    #   除非训练的主体是他们」。实测依据（同一夜，6 个默认组逐组墙钟）：前 4 组每组 3~13 分钟，
    #   而含 `hero_08`（德鲁伊）的**后两组**——`hero_46,hero_11,hero_08` 约 22 分、`hero_06,hero_08,hero_43`
    #   约 30~42 分（四臂 32 格那一档）——**合起来占掉一个模式一半以上的墙钟**，还两次撞组级硬超时
    #   （T25 的 L2PO 901s、shield 的 L6SH 2101s）。
    #   ⇒ 默认只留 4 个**快组**；**慢组改为显式 opt-in**（见下面注释里的两行，复制进 `-Decks` 即可），
    #   只有"该批的主体就是那两个英雄"（德鲁伊/塔盾/宿魂/医护兵/光环队）时才加回来。
    #   ⚠️ 牌组序号 = 它在 `-Decks` 里的位置 ⇒ 前 4 组的新序号 L1~L4 与历史完全一致（老批次的 L5/L6 仍在盘上，
    #   只是新批次不再跑）。
    [string[]]$Decks = @(
        'hero_13,hero_12,hero_18',   # L1 近战前排：嘲讽/重伤/穿刺
        'hero_24,hero_09,hero_20',   # L2 远程多
        'hero_42,hero_03,hero_17',   # L3 矿工/毒蛇/烛火
        'hero_48,hero_14,hero_25'    # L4 装甲堡垒/古拉/战锤
        # ---- 慢组（默认不跑；要跑就取消注释并放到 `-Decks` 里）----
        # 'hero_46,hero_11,hero_08', # L5 宿魂/塔盾/德鲁伊 —— 约 22 分/组
        # 'hero_06,hero_08,hero_43'  # L6 续航/光环 —— 约 30~42 分/组（**故意不用召唤队**：
        #                            #   `hero_33,hero_35,hero_05` 单位数会涨，harness 又 `time_budget_ms=0`
        #                            #   ⇒ 单步 42 秒、整队 17 分钟，见 `难度体检_6队_20260919.md` §判读4）
    ),
    [int]$Seeds = 4,
    [int]$SeedStart = 80,
    [int]$Workers = 6,
    [int]$TimeoutSec = 300,   # 【2026-09-22 新增】每格（= 2 局）的墙钟上限，透传给 Train.ps1。
                              #   原来 Train.ps1 默认 3600 ⇒ 撞上那 0.6%~1% 的"卡死格"会把整批拖住 1 小时。
                              #   正常一格 ≈ 60~80 s（实测）⇒ 300 s 足够宽，又能及时把卡死格切掉。
    [string]$Tag = 'r1',
    [string]$Base = 'RL\weights\空白基线.json',
    # 【2026-09-23 用户点名】「噩梦打困难，噩梦模式2，beam 调到 800，其他不变」⇒ 只给**噩梦那一臂**换宽度
    #   （对照臂 `hard` 恒 200、对手恒 `opp=base`）⇒ 与上一批（`-NmBeam` 默认 200）逐格可比：
    #   同一批队伍/种子/对手，唯一变化 = 噩梦自己的搜索宽度。0 = 不改（用各臂表里的默认值）。
    [int]$NmBeam = 0,
    # ===================== 【2026-09-24 用户拍板·镜像噩梦协议】 =====================
    # 用户口径原话：「训练的时候一般是同队伍打同队伍…对手得是一模一样的队伍，噩梦难度，用改之前的设置。
    #   也就是说唯一的区别是需要比较的项。同时把思考比较慢的毙了。而且你选择的队伍需要基本把所有类型的英雄覆盖」。
    # 打开 `-OppNm` 后本器具的 spec 变成：
    #   · `opponent = 'cand'` ⇒ 对手也用 fork（`RL/ai/AI_Battle.gd`，与候选**同一份代码**）
    #   · `league = { self_play_fraction: 1.0; checkpoint: <$Baseline> }` ⇒ **每一格**对手都读那份底座权重
    #     （RlTrain 会把 checkpoint 的 sha12 写进审计串与格键 ⇒ 换底座自动作废旧读数）
    #   · `base_weights = $Baseline`（**强制的**，忽略各模式自带的 base）——
    #     这一条是"唯一区别 = 被比较的项"的关键：两侧必须同一份底座，否则差的不止 θ。
    #   · beam 仍是 200/200（对手不被削弱），牌组仍是镜像（`decks.enemy == decks.player`）。
    # ⚠️ 与旧口径的关系：不开 `-OppNm` 时一切照旧（`opp=base` = 困难档陪练副本、空权重），
    #   **游戏内的陪练对手不受影响**；但两种协议的读数**不能直接比绝对值**（对手不是同一个东西）。
    # ⚠️ 代价：对手从"空权重的模式 0"变成"噩梦档的模式 2 + 去重" ⇒ 单格明显变慢，
    #   所以配套要求"把思考慢的牌组毙掉"（实测 >90 s/格 的不要）。
    [switch]$OppNm,
    # 镜像噩梦协议下两侧共用的**底座**（仓库相对路径）。默认那份是"现役生产值的冻结快照"：
    #   冻结的理由 = 批跑到一半若有人改了 `噩梦.json`，读数不至于前后不一致（RlTrain 的 checkpoint sha 也会兜底）。
    #   想 A/B 某次落地（例如今晚的 ⑫/㉕）时，把它指向改前快照即可。
    [string]$Baseline = 'RL\weights\噩梦_基线.json',
    [ValidateSet('tiers', 'tiers2', 'tiers3', 'weak', 'ruleb', 'weakp', 'weakp2', 'pull', 'nlf', 'ipool', 'merge', 'smode', 'taunt', 'p1beam', 'poison', 'shield', 'dedup', 'split', 'spread', 'apply', 'hpacc', 'bpool', 'funnel', 'p2dd', 'tpinner', 'fundiv', 'core', 'combo', 'polish')][string]$Mode = 'tiers'   # tiers = 难度四档（**旧口径**：低档=裸默认+概率弱化）；tiers2 = 噩梦/噩梦+ 对困难（用户 2026-09-20 点名）；**tiers3 = 真·难度梯度：档位互相打（简单→普通 · 普通→困难 · 困难→噩梦 · 简单→噩梦 · 普通→噩梦：A = 该组 base 那一档、B = 该组 checkpoint 那一档，2026-09-25 用户口径「前三个难度建立在噩梦基础上」+「以噩梦为唯一对比项」）**；weak = 削弱项候选；weakp/weakp2 = 概率性弱化 p 剂量；pull = 进圈拉力剂量；ipool = 血量池折算 INCOMING_POOL_W 剂量（2026-09-22）；smode = 搜索模式 SEARCH_MODE 剂量（2 对 0，2026-09-23 用户点名）；**taunt = ㉕嘲讽吸火 TAUNT_SOAK_W 剂量（0/1.5/3/6，2026-09-23 用户实机点名）**；**bpool = ⑥ 的罚按血量池折算 MOVE_ACCEPT_POOL（2026-09-24）**；**core = ⑦核心系数**混合权重** RISK_CORE_OUTPUT_W（cw0 纯身价 ／ cw25 ／ cw5，2026-09-25 用户口径「让低血量的延缓死亡时间，增加输出机会」。二选一那版 RISK_CORE_BY_OUTPUT 已删）**；**funnel = 阶段 2 漏斗宽度 TWO_PHASE_LAYOUTS 剂量（8/16/32/64，2026-09-24 用户「你把漏斗调到其他数值，跑一下」）**；原 `rtk`（真推演剂量）已于 2026-09-22 晚随引擎整段删除
)
$ErrorActionPreference = 'Stop'
$train = Join-Path $PSScriptRoot 'Train.ps1'
$results = Join-Path $PSScriptRoot 'results'

# 【2026-09-24 镜像噩梦协议】开跑前校验底座并打横幅 —— 这批读数怎么解释全靠它
if ($OppNm) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $blAbs = Join-Path $repoRoot $Baseline
    if (-not (Test-Path -LiteralPath $blAbs)) {
        throw ('-OppNm：底座权重文件不存在：' + $Baseline +
               '（镜像噩梦协议要求两侧共用同一份底座。先冻结一份快照，例：' +
               'Copy-Item RL\weights\噩梦.json RL\weights\噩梦_基线.json）')
    }
    $blSha = (Get-FileHash -LiteralPath $blAbs -Algorithm SHA256).Hash.Substring(0,12).ToUpper()
    Write-Host ('[镜像噩梦] 同码（两侧都用 fork）· 同底座 ' + $Baseline + '（sha12 ' + $blSha + '）· opp=cand · beam 200/200 · 牌组镜像 · 不限时')
    Write-Host '[镜像噩梦] ⚠️ 对手也走噩梦档（模式 2 + 同末态去重）⇒ 单格比"困难对手"慢，慢牌组必须按实测毙掉'
}

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

# 【2026-09-22 晚·整块删除】原来这里有个 `-Mode rtk`（「终选层真推演」`ROLLOUT_TOPK` 剂量 0/16/32）。
#   删因：剂量批 16/32 都与关打平（−1.72 / −1.74，CI 跨 0），实机又验出它把「对面会来打我们」判成 0
#   （模型里的玩家按我们自己的评分贪心 ⇒ 遇上 `<嘲讽>`＋反击×2 就不出手）⇒ 用户拍板「推演的不到位」
#   ⇒ 引擎整段删除、键退役 ⇒ 本模式与那两个臂一起删。依据见 `RL/progress_tracking/1_通用策略.md` §四。

# ---- 模式 FM：「队形一把尺」合并 A/B（`FORM_MERGE_MODE`，2026-09-22 晚用户点名「试一下这个合并的效果」）----
# 口径：三个臂**同一份权重**（噩梦.json）、同一个对手（困难陪练）、同一批队伍/种子，**唯一变量 = 队形怎么记**
#   · `mg0`（对照）= 现役：⑳抱团(5.0/孤立) + ㉑退路被夹(2.0) + ㉓离队梯度(3.0/格) 三项独立
#   · `mg1`       = 合并：⑳ 并进 ㉓ 当台阶（比例 5/3 ⇒ 与 ⑳+㉓ **逐点等价**，见 `RL/probe/队形合并自检.gd` 5/5 等价）
#                  + **㉑ 退役** ⇒ 与对照的唯一行为差 = 丢掉 ㉑
#   · `mg1w2`     = 合并 + 整条尺调轻 1/3（`FORM_SPREAD_CELL_W` 3.0 → 2.0）⇒ 看"合并后该取多少"
$FM_ARMS = [ordered]@{
    'mg0'   = @{ merge = 0; spread = -1.0 }    # 对照（现役三项）
    'mg1'   = @{ merge = 1; spread = -1.0 }    # 合并（㉓ 3.0/格 + 台阶）· ㉑ 退役
    'mg1w2' = @{ merge = 1; spread = 2.0 }     # 合并 + 调轻到 2.0/格
}
if ($Mode -eq 'merge') {
    $TIERS = [ordered]@{}
    foreach ($k in $FM_ARMS.Keys) {
        $th = @{ FORM_MERGE_MODE = [int]$FM_ARMS[$k].merge }
        if ([double]$FM_ARMS[$k].spread -gt 0) { $th['FORM_SPREAD_CELL_W'] = [double]$FM_ARMS[$k].spread }
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = $th }
    }
    $GROUPS = @(@{ slug = 'FM'; base = 'RL\weights\噩梦.json'; tiers = @($FM_ARMS.Keys) })
}

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
# ---- 模式 L：「血量池折算」剂量（`INCOMING_POOL_W`，2026-09-22 用户点名「跑一下 INCOMING_POOL_W，看看多少最好」）----
# 这一项管的是"**我方掉血按血量池折算**"：倍率 = `1 + W × (20 ÷ 该单位**回合起始血** − 1)`（夹 0.5~3.0），
#   只乘我方那一侧（打出去那侧由 ④集火 frac² 计价）。W=0 ⇒ 纯线性 1 分/血点（= 加这个键之前的行为）。
# ⚠️ 分母已在同一天从"当前血"改成"**回合起始血 `hp0`**"（用户拍板 A）⇒ 本批量的读数对应**新口径**：
#   同一笔伤害不再按"最惨时刻"计价、也不再受结账顺序影响。对照臂 `ip10` = 现役值。
# 读三样：配对 Δpts（相对现役）/ 我方挨打量 / 打出量与回合数（怕它变成"缩"或"送"）。
$IP_ARMS = [ordered]@{
    'ip0'  = @{ v = 0.0 }   # 关（纯线性）= 加键之前的口径
    'ip05' = @{ v = 0.5 }
    'ip10' = @{ v = 1.0 }   # 对照（= 现役 `噩梦.json`）
    'ip20' = @{ v = 2.0 }   # 更狠的池子惩罚（看曲线有没有拐点）
}
if ($Mode -eq 'ipool') {
    $TIERS = [ordered]@{}
    foreach ($k in $IP_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ INCOMING_POOL_W = [double]$IP_ARMS[$k].v } }
    }
    $GROUPS = @(@{ slug = 'IP'; base = 'RL\weights\噩梦.json'; tiers = @($IP_ARMS.Keys) })
}

# ---- 模式 S（`smode`）：「搜索模式」剂量（`SEARCH_MODE`）—— 2026-09-23 用户点名「跑一下噩梦模式2对模式0的胜率」----
# 两臂都跑在 **`噩梦.json`** 上（同一份文件、同一批键/英雄段），唯一变量 = `SEARCH_MODE`：
#   · `sm0` = 0（旧口径：每个单位的"移动+攻击"绑成一个组合、一步做完就出局）= **对照臂**
#   · `sm2` = 2（现役：两阶段联合搜索 —— 先联合走位、再联合分配出手；允许"A 挪位 → B 挪位 → C 挪位打 → B 打 → A 打"）
# 对手恒为**困难档陪练副本**（`opp=base`，beam_opp 200）⇒ 读数的字面意义 =「两种搜索模式各自打困难的胜率」，
#   而**配对 Δpts(sm2 − sm0)** 才是"模式 2 比模式 0 强多少"的直接读数（同 队伍×种子×先后手 配对）。
# ⚠️ 两点口径：① 跑批走查台把 `ai.time_budget_ms` 固定设 **0**（不限时求可复现）⇒ 本批**与生产里的
#   `TIME_BUDGET_MS` 无关**（那个键只在实机生效）；② `SEARCH_MODE` 是**规则键**（在 `Get-RuleScoreKeys`
#   里）⇒ 可以从 theta 注入，两臂的 `cand_*.json` 各自只差这一行。
$SM_ARMS = [ordered]@{ 'sm0' = 0; 'sm2' = 2 }
if ($Mode -eq 'smode') {
    $TIERS = [ordered]@{}
    foreach ($k in $SM_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ SEARCH_MODE = [int]$SM_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'SM'; base = 'RL\weights\噩梦.json'; tiers = @($SM_ARMS.Keys) })
}

# ---- 模式 T（`taunt`）：「嘲讽吸火」剂量（`TAUNT_SOAK_W`）—— 2026-09-23 用户实机点名「装甲堡垒站在
#   其他英雄的后面，起不到嘲讽的作用」⇒ 同一次改动做了两件事：① ⑭坚固的"够得着"判据换成真尺子
#   （`_threat_can_hit`，**代码里的判据修正，对四个臂同样生效**）；② 新增 ㉕`TAUNT_SOAK_W`。本批只扫 ② 的剂量。
#   · 四臂全部跑在 **`噩梦.json`** 上，唯一变量 = `TAUNT_SOAK_W`（theta 注入 ⇒ 各自 cand_*.json 只差一行）
#   · `t0`  = 关（只剩 ① 判据修正）⇒ **把"判据修正"与"新评分项"两笔效果分开的基准**
#   · `t3`  = 现役值（**对照臂**：`噩梦.json` 里就是 3.0）
#   · 读五样：配对 Δpts（相对 t3）· 生产侧胜率 · **挨打量 `dmgB`（该降）** · 打出量 `dmgA`（不该塌）· 回合数
#   ⚠️ **逐单位**的行为量（装甲堡垒前压格数 / 后排挨打血点 / 它自己挨打血点）**这批读不到** ——
#      `measure.csv` 只有全队 dmgA/dmgB ⇒ 要看它得另开探针；本批能间接看的是**第 4 队**
#      （`hero_48,hero_14,hero_25`，我方带装甲堡垒）在各臂之间的差异。
$TS_ARMS = [ordered]@{
    't0'  = 0.0    # 关（只有 ⑭判据修正那一笔）
    't15' = 1.5
    't3'  = 3.0    # 对照（= 现役 `噩梦.json`）
    't6'  = 6.0    # 更狠（看曲线有没有拐点）
}
if ($Mode -eq 'taunt') {
    $TIERS = [ordered]@{}
    foreach ($k in $TS_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ TAUNT_SOAK_W = [double]$TS_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'TS'; base = 'RL\weights\噩梦.json'; tiers = @($TS_ARMS.Keys) })
}
# ---- 模式 P1（`p1beam`）：两阶段搜索的**阶段 1 每层宽度**剂量（`TWO_PHASE_P1_BEAM`）—— 2026-09-23 深夜
#   用户拍板「5 试试」（目标：找"**不降水平**地减少搜索路径"的那个点）。病灶：实机 `[搜索分账]` 显示
#   阶段 1 花 10.6~13.5s 枚举 `BEAM`(线上 400) 套阵型，而下游 `TWO_PHASE_LAYOUTS` **只用 16 套** ⇒ 后 384 套白算。
#   · 三臂全部跑在 **`噩梦.json`** 上，唯一变量 = `TWO_PHASE_P1_BEAM`（theta 注入 ⇒ 各自 cand_*.json 只差一行）
#   · `b0`   = 0（沿用 `BEAM`；⚠️ 走查台的 spec 把 `beam` 显式设 200 ⇒ 本批实际 = 200）= **对照臂**
#   · `b96`  = 96（线上现役值；在走查台口径下是 200 → 96 的"腰斩"，**比线上 400 → 96 更狠** ⇒ 结论更保守）
#   · `b192` = 192（几乎不动 = **噪音对照**：若它与 b0 也差出好几个点，说明本批分辨率不足、别急着下结论）
#   · 读法：配对 Δpts(臂 − b0) + 生产侧胜率；⚠️ 本批**量不到"省了多少秒"** —— 走查台 `time_budget_ms = 0`
#     （不限时求可复现）⇒ 提速只能回实机看 `[搜索分账]` 里阶段 1 的秒数。登记：`1_通用策略.md` §五 T22。
#   【2026-09-24 晚·L2 重跑】T22 那条 `b96 = −2.92` 是**去重开启之前**测的：那时 beam 名额里一半装着
#   "同末态重份"⇒ 砍到 96 等于真砍掉一半**不同**的阵型。现在 `TWO_PHASE_DEDUP = 1`（生产已开）⇒
#   名额里是不同阵型，`RL/probe/路径分账自检.gd` 实测 **4/4 局面「阶段 1 宽度 96 + 漏斗 32」与 200 出招逐字相同**、
#   阶段 1 少 38~47% 时间 ⇒ 用本模式（`-OppNm` 镜像噩梦）重测 96，并补一臂 `b48` 探底。
$PB_ARMS = [ordered]@{
    'b0'   = 0      # 沿用 BEAM（走查台 beam = 200）= 对照
    'b192' = 192    # 噪音对照
    'b96'  = 96     # 线上现役值（T22 那次 −2.92；⚠️ 那是**去重之前**的读数）
    'b48'  = 48     # 【2026-09-24·L2】探底：去重开启后能不能再往下砍一半
}
if ($Mode -eq 'p1beam') {
    $TIERS = [ordered]@{}
    foreach ($k in $PB_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ TWO_PHASE_P1_BEAM = [int]$PB_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'PB'; base = 'RL\weights\噩梦.json'; tiers = @($PB_ARMS.Keys) })
}

# ---- 模式 L（`poison`）：⑫猛毒计价的「(每跳单价, 跳数上限)」剂量批 ----
# 起因（2026-09-23 深夜·用户原话）：「我是觉得 4 和 2.5 不合理。4 血这也太苛刻了」。
# 查证成立且更严重：真实血量区间 **13~40**（`Data/Hero/Source/角色列表.json`，中位 19；50 个英雄里
#   ≤4 血的只有骷髅兵）⇒ `min(血,4)` 对**全部真英雄满血都等于 4** ⇒ ⑫ 退化成"有毒 = +10"的纯开关
#   （设计意图"目标选择偏向毒优势最大的"零实现）；而唯一有区分度的区间（≤4 血）方向还是反的。
# ⚠️ 两个数**必须一起扫**：封顶低 ⇒ 单价 2.5 那条"打瘦倒扣 2.5/血、而 ③只给 1.0/血"的反向激励
#   只在 ≤4 血时发作、平时看不见；**只抬封顶不降单价**会让它扩散到全程（AI 更不愿打已中毒的人）。
#   硬约束 = **单价 ≤ 1.0** 才保证"打已中毒的人"不亏（净值 = ③的 1.0 − 单价）。
# 臂（`POISON_TICK_VALUE` × `POISON_MAX_TICKS`）：
#   · `p0`     = 0 / 4    ⇒ **关掉 ⑫**（看这一项总共值多少分）
#   · `p25t4`  = 2.5 / 4  ⇒ **现役口径**（对照臂，Δpts 读作 `臂 − p25t4`）
#   · `p05t20` = 0.5 / 20 （① 上限 10；中位 19 血 ≈ 9.5 ≈ 现役，13~20 血开始区分）
#   · `p05t40` = 0.5 / 40 （② **真正"血越多越值"**；塔盾 40 血 = 20 分）
#   · `p025t40`= 0.25 / 40（③ 上限 10；区分度最好、力度最小）
# ⚠️ **默认牌组里只有 1/6 含毒蛇**（`hero_42,hero_03,hero_17`）⇒ 不指定 `-Decks` 的话 5/6 的牌组里
#   ⑫ 恒为 0、纯属白跑。推荐配一组**全部含 hero_03** 的牌组，见 `1_通用策略.md` §五 T25。
# ⚠️⚠️ **基线必须用 `噩梦_测毒.json`（不是 `噩梦.json`）** —— 2026-09-24 实测踩到的坑：
#   `POISON_TICK_VALUE` / `POISON_APPLY_W` 走 `_wh(施加者.hero_id, key, 扁平兜底)` ⇒ **英雄段里的值赢**，
#   而 `噩梦.json` 的 `hero_03` 段写着 2.5 / 3.0 ⇒ theta 注入的扁平价被**压住**：`p0` 不等于"关掉"、
#   `p05*` 也不等于 0.5（**价格臂等于没改**，只有 `POISON_MAX_TICKS` 真的生效）⇒ 那一批整批作废。
#   `噩梦_测毒.json` = `噩梦.json` 剥掉 `hero_03` 段 + 扁平补 `POISON_APPLY_W = 3.0`
#   ⇒ **对手侧仍与线上逐位相同**（现役两条路都是 2.5 / 3.0），候选臂的扁平 theta 才真正生效。
#   （凡是 `_wh()` 读的键都适用这条：POISON_* / SOLID_HOLD_W / SILENCE_VALUE_W / THORN_PIN_* /
#     PARALYZE_ZERO_W / POSSESS_TARGET_W / GOLD_*。）
$PO_ARMS = [ordered]@{
    'p0'      = @{ v = 0.0;  t = 4  }
    'p25t4'   = @{ v = 2.5;  t = 4  }
    'p05t20'  = @{ v = 0.5;  t = 20 }
    'p05t40'  = @{ v = 0.5;  t = 40 }
    'p025t40' = @{ v = 0.25; t = 40 }
}
if ($Mode -eq 'poison') {
    $TIERS = [ordered]@{}
    foreach ($k in $PO_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦_测毒.json'; beam = 200; theta = @{
            POISON_TICK_VALUE = [double]$PO_ARMS[$k].v
            POISON_MAX_TICKS  = [int]$PO_ARMS[$k].t
        } }
    }
    $GROUPS = @(@{ slug = 'PO'; base = 'RL\weights\噩梦_测毒.json'; tiers = @($PO_ARMS.Keys) })
}
# ---- 模式 M（`shield`）：㉔破盾 `SHIELD_BREAK_W` 剂量批（T20）----
# 口径 = `SHIELD_BREAK_DMG_REF(1.0) / max(这一击伤害, 1.0)` ⇒ **伤害越低破盾越值**。值 4.0 是首版体感值。
# 读法：配对 Δpts(臂 − 4.0) + 生产侧胜率；顺带看"poke 拆盾"出现率（日志里 ㉔破盾 那一项非零的次数）。
$SH_ARMS = [ordered]@{ 's0' = 0.0; 's2' = 2.0; 's4' = 4.0; 's8' = 8.0 }   # s4 = 现役（对照）
if ($Mode -eq 'shield') {
    $TIERS = [ordered]@{}
    foreach ($k in $SH_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ SHIELD_BREAK_W = [double]$SH_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'SH'; base = 'RL\weights\噩梦.json'; tiers = @($SH_ARMS.Keys) })
}

# ---- 模式 C（`core`）：⑦核心风险"核心系数**混合权重**"`RISK_CORE_OUTPUT_W` 的**棋力**批（2026-09-25）----
# 为什么要跑：用户口径「让低血量的延缓死亡时间，增加输出机会」—— ⑦ 现在按**身价**挑核心，而身价走面板值、
#   含 `max_hp × 0.45` ⇒ 实测倒挂（塔盾 1 攻/40 血 20.10 > 白游侠 2 攻/19 血 18.85）⇒ ⑦ 更护着打不出伤害的肉。
# 核心系数 = `身价^(1−w) × 输出潜力^w`：`cw0` = 现役（纯身价，对照）· `cw25` = 混一点 · `cw5` = 两者相乘开方。
# ⚠️ 先试过**二选一**（旧键 `RISK_CORE_BY_OUTPUT` 硬切纯输出潜力）：`c1 − c0 = −3.13 [−7.26,+1.01]`
#   （4 组里 3 组偏负、打出/局还降 1.3）⇒ 那个键**已删**，登记见 `1_通用策略.md` §四 已删表 / §五 T34。
# 读法：配对 Δpts(臂 − cw0) + 生产侧胜率 + 挨打/打出/回合；探针 `RL/probe/核心保谁自检.gd` 看"该保谁"的排序变化。
$CORE_ARMS = [ordered]@{ 'cw0' = 0.0; 'cw25' = 0.25; 'cw5' = 0.5 }
if ($Mode -eq 'core') {
    $TIERS = [ordered]@{}
    foreach ($k in $CORE_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ RISK_CORE_OUTPUT_W = [double]$CORE_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'CO'; base = 'RL\weights\噩梦.json'; tiers = @($CORE_ARMS.Keys) })
}

# ---- 模式 N（`dedup`）：阶段 1「同末态去重」`TWO_PHASE_DEDUP` 的**棋力**批（T23）----
# 为什么要跑：去重在机制上"只省算、不改漏斗 top-16"，但那条推理有两个理论边界（同分并列的取舍、
#   T4 那个 `_evaluate` 共享缓存的顺序依赖）⇒ 要坐实"不降水平"必须跑整局。d1 = 现役（对照）。
$DD_ARMS = [ordered]@{ 'd0' = 0; 'd1' = 1 }
if ($Mode -eq 'dedup') {
    $TIERS = [ordered]@{}
    foreach ($k in $DD_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ TWO_PHASE_DEDUP = [int]$DD_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'DD'; base = 'RL\weights\噩梦.json'; tiers = @($DD_ARMS.Keys) })
}

# ---- 模式 P（`bpool`）：⑥ 的罚"按血量池折算"`MOVE_ACCEPT_POOL`（2026-09-24·用户拍板方案 A）----
# 病灶（用户实机 + 逐行读码）：⑥ 的阈值(4)与斜率(1.0/点)对**所有人一样** ⇒ 坦克与脆皮同罚
#   （荆棘树人 22 血吃 11 伤罚 7 分、风语者 14 血吃 11 伤**也**罚 7 分），而 ③血量账 / ㉕嘲讽吸火
#   都乘 `_incoming_pool_mult(u)` ⇒ ⑥ 是**唯一没用那把尺子**的地方 ⇒ 坦克的本职（嘲讽/坚固/替后排吃）
#   在开局被自己人罚，表现出来就是"坦克往角落缩、能打却不打"。
# 1 = 开：`罚 × 池倍率`（22 血吃 11 伤 ⇒ 6.4；14 血吃 11 伤 ⇒ 10.0；池强度仍由 `INCOMING_POOL_W` 决定）。
# bp0 = 现役（对照）。读法：配对 Δpts(臂 − bp0) + 挨打/打出/回合 + 生产侧胜率。
$BP_ARMS = [ordered]@{ 'bp0' = 0; 'bp1' = 1 }
if ($Mode -eq 'bpool') {
    $TIERS = [ordered]@{}
    foreach ($k in $BP_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ MOVE_ACCEPT_POOL = [int]$BP_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'BP'; base = 'RL\weights\噩梦.json'; tiers = @($BP_ARMS.Keys) })
}

# ---- 模式 U（`fundiv`）：**漏斗名额按"战术轮廓"多样化** `FUNNEL_DIVERSITY`（2026-09-25·用户「还有什么能减少路径的」→「你都试试，比比哪个效果好」）----
# 背景：漏斗（`TWO_PHASE_LAYOUTS`）只按代理分取前 N 名，而「83% 的局面分差 < 0.5」⇒ 前 N 名里常常一半是
#   **同一个战术想法的不同写法**（阶段 2 排出来的计划也一样）⇒ 名额的信息量被浪费。本键 = 给"同轮廓"限席
#   （轮廓 = 我方每个单位够得到的敌人），送进阶段 2 的**套数不变**（成本不变），只是这 N 套里"不同想法"更多。
# 四臂（都跑在新基线 `噩梦_基线_0925.json` 上，漏斗 N 用 `TWO_PHASE_LAYOUTS` 注入）：
#   · `p16` = N16 + 限席关（**今天的生产行为** = 对照）
#   · `p8`  = N8 + 限席关（**单纯把漏斗砍一半**，量"少走路掉不掉水平"）
#   · `d8`  = N8 + 限席 2（**同样 8 个名额，但按不同想法分配**）
#   · `d8s1`= N8 + 限席 1（把"每种想法只留一套"压到底，**探针里唯一真改写出招的那档**）
# 读法：`p8 − p16` = 砍路的代价；`d8 − p8` = 同样名额下"选法改好"值多少；`d8 − p16` = 少走路还能不能持平。
# ⚠️ 2026-09-25 03:1x 探针先跑（`RL/probe/路径分账自检.gd` · 4 局面 · 见 T36）：**限席 2 在 4/4 局面上一次都没触发**
#   （`d8` 与 `p8` 出招指纹/终局分数/`leaves` 逐字相同）⇒ 追加 `d8s1` = **限席 1**（真会改写漏斗内容的那一档）。
$FD_ARMS = [ordered]@{
    'p16' = @{ TWO_PHASE_LAYOUTS = 16; FUNNEL_DIVERSITY = 0 }
    'p8'  = @{ TWO_PHASE_LAYOUTS = 8;  FUNNEL_DIVERSITY = 0 }
    'd8'  = @{ TWO_PHASE_LAYOUTS = 8;  FUNNEL_DIVERSITY = 2 }
    'd8s1' = @{ TWO_PHASE_LAYOUTS = 8; FUNNEL_DIVERSITY = 1 }
}
if ($Mode -eq 'fundiv') {
    $TIERS = [ordered]@{}
    foreach ($k in $FD_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = $FD_ARMS[$k] }
    }
    $GROUPS = @(@{ slug = 'FD'; base = 'RL\weights\噩梦.json'; tiers = @($FD_ARMS.Keys) })
}

# ---- 模式 W（`polish`）：**搜索后的"逐单位复查"** `TWO_PHASE_POLISH`（2026-09-25·用户「长剑是步臭棋…他本来可以打 6 伤」）----
# 病灶：两阶段搜索挑的是"整套阵型"，阶段 1 的**代理分**把"某单位换一手"的那套挤出漏斗（线上 N = 8）
#   ⇒ 那一手永远看不到（引擎自己的诊断叫「疑似被搜索漏掉（剪枝）」）。用户那局思考 2.0s / 上限 40s（时间没花完）。
# 三臂（都按**今天生产**的口径注入：N = 8 + INNER = 16；底座仍走 `-Baseline` 的 0925 快照）：
#   · `p0`  = 复查关（**对照 = 今天生产**）
#   · pl1 = 复查一趟 · pl2 = 复查最多两趟（不再改进就停）
# 读法：`pl1 − p0` / `pl2 − p0` = 复查值多少棋力、多花多少墙钟；实机抬头行会打「复查（逐单位改良）：换 N 手 / +X.X 分 / Yms」。
$PL_ARMS = [ordered]@{
    'p0'  = @{ TWO_PHASE_LAYOUTS = 8; TWO_PHASE_INNER = 16; TWO_PHASE_POLISH = 0 }
    'pl1' = @{ TWO_PHASE_LAYOUTS = 8; TWO_PHASE_INNER = 16; TWO_PHASE_POLISH = 1 }
    'pl2' = @{ TWO_PHASE_LAYOUTS = 8; TWO_PHASE_INNER = 16; TWO_PHASE_POLISH = 2 }
}
if ($Mode -eq 'polish') {
    $TIERS = [ordered]@{}
    foreach ($k in $PL_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = $PL_ARMS[$k] }
    }
    $GROUPS = @(@{ slug = 'PL'; base = 'RL\weights\噩梦.json'; tiers = @($PL_ARMS.Keys) })
}

# ---- 模式 V（`combo`）：**两项算力键"联合落地"批**（2026-09-25·用户「3跑一个」）----
# 背景：(a) 内层宽度 `TWO_PHASE_INNER` 25→16（T35：48 配对 +0.54 [−0.62,+1.70]、墙钟 −5~11%）与
#   (b) 漏斗宽度 `TWO_PHASE_LAYOUTS` 16→8（T36：48 配对 +1.96 [−0.38,+4.30]、墙钟 −18%、召唤 −21%）
#   **各自都没量到棋力损失**。本批 = 同一条协议上把两者**一起落**，量：
#   · `p16`   = N16 + INNER25 = **今天生产**（对照 = 噪音对照）
#   · `p8`    = N8  + INNER25（(b) 那一档，核对本批与 T36 对得上）
#   · `i16`   = N16 + INNER16（(a) 那一档）
#   · `c8i16` = N8  + INNER16 = **联合落地候选**（要看的就这一格）
# 读法：`c8i16 − p16` = 联合能省多少、掉不掉水平；`c8i16 − p8` / `c8i16 − i16` = 交互项（两项可否相加）。
# ⚠️ 两侧都用基线 `噩梦_基线_0925.json`（含 P1_BEAM 96 / INNER 25 / P2_DEDUP 1 / SUMMON_SLOT_ONLY 1）
#   ⇒ `p16` 那一臂 = 基线本身（应当量出 0.00 = 噪音对照）。
# ⚠️ 本块**必须留在 `if ($Mode -eq …)` 顶层**：第一版插在 fundiv 的 `{ }` 里 ⇒ `-Mode combo` 静默退回默认
#   tiers（四档批），跑了一分钟才发现。改这一段后务必用 `[Parser]::ParseFile` + 看 `[run] run=… configs=` 复核。
$CB_ARMS = [ordered]@{
    'p16'   = @{ TWO_PHASE_LAYOUTS = 16; TWO_PHASE_INNER = 25 }
    'p8'    = @{ TWO_PHASE_LAYOUTS = 8;  TWO_PHASE_INNER = 25 }
    'i16'   = @{ TWO_PHASE_LAYOUTS = 16; TWO_PHASE_INNER = 16 }
    'c8i16' = @{ TWO_PHASE_LAYOUTS = 8;  TWO_PHASE_INNER = 16 }
}

if ($Mode -eq 'combo') {
    $TIERS = [ordered]@{}
    foreach ($k in $CB_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = $CB_ARMS[$k] }
    }
    $GROUPS = @(@{ slug = 'CB'; base = 'RL\weights\噩梦.json'; tiers = @($CB_ARMS.Keys) })
}

# ---- 模式 T（`tpinner`）：**阶段 2 内层宽度** `TWO_PHASE_INNER` 剂量批（2026-09-25·用户「还有什么能减少路径的」→「你都试试」）----
# 背景：阶段 2 对每套阵型还跑一个"谁打谁"的内层 beam，宽度原来写死 = `beam / 8` ⇒ 线上 `BEAM=400` 时
#   inner = 50（走查台 200 ⇒ 25），而阶段 2 的评估次数 `leaves` **恒 = 阵型数 × inner**。
#   2026-09-25 已把 `TWO_PHASE_INNER = 25` 写进生产（探针：召唤局 19.6s → 13.6s、4/4 局面逐位相同）。
# 本批 = 在**新基线 `噩梦_基线_0925.json`**（= 含 P1_BEAM 96 / INNER 25 / P2_DEDUP 1 / SUMMON_SLOT_ONLY 1
#   的生产档快照）上继续往下探：
#   · `t25` = 25（**噪音对照**：与基线同值 ⇒ 应当量出 0.00，用来判本批分辨率）
#   · `t16` = 16（探针里逐位相同过的档）· `t12` = 12（再往下探底）
#   ⚠️ 走查台 `beam = 200` 时 `beam/8 = 25` ⇒ 不注入 theta 就是 25，所以 `t25` 只能当对照用。
$TI_ARMS = [ordered]@{ 't25' = 25; 't16' = 16; 't12' = 12 }
if ($Mode -eq 'tpinner') {
    $TIERS = [ordered]@{}
    foreach ($k in $TI_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ TWO_PHASE_INNER = [int]$TI_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'TI'; base = 'RL\weights\噩梦.json'; tiers = @($TI_ARMS.Keys) })
}

# ---- 模式 Q（`funnel`）：**阶段 2 漏斗宽度** `TWO_PHASE_LAYOUTS` 剂量批（2026-09-24·用户「你把漏斗调到其他数值，跑一下」）----
# 背景：阶段 1 枚举 `BEAM` 套阵型（跑批里 beam=200），排序后**只把前 N 套送进阶段 2**（N = 本键，原写死 16）。
#   T24 已经用"改常量 + 重建副本 + 同一个局面"试过 16 → 32 ⇒ 出招**逐字相同**、阶段 2 完整计划 1520 → 3104、
#   思考 12.5s → 27.0s（"漏斗不是瓶颈"）。但那是**单局面**读数，而且只有"往上"一个方向。
# 本批量两件事：① 往下（8）—— 若不变 ⇒ 阶段 2 的一半预算可以省掉（**算力收益**）；
#   ② 往上（32）—— 用配对批（4 组 × 4 种子 × 双先后手）坐实 T24 的单局面结论。
# ⚠️ **没跑 64**：阶段 2 成本 ≈ 线性 ⇒ 64 比 16 贵约 4 倍（预计每格墙钟 ×3~4），而 T24 已证"往上"无出招变化
#   ⇒ 先看 32；若 32 出招也不变，就没有理由再往上加。
# 对照 = `fn16` = 现役值（引擎默认也是 16 ⇒ 这一臂应当与"不注入"逐位相同）。
# ⚠️ 读法：配对 Δpts(臂 − fn16) + 挨打/打出/回合 + 单格墙钟（`throughput.csv`）；32 那臂会更慢。
$FN_ARMS = [ordered]@{ 'fn8' = 8; 'fn16' = 16; 'fn32' = 32 }
if ($Mode -eq 'funnel') {
    $TIERS = [ordered]@{}
    foreach ($k in $FN_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ TWO_PHASE_LAYOUTS = [int]$FN_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'FN'; base = 'RL\weights\噩梦.json'; tiers = @($FN_ARMS.Keys) })
}

# ---- 模式 R（`p2dd`）：**阶段 2 的"同末态去重"** `TWO_PHASE_P2_DEDUP`（2026-09-24·用户「做L1」）----
# 背景（`RL/probe/路径分账自检.gd` 的路径账）：阶段 2 的完整计划数 `leaves` **恒 = 漏斗 × max(4, beam/8)**，
#   且阶段 2 占整局 **44~89%**（召唤队 97%）⇒ 阶段 2 就是"漏斗宽度"的乘法器；而它的枚举结构与阶段 1
#   **去重之前**完全同构（逐层决定"谁先出手"），阶段 2 连位置都不变 ⇒ 只是出手顺序不同的条目末态逐位相同。
# 三臂（都把漏斗写清楚，免得读的人对不上）：
#   `p0` = **现役**（漏斗 16 · 去重 0）= 对照
#   `p1` = 漏斗 16 · 去重 **1**      ⇒ 量"**不降水平 + 省多少墙钟**"（预期 Δ≈0、阶段 2 掉 30~50%）
#   `q1` = 漏斗 **32** · 去重 **1**  ⇒ 量"**用省下来的预算换 T30 那 +3.11**"（预期 Δ>0、墙钟 ≈ p0）
# ⚠️ 读法：配对 Δpts(臂 − p0) + 挨打/打出/回合 + 单格墙钟；**墙钟是本批的主角**（棋力那一半已知）。
$PD_ARMS = [ordered]@{
    'p0' = @{ TWO_PHASE_LAYOUTS = 16; TWO_PHASE_P2_DEDUP = 0 }
    'p1' = @{ TWO_PHASE_LAYOUTS = 16; TWO_PHASE_P2_DEDUP = 1 }
    'q1' = @{ TWO_PHASE_LAYOUTS = 32; TWO_PHASE_P2_DEDUP = 1 }
}
if ($Mode -eq 'p2dd') {
    $TIERS = [ordered]@{}
    foreach ($k in $PD_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = $PD_ARMS[$k] }
    }
    $GROUPS = @(@{ slug = 'PD'; base = 'RL\weights\噩梦.json'; tiers = @($PD_ARMS.Keys) })
}

# ---- 模式 O（`split`）：㉒隔断 `SPLIT_W` 剂量批（T16）----
# 值 2.0 是首版体感值（探针只证明"机制会动"）。sp2 = 现役（对照）。
$SP_ARMS = [ordered]@{ 'sp0' = 0.0; 'sp2' = 2.0; 'sp4' = 4.0 }
if ($Mode -eq 'split') {
    $TIERS = [ordered]@{}
    foreach ($k in $SP_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ SPLIT_W = [double]$SP_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'SP'; base = 'RL\weights\噩梦.json'; tiers = @($SP_ARMS.Keys) })
}

# ---- 模式 P（`spread`）：㉓离队距离 `FORM_SPREAD_CELL_W` 剂量批（T17）----
# 值 3.0 是首版体感值（推导：位置拉力 2.4/格 ⇒ 梯度要 > 2.4）。f3 = 现役（对照）。
# ⚠️ 这是**评分项** ⇒ 别只看胜率，同时看风格读数：队伍离散度 / 挨打量。
$FS_ARMS = [ordered]@{ 'f0' = 0.0; 'f3' = 3.0; 'f6' = 6.0 }
if ($Mode -eq 'spread') {
    $TIERS = [ordered]@{}
    foreach ($k in $FS_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ FORM_SPREAD_CELL_W = [double]$FS_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'FS'; base = 'RL\weights\噩梦.json'; tiers = @($FS_ARMS.Keys) })
}

# ---- 模式 Q（`apply`）：⑯猛毒新挂 `POISON_APPLY_W` 剂量批（T26）----
# 它是 T6 的体感值 3.0，从来没单独验证过（与 ⑫ 互补：⑫ 付状态钱、⑯ 付动作钱）。
# ⚠️ **基线必须用 `噩梦_测毒.json`**：`POISON_APPLY_W` 也是 `_wh()` 按英雄段覆盖读的
#   （`hero_03` 段写着 3.0）⇒ 拿 `噩梦.json` 跑 theta 会被段里的 3.0 压住、臂等于没改。a3 = 现役（对照）。
$AP_ARMS = [ordered]@{ 'a0' = 0.0; 'a3' = 3.0; 'a6' = 6.0 }
if ($Mode -eq 'apply') {
    $TIERS = [ordered]@{}
    foreach ($k in $AP_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦_测毒.json'; beam = 200; theta = @{ POISON_APPLY_W = [double]$AP_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'AP'; base = 'RL\weights\噩梦_测毒.json'; tiers = @($AP_ARMS.Keys) })
}

# ---- 模式 R（`hpacc`）：血量账族 `HP_VALUE_W` 剂量批 ----
# ③血量账 的单价（1 血 = 多少分）。默认 1.0（噩梦档没写它）。h10 = 现役（对照）。
# 同族的 `FOCUS_FIRE_WEIGHT`(30) / `HEAL_CREDIT_W`(1.0) / `INCOMING_POOL_W`(1.0) 本轮固定不动，留待下一批。
$HP_ARMS = [ordered]@{ 'h05' = 0.5; 'h10' = 1.0; 'h20' = 2.0 }
if ($Mode -eq 'hpacc') {
    $TIERS = [ordered]@{}
    foreach ($k in $HP_ARMS.Keys) {
        $TIERS[$k] = @{ base = 'RL\weights\噩梦.json'; beam = 200; theta = @{ HP_VALUE_W = [double]$HP_ARMS[$k] } }
    }
    $GROUPS = @(@{ slug = 'HP'; base = 'RL\weights\噩梦.json'; tiers = @($HP_ARMS.Keys) })
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
        # 【2026-09-23 用户点名】`-NmBeam` 只改**噩梦那一臂**的搜索宽度（对照臂 `hard` 恒 200、对手恒
        #   `opp=base`）⇒ 与默认批（200）**逐格可比**：同一批队伍/种子/对手，唯一变化 = 噩梦自己的宽度。
        $bm = 200
        if ($k -eq 'nmare' -and $NmBeam -gt 0) { $bm = $NmBeam }
        $TIERS[$k] = @{ base = $TIER2_ARMS[$k]; beam = $bm; theta = @{} }
        $g += @{ slug = ('T{0}' -f $gi); base = $TIER2_ARMS[$k]; tiers = @($k) }
    }
    $GROUPS = $g
}

# ---- 模式 L（`tiers3`）：「**真·难度梯度**」—— 照实读四份**生产权重文件**（2026-09-25 新口径）----
# 为什么要新模式：2026-09-25 用户拍板「把前三个难度按照噩梦的基础上修改」+「困难和噩梦的区别就是专属键和概率弱智」
#   ⇒ 低三档不再是"裸默认 + 概率弱化"，而是由 `RL\train\派生低档权重.ps1` 从 `噩梦.json` **派生**的文件
#   （通用评分键照抄噩梦 / 不抄算力键 / 不带 hero_XX 英雄段 / 三档之间只差 `WEAK_P`）。
#   ⇒ 本模式**不做任何 θ 注入**，直接读那几份文件，量"档位打档位"的强度差。
#   · 每对单独一组（一份 spec 只能有一个 `base_weights`）：**A 方 = 该档自己的文件**（`base_weights`），
#     **B 方 = 另一档的文件**（`league.checkpoint` + `opp=cand` ⇒ 用 fork 跑，与 A 同码同宽度）
#     ⇒ 读数的字面意义 = 「**A 打 B**」：A 生产侧胜率 < 50%、pts/game < 0 ⇒ A 更弱。
#   · 【2026-09-25 用户口径】「也可以用简单打普通，普通打困难，困难打噩梦，这样子也能看出强度梯度」
#     +「以噩梦难度为唯一对比项」⇒ 默认五对：`简单→普通` · `普通→困难` · `困难→噩梦` ·
#     `简单→噩梦` · `普通→噩梦`（前三条 = 相邻梯度，后两条 = 都跟噩梦比）。
#   · ⚠️ 走查台把 `beam` 交给 spec 覆盖（不读文件里的 `BEAM`）⇒ 双方都跑 200；
#     但 `SEARCH_MODE=2`（两阶段）由文件驱动 ⇒ 带算力键的那几档确实跑两阶段（单格会明显更慢）。
#   · 判读：相邻三条应出现「A 明显打不过 B」（胜率 < 50%）；三条 vs 噩梦的落差应随档位单调收窄。
#   · 改完权重文件后想复测梯度，就重跑本模式（Tag 换一个即可）。
$TIER3_PAIRS = @(
    @{ a = 'RL\weights\简单.json'; b = 'RL\weights\普通.json';  arm = 'easy_vs_norm'  },
    @{ a = 'RL\weights\普通.json'; b = 'RL\weights\困难.json';  arm = 'norm_vs_hard'  },
    @{ a = 'RL\weights\困难.json'; b = 'RL\weights\噩梦.json';  arm = 'hard_vs_nmare' },
    @{ a = 'RL\weights\简单.json'; b = 'RL\weights\噩梦.json';  arm = 'easy_vs_nmare' },
    @{ a = 'RL\weights\普通.json'; b = 'RL\weights\噩梦.json';  arm = 'norm_vs_nmare' }
)
if ($Mode -eq 'tiers3') {
    $TIERS = [ordered]@{}
    $g = @(); $gi = 0
    foreach ($p in $TIER3_PAIRS) {
        $gi++
        $TIERS[$p.arm] = @{ base = $p.a; beam = 200; theta = @{} }
        $g += @{ slug = ('D{0}' -f $gi); base = $p.a; opp = $p.b; tiers = @($p.arm) }
    }
    $GROUPS = $g
}

function New-LadderSpec([string]$deck, [string]$deckSlug, [string]$groupBase, [string[]]$groupTiers) {
    # 【2026-09-24】镜像噩梦协议：两侧同码、同底座、同牌组、同宽度 ⇒ 唯一差别 = config 里的 θ。
    #   `$OppNm` 打开时**强制**用 `$Baseline` 当 base（并且与 league.checkpoint 同一份）——
    #   若某个模式自带的 base 与它不同（例如 poison/apply 用的 `噩梦_测毒.json`），这里打印一行警告，
    #   因为"两侧不同底座"就不再是"唯一区别 = 被比较的项"了。
    $baseForSpec = $groupBase
    if ($OppNm) {
        $baseForSpec = $Baseline
        if ($groupBase -ne $Baseline) {
            Write-Host ('[镜像噩梦] ⚠️ 本模式的 base（' + $groupBase + '）与底线（' + $Baseline + '）不同 ⇒ 已强制换成底线（否则两侧不止差 θ）')
        }
    }
    $o = [ordered]@{
        base_weights = $baseForSpec
        opponent     = $(if ($OppNm) { 'cand' } else { 'base' })   # cand = 对手也用 fork（镜像噩梦）
        beam         = @{ candidate = 200; opponent = $OPP_BEAM }
        decks        = @{ enemy = $deck; player = $deck }
        seeds        = @{ train = @(); holdout = @() }
        measurement  = @{ firsts = @('p', 'e'); asides = @('e') }
        lineups      = @{ version = 'v2'; pool_size = 49; slots = 12 }
        params       = @{}
        configs      = @()
    }
    if ($OppNm) {
        $o['league'] = @{ self_play_fraction = 1.0; checkpoint = $Baseline; base_opp_beam = $OPP_BEAM }
    }
    # 【2026-09-25 用户拍板】`tiers3`（真·难度梯度）的**对比项 = 另一档的权重文件**（默认噩梦）：
    #   用户口径：「也可以用简单打普通，普通打困难，困难打噩梦，这样子也能看出强度梯度」+
    #   「以噩梦难度为唯一对比项」⇒ 每个 group 自带一个 `opp` 文件：A 方 = `base_weights`（该档自己），
    #   B 方 = fork + `opp` 文件（`$script:OppFile`）⇒ Δ/胜负的字面意义 = 「A 打 B」。
    #   为什么不用 `opp=base` 的陪练副本：那条路默认**不传 B 方权重**（实测 `nB=0` = 零键 = 旧困难口径），
    #   而用户要的是"档位之间互相打"。
    if ($script:OppFile) {
        $o['opponent'] = 'cand'
        $o['league'] = @{ self_play_fraction = 1.0; checkpoint = $script:OppFile; base_opp_beam = $OPP_BEAM }
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
        # 【2026-09-25】`tiers3` 的每组自带对手文件（`$grp.opp`）：A = 该组 base、B = 这个文件。
        $script:OppFile = $(if ($grp.ContainsKey('opp')) { [string]$grp.opp } else { '' })
        $spec = New-LadderSpec $deck $slug $grp.base $grp.tiers
        $run = ('ladder6_{0}_{1}' -f $Tag, $slug)
        & $train -Task run -Spec $spec -Run $run -SeedSet train -SeedStart $SeedStart -SeedBlock $Seeds -FixedDecks -Workers $Workers -TimeoutSec $TimeoutSec | Out-Null
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
if ($Mode -eq 'smode') {
    Write-Host '[档位·smode] sm0 = SEARCH_MODE 0（旧口径，对照）／ sm2 = SEARCH_MODE 2（现役两阶段联合搜索）；两臂同一份 `噩梦.json`、对手恒为困难陪练副本'
    Write-Host '[档位·smode] ⚠️ 下表那一列 `Δpts_vs_困难` 在本模式读作 **Δpts(sm2 − sm0)**（对照臂 = sm0，配对口径同其它模式）'
}
if ($Mode -eq 'tiers3') {
    Write-Host '[档位·tiers3] **真·难度梯度（2026-09-25 新口径）**：照实读生产权重文件，**档位之间互相打**（A = base_weights 那一档，B = 该组的 `league.checkpoint` 那一档，两侧同码同宽度 200）'
    Write-Host '[档位·tiers3] 五对 = 简单→普通 · 普通→困难 · 困难→噩梦（相邻三条，看梯度）· 简单→噩梦 · 普通→噩梦（都跟噩梦比）；三份低档由 `RL\train\派生低档权重.ps1` 从 噩梦.json 派生（通用评分键照抄 / 简单普通不写算力键 / 困难两阶段+400+25s / 无 hero_XX 段 / 只差 WEAK_P=0.70·0.40·0.20）'
    Write-Host '[档位·tiers3] ⚠️ 本模式下表那一列 `Δpts_vs_困难` **读不了**（每组只有一条臂、且对手各不相同）⇒ 看 **生产侧胜率**（< 50% = A 打不过 B）与 `pts/game` 的符号；走查台把 beam 交给 spec（200）⇒ 文件里的 BEAM=400 本批量不到，但 SEARCH_MODE=2 由文件驱动、照跑（带算力键的格子会明显更慢）'
    foreach ($p in $TIER3_PAIRS) {
        $line = '[档位·tiers3] ' + $p.arm + ' ： A = ' + $p.a
        foreach ($f in @($p.a, $p.b)) {
            $full = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) $f
            $line += $(if (Test-Path $full) { '' } else { ' ⚠️缺文件' })
        }
        $shaA = (Get-FileHash (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) $p.a) -Algorithm SHA256).Hash.Substring(0,12)
        $shaB = (Get-FileHash (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) $p.b) -Algorithm SHA256).Hash.Substring(0,12)
        Write-Host ($line + '（sha12 ' + $shaA + '） 打 B = ' + $p.b + '（sha12 ' + $shaB + '）')
    }
}
if ($Mode -eq 'tiers2') {
    Write-Host '[档位·tiers2] hard = 零键基线（= 困难口径，对照）／ nmare = 噩梦.json（通用键 + hero_XX 英雄段，同一份文件）；对手恒为困难陪练副本'
    Write-Host ('[档位·tiers2] 候选宽度：hard = 200 ／ nmare = {0}（`-NmBeam`，0 = 默认 200；对手 beam 恒 200）' -f $(if ($NmBeam -gt 0) { $NmBeam } else { 200 }))
    Write-Host ("[基线 sha12] nmare = {0}" -f `
        (Get-FileHash (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'RL\weights\噩梦.json') -Algorithm SHA256).Hash.Substring(0,12))
}
if ($Mode -eq 'taunt') {
    Write-Host '[档位·taunt] t0 = 关（只有 ⑭判据修正）／ t15 = 1.5 ／ t3 = 3.0（现役，对照）／ t6 = 6.0；四臂同一份 `噩梦.json`、对手恒为困难陪练副本'
    Write-Host '[档位·taunt] ⚠️ 下表 `Δpts_vs_困难` 这一列在本模式读作 **Δpts(臂 − 3.0)**；`dmgB` = 我方挨打量（该降）、`dmgA` = 我方打出量（不该塌）'
    Write-Host ("[基线 sha12] 噩梦.json = {0}（㉕ 的现役值就在这份文件里）" -f `
        (Get-FileHash (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'RL\weights\噩梦.json') -Algorithm SHA256).Hash.Substring(0,12))
}
if ($Mode -eq 'poison') {
    Write-Host '[档位·poison] p0 = 0/4（关掉 ⑫）／ p25t4 = 2.5+4（现役口径，**对照臂**）／ p05t20 = 0.5+20（①）／ p05t40 = 0.5+40（②"血越多越值"）／ p025t40 = 0.25+40（③）；五臂同一份 `噩梦_测毒.json`（= 噩梦.json 剥掉 hero_03 段）+ θ 注入、对手恒为困难陪练副本'
    Write-Host '[档位·poison] ⚠️ 下表 `Δpts_vs_困难` 这一列在本模式读作 **Δpts(臂 − p25t4)**（配对口径同其它模式）⇒ `p0 − p25t4` = ⑫ 这一项总共值多少分'
    Write-Host '[档位·poison] ⚠️ ⑫ **只在场上有毒蛇淑女（hero_03）时非零** ⇒ 牌组必须含它（见 §五 T25 的 `-Decks` 建议）'
    Write-Host '[档位·poison] 候选/对手宽度 beam = 200/200；⏱ 五臂 × 牌组数 × 4 种子'
    Write-Host ("[基线 sha12] 测毒基线 噩梦_测毒.json = {0}" -f (Get-FileHash (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'RL\weights\噩梦_测毒.json') -Algorithm SHA256).Hash.Substring(0,12))
}
if ($Mode -eq 'shield') {
    Write-Host '[档位·shield] s0 = 关 ／ s2 = 2.0 ／ s4 = 4.0（**现役，对照臂**）／ s8 = 8.0；四臂同一份 `噩梦.json`、对手恒为困难陪练副本'
    Write-Host '[档位·shield] ⚠️ 下表 `Δpts_vs_困难` 读作 **Δpts(臂 − 4.0)**；另请看日志里 ㉔破盾 非零的出现率（"poke 拆盾"意图）'
}
if ($Mode -eq 'core') {
    Write-Host '[档位·core] cw0 = 纯身价（**现役，对照臂**）／ cw25 = 身价^0.75 × 输出^0.25 ／ cw5 = 身价^0.5 × 输出^0.5；三臂同一份 `噩梦.json`、对手恒为困难陪练副本'
    Write-Host '[档位·core] ⚠️ 旧键 `RISK_CORE_BY_OUTPUT`（硬切纯输出潜力）读数 c1−c0 = −3.13 [−7.26,+1.01] ⇒ 已删，改成本键的**几何混合**'
    Write-Host ("[基线 sha12] 噩梦.json = {0}（RISK_CORE_OUTPUT_W 的现役值 0 就在这份文件里）" -f `
        (Get-FileHash (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'RL\weights\噩梦.json') -Algorithm SHA256).Hash.Substring(0,12))
}
if ($Mode -eq 'dedup') {
    Write-Host '[档位·dedup] d0 = 关（阶段 1 不去重）／ d1 = 1（**现役，对照臂**）；两臂同一份 `噩梦.json`、对手恒为困难陪练副本'
    Write-Host '[档位·dedup] 本批回答「去重到底降不降水平」：d0 − d1 为正 ⇒ 去重吃亏；≈0 ⇒ 白赚（阶段 1 省 5/6 评分）'
}
if ($Mode -eq 'split') {
    Write-Host '[档位·split] sp0 = 关 ／ sp2 = 2.0（**现役，对照臂**）／ sp4 = 4.0；三臂同一份 `噩梦.json`、对手恒为困难陪练副本'
    Write-Host '[档位·split] 本项是**风格旋钮**（㉒隔断）⇒ 别只看胜率，配合"卡口次数/回合数"读'
}
if ($Mode -eq 'spread') {
    Write-Host '[档位·spread] f0 = 关 ／ f3 = 3.0（**现役，对照臂**）／ f6 = 6.0；三臂同一份 `噩梦.json`、对手恒为困难陪练副本'
    Write-Host '[档位·spread] 本项是**评分项** ⇒ 主看风格读数（队伍离散度 / 挨打量），胜率只作副证'
}
if ($Mode -eq 'apply') {
    Write-Host '[档位·apply] a0 = 关 ／ a3 = 3.0（**现役，对照臂**）／ a6 = 6.0；基线 = `噩梦_测毒.json`（剥掉 hero_03 段 ⇒ 扁平 theta 才生效）'
    Write-Host '[档位·apply] 读作 **Δpts(臂 − 3.0)**；回答「⑯『我又毒了一个新人』这笔动作钱值不值」'
}
if ($Mode -eq 'hpacc') {
    Write-Host '[档位·hpacc] h05 = 0.5 ／ h10 = 1.0（**现役，对照臂**）／ h20 = 2.0；三臂同一份 `噩梦.json`、对手恒为困难陪练副本'
    Write-Host '[档位·hpacc] ③血量账 的单价（1 血 = 多少分）；读作 **Δpts(臂 − 1.0)**'
}
if ($Mode -eq 'p1beam') {
    Write-Host '[档位·p1beam] b0 = 沿用 BEAM（走查台 beam=200，对照）／ b96 = 96（线上现役值）／ b192 = 192（噪音对照）；三臂同一份 `噩梦.json`、对手恒为困难陪练副本'
    Write-Host '[档位·p1beam] ⚠️ 下表 `Δpts_vs_困难` 这一列在本模式读作 **Δpts(臂 − b0)**；本批量的是**棋力有没有掉**，"省了多少秒"要回实机看 `[搜索分账]`（走查台不限时、量不到提速）'
    Write-Host ("[基线 sha12] 噩梦.json = {0}（TWO_PHASE_P1_BEAM 的现役值就在这份文件里）" -f `
        (Get-FileHash (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'RL\weights\噩梦.json') -Algorithm SHA256).Hash.Substring(0,12))
}
$key = @{}
foreach ($r in $rows) { $key["$($r.arm)|$($r.deck)|$($r.seed)|$($r.first)"] = $r }
$ctl = 'hard'
# 【2026-09-22】`ipool` 模式没有 `hard` 臂（全部臂都跑在 `噩梦.json` 上）⇒ 对照 = **现役值 `ip10`**。
if ($Mode -eq 'ipool') { $ctl = 'ip10' }
if ($Mode -eq 'merge') { $ctl = 'mg0' }
# 【2026-09-23】`smode` 模式两臂都跑在 `噩梦.json` 上 ⇒ 对照 = **旧搜索模式 `sm0`**（那一列读作
#   `Δpts(sm2 − sm0)`，即"模式 2 比模式 0 强多少"）。
if ($Mode -eq 'smode') { $ctl = 'sm0' }
# 【2026-09-23】`taunt` 模式四臂都跑在 `噩梦.json` 上 ⇒ 对照 = **现役值 `t3`**（Δpts 读作 `臂 − 3.0`）。
if ($Mode -eq 'taunt') { $ctl = 't3' }
# 【2026-09-23 深夜】`p1beam` 模式三臂都跑在 `噩梦.json` 上 ⇒ 对照 = **沿用 BEAM 的 `b0`**（Δpts 读作 `臂 − b0`）。
if ($Mode -eq 'p1beam') { $ctl = 'b0' }
# 【2026-09-23 深夜】`poison` 模式五臂都跑在 `噩梦.json` 上 ⇒ 对照 = **现役口径 `p25t4`**（Δpts 读作 `臂 − 2.5/4`）。
if ($Mode -eq 'poison') { $ctl = 'p25t4' }
# 【2026-09-25】`core` 模式三臂都跑在 `噩梦.json` 上 ⇒ 对照 = **现役值 `cw0`**（Δpts 读作 `臂 − cw0`，
#   而 `cw0` 那行的 Δpts 恰好 = 0，可当"这批有没有跑歪"的自检行）。
if ($Mode -eq 'core') { $ctl = 'cw0' }
# 【2026-09-25】`tiers3`（真·难度梯度）每组一条臂、**对手各不相同** ⇒ 这张表的 `Δpts_vs_困难` 列
#   **读不了**（没有共同对照臂）；判读看**生产侧胜率**（< 50% = A 打不过 B）与 `pts/game` 的符号。
if ($Mode -eq 'tiers3') { $ctl = '' }
# 【2026-09-24】下面六个模式的对照臂 = 各自的**现役值**（Δpts 读作 `臂 − 现役`）。
if ($Mode -eq 'shield') { $ctl = 's4' }
if ($Mode -eq 'dedup')  { $ctl = 'd1' }
if ($Mode -eq 'split')  { $ctl = 'sp2' }
if ($Mode -eq 'spread') { $ctl = 'f3' }
if ($Mode -eq 'apply')  { $ctl = 'a3' }
if ($Mode -eq 'hpacc')  { $ctl = 'h10' }
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
