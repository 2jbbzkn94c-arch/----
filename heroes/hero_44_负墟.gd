extends HeroBase
## 负墟：<嘲讽>。所有负面效果对其无效，每受到一次负面效果攻击，攻击力+1（持续到我方回合结束）。
## 实现位置：规则全在本脚本——负面免疫由 HeroBase.immune_to_negative() 声明（Unit.add_status 询问），
## 成长计数走 on_negative_blocked()（负面被挡下时回调）。
## 为什么拦在 Unit.add_status：所有状态都经那里挂载，统一询问才能保证
## "一次攻击无论带几个负面只触发一次"（同帧去重）。

class_name HeroNullfield

var _last_frame := -1   # 上一次计数的帧号：同一帧（同一次攻击的多个负面）只算一次

## 所有负面状态（毒/重伤/麻痹/冰冻/沉默/眩晕/附体/荆棘）一律不挂到自己身上。
## 与沉默/眩晕无关：原实现在 Unit.add_status 里也没有 skill_allowed() 判定，故保持一致。
func immune_to_negative() -> bool:
	return true

## 一次负面被免疫挡下：攻击力 +1（atk_buff 由回合末统一清空，即"持续到我方回合结束"），并弹提示。
func on_negative_blocked() -> void:
	var f := Engine.get_process_frames()
	if f == _last_frame:
		return   # 同一帧（同一次攻击的多个负面）只算一次
	_last_frame = f
	unit.atk_buff += 1
	unit.refresh_stats()
	unit._float_text("免疫负面 攻+1", Color(0.8, 0.75, 1.0), -22, -48)
