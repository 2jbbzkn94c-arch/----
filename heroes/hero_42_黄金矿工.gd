extends HeroBase
## 黄金矿工：己方回合开始时，在战场中的空地随机发现一枚金块。
## 黄金矿工可以拾取金块，每拾得一枚，攻击力 +1、HP 上限和 HP +3。
##
## 本脚本负责**全部金矿规则**：谁掉矿、掉在哪一格、谁能捡、捡了加什么。
## Battle 只保留"矿已经落在盘面上之后"的地形规则（寿命倒计时、渲染、拾取落盘、AI 参考），
## 并提供原语：gold_cell_ok(cell) / place_gold(cell, unit)。
class_name HeroGoldminer

func on_turn_start() -> bool:
	# 在随机空地丢一块矿。落点合法性交给 Battle 的 gold_cell_ok（与其它落点同一套规则：
	# 空地、无障碍/炸弹/其它道具/墓碑）；随机数必须用 battle.rng —— 联机两端同种子，落点才会一致。
	var spots: Array = []
	for cell in battle.grid.all_cells():
		if battle.gold_cell_ok(cell):
			spots.append(cell)
	if spots.size() == 0:
		return true   # 整盘没空地可放：技能照常算发动（闪被动边框），只是这一回合没矿
	battle.place_gold(spots[battle.rng.randi() % spots.size()], unit)
	play_skill_sfx()   # 【2026-09-28·用户要求「丢金矿要有声」】真的丢下矿才响
	return true

## 只有黄金矿工能拾取金矿（其他单位踩到不消费、金矿留在格上继续倒计时）
func can_pickup_gold() -> bool:
	return true

## 拾取一枚金矿的收益：攻击 +1（永久，变身时保留）、生命上限 +3 并回复 3 血（不溢出上限）
func on_pickup_gold() -> void:
	if unit == null or not is_instance_valid(unit):
		return
	play_skill_sfx()   # 拾到金矿响一声（与回合开始「丢矿」各一声：时机不同、不重叠）
	unit.atk += 1
	unit.perm_atk += 1   # 永久加成，变身重置攻击力时保留
	unit.max_hp += 3
	unit.hp = min(unit.hp + 3, unit.max_hp)
	unit.refresh_stats()   # 刷新面板数值与血条（refresh_stats 内含 _update_hp_label）
	battle.log_message.emit("%s 拾取金矿！攻击 +1（永久）、生命上限 +3 并回复 3 血。" % unit.display_name)
