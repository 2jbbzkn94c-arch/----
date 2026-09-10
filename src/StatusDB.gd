class_name StatusDB
extends RefCounted
## 状态唯一真相表：键名常量 + 每个状态的"是什么 / 怎么显示 / 何时消失"。
##
## 以前这些信息散在 5 处（Unit 的负面白名单与清理名单、Unit 的单字显示、HUD 的两字映射、
## 英雄脚本调用时再写一遍中文名、BattleAI 自己的布尔字段），中文名抄了 3 份、键是裸字符串
## （has_status("stunn") 拼错不报错）。现在统一查这张表。
##
## 用法：
##   unit.add_status(StatusDB.POISON)          # 施加速度：用常量，别写裸字符串
##   StatusDB.label(StatusDB.POISON)           # => "猛毒"
##   StatusDB.is_negative(key)                 # 是否负面（会被圣盾挡 / 被负墟免疫）
##   StatusDB.clears_on_turn_end(key)          # 是否随"该方回合末"自动解除
##
## 新增一个状态：只在本文件加一条 DEFS 即可，Unit/HUD/日志自动跟上。

# ---- 键名常量 ----
const POISON := "poison"
const HEAVY := "heavy"
const ATKDOWN := "atkdown"
const FREEZE := "freeze"
const SILENCE := "silence"
const STUN := "stun"
const POSSESS := "possess"
const THORN := "thorn"
const SOLID := "solid"
const SHIELD := "shield"

# ---- 定义表 ----
#   label              两字中文名（HUD 文本/属性框/战斗日志都用它）
#   glyph              牌面单字（Unit 的减益紫字 / 增益金字 / 独立盾字）
#   group              "debuff"=紫字减益 / "buff"=金字增益 / "shield"=独立金色盾字
#   negative           负面：施加时被圣盾挡下、被负墟免疫；正面不算
#   clear_on_turn_end  是否随"该方回合结束"自动解除
#                      （猛毒是永久毒 → false；坚固由装甲堡垒自己 on_turn_start 管 → false）
#   order              显示顺序（HUD 状态行 / 牌面小字都按它排）
const DEFS := {
	POISON:  { "label": "猛毒", "glyph": "毒", "group": "debuff", "negative": true,  "clear_on_turn_end": false, "order": 10 },
	HEAVY:   { "label": "重伤", "glyph": "伤", "group": "debuff", "negative": true,  "clear_on_turn_end": true,  "order": 20 },
	ATKDOWN: { "label": "麻痹", "glyph": "麻", "group": "debuff", "negative": true,  "clear_on_turn_end": true,  "order": 30 },
	FREEZE:  { "label": "冰冻", "glyph": "冻", "group": "debuff", "negative": true,  "clear_on_turn_end": true,  "order": 40 },
	SILENCE: { "label": "沉默", "glyph": "默", "group": "debuff", "negative": true,  "clear_on_turn_end": true,  "order": 50 },
	STUN:    { "label": "眩晕", "glyph": "晕", "group": "debuff", "negative": true,  "clear_on_turn_end": true,  "order": 60 },
	POSSESS: { "label": "附体", "glyph": "附", "group": "debuff", "negative": true,  "clear_on_turn_end": true,  "order": 70 },
	THORN:   { "label": "荆棘", "glyph": "荆", "group": "debuff", "negative": true,  "clear_on_turn_end": true,  "order": 80 },
	SOLID:   { "label": "坚固", "glyph": "固", "group": "buff",   "negative": false, "clear_on_turn_end": false, "order": 90 },
	SHIELD:  { "label": "圣盾", "glyph": "盾", "group": "shield", "negative": false, "clear_on_turn_end": false, "order": 100 },
}

static var _ordered: Array = []   # 按 order 排好的键（首次访问建一次；调用方只读，别改）

## 全部状态键，按显示顺序排好
static func keys() -> Array:
	if _ordered.is_empty():
		_ordered = DEFS.keys()
		_ordered.sort_custom(func(a, b): return int(DEFS[a]["order"]) < int(DEFS[b]["order"]))
	return _ordered

## 该键是否已登记（未登记说明拼错了或忘了加定义）
static func known(key: String) -> bool:
	return DEFS.has(key)

## 两字中文名；未登记时回退成键本身，方便当场看出问题
static func label(key: String) -> String:
	return String(DEFS[key]["label"]) if DEFS.has(key) else key

static func glyph(key: String) -> String:
	return String(DEFS[key]["glyph"]) if DEFS.has(key) else "?"

static func group_of(key: String) -> String:
	return String(DEFS[key]["group"]) if DEFS.has(key) else "debuff"

## 是否负面状态（会被圣盾挡下、被负墟免疫）
static func is_negative(key: String) -> bool:
	return bool(DEFS[key]["negative"]) if DEFS.has(key) else false

## 是否随"该方回合结束"自动解除
static func clears_on_turn_end(key: String) -> bool:
	return bool(DEFS[key]["clear_on_turn_end"]) if DEFS.has(key) else false
