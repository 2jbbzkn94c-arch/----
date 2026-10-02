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
		# 一次性道具的"持有量"：eatk/emove 是把它们**算进去之后**的实时值，
		# 光看 eatk/emove 无法知道"用掉之后该回落多少"。AI 的模拟要按真实公式
		# （`effective_atk() = base + atk_buff + ramble_bonus + sun_bonus + atk_use_buff − 麻痹`、
		#   `effective_move() = move_range + move_buff + move_use_buff − 冰冻`）记账，
		# 所以把这两项单独带出来；不读这两个键的调用方行为不变。
		"atk_use_buff": u.atk_use_buff,
		"move_use_buff": u.move_use_buff,
		# [麻痹]ATKDOWN / [荆棘]THORN 的**状态存在性**（与上两项同类：eatk/emove 里已经含了它们的
		# 效果——麻痹降攻、荆棘移动清零——但"这个状态在不在"看不出来）。判定来源与真实侧同源
		# （Unit.has_status），供模拟/检视器按状态比对；不读这两个键的调用方行为不变。
		"atkdown": u.has_status(StatusDB.ATKDOWN),
		"thorn": u.has_status(StatusDB.THORN),
		# 共鸣者(hero_47)的 echo 状态：`echo_set >= 0` 时 `effective_atk()` 会**直接 return** 它
		# （攻击力=队友攻击力之和，**覆盖**一切 buff/道具/被贴身），模拟侧要据此让"攻击道具那笔加成"不生效（现役 +2，见 `Battle.ATK_ITEM_BUFF`）。
		"echo_set": u.echo_set,
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
	var buff_own := {}
	for c in battle.buff_items.keys():
		if battle.buff_items[c] == "gold":
			gold[c] = true
		else:
			buff[c] = battle.buff_items[c]
			# 【2026-09-21 用户定稿·圣诞老人】道具**归属**（只有圣诞老人当场生成的礼物才有）：
			#   必须进快照，否则 AI 会把「敌方踩到我们的礼物」误判成「玩家吃到了道具」——分记反了。
			if battle.buff_owner.has(c):
				buff_own[c] = int(battle.buff_owner[c])
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
		"buff_owner": buff_own,   # 【2026-09-21】道具归属（cell -> 阵营）；老读取方忽略即可
		# 【RL 修正·用户已批准】双方**替补席**英雄 id 列表（battle.player_roster / battle.enemy_roster；
		# 生产侧替补流程见 src/Battle.gd:118-125、4338(_pending_enemy_sub += 1)、4388(_place_enemy_sub)、
		# 4413(_best_enemy_sub_idx)、4561(_free_sub_cell_for 优先本方墓碑格)）。RL 的 sim 需要它才能预测
		# "某一招窗口内替补登场"的选人与登场效果（如波盾 on_enter 给己方全体盾），把那类块从"不可比"变成可比。
		# 纯读取、不改游戏行为；与 atk_use_buff/move_use_buff/atkdown/thorn/echo_set 同批同类，只被 RL 的 sim/harness 消费。
		"rosters": { DataRegistry.Faction.PLAYER: battle.player_roster.duplicate(), DataRegistry.Faction.ENEMY: battle.enemy_roster.duplicate() },
		# 【2026-10-01 晚·用户「她没考虑 AI 已经死了 2 个了啊，**自爆就输了**」】**累计阵亡 + 判负线**：
		#   ⑩终局项要按"**还剩几条命**"算（判负线是**累计阵亡** `LOSS_DEATH_COUNT`，与"场上还剩几个"
		#   不是一回事 —— 队伍 > 3 人时，场上还有 3 个也可能已经死了 2 个）。纯新增键：
		#   不读它的调用方（RL harness / 老工具）行为不变（模拟里那两个字段留 −1 = 未知 ⇒ 退回老口径）。
		"deads": { "my": battle.enemy_dead, "foe": battle.player_dead, "line": battle.LOSS_DEATH_COUNT },
	}
