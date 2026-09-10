class_name BattleSnapshot
extends RefCounted
## 敌方 AI 的"局面快照"打包：把 Battle 的现场（单位 + 地形）转成 BattleAI 能吃的纯数据。
##
## 为什么单独成文件：这份字段表以前散在 13 处——Battle 里 2 处（回合开始 / 中途替补补算）
## 加上 11 个测试与工具各抄一份 `build_desc`，而且已经漂移过（测试那几份缺
## poss_by / immune_bombs / can_pickup_gold）。现在只此一处，谁要快照都来这里取。
##
## 依赖方向：BattleSnapshot → Battle（读现场）+ BattleAI（喂数据）。
## BattleAI 自己仍然零场景依赖（只吃 descs/地形字典），所以照旧能丢进后台线程。
##
## 用法：
##   var snap := BattleSnapshot.collect(battle)                    # 全场
##   var snap := BattleSnapshot.collect(battle, [nu] + players)    # 只要这几个人（中途补算）
##   var one := BattleSnapshot.unit_desc(battle, u)                # 单个单位
## battle 故意未定型：需要动态调用 Battle 的 _hero(u)（与 HeroBase 同一约定）。

## 单个单位描述。poss_by = 施加[附体]的宿魂在"本快照里的下标"（-1 = 无附体）。
static func unit_desc(battle, u: Unit, poss_by: int = -1) -> Dictionary:
	var hb = battle._hero(u)   # 英雄行为脚本：炸弹免疫 / 金矿拾取权等由它决定，AI 不认 hero_id
	return {
		"fn": u.faction, "hero": u.hero_id, "cell": u.cell, "hp": u.hp, "max_hp": u.max_hp,
		"atk": u.atk, "eatk": u.effective_atk(), "move": u.move_range, "emove": u.effective_move(),
		"atk_range": u.attack_range,
		"atk_type": u.attack_type, "skills": u.skills, "name": u.display_name,
		"stunned": u.has_status(StatusDB.STUN), "silenced": u.has_status(StatusDB.SILENCE),
		"shield": u.has_status(StatusDB.SHIELD), "heavy": u.has_status(StatusDB.HEAVY),
		"poisoned": u.has_status(StatusDB.POISON), "frozen": u.has_status(StatusDB.FREEZE),
		"poss_by": poss_by,
		"immune_bombs": hb.immune_to_bombs(),
		"can_pickup_gold": hb.can_pickup_gold(),
	}

## 打包一份完整快照。pool 为空 = 取 battle.units 全部（顺序即 descs/occ 的下标顺序）。
## 返回 { descs, occ, gold, grave, obstacle, bomb, buff }，可直接喂 BattleAI.build_state。
static func collect(battle, pool: Array = []) -> Dictionary:
	var list: Array = pool if pool.size() > 0 else battle.units
	var links: Dictionary = battle._possess_links   # [附体] 绑定：目标 -> 施加者
	var descs: Array = []
	var occ := {}
	var uidx := {}   # Unit -> 本快照里的下标
	for i in list.size():
		uidx[list[i]] = i
	for i in list.size():
		var u: Unit = list[i]
		var poss_by := -1
		if links.has(u) and is_instance_valid(links[u]):
			poss_by = uidx.get(links[u], -1)   # 被附体者记录施加它的宿魂
		descs.append(unit_desc(battle, u, poss_by))
		occ[u.cell] = i
	# 地形：金矿与普通增益道具都在 buff_items 里，按类型拆成两份
	var gold := {}
	var buff := {}
	for c in battle.buff_items.keys():
		if battle.buff_items[c] == "gold":
			gold[c] = true
		else:
			buff[c] = battle.buff_items[c]
	var grave := {}
	for c in battle.graves.keys():
		grave[c] = true
	var obstacle := {}
	for c in battle.obstacles.keys():
		obstacle[c] = battle.obstacles[c]   # 带耐久：AI 可评估"再补几下能拆掉"
	var bomb := {}
	for c in battle.bombs.keys():
		bomb[c] = true
	return {
		"descs": descs, "occ": occ,
		"gold": gold, "buff": buff, "grave": grave, "obstacle": obstacle, "bomb": bomb,
	}
