# 英雄特化_批跑.ps1 —— 【2026-09-19 修订】英雄特化训练总驱动（按用户口径：**以"不同队伍"为主，种子少给**）
#
# 用户口径（2026-09-19）：
#   「被训练的队伍用噩梦+最新权重，陪练队伍用噩梦+上一个权重。只要最新的权重对上一个权重胜率能不断增加，
#     最终到达一个边界，是不是就能找到相对更强的权重？还有你训练某个英雄的时候，其他英雄不要被正在训练的
#     权重影响了，要控制变量」「为什么要那么多种子？以测试权重和不同队伍为主啊。其他几个英雄训练起来」
#
# 结构（每一段 = 一次 `英雄特化搜索.ps1` 调用）：
#   · 候选 = RL\weights\英雄世代.json + **一个英雄的若干键**（臂）；陪练 = 英雄世代.json 本身
#     （league.checkpoint + self_play_fraction=1.0 ⇒ harness 的 wB 通道）
#   · 镜像同队伍 ⇒ 双方唯一差别就是被训英雄的那几个键 ⇒ 控制变量天然成立
#   · **多支队伍**：同一个臂在 3~6 支不同队伍上各打一遍，只有"跨队伍都赢"才算数
#   · 每个英雄的第一个臂是**恒等对照**（写成引擎默认值）⇒ 那一行就是噪声地板，配对的基准
#
# 臂的数值量纲依据见 `英雄特化搜索.ps1` 与 `RL/ai/AI_Battle.gd` 的实现注释。
$ErrorActionPreference = 'Stop'
$s = Join-Path $PSScriptRoot '英雄特化搜索.ps1'

$SEEDS = 3          # 每队种子数（用户口径：种子少给，队伍多给）
$TAG = 'r2'

# ================= ① 黄金矿工 hero_42：把上一轮（单队）最好的几个臂放到 6 支队伍上验 =================
# 上一轮（D1=hero_42,hero_03,hero_17，12 种子）结论：吃矿价 40→30 最好（胜率 .708 / Δpts +6.3），
# 其次 ATK_DECAY（.667 / +4.4）、ENDGAME_MULT（.625 / +2.0）；KILL_GATE 单用几乎无效（.625 / +0.9）。
# 本轮 = 同 5 个臂 × 6 支队伍（对手组合完全不同）⇒ 看它是不是"只对那一支队有效"。
Write-Host ''
Write-Host '################ ① 黄金矿工 hero_42 · 6 队复验 ################'
& $s -Hero 'hero_42' -Tag $TAG -Seeds $SEEDS -Beam 100 -Workers 6 -Decks @(
    'hero_42,hero_03,hero_17',
    'hero_42,hero_14,hero_26',
    'hero_42,hero_46,hero_11',
    'hero_42,hero_01,hero_18',
    'hero_42,hero_06,hero_43',
    'hero_42,hero_24,hero_20'
) -Arms @(
    'HERO_hero_42_GOLD_TAKE_VALUE=40',                      # 恒等对照（= 英雄世代.json 里的值）
    'HERO_hero_42_GOLD_TAKE_VALUE=30',
    'HERO_hero_42_GOLD_ATK_DECAY=1.0',
    'HERO_hero_42_GOLD_ENDGAME_MULT=0.3',
    'HERO_hero_42_GOLD_KILL_GATE=1'
)

# ================= ② A 档另外 4 个英雄：各 3 支队伍 × 4 个臂 =================
# 每个英雄第一臂 = 恒等对照（默认值 0）⇒ 配对基准 + 噪声地板。
$rounds = @(
    @{ hero = 'hero_03'; note = '毒蛇淑女：猛毒是"未来 1~4 点真伤"，键 = 每跳计价'
       decks = @('hero_42,hero_03,hero_17', 'hero_48,hero_03,hero_22', 'hero_03,hero_49,hero_25')
       arms = @('POISON_TICK_VALUE=0', 'POISON_TICK_VALUE=1.0', 'POISON_TICK_VALUE=2.5', 'POISON_TICK_VALUE=5.0') },
    @{ hero = 'hero_14'; note = '古拉博士：攻击 HP 高于自己的目标时回血，键 = 这次触发值多少分'
       decks = @('hero_42,hero_14,hero_26', 'hero_48,hero_14,hero_25', 'hero_14,hero_11,hero_13')
       arms = @('LEECH_TRIGGER_W=0', 'LEECH_TRIGGER_W=3', 'LEECH_TRIGGER_W=8', 'LEECH_TRIGGER_W=15') },
    @{ hero = 'hero_46'; note = '宿魂：附体让敌人替我挨打，键 = 附到高身价目标值多少分'
       decks = @('hero_42,hero_46,hero_11', 'hero_46,hero_48,hero_35', 'hero_46,hero_08,hero_22')
       arms = @('POSSESS_TARGET_W=0', 'POSSESS_TARGET_W=1', 'POSSESS_TARGET_W=3', 'POSSESS_TARGET_W=8') },
    @{ hero = 'hero_48'; note = '装甲堡垒：本回合不动 ⇒ 下回合[坚固]（受攻击 −1），键 = 这笔值多少分'
       decks = @('hero_48,hero_03,hero_22', 'hero_48,hero_14,hero_25', 'hero_46,hero_48,hero_35')
       arms = @('SOLID_HOLD_W=0', 'SOLID_HOLD_W=2', 'SOLID_HOLD_W=5', 'SOLID_HOLD_W=10') }
)

$i = 1
foreach ($r in $rounds) {
    $i++
    Write-Host ''
    Write-Host ('################ ②-{0} 英雄特化：{1} · {2} ################' -f $i, $r.hero, $r.note)
    & $s -Hero $r.hero -Tag $TAG -Seeds $SEEDS -Beam 100 -Workers 6 -Decks $r.decks -Arms $r.arms
}

Write-Host ''
Write-Host '################ 英雄特化批跑结束 ################'
