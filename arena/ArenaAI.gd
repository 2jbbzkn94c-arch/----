extends "res://RL/ai/AI_Battle.gd"
## 【竞技场覆盖层】只干一件事：把**裁判那边与我们不一样的技能效果**改成他们的口径。
##
## 铁律：**游戏本体一个字不动**（`src/BattleAI.gd`、`RL/ai/AI_Battle.gd`、`heroes/*.gd` 全部保持原样）。
## 这里用 `extends` 继承线上那份 AI，**逐个方法覆盖**；竞技场引擎只加载本文件，单机照旧走原来那份。
##
## 与 base 的差别清单（每加一条，必须在 `arena/规则差异台账.md` 里同步登记）：
##   ① 圣光(hero_22)：**去掉"伤者必须是非行动方"那道闸门**。
##      本地规则（`heroes/hero_22_圣光.gd` + base 的 `_sim_maybe_guard`）：只有"敌方回合里己方英雄受伤"才给盾。
##      裁判规则书写的是"**你的英雄受到伤害时可获得护盾**，此效果每回合最多触发1次"——**不分谁在行动**。
##      影响面：我们自己进攻时挨的反击/反伤，在裁判那边会给我们自己的圣光触发一面盾（我们原来不算）。
##   ② 站位评分：补一笔"**被长角(hero_32)击退到炸弹上**"的风险（擂台实测白送 15 点），见下方覆盖。
##
## 证据与验收：`arena/技能对表.tscn`（逐英雄对表）+ `arena/对账复盘.tscn`（逐手对账）。
## 哪一局出现"我方单位在自己回合多了一面没料到的盾"，就是 ① 在起作用。

const GUARD_HERO := "hero_22"

## ② 站位：**别站在"会被长角推到自家雷上"的位置**。
##    擂台实测（`arena_b9f75a60`）：对方长角 3 次把我方单位击退到**我们自己**的炸弹上，白送 15 点伤害。
##    模拟本身是知道"击退落雷会爆"的（`_sim_knockback_away` 里调 `_sim_trigger_bomb`），
##    但评分里只有"挨打伤害"，没有"被推到雷上"这一笔 ⇒ 搜索不回避那种站位。这里补上（只在竞技场层）。
##    判据：长角把我推开的落点 = 我沿"攻击者→我"方向的再下一格 ⇒ 雷在那一格时，
##          攻击者必须站在**那格关于我的镜像位**上，且它够得到 ⇒ 记一笔风险。
const HORN_HERO := "hero_32"
const BOMB_DAMAGE_EST := 5.0
const HORN_BOMB_RISK_W := 2.5     # 每处风险的价钱（保守：只当"提醒"用，不压过正常攻防）

func _position_score(sim) -> float:
	var s: float = super._position_score(sim)
	if sim == null or sim.bombs.is_empty():
		return s
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY or u.immune_bombs:
			continue
		for bi in sim.bombs.keys():
			var b: Vector2i = bi
			if grid.distance(u.cell, b) != 1:
				continue
			# 落点 = b 的对侧镜像：攻击者得站在那儿才推得动（位移方向 = 攻击者→我 的延长线）
			var mirror := _mirror_across(u.cell, b)
			for j in sim.units.size():
				var e = sim.units[j]
				if e == null or not e.alive or e.fn == DataRegistry.Faction.ENEMY or e.hero_id != HORN_HERO:
					continue
				if e.silenced or e.stunned:
					continue
				if approach_dist(sim, e.cell, mirror) <= e.emove + e.atk_range:
					s -= HORN_BOMB_RISK_W * (BOMB_DAMAGE_EST / 5.0)
					break
	return s


## 以 center 为中心、把 cell 镜像到另一侧（轴向坐标下 + 与 −）
func _mirror_across(center: Vector2i, cell: Vector2i) -> Vector2i:
	var ca := grid.axial_of(center)
	var da := grid.axial_of(cell) - ca
	return grid.offset_of(ca - da)



## ① 圣光：**不分回合**，己方英雄受伤就给盾（每名圣光每回合限一次）。
##    其余逐条与 base 一致：伤者已有盾/已死 → 不给；给盾者必须存活且未被沉默/眩晕、且本回合名额未用；
##    名额先占、盾延到动作末尾发（`pending_guard` + `_sim_flush_guards` 的帧末复查照旧）。
func _sim_maybe_guard(sim, wounded) -> void:
	if wounded == null or wounded.shield or not wounded.alive:
		return
	# ⚠️ base 在这里还有一行 `if wounded.fn == sim.active_fn: return`（伤者是行动方就不触发）——
	#    裁判规则书没有这条限制 ⇒ 覆盖掉。
	for i in sim.units.size():
		var g = sim.units[i]
		if not g.alive or g.fn != wounded.fn or g.hero_id != GUARD_HERO \
				or g.silenced or g.stunned or g.aura_used:
			continue
		g.aura_used = true
		sim.pending_guard.append({ "dst": wounded, "giver": g })
		return
