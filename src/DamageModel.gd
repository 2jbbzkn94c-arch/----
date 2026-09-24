class_name DamageModel
extends RefCounted
## 【2026-09-24 新增·用户拍板「3」】"**某英雄打某目标的那一下到底几倍**"的**唯一权威**。
##
## 为什么要抽出来（用户当天实机抓到的 bug）：这条规则原来有**两份实现** ——
##   生产：`Battle._bonus_damage()`（沉默/远程贴身两道门槛）＋ `heroes/*.gd::damage_mult()`（逐英雄规则）；
##   AI  ：`BattleAI._sim_mult()`（同样两道门槛 + 同样三条规则，另加复仇者的修正）。
## 两份已经漂过三次：① 共鸣者的"下回合攻击力"（见 `BattleAI._echo_atk_now()` 那段）；
##   ② 受击侧的重伤 +1 / 坚固 −1（`_sim_take_damage()` 那段）；③ **赏金猎人的 ×2 在"挨打合计"里根本没乘**
##   （用户实机日志：战锤那一格被算成 3，真实是 6）。
## ⇒ 现在生产与 AI 都调这里：**改规则只改这一个文件**（AI 的那两个副本靠 `_rebuild_sync.ps1` 重建时自动带上）。
##
## 调用者怎么喂参（本文件**不认识 `Unit` 也不认识 `SimUnit`**，只吃标量 —— 这样两边都能用）：
##   生产：`Unit` 是活对象 ⇒ 用 `battle._is_lowest_hp()` / `battle._is_isolated()` 判好再传 bool；
##   AI  ：`SimUnit` ⇒ 用模拟盘的等价判据（`_sim_lowest_hp()` / `_sim_isolated()`）判好再传。
##
## ⚠️ **门槛口径必须与生产一致**（`src/Battle.gd::_bonus_damage()` 三行）：
##   ① 攻击者 `skill_allowed()` = **存活 且 未被[沉默]且未被[眩晕]**；
##   ② **远程被贴身**（`ranged_pinned`）⇒ 伤害倍率技整条失效；
##   ③ 目标必须存活。


## 主动攻击的伤害倍率（**含两道门槛**）。目前所有倍率技都是 ×2 ⇒ 返回 1 或 2。
## 参数：`a_*` = 攻击者、`t_*` = 目标（标量化的判据结果，见文件头）。
static func attack_mult(a_hero: String, a_skill_allowed: bool, a_ranged: bool, a_ranged_pinned: bool,
		t_alive: bool, t_has_taunt: bool, t_is_lowest_hp: bool, t_isolated: bool) -> int:
	if not a_skill_allowed:
		return 1
	if a_ranged and a_ranged_pinned:
		return 1
	if not t_alive:
		return 1
	return hero_damage_mult(a_hero, a_ranged, t_has_taunt, t_is_lowest_hp, t_isolated)


## **纯英雄规则**（不含沉默/贴身那两道门槛）—— 各英雄脚本的 `damage_mult()` 直接转发到这里，
## 于是"规则本体"只有这一份。要加新的倍率英雄**只改这个 match**。
static func hero_damage_mult(a_hero: String, a_ranged: bool, t_has_taunt: bool,
		t_is_lowest_hp: bool, t_isolated: bool) -> int:
	match a_hero:
		"hero_15":   # 小阴影：目标是全场 HP 最低（或之一）⇒ ×2
			return 2 if t_is_lowest_hp else 1
		"hero_20":   # 赏金猎人：**远程**打带 <嘲讽> 的目标 ⇒ ×2
			return 2 if (a_ranged and t_has_taunt) else 1
		"hero_30":   # 嬉皮死神：目标孤立（1 格内没有同阵营队友）⇒ ×2
			return 2 if t_isolated else 1
	return 1


## 反击倍率（真实 `HeroBase.counter_mult()` 一族）：目前只有复仇者 hero_23 = ×2（且反击次数无限）。
## ⚠️ 它**只作用于"被攻击时的反击伤害"**，不能乘在复仇者自己的主动攻击上 ——
##   后者走 `hero_damage_mult()`（复仇者没实现 ⇒ 1 倍）。实测见 `BattleAI._sim_mult()` 那段注释。
static func counter_mult(d_hero: String, d_skill_allowed: bool) -> int:
	if not d_skill_allowed:
		return 1
	return 2 if d_hero == "hero_23" else 1


## 【下一回合语义】"**敌方回合开始时**给全队加攻"的那一族，对**下一回合单击伤害**的加成。
##   目前只有**烈焰祭司 hero_19**：`heroes/hero_19_烈焰祭司.gd::on_turn_start()` 给
##   **所有其他队友** `v.atk_buff += 1`（`atk_buff` 进 `Unit.effective_atk()` ⇒ 普攻与"移动后技能"都吃得到；
##   **多个祭司会叠加**）。
##   ⚠️ **与共鸣者同一个时序坑**（见 `BattleAI._echo_atk_now()` 的注释）：AI 的搜索跑在**我方**回合、
##   估的是**下一个敌方回合**的伤害，而那道 +1 要等**敌方回合开始**才发生 ⇒ 快照里的 `eatk` 里没有它。
##   ⇒ 凡是"估下回合伤害"的地方都要显式补上（`BattleAI._incoming_total_on()` 的 ①普攻 与 ②移动后技能）。
##   返回**这个攻击者**实际能拿到的那份（它自己就是祭司时拿不到别人的）。
static func turn_start_atk_bonus(a_hero: String, priests_on_side: int) -> int:
	var n := maxi(priests_on_side, 0)
	if a_hero == "hero_19":
		n -= 1     # 技能原文是"所有**其他**队友" ⇒ 祭司自己不吃自己那一份
	return maxi(n, 0)
