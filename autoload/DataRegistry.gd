extends Node
## 卡牌/英雄数据注册表（全局自动加载）。
## 从 res://Data/Hero/Source/角色列表.json 解析全部角色（该 json 由 Data/Hero/角色列表.xlsx 经
## Data/Hero/Source/角色列表转Json.ps1 生成 —— 刷新走 Data/Hero/Bat/一键刷新AI解析.bat），
## 生成数值、品级、类型与关键词标签。
## 复杂/角色专属技能全文存入 desc（暂未实现），引擎已支持：近战/远程、嘲讽、疾行、渗透。

# 攻击类型
enum AttackType { MELEE, RANGED }

# 关键词技能（引擎已实现其基础机制）
enum Skill { NONE, TAUNT, SWIFT, RANGED, BENCH, LOGISTICS, INFILTRATE }

# ---- 机制协同知识库（选人/战斗 AI 共用）----
# 【2026-09-25 已删除】原来的手写表 `const SYNERGY := {…}` 整表删掉（用户 2026-09-24 拍板"直接删、不管丢分"，
#   因当时撞上正在跑的批而暂缓；2026-09-25 用户再次确认「手写表删掉」⇒ 本次落地）。
#   ⇒ 现在协同分的**唯一来源**是英雄表的列：`「协同英雄」`列（点名档 +2.0，`explicit_pairs`）＋
#     `「语义伙伴」`列（语义档，默认 +1.0、可写 `名字×N`，`sy_partners`/`sy_weight`）。
#   删除当天算出的影响（`RL/probe/配合对自检.gd` 口径）：配合对 **126 → 87**；**独脚龟/雪拳/猎颅者归零**
#   （它们在手写表里是唯一来源）；小阴影少了 白游侠 1.5 / 烛火 1.5 / 长剑 1.5。
#   ⚠️ `autoload/` **不在跑批指纹里**（`RL/harness/对局.gd` 只哈希两份 AI 副本）⇒ 本改动会**静默**改变
#      跑批里的 AI 行为，闸门看不出来；**改完起的进程才是新口径**。
#   要回退：从 git 恢复本段（`git show <旧提交>:autoload/DataRegistry.gd`）并把下面 `d1`/`d2` 两段加回去。

func synergy_bonus(a: String, b: String) -> float:
	var s := 0.0
	# 【2026-09-25】这里原来还有手写表 `SYNERGY` 的两段（`d1`/`d2`）—— 已随整表删除（见上方说明）。
	# "协同英雄"列直接点名的搭配（md 自动读取），任意一方点名对方即算搭配分
	var ad: HeroDef = heroes.get(a, null)
	var bd: HeroDef = heroes.get(b, null)
	if (ad != null and ad.explicit_pairs.has(b)) or (bd != null and bd.explicit_pairs.has(a)):
		s += 2.0
	# "配合"列语义展开的候选伙伴：任一方的展开结果包含对方,记低一档协同(语义较宽,宽松加分)
	# 【2026-09-24 用户拍板①】这一档支持**加权写法**（「语义伙伴」列里写 `名字×N`，不写 = 1.0）。
	#   双方都写时取**较大值**、不叠加 ⇒ 一边写就够，两边都写不会翻倍；不写 ×N 时与旧口径逐位相同。
	var w_sem := 0.0
	if ad != null and ad.sy_partners.has(b):
		w_sem = maxf(w_sem, float(ad.sy_weight.get(b, 1.0)))
	if bd != null and bd.sy_partners.has(a):
		w_sem = maxf(w_sem, float(bd.sy_weight.get(a, 1.0)))
	s += w_sem
	return s

# 克制分：a 是否克制 b（依据角色列表「克制」与「被克制」两列的明确关系）。
# 单向判定：b 的"被克制"列点名 a (b.counters 含 a)，或 a 的"克制"列点名 b (a.beats 含 b)。
# 两列可能重复指向同一关系（如战锤克毒蛇两列都有），此处只记一次，避免重复加分。
# 【2026-09-24 用户要求】两列改成可加权名单（`名字×N`，不写 = **2.0**）⇒ 双方都写取**较大值**、不叠加；
# 旧原文（"远程"/"嘲讽"这类词）解析出来的权重全是 2.0 ⇒ 与旧口径逐对相同。
func counter_bonus(a: String, b: String) -> float:
	var ad: HeroDef = heroes.get(a, null)
	var bd: HeroDef = heroes.get(b, null)
	var w := 0.0
	if bd != null and bd.counters.has(a):
		w = maxf(w, float(bd.counters_weight.get(a, 2.0)))   # b 被克制列点名 a → a 克制 b
	if ad != null and ad.beats.has(b):
		w = maxf(w, float(ad.beats_weight.get(b, 2.0)))      # a 克制列点名 b → a 克制 b
	return w

# 英雄单体评分（唯一实现）：竞技场选人/普通敌方组队/首发部署共用。
# 权重：重攻击、轻血量——避免高血坦克把输出全挤出高分池（导致敌方全肉盾）。
func hero_strength(id: String) -> float:
	var def: HeroDef = heroes.get(id, null)
	if def == null:
		return 0.0
	# 若角色列表配置了"总评分"(影响AI行为的手动列),以它作为单体评分;
	# 否则回退到原有的数值/词条加权公式。
	if def.ai_total > 0.0:
		return def.ai_total
	var s := float(def.atk) * 2.2 + float(def.max_hp) * 0.45
	if def.attack_type == AttackType.RANGED:
		s += 2.5
	for sk in def.skills:
		match sk:
			Skill.TAUNT:
				s += 0.8
			Skill.SWIFT:
				s += 1.0
			Skill.INFILTRATE:
				s += 1.5
			Skill.LOGISTICS:
				s += 1.0
	return s

# ---- 身价评分（战斗 AI 唯一实现）：一个单位"值不值得打 / 值不值得保"由三项加权合成 ----
#   solo    : 单人评分 hero_strength(id)（角色列表"总评分"优先，否则数值/词条加权）
#   synergy : 与我方**其他单位**的协同分之和（走 `synergy_bonus()`：角色列表"协同英雄"列 + "语义伙伴"/"配合"列）
#   counter : 我克制对面之和 − 对面克制我之和（引用角色列表"克制"/"被克制"两列）
# 权重可被外部（RL 训练器 / 权重文件）用 coef 覆盖；不给就用下面这套官方默认比例。
# 注意：这里只算"原始身价"，**眩晕/沉默的折减不在这里做** —— 那是"受控折减"，
# 只对**对面**的单位生效（我方英雄被晕不该让 AI 觉得"不值得保"），由调用方施加。
const VALUE_SOLO_W_DEFAULT := 1.0
const VALUE_SYNERGY_W_DEFAULT := 0.6
const VALUE_COUNTER_W_DEFAULT := 0.6

# 身价三项原始分量（**不带权重**，权重交给调用方，便于各 AI 用自己的比例）。
# cache：一次评估内复用的记忆表（键 = "p:" + hero_id）。
# 因为键只有 hero_id，同一张表只能在 ally_ids/enemy_ids 都不变的一轮评估里复用。
func battle_unit_value_parts(hero_id: String, ally_ids: Array, enemy_ids: Array, cache = null) -> Dictionary:
	if cache != null:
		var ck := "p:" + hero_id
		if cache.has(ck):
			return cache[ck]
	var solo := hero_strength(hero_id)
	var syn := 0.0
	for a in ally_ids:
		var aid := String(a)
		if aid == hero_id:
			continue
		syn += synergy_bonus(hero_id, aid)
	var cnt := 0.0
	for e in enemy_ids:
		var eid := String(e)
		if eid == hero_id:
			continue
		cnt += counter_bonus(hero_id, eid) - counter_bonus(eid, hero_id)
	var out := { "solo": solo, "synergy": syn, "counter": cnt }
	if cache != null:
		cache["p:" + hero_id] = out
	return out

# 加权身价（浮点，便捷入口）。coef 缺省用官方比例；cache 同 battle_unit_value_parts。
func battle_unit_value(hero_id: String, ally_ids: Array, enemy_ids: Array, coef: Dictionary = {}, cache = null) -> float:
	var p := battle_unit_value_parts(hero_id, ally_ids, enemy_ids, cache)
	return float(p["solo"]) * float(coef.get("solo", VALUE_SOLO_W_DEFAULT)) \
			+ float(p["synergy"]) * float(coef.get("synergy", VALUE_SYNERGY_W_DEFAULT)) \
			+ float(p["counter"]) * float(coef.get("counter", VALUE_COUNTER_W_DEFAULT))

# ============ 【2026-09-22 用户拍板】替补选人：**先判"需要什么"，再在"满足需求的人"里排名** ============
# 用户原话：「在替补不需要补位和斩杀的时候，按评分来选这个方案我觉得不算合理。因为评分排名并没有按照
#   你的需求排的，有可能你不需要坦克，但排名第一是坦克，所以就上了坦克，这个不是调阈值可以解决的。
#   我觉得你在需要替补的时候，先评估需要什么，再给英雄池里你需要的英雄评分排名，然后选其中一个」。
# ⇒ 旧口径把「身价 + 缺前排+11 / 补坦克位+3 / 支援伤员…」**混成一个数** ⇒ 不缺坦克时坦克照样能排第一。
#   现在拆成两段：① `sub_need(ctx)` 按优先级判出**唯一一个需求**；② `sub_hero_eligible()` 决定"谁算满足"，
#      `sub_hero_score()` 在该需求下排名（身价 + 「满足需求」优先价 + 需求专属项）。
# ⚠️ **唯一实现放在这里**：`src/Battle.gd`（真实选人）与 `src/BattleAI.gd::_sim_best_sub_idx()`（AI 的模拟
#   镜像）**都调本段函数** —— 这两处一直要求"逐条一致"，各抄一份迟早漂（项目被这类漂移坑过好几次）。
# 需求清单与优先级（命中即停；都不命中 ⇒ `""` 兜底）：
#   1 **缺前排**：我方**存活嘲讽 = 0**          → 候选 = 有 `<嘲讽>`
#   2 **缺治疗**：存活治疗族 = 0 且 伤员 ≥ 2      → 候选 = `MECH_TAGS["治疗"]` ∪ `SUB_HEAL_EXTRA`（波盾圣盾）
#   3 **需克制**：对面存活里身价最高的人 X，而我方**无人**克制 X → 候选 = `counter_bonus(h, X) > 0`
#   4 **缺输出**：存活单位**表格攻之和 ≤ `SUB_DPS_ATK_SUM`** → 候选 = 表格攻 ≥ 3
#   5 **缺射程**：存活远程 = 0                   → 候选 = `<远程>`
# ⚠️ 判据一律用**英雄表**（`def.skills/attack_type/atk`）而不是实时数值 ⇒ 真实与模拟必然一致
#   （实时值在两侧来源不同：真实读 `effective_*()`、模拟读快照/被状态改过的 `eatk`）。
# ⚠️ `ctx` 由调用方按**存活单位**填（字段名统一，见 `sub_need()` 注释）。
const SUB_NEED_PRIORITY_BONUS := 20.0    # "满足需求"的优先价：远大于身价极差(≈12) ⇒ 在**预设替补**那条路上
                                         # "不缺的职能"永远排不到"缺的职能"前面（动态路已先按需求筛过候选）
const SUB_HEAL_EXTRA: Array[String] = ["hero_16"]   # 波盾：登场全队圣盾 —— 与"治疗"同属"队伍被打疼了"的解
const SUB_DPS_ATK := 3                   # "算输出"的**表格**基础攻击门槛（= 谁够格补输出）
# 【2026-09-25 用户拍板 C】"缺输出"的**触发线**从"人头数"改成"总量"，用户定 N = 5：
#   旧口径 = `dps`（存活里表格攻 ≥ 3 的人数）≤ 0 ⇒ **一个能打的都不剩**才算缺输出，太靠边：
#   只剩一个 3 攻脆皮（还被贴住/被沉默）、或全队攻 2+2+2 时它照样判"不缺输出" ⇒ 替补按身价挑，
#   很可能又补个坦克/辅助上来，越补越打不动。
#   新口径 = 存活单位**表格攻之和** ≤ 5（≈ **凑不出两个能打的**：3+2 算缺、3+3 不算）。
#   定这个数用的实测分布（51 人：攻 0×3 · 1×7 · 2×18 · 3×17 · 4×4 · 5×2，均值 2.35）⇒
#   死一个后场上 2 人时 Σ 均值 ≈ 4.7（满编 3 人 ≈ 7.1）。
#   ⚠️ `dps` 字段**保留**（老 ctx 与实机日志还在印它），只是不再当"缺输出"的判据。
#   ⚠️ 调用方**必须**填 `atk_sum`：漏填会被 `ctx.get("atk_sum", 0)` 读成 0 ⇒ **恒判"缺输出"**。
#      目前只有两处构 ctx —— `src/Battle.gd::_sub_ctx()` 与 `src/BattleAI.gd::_sim_sub_ctx()`，两处都已填。
const SUB_DPS_ATK_SUM := 5

## ① 需求判定。ctx 字段（都由调用方从**我方/对方存活单位**统计）：
##   `taunt` 存活嘲讽数 · `healers` 存活治疗族数 · `dps` 存活且表格攻≥3 的数 · `atk_sum` 存活单位
##   表格攻**之和**（"缺输出"的判据，见 `SUB_DPS_ATK_SUM`）· `ranged` 存活远程数 ·
##   `wounded` 存活且 hp < max_hp 的数 · `core` 对面存活里身价最高的 hero_id（""=没有）·
##   `countered` 我方是否已有人克制 core · `ally_heroes`/`foe_heroes` 双方存活 hero_id（给身价/克制用）·
##   `player_near` 对面有单位贴着我方（后勤在贴身时贬价，沿用旧口径）。
## 需求优先级（顺序 = 判定顺序；`sub_need()` 与 `sub_need_for()` 共用这一份）。
const SUB_NEED_ORDER := ["缺前排", "缺治疗", "需克制", "缺输出", "缺射程"]

## 某个需求"条件本身成不成立"（**独立判定、互不短路** ⇒ 供 `sub_need_for()` 逐个试）。
func sub_need_ok(need: String, ctx: Dictionary) -> bool:
	match need:
		"缺前排": return int(ctx.get("taunt", 0)) <= 0
		"缺治疗": return int(ctx.get("healers", 0)) <= 0 and int(ctx.get("wounded", 0)) >= 2
		"需克制": return String(ctx.get("core", "")) != "" and not bool(ctx.get("countered", false))
		"缺输出": return int(ctx.get("atk_sum", 0)) <= SUB_DPS_ATK_SUM
		"缺射程": return int(ctx.get("ranged", 0)) <= 0
	return false

func sub_need(ctx: Dictionary) -> String:
	for n in SUB_NEED_ORDER:
		if sub_need_ok(String(n), ctx):
			return String(n)
	return ""

## 【2026-09-24 用户拍板 A】**带候选名单的需求判定**（预设替补那条路专用）：
##   按优先级逐个需求试，第一个"条件成立 ＋ 名单里至少一人够格（`sub_hero_eligible()`）"的才算本次需求；
##   全都不满足 ⇒ 返回 ""（= 兜底，按身价挑）。
##   病灶（用户实机）：只剩 赏金猎人＋负墟、伤员 2 ⇒ 旧口径判"缺治疗"，而 5 人预设名单里
##   **一个治疗族都没有**（治疗族只有 医护兵/德鲁伊/风语者/梅林/圣诞老人）⇒ 战锤/古灵精怪/复仇者
##   三名非治疗英雄照样印"补续航"、还白拿"缺治疗"那笔加分，最后上了战锤。
func sub_need_for(hids: Array, ctx: Dictionary) -> String:
	for n in SUB_NEED_ORDER:
		if not sub_need_ok(String(n), ctx):
			continue
		for hid in hids:
			if sub_hero_eligible(String(hid), String(n), ctx):
				return String(n)
	return ""

func sub_need_label(need: String) -> String:
	return "兜底（无缺口）" if need == "" else need

## ② 谁算"满足这个需求"（兜底 ⇒ 全算）。
func sub_hero_eligible(hid: String, need: String, ctx: Dictionary) -> bool:
	if need == "":
		return true
	var def: HeroDef = heroes.get(hid, null)
	if def == null:
		return false
	match need:
		"缺前排":
			return def.skills.has(Skill.TAUNT)
		"缺治疗":
			return (MECH_TAGS["治疗"] as Array).has(hid) or SUB_HEAL_EXTRA.has(hid)
		"需克制":
			return counter_bonus(hid, String(ctx.get("core", ""))) > 0.0
		"缺输出":
			return int(def.atk) >= SUB_DPS_ATK
		"缺射程":
			return def.attack_type == AttackType.RANGED
	return true

## ③ 该需求下的分数 = 身价（总评分+配合+克制）+「满足需求」优先价 + 需求专属项。
## 返回 { "s": float, "why": Array[String] }（`why` 只给日志用）。
func sub_hero_score(hid: String, need: String, ctx: Dictionary) -> Dictionary:
	var def: HeroDef = heroes.get(hid, null)
	if def == null:
		return { "s": -1e18, "why": [] }
	var ally: Array = ctx.get("ally_heroes", [])
	var foe: Array = ctx.get("foe_heroes", [])
	var wounded := int(ctx.get("wounded", 0))
	var s := battle_unit_value(hid, ally, foe)
	var base_v := s          # 身价（分项，给日志用）
	var prio_v := 0.0        # 需求优先价（+20，够格才给）
	var bonus_v := 0.0       # 需求专属加分
	var why: Array[String] = []
	var ok: bool = sub_hero_eligible(hid, need, ctx)
	# 【2026-09-24 用户拍板 B】这 20 分是"优先价"，只在**真有需求且这人够格**时给；兜底档（need == ""）不给
	#   （原来 `need == ""` ⇒ eligible 恒真 ⇒ 全池白加 20：名次不变但数字虚高、语义错）。
	if ok and need != "":
		s += SUB_NEED_PRIORITY_BONUS
		prio_v = SUB_NEED_PRIORITY_BONUS
	elif need != "":
		# 【2026-09-24 用户拍板 B】够不上这个需求的人，日志要写明"他做不到"，别再印成"补X"（实机误导）。
		why.append("需求=%s·这人做不到" % sub_need_label(need))
	if ok:
		match need:
			"缺前排":
				s += 0.3 * float(def.max_hp)                     # 厚血优先
				why.append("补前排(血%d)" % def.max_hp)
			"缺治疗":
				s += 1.0 * (def.ai_skill_score + def.ai_boost) + 0.5 * float(wounded)
				why.append("补续航")
			"需克制":
				var core := String(ctx.get("core", ""))
				var cb := counter_bonus(hid, core)
				s += 2.0 * cb
				var cd: HeroDef = heroes.get(core, null)
				why.append("克制%s(+%.1f)" % [cd.display_name if cd != null else core, cb])
			"缺输出":
				s += 1.5 * float(def.atk)
				why.append("补输出(攻%d)" % def.atk)
			"缺射程":
				s += 0.5 * float(def.atk)
				why.append("补射程")
	bonus_v = s - base_v - prio_v
	if def.skills.has(Skill.BENCH):
		# 【2026-09-24 用户拍板 A】替补技（登场技）按**强度**计价 —— 原来写死 `+0.5`，等于在"判出需求"的档里白送：
		#   实机例（用户）：需求=缺前排 ⇒ 太阳斩(技能强) 输给 小阴影(血厚) 1.0 分，而登场技只值那 0.5。
		#   口径与「缺治疗」档一致 = `1.0 × (技能评分 + 补强)`；**保留 0.5 作下限**（技能评分很低但有〈替补〉的
		#   英雄不会比改动前更差）。⚠️ 与 `need == ""` 兜底档的那张英雄写死表（波盾/梅林…）不冲突：那张只在没缺口时才走。
		var bench_val: float = maxf(0.5, 1.0 * (float(def.ai_skill_score) + float(def.ai_boost)))
		s += bench_val
		why.append("替补技(+%.1f)" % bench_val)
	if def.skills.has(Skill.LOGISTICS):
		# 后勤/支援：伤员多时值钱；贴身交战中不值钱（不能主动输出）—— 沿用旧口径
		if wounded > 0:
			s += float(wounded) * 1.2
			why.append("支援伤员")
		elif bool(ctx.get("player_near", false)):
			s -= 4.0
		else:
			s -= 1.5
	if need == "":
		# 兜底档才给的"登场技"价（旧口径里这几条一直在 ⇒ 会把波盾顶到第一；作为"没有缺口时"的偏好保留）
		match hid:
			"hero_16":   # 波盾：登场让己方全体获得圣盾
				s += 5.0 + (3.0 if wounded > 0 else 0.0)
				why.append("登场全队圣盾")
			"hero_36":   # 梅林：治疗最低血量队友并与其换位
				s += 5.0 if wounded > 0 else 1.0
				why.append("登场治疗换位")
			"hero_29":   # 太阳斩：登场攻击3（短时爆发）
				s += 3.0
				why.append("登场爆发")
			"hero_39":   # 猎颅者：登场锁定目标
				s += 2.0
				why.append("登场锁定")
	return { "s": s, "why": why, "base": base_v, "prio": prio_v, "bonus": bonus_v }

# 职能分类（给 AI 组队配比用）：替补标签>嘲讽坦克>后勤功能>其余输出
func hero_role_name(id: String) -> String:
	var def: HeroDef = heroes.get(id, null)
	if def == null:
		return "输出"
	if def.skills.has(Skill.BENCH):
		return "替补"
	if def.skills.has(Skill.TAUNT):
		return "坦克"
	if def.skills.has(Skill.LOGISTICS):
		return "功能"
	return "输出"

# 组队职能平衡加分：按目标比例给"当前缺的职能"加价、给"超量的职能"压价。
# deck = 已选卡组（不含 cand），cand 准备加入后总人数 N=deck.size()+1。
func role_balance_bonus(deck: Array, cand: String) -> float:
	var role := hero_role_name(cand)
	var counts := { "坦克": 0, "输出": 0, "功能": 0, "替补": 0 }
	for id in deck:
		counts[hero_role_name(id)] = int(counts[hero_role_name(id)]) + 1
	var n := deck.size() + 1
	var tank_before := int(counts["坦克"])
	counts[role] = int(counts[role]) + 1
	var b := 0.0
	# 各职能目标占比（取整），宽松区间：少于目标 -> 加分；比目标多 2 个及以上 -> 压价
	var targets := {
		"坦克": int(round(n * 0.25)),
		"输出": int(round(n * 0.4)),
		"功能": int(round(n * 0.2)),
		"替补": int(round(n * 0.15)),
	}
	for r in targets.keys():
		var c := int(counts[r])
		var t := int(targets[r])
		if c <= t:
			b += 0.8
		elif c >= t + 2:
			b -= 1.4
	# 特别拉力：己方卡组还没有坦克时，坦克候选额外加分（避免整套脆皮无前排）
	if role == "坦克" and tank_before == 0:
		b += 2.0
	# 防止出现"全场清一色"的职能（如全是坦克/全是输出）
	if int(counts[role]) >= n and n >= 3:
		b -= 3.0
	return b

# 从一段中文文本里抽取出现的英雄 id（用 NAME_ALIAS 简称 + 英雄显示名全名匹配）。
func _without_self(arr: Array, self_id: String) -> Array:
	var out: Array = []
	for x in arr:
		if x != self_id and not out.has(x):
			out.append(x)
	return out

func _extract_ids(text: String) -> Array:
	var out: Array = []
	if text == "":
		return out
	for alias in NAME_ALIAS.keys():
		if text.contains(alias) and not out.has(NAME_ALIAS[alias]):
			out.append(NAME_ALIAS[alias])
	# 全名匹配（若文本里直接写了某英雄显示名）
	# 用 _full_name_map（预扫建立的 name->id），不依赖 heroes 的加载顺序。
	for nm in _full_name_map.keys():
		if nm != "" and text.contains(nm) and not out.has(_full_name_map[nm]):
			out.append(_full_name_map[nm])
	return out

# 【2026-09-24 用户拍板①】名单列分词：与体检工具同一套分隔符（、，,；;|／/ 与空白/换行）。
func _split_pair_tokens(text: String) -> Array:
	var out: Array = []
	var cur := ""
	for i in text.length():
		var ch: String = text[i]
		if ch == "、" or ch == "，" or ch == "," or ch == "；" or ch == ";" or ch == "|" or ch == "／" or ch == "/" or ch == "\n" or ch == "\r" or ch == "\t" or ch == " " or ch == "　":
			if cur.strip_edges() != "":
				out.append(cur.strip_edges())
			cur = ""
		else:
			cur += ch
	if cur.strip_edges() != "":
		out.append(cur.strip_edges())
	return out

# 【2026-09-24 用户拍板①】「语义伙伴」列的**加权写法**解析：`名字×N`（`×` `x` `X` `*` 都认，不写 = `default_w`）。
# 同一个名字出现多次取**最大权重**；万一某一段不是英雄名（写成"远程/坦克"这类词）则退回语义/数值展开，权重照给。
# `default_w`：语义伙伴列 = 1.0；「克制」/「被克制」两列 = 2.0（= 旧口径那条硬编码的 +2.0）。
func _parse_weighted_pairs(text: String, default_w: float = 1.0) -> Dictionary:
	var out: Dictionary = {}
	for tok in _split_pair_tokens(text):
		var w := default_w
		var name_part: String = tok
		var re := RegEx.new()
		re.compile("[×xX*]\\s*([0-9]+(?:\\.[0-9]+)?)$")
		var m := re.search(tok)
		if m != null:
			w = m.get_string(1).to_float()
			name_part = tok.substr(0, m.get_start(0)).strip_edges()
		if name_part == "":
			continue
		var ids: Array = _extract_ids(name_part)
		if ids.is_empty():
			ids = _semantic_heroes(name_part) + _numeric_filter_heroes(name_part)
		for hid in ids:
			var key := String(hid)
			if key == "":
				continue
			out[key] = maxf(float(out.get(key, 0.0)), w)
	return out

# 从文本的"语义关键词"(如 坦克/位移/攻击力收益)展开出对应机制标签下的英雄 id——
# 用于把"配合/被克制"列的宽泛描述转成可计算的协同/克制候选。
func _semantic_heroes(text: String) -> Array:
	var out: Array = []
	if text == "":
		return out
	for kw in SEMANTIC.keys():
		if text.contains(kw):
			for tag in SEMANTIC[kw]:
				for hid in MECH_TAGS.get(tag, []):
					if not out.has(hid):
						out.append(hid)
	# 【2026-09-21 新增·用户拍板 B】**特性标签式写法**（「远程 / 后勤 / 嘲讽 …」）⇒ 展开成带该标签的
	#   全部英雄（表由特性列预扫建立 ⇒ 改英雄特性自动跟随）。没有这一步，荆棘树人「远程/后勤」、
	#   宿魂「远程」、赏金猎人「嘲讽」这三格展开为空、AI 读不到（详见 `const TRAIT_TAGS` 处说明）。
	for tg in TRAIT_TAGS:
		if text.contains(tg):
			for hid in _trait_tag_ids.get(tg, []):
				if not out.has(hid):
					out.append(hid)
	return out

# 数值筛选类文本（如"技能评分+补强>3的非替补角色"、"面板攻击力可以大于等于4的"）：
# 按若干数值列求和之后 与阈值比较 筛选英雄。支持句式「列A(+列B...)比较N」。
# 数值列：攻击力 / 补强 / 技能评分 / 总评分。
# 比较符：> / >= / 大于 / 大于等于 / 不少于 / 不低于 / 超过 / 高于。
func _numeric_filter_heroes(text: String) -> Array:
	var out: Array = []
	if text == "":
		return out
	# 抓取 比较符 + 阈值（阈值可为小数）。
	# 注意：先匹配"大于等于/不少于/不低于"再匹配单字"大于/超过/高于"，避免"大于等于"只取到"大于"。
	var re := RegEx.new()
	re.compile("(?:>=|大于等于|不少于|不低于|>|大于|超过|高于)\\s*([0-9]+(?:\\.[0-9]+)?)")
	var m := re.search(text)
	if m == null:
		return out
	var op := m.get_string(0)   # 整个匹配段，用于判断是否包含等号
	var threshold := m.get_string(1).to_float()
	var incl_equal := (op.contains(">=") or op.contains("等于") or op.contains("少于") or op.contains("低于"))
	# 是否排除替补角色
	var exclude_bench := text.contains("非替补")
	# 文本里涉及哪些数值列（求和）
	var uses_atk := text.contains("攻击力")
	var uses_boost := text.contains("补强")
	var uses_score := text.contains("技能评分")
	var uses_total := text.contains("总评分")
	for id in heroes:
		var d: HeroDef = heroes[id]
		if d == null or d.is_summon:
			continue
		if exclude_bench and d.skills.has(Skill.BENCH):
			continue
		var v := 0.0
		if uses_atk:
			v += float(d.atk)
		if uses_boost:
			v += d.ai_boost
		if uses_score:
			v += d.ai_skill_score
		if uses_total:
			v += d.ai_total
		var ok := (v > threshold) if not incl_equal else (v >= threshold)
		if ok and not out.has(id):
			out.append(id)
	return out

# 公开调试方法：把一列文本用与角色解析完全相同的三路逻辑展开成 hero_id 列表。
# 供 tools/生成解析体检.gd 与运行时诊断复用之，确保体检结果与真实协同/克制一致。
func parse_column(text: String) -> Array:
	var out: Array = []
	out.append_array(_extract_ids(text))
	out.append_array(_semantic_heroes(text))
	out.append_array(_numeric_filter_heroes(text))
	return out

# 种族（卡面配色/卡池分组用；随 角色列表 第二列）
enum Race { HUMAN, MECH, BEAST, ELF, DEMON }

# 种族英文名 -> 中文（展示/调试用）
const RACE_NAMES := {
	Race.HUMAN: "人族",
	Race.MECH: "机械",
	Race.BEAST: "兽族",
	Race.ELF: "精灵",
	Race.DEMON: "魔族",
}

# 阵营
enum Faction { PLAYER, ENEMY }

## 每位角色的数据结构
class HeroDef:
	var id: String
	var display_name: String
	var race: int   # Race 枚举（人族/机械/兽族/精灵/魔族）
	var attack_type: int
	var max_hp: int
	var atk: int
	var move_range: int
	var attack_range: int
	var skills: Array = []
	var desc: String = ""
	var is_summon := false   # 衍生物（召唤单位，不入卡池）
	# 角色列表新增三列（不用于显示，仅供 AI 策略参考/结构化抽取）
	var synergy_note: String = ""       # 配合（文本备注）
	var effective_behavior: String = "" # 有效行为（文本备注）
	var countered_by_note: String = ""  # 被克制（文本备注）
	var pairs_note: String = ""         # 协同英雄列原文备注
	var sem_note: String = ""           # 【2026-09-24】"语义伙伴"列原文（手工维护；非空 ⇒ 以它为准，不再自动展开"配合"列）
	var sy_partners: Array = []         # 语义伙伴 id 列表（"语义伙伴"列手工填的名字，或自动展开结果）
	var sy_weight: Dictionary = {}      # 【2026-09-24 用户拍板①】配对权重 id->float（`名字×N`；自动展开/未写 ×N 时为 1.0）
	var counters: Array = []            # "被克制"列抽出：**克制我的**英雄(我的天敌)
	var beats: Array = []               # "克制/有效行为"列抽出：**我能克制**的英雄
	var counters_weight: Dictionary = {} # 【2026-09-24】被克制的权重 id->float（`名字×N`，不写 = 2.0）
	var beats_weight: Dictionary = {}   # 【2026-09-24】克制的权重 id->float（同上）
	var explicit_pairs: Array = []      # "协同英雄"列直接点名的搭配英雄 id（AI 协同用）
	# 影响 AI 行为的手动评分列（角色列表 属性评分/特性评分/技能量化/技能评分/补强/总评分）
	var ai_attr_score := 0.0
	var ai_trait_score := 0.0
	var ai_skill_quant := 0.0
	var ai_skill_score := 0.0
	var ai_boost := 0.0
	var ai_total := 0.0

	func _init(id_: String = "") -> void:
		id = id_

# 角色列表文本里的中文名/简称 -> hero_id 映射（三列解析时抽取协同/克制用）
const NAME_ALIAS := {
	"死神": "hero_30", "嬉皮死神": "hero_30",
	"小红帽": "hero_40", "红帽": "hero_40",
	"烈焰祭祀": "hero_19", "烈焰祭司": "hero_19",
	"风语者": "hero_43", "死灵法师": "hero_33", "末日": "hero_31",
	"毒蛇": "hero_03",
}

# 机制标签：hero_id -> [标签]。用于把"配合/有效行为/被克制"列的宽泛语义翻译成可计算的协同/克制。
const MECH_TAGS := {
	"坦克": ["hero_11", "hero_12", "hero_13", "hero_22", "hero_23", "hero_24", "hero_25", "hero_26", "hero_36"],
	# 位移分两个相反方向：
	# 位移提供 = 能主动使敌人移动/击退/换位/拉近；位移受益 = 依赖敌人被移动/聚拢才打出效果。
	"位移提供": ["hero_05", "hero_21", "hero_27", "hero_32", "hero_41"],
	"位移受益": ["hero_30", "hero_35", "hero_17"],
	# 攻击力相关分两个相反方向：
	# 攻击增益提供 = 能给队友加攻击/放攻增益道具的辅助；攻击增益受益 = 自身攻击收益大的输出。
	"攻击增益提供": ["hero_19", "hero_02"],
	"攻击增益受益": ["hero_23", "hero_30", "hero_32", "hero_15", "hero_29", "hero_37", "hero_14"],
	"多倍": ["hero_23", "hero_30", "hero_32", "hero_15", "hero_14"],
	"AOE": ["hero_10", "hero_17", "hero_18", "hero_40", "hero_31"],
	# 多段 = 一次行动/一回合里能打出≥2次伤害事件的英雄（多目标命中、或一次召唤出多个攻击者）。
	# 与 AOE 高度重叠，但额外包含"靠数量打出多次伤害"的死灵法师（自身+2骷髅=3次攻击）。
	# 对"每当敌人受到一次伤害就成长"的锤头鲨这类英雄，多段是最直接的收益来源。
	"多段": ["hero_33", "hero_10", "hero_17", "hero_18", "hero_21", "hero_31", "hero_40"],
	"治疗": ["hero_06", "hero_08", "hero_43", "hero_36", "hero_02"],
	"召唤": ["hero_33"],
	"减益": ["hero_25", "hero_26", "hero_34", "hero_38"],
	# 具体负面状态对应到"施加者"(供被克制列的精准匹配)
	"麻痹": ["hero_25"],
	"冰冻": ["hero_25", "hero_26", "hero_10"],
	"沉默": ["hero_34"],
	"眩晕": ["hero_39"],
	"猛毒": ["hero_03"],
	# 异常状态施加者全集（供"能施加异常状态/负面效果"类语义）：
	# 猛毒03、冰冻25/26/10、沉默34、眩晕39、重伤12、附体46、减攻麻痹25。
	"异常": ["hero_03", "hero_25", "hero_26", "hero_10", "hero_34", "hero_39", "hero_12", "hero_46"],
}

# 文本语义关键词 -> 相关机制标签（用于把三列的宽泛描述翻译成标签偏好）
const SEMANTIC := {
	# 【已删 2026-09-24·用户拍板】原 `"坦克": ["坦克"]` —— 用户口径：「**不用特意写坦克吧，队伍配比会上坦克的**，
	#   如果加上，那再有坦克的情况下会加大医护兵的选择」。核对属实：坦克由 `role_balance_bonus()` 统一管
	#   （"己方卡组还没有坦克时坦克候选 **+2.0**"，见 `:307`），再在"配合"列的语义展开里算一遍就是**重复计价**
	#   ⇒ 摘掉这条关键词。影响面：**只在"配合"列写过坦克的 4 个英雄**（医护兵 hero_06 / 影丸 hero_07 /
	#   古拉博士 hero_14 / 沉默术士 hero_34）——它们不再把 9 个坦克当"语义伙伴"；
	#   医护兵/古拉 仍保留另一条真配合（"能提供攻击力加成的角色" ⇒ 烈焰祭司/圣诞老人）。
	#   `MECH_TAGS["坦克"]` 保留（文档/以后可能复用），只是不再被语义关键词自动展开。
	#   ⚠️ 核对过：`克制` / `被克制` 两列**没有任何一格**写"坦克" ⇒ 摘掉它不影响克制解析。
	"需要敌人位移": ["位移受益"],
	"能使敌人位移": ["位移提供"],
	"使敌人位移": ["位移提供"],   # 兼容"可以使敌人位移英雄"这类写法（不含"需要"→只按"提供位移"解）
	"攻击力收益": ["攻击增益受益", "多倍", "AOE"],
	"需要攻击力加成": ["攻击增益受益"],
	"能提供攻击力加成": ["攻击增益提供"],
	"多倍伤害": ["多倍"],
	"AOE": ["AOE"],
	"多段": ["多段"],
	"治疗": ["治疗"],
	"召唤": ["召唤"],
	"减攻": ["减益"],
	"克制": ["减益"],
	"麻痹": ["麻痹"],
	"冰冻": ["冰冻"],
	"沉默": ["沉默"],
	"眩晕": ["眩晕"],
	"猛毒": ["猛毒"],
	"异常状态": ["异常"],
	"负面效果": ["异常"],
	"施加异常": ["异常"],
	"依赖技能": ["攻击增益受益"],
}

# 英雄专属技能特效：id -> {color 主色, text 机制飘字文案}。触发时呈现贴合英雄特点的演出。
const HERO_FX := {
	"hero_01": { "color": Color(0.95, 0.72, 0.35), "text": "伐木" },
	"hero_02": { "color": Color(1.0, 0.3, 0.3), "text": "圣诞" },
	"hero_03": { "color": Color(0.4, 0.9, 0.45), "text": "猛毒" },
	"hero_04": { "color": Color(0.85, 0.5, 0.95), "text": "疾行" },
	"hero_05": { "color": Color(0.75, 0.4, 0.9), "text": "傀儡" },
	"hero_06": { "color": Color(0.4, 0.95, 0.55), "text": "治疗" },
	"hero_07": { "color": Color(0.35, 0.4, 0.95), "text": "影击" },
	"hero_08": { "color": Color(0.4, 0.9, 0.5), "text": "德鲁伊" },
	"hero_09": { "color": Color(1.0, 0.5, 0.3), "text": "火枪" },
	"hero_10": { "color": Color(0.45, 0.8, 1.0), "text": "冰霜" },
	"hero_11": { "color": Color(0.7, 0.8, 0.95), "text": "塔盾" },
	"hero_12": { "color": Color(1.0, 0.4, 0.35), "text": "重伤" },
	"hero_13": { "color": Color(0.75, 0.7, 0.5), "text": "坚盾" },
	"hero_14": { "color": Color(0.9, 0.2, 0.35), "text": "吸血" },
	"hero_15": { "color": Color(0.35, 0.35, 0.35), "text": "阴影" },
	"hero_16": { "color": Color(0.5, 0.85, 1.0), "text": "圣盾" },
	"hero_17": { "color": Color(1.0, 0.55, 0.25), "text": "烛火" },
	"hero_18": { "color": Color(0.9, 0.85, 0.7), "text": "穿透" },
	"hero_19": { "color": Color(1.0, 0.5, 0.6), "text": "烈焰" },
	"hero_20": { "color": Color(1.0, 0.8, 0.3), "text": "赏金" },
	"hero_21": { "color": Color(0.6, 0.7, 1.0), "text": "击退" },
	"hero_22": { "color": Color(0.95, 0.85, 0.4), "text": "圣光" },
	"hero_23": { "color": Color(0.85, 0.2, 0.25), "text": "复仇" },
	"hero_24": { "color": Color(0.9, 0.5, 0.2), "text": "冲锋" },
	"hero_25": { "color": Color(0.6, 0.6, 0.65), "text": "麻痹" },
	"hero_26": { "color": Color(0.5, 0.85, 1.0), "text": "冰冻" },
	"hero_27": { "color": Color(0.3, 0.3, 0.45), "text": "换位" },
	"hero_28": { "color": Color(0.75, 0.4, 0.95), "text": "变身" },
	"hero_29": { "color": Color(1.0, 0.75, 0.25), "text": "太阳斩" },
	"hero_30": { "color": Color(0.5, 0.35, 0.75), "text": "收割" },
	"hero_31": { "color": Color(0.35, 0.3, 0.55), "text": "末日" },
	"hero_32": { "color": Color(1.0, 0.55, 0.3), "text": "击退" },
	"hero_33": { "color": Color(0.45, 0.75, 0.4), "text": "召唤" },
	"hero_34": { "color": Color(0.55, 0.5, 0.75), "text": "沉默" },
	"hero_35": { "color": Color(1.0, 0.6, 0.15), "text": "爆破" },
	"hero_36": { "color": Color(0.5, 0.8, 0.95), "text": "置换" },
	"hero_37": { "color": Color(0.6, 0.85, 1.0), "text": "锤头" },
	"hero_38": { "color": Color(0.6, 0.9, 0.9), "text": "涌电" },
	"hero_39": { "color": Color(0.9, 0.4, 0.6), "text": "猎颅" },
	"hero_40": { "color": Color(0.95, 0.3, 0.25), "text": "扑街" },
	"hero_41": { "color": Color(0.9, 0.2, 0.3), "text": "血锁" },
	"hero_42": { "color": Color(1.0, 0.8, 0.3), "text": "金矿" },
	"hero_43": { "color": Color(0.5, 1.0, 0.8), "text": "风语" },
	"hero_44": { "color": Color(0.75, 0.6, 0.9), "text": "负墟" },
	"hero_48": { "color": Color(0.55, 0.72, 0.9), "text": "坚固" },
	"hero_49": { "color": Color(0.5, 0.9, 0.5), "text": "荆棘" },
}

# 取某英雄的技能特效（颜色 + 文案），返回 {color, text}
func hero_fx(id: String) -> Dictionary:
	return HERO_FX.get(id, { "color": Color(1.0, 1.0, 1.0), "text": "" })

# 【2026-09-23 新增·用户要求】远程攻击的**射线演出**：id -> { style, color? }。
#   用户口径：「为远程攻击增加演出，发射一条射线到目标。这个射线**默认白色**，**部分英雄给点效果**。
#   比如白游侠的是冰冻，所以是蓝色。沉默术士是魔法，可以用紫色」。
#   ⇒ **没列在这里的英雄 = 纯白默认光束**（`style:"beam"`）；列出来的英雄默认沿用 `HERO_FX` 里
#     已有的主题色（那张表本来就是按英雄机制配的色），要单独改色就在条目里写 `"color"`。
#   `style` 可选值见 `src/Battle.gd::RangedRay._draw()`：
#     `beam` 默认光束 / `bullet` 枪弹曳光 / `lightning` 锯齿闪电 / `shell` 粗弹体+尾烟 /
#     `ice` 冰晶+霜环 / `magic` 符文环+法阵 / `fire` 火星 / `star` 星芒 / `wind` 风刃 /
#     `nature` 叶影 / `necro` 魂点 / `shadow` 残影。
const HERO_RAY := {
	"hero_09": { "style": "bullet" },      # 火枪手：就是一杆枪 ⇒ 细曳光 + 枪口闪
	"hero_10": { "style": "ice" },         # 白游侠：远程一并伤害相邻 + [冰冻] ⇒ 冰蓝晶束（用户点名）
	"hero_34": { "style": "magic" },       # 沉默术士：命中挂[沉默]（魔法）⇒ 紫色符文束（用户点名）
	"hero_19": { "style": "fire" },        # 烈焰祭司：全场攻击 +1 的火焰祭司 ⇒ 火束带火星
	"hero_20": { "style": "bullet" },      # 赏金猎人：枪械赏金 ⇒ 金色弹道
	"hero_21": { "style": "star" },        # 超新星：冲击波/击退 ⇒ 星芒射线
	"hero_07": { "style": "shadow" },      # 影丸：暗杀者 ⇒ 暗色残影
	"hero_43": { "style": "wind" },        # 风语者：全队[风语]（移动力）+风 ⇒ 风刃
	"hero_08": { "style": "nature" },      # 德鲁伊：回合末治愈全队 ⇒ 自然绿束
	"hero_33": { "style": "necro" },       # 死灵法师：召唤骷髅 ⇒ 亡灵魂点
	"hero_35": { "style": "shell" },       # 炸弹人：爆破 ⇒ 粗弹体拖烟
	"hero_45": { "style": "shell" },       # 坠炮手：全场炮击、弹道无视阻挡 ⇒ 炮弹轨迹（粗、带烟）
	"hero_05": { "style": "magic" },       # 傀儡师：操控敌人位移 ⇒ 紫线操控（同魔法家族）
	"hero_06": { "style": "nature" },      # 医护兵：治疗 ⇒ 柔和绿束（同自然家族）
}

# 取某英雄的远程射线规格：没配置 = **纯白默认光束**；配置了 = 主题样式 + 主题色（可单独覆盖）
func hero_ray(id: String) -> Dictionary:
	if not HERO_RAY.has(id):
		return { "style": "beam", "color": Color(1.0, 1.0, 1.0) }
	var d: Dictionary = HERO_RAY[id]
	var col: Color = d.get("color", HERO_FX.get(id, {}).get("color", Color(1.0, 1.0, 1.0)))
	return { "style": String(d.get("style", "beam")), "color": col }

var heroes: Dictionary = {}
# id -> HeroDef（衍生物/召唤单位）
var summons: Dictionary = {}
# 显示名 -> id（预扫建立，供 _extract_ids 全名匹配），独立于加载顺序。
var _full_name_map: Dictionary = {}
# 【2026-09-21 新增·用户拍板 B】特性标签 -> 英雄 id（预扫"特性"列建立，供"标签式克制"解析）。
# 为什么需要：角色列表「克制 / 被克制 / 配合」列里存在**标签式写法** ——
#   荆棘树人「远程/后勤」· 宿魂「远程」· 赏金猎人「嘲讽」，而原来的三路解析
#   （① 名称/简称 ② SEMANTIC 关键词 → MECH_TAGS ③ 数值筛选句式）**一个都认不出这些标签**
#   ⇒ 整列展开为空 ⇒ `battle_unit_value_parts().counter` 恒 0 ⇒ 写在那儿的"克制"对 AI **完全不可见**
#   （= 假数据；用户实测反馈「荆棘树人怎么克制那里没解释出来」就是这么来的）。
# 现改为：**文本里出现某个特性标签 ⇒ 展开成"特性里带该标签"的全部英雄**，且这张表是
#   **从特性列现扫出来的** ⇒ 以后改英雄特性，这里自动跟着变，不用手抄 id 表。
# ⚠️ 刻意**不含「替补」**：那是"职能标记"而不是机制标签，而且「克制」列里本就有
#   「技能评分+补强>3的**非替补**角色」这种数值句式（含"替补"二字）⇒ 收进来会把整批替补英雄
#   误判成"被它克制"（这是真会出错的，不是洁癖）。
const TRAIT_TAGS: Array[String] = ["远程", "后勤", "嘲讽", "疾行", "渗透"]
var _trait_tag_ids: Dictionary = {}

func _ready() -> void:
	_load_heroes()

func _load_heroes() -> void:
	heroes.clear()
	summons.clear()
	_trait_tag_ids.clear()   # 特性标签表随英雄表一起重建（见 TRAIT_TAGS 说明）
	var rows := _read_json_rows("res://Data/Hero/Source/角色列表.json")
	if rows.is_empty():
		push_error("无法读取 res://Data/Hero/Source/角色列表.json")
		return

	# 表头列名 -> 下标（表格列可增改，按列名取值，避免列位置写死错位）
	var col := {}   # "名称"/"攻击力"/"HP"/"技能"/"种族"... -> 下标
	var hdr_idx := -1
	for ri in rows.size():
		var r0: Array = rows[ri]
		var first := (str(r0[0]).strip_edges() if r0.size() > 0 else "")
		if first == "No." or first == "No":
			hdr_idx = ri
			break
	if hdr_idx < 0:
		push_error("xlsx 中未找到表头(No. 行)")
		return
	var header: Array = rows[hdr_idx]
	for i in header.size():
		var col_name_cell := str(header[i]).strip_edges()
		if col_name_cell != "":
			col[col_name_cell] = i
	var col_race: int = col.get("种族", col.get("等级", 2))
	var col_no: int = col.get("No.", 1)
	var col_name: int = col.get("名称", 3)
	var col_atk: int = col.get("攻击力", 4)
	var col_hp: int = col.get("HP", 5)
	var col_trait: int = col.get("特性", -1)      # 新表：词条独立列（旧表无）
	var col_skill: int = col.get("技能", 6)        # 新表7/旧表6
	var col_syn: int = col.get("配合", 7)
	var col_eff: int = col.get("克制", col.get("有效行为", 8))   # 表头曾用"克制"，旧称"有效行为"
	var col_counter: int = col.get("被克制", 9)
	var col_pairs: int = col.get("协同英雄", 10)
	# 【2026-09-24 用户要求】「语义伙伴」列：**手工维护的语义协同名单**（用户口径：「改代码太累了，
	#   把解析出来的英雄列在后面，我直接改 Excel」）。**填了这一列 ⇒ 以它为准**（不再按"配合"列
	#   自动展开）；留空 ⇒ 仍走原来的自动展开（`_semantic_heroes` + `_numeric_filter_heroes`）⇒ 逐位不变。
	var col_sem: int = col.get("语义伙伴", -1)
	var col_attr_score: int = col.get("属性评分", -1)
	var col_trait_score: int = col.get("特性评分", -1)
	var col_skill_quant: int = col.get("技能量化", -1)
	var col_skill_score: int = col.get("技能评分", -1)
	var col_boost: int = col.get("补强", -1)
	var col_total: int = col.get("总评分", -1)

	# 预扫一次：先建立 "显示名 -> id" 映射，供 _extract_ids 全名匹配使用。
	# 不依赖 heroes 的加载顺序，也避免"排在后面英雄被前面英雄列点名时匹配不到"。
	for ri in range(hdr_idx + 1, rows.size()):
		var cells: Array = rows[ri]
		if cells.size() < 7:
			continue
		var race_text: String = str(cells[col_race]).strip_edges() if (col_race >= 0 and col_race < cells.size()) else ""
		if race_text == "":
			continue
		var no_text: String = str(cells[col_no]).strip_edges() if (col_no >= 0 and col_no < cells.size()) else ""
		var is_summon := (race_text == "衍生物")
		if not is_summon and (no_text == "" or not no_text.is_valid_int()):
			continue
		var pid: String = "summon_skeleton" if is_summon else ("hero_%02d" % no_text.to_int())
		var pname: String = str(cells[col_name]).strip_edges()
		if pname != "" and not _full_name_map.has(pname):
			_full_name_map[pname] = pid
		# 同时建立"特性标签 -> 英雄 id"表（见 `const TRAIT_TAGS` 处说明）。衍生物也收：
		#   它们同样能当克制对象（例如"能施加异常的英雄"里就有召唤物来源），收进来只多不少。
		var ptrait: String = str(cells[col_trait]).strip_edges() if (col_trait >= 0 and col_trait < cells.size()) else ""
		if ptrait != "":
			for tg in TRAIT_TAGS:
				if ptrait.contains(tg):
					var arr: Array = _trait_tag_ids.get(tg, [])
					if not arr.has(pid):
						arr.append(pid)
					_trait_tag_ids[tg] = arr

	for ri in range(hdr_idx + 1, rows.size()):
		var cells: Array = rows[ri]
		if cells.size() < 7:
			continue
		var race_text: String = str(cells[col_race]).strip_edges() if (col_race >= 0 and col_race < cells.size()) else ""
		if race_text == "":
			continue
		# 跳过表头/分隔行（No 列非整数且非"-"）
		var no_text: String = str(cells[col_no]).strip_edges() if (col_no >= 0 and col_no < cells.size()) else ""
		var is_summon := (race_text == "衍生物")
		if not is_summon and (no_text == "" or not no_text.is_valid_int()):
			continue

		var h := HeroDef.new()
		if is_summon:
			h.id = "summon_skeleton"
		else:
			h.id = "hero_%02d" % no_text.to_int()
		h.display_name = str(cells[col_name]).strip_edges()
		h.atk = str(cells[col_atk]).strip_edges().to_int()
		h.max_hp = str(cells[col_hp]).strip_edges().to_int()
		var cell_at := func(i: int) -> String:
			return str(cells[i]).strip_edges() if (i >= 0 and i < cells.size()) else ""
		# 词条检测：新表"特性"列是独立词条区(在句号前)，直接查 contains；
		# 旧表词条嵌在技能正文尾部，用 _tail_has(最后'。'之后) 兼容。
		var trait_txt: String = (cell_at.call(col_trait)).replace("\\", "")
		var skill_raw: String = (cell_at.call(col_skill)).replace("\\", "")
		h.desc = skill_raw
		h.is_summon = is_summon

		# 存原文备注(真正解析在全部英雄加载完后统一跑，避免依赖加载顺序——见函数末尾 _resolve_notes)
		h.synergy_note = cell_at.call(col_syn)
		h.effective_behavior = cell_at.call(col_eff)
		h.countered_by_note = cell_at.call(col_counter)
		h.pairs_note = cell_at.call(col_pairs)
		h.sem_note = cell_at.call(col_sem) if col_sem >= 0 else ""
		h.sy_partners = []
		h.counters = []
		h.beats = []
		h.counters_weight = {}
		h.beats_weight = {}
		h.explicit_pairs = []
		h.pairs_note = cell_at.call(col_pairs)

		# 影响 AI 行为的手动评分列
		h.ai_attr_score = cell_at.call(col_attr_score).to_float()
		h.ai_trait_score = cell_at.call(col_trait_score).to_float()
		h.ai_skill_quant = cell_at.call(col_skill_quant).to_float()
		h.ai_skill_score = cell_at.call(col_skill_score).to_float()
		h.ai_boost = cell_at.call(col_boost).to_float()
		h.ai_total = cell_at.call(col_total).to_float()

		var has_tag := func(tag: String) -> bool:
			return trait_txt.contains(tag) or _tail_has(skill_raw, tag)
		var has_ranged: bool = has_tag.call("<远程>")
		var has_taunt: bool = has_tag.call("<嘲讽>")
		var has_swift: bool = has_tag.call("<疾行>")
		var has_infiltrate: bool = has_tag.call("<渗透>")
		var has_logistics: bool = has_tag.call("<后勤>")
		var has_bench: bool = skill_raw.begins_with("<替补>") or has_tag.call("<替补>")

		h.race = _race_of(race_text)
		h.attack_type = AttackType.RANGED if has_ranged else AttackType.MELEE
		# 基础移动力 2（疾行由生成时 +1），射程 1（远程 → 2）
		h.move_range = 2
		h.attack_range = 2 if has_ranged else 1
		h.skills = []
		if has_taunt:
			h.skills.append(Skill.TAUNT)
		if has_swift:
			h.skills.append(Skill.SWIFT)
		if has_infiltrate:
			h.skills.append(Skill.INFILTRATE)
		if has_logistics:
			h.skills.append(Skill.LOGISTICS)
		if has_bench:
			h.skills.append(Skill.BENCH)

		if is_summon:
			summons[h.id] = h
		else:
			heroes[h.id] = h

	# 全部英雄加载完毕后再统一解析三列：此时 heroes 已含所有 id，
	# 数值筛选/语义解析遍历全量，不再受"处理靠前英雄时排在后面的还没加载"的顺序影响。
	for hid in heroes.keys():
		var hd: HeroDef = heroes[hid]
		if hd.sem_note.strip_edges() != "":
			# 【2026-09-24 用户要求】手工"语义伙伴"列优先：填了就完全以它为准（用户可直接在 Excel 里增删伙伴）
			# 【2026-09-24 用户拍板①】支持加权写法 `名字×N`（不写 = 1.0）⇒ 原「协同英雄」点名档（+2.0）退役：
			#   需要强绑定就写 ×3（= 旧口径 1.0 语义 + 2.0 点名）。
			hd.sy_weight = _parse_weighted_pairs(hd.sem_note)
			hd.sy_partners = _without_self(hd.sy_weight.keys(), hd.id)
			hd.sy_weight.erase(hd.id)
		else:
			hd.sy_weight = {}
			hd.sy_partners = _without_self((_extract_ids(hd.synergy_note) + _semantic_heroes(hd.synergy_note) + _numeric_filter_heroes(hd.synergy_note)), hd.id)
		# 【2026-09-24 用户要求·与「语义伙伴」同一套】"克制"/"被克制"两列也改成**可加权的人工名单**：
		#   写法 `名字×N`（不写 = **2.0**，等于旧口径那条硬编码的 +2.0）；非英雄名的词（"远程"/"嘲讽"/
		#   "技能评分+补强>3的非替补角色"这类）照旧退回语义/数值展开，权重同样生效 ⇒ 旧原文一格不改也不变。
		hd.counters_weight = _parse_weighted_pairs(hd.countered_by_note, 2.0)   # 被克制列->克制我的英雄
		hd.counters = _without_self(hd.counters_weight.keys(), hd.id)
		hd.counters_weight.erase(hd.id)
		hd.beats_weight = _parse_weighted_pairs(hd.effective_behavior, 2.0)    # 克制/有效行为列->我能克制的英雄
		hd.beats = _without_self(hd.beats_weight.keys(), hd.id)
		hd.beats_weight.erase(hd.id)
		hd.explicit_pairs = _without_self(_extract_ids(hd.pairs_note), hd.id)   # "协同英雄"列：直接点名的搭档


# 从 res://Data/Hero/Source/角色列表.json 读取全部行（由本机 PowerShell 脚本从 Data/Hero/角色列表.xlsx
# 转换生成；本引擎构建未包含 ZipReader/Compression,无法直接解 xlsx,故改为读 JSON 副产物）
func _read_json_rows(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("无法读取 %s" % path)
		return []
	var txt: String = f.get_as_text()
	f.close()
	var data = JSON.parse_string(txt)
	if data is Array:
		var rows: Array = []
		for r in data:
			var row: Array = []
			for c in r:
				row.append(str(c))
			rows.append(row)
		return rows
	return []

# 判断某关键词是否出现在技能文本"尾部标签区"（最后一个'。'之后）
# 正文中引用他人关键词（如"目标有<嘲讽>"）属于正文，不计为自身关键词。
func _tail_has(text: String, tag: String) -> bool:
	var tail := text
	var dot := text.rfind("。")
	if dot >= 0:
		tail = text.substr(dot + 1)
	return tail.contains(tag)

func _race_of(race_text: String) -> int:
	match race_text:
		"人族":
			return Race.HUMAN
		"机械":
			return Race.MECH
		"兽族":
			return Race.BEAST
		"精灵":
			return Race.ELF
		"魔族":
			return Race.DEMON
	return Race.HUMAN

func get_hero(id: String) -> HeroDef:
	return heroes.get(id, null)

func get_summon(id: String) -> HeroDef:
	return summons.get(id, null)

# —— 数值图标素材（爱心=血量、攻击=攻击力）——
# 素材是"图标+近白实底"：首次使用把白底抠成透明，同时记录主体包围盒（宽/高/中心）。
# 供 Unit 棋子与 HexCard 卡面按"主体宽度"等比放大，并把图标主体精确放到数字下方。
const ICON_HEART := "res://assets/美术资源/爱心.png"
const ICON_ATK := "res://assets/美术资源/攻击.png"
const ICON_ATK_RANGED := "res://assets/美术资源/攻击_远程.png"   # 远程角色的攻击力图标（弩）
const ICON_ATK_LOGISTICS := "res://assets/美术资源/攻击_后勤.png"   # 后勤角色的攻击力图标（齿轮）
var _stat_icons: Dictionary = {}   # path -> {tex:Texture2D, w,h,cx,cy}
var _stat_bold_font: FontVariation = null   # 数值（攻击/血量）加粗字体，全部界面共享

# —— 英雄卡面图（六边形卡里的人物本体）——
# 【2026-09-27·用户要求】六边形卡里放"人物本体"，字体名字不再由卡自己画。
#   查找顺序（按**中文名**，与现有素材命名一致）：
#     ① `res://assets/英雄卡面/<名字>_人物.png`（生成图抠出来的透明底本体，卡里就用这张）
#     ② `res://assets/英雄卡面/<名字>.png`（整张卡面，兜底）
#     ③ `res://assets/美术资源/角色/<名字>.png`（旧立绘）
#   三处都没有 ⇒ 返回 null ⇒ 卡退回原来的"纯色六边形"外观（**别的英雄还没出图，行为与改前一致**）。
#   ⚠️ 新丢进来的 png 若还没被编辑器导入（没有 `.import`），`load()` 会失败 ⇒ 兜底走运行时解码
#      （`Image.load()`，开发期跑 res:// 目录有效；进编辑器扫一遍就会走正常导入）。
const HERO_ART_DIRS: Array[String] = ["res://assets/英雄卡面/", "res://assets/美术资源/角色/"]
const HERO_ART_MAX := 512   # 卡面图最长边上限（卡只有 90~160 px ⇒ 512 已 3~5 倍余量）
var _hero_art: Dictionary = {}   # 中文名 -> Texture2D / null

func hero_card_art(display_name: String) -> Texture2D:
	if _hero_art.has(display_name):
		return _hero_art[display_name]
	var found: Texture2D = null
	for d in HERO_ART_DIRS:
		for suf in ["_人物.png", ".png"]:
			found = _load_tex_any(d + display_name + suf)
			if found != null:
				break
		if found != null:
			break
	# 【为什么必须缩 + 必须带 mipmap】出图是 2048²（RGBA ≈ 11 MB/张），49 个英雄全出图会把显存吃爆；
	#   而卡/棋子上的实际显示尺寸只有 ~150~190 px（棋盘 `hex_size≈73` ⇒ 棋子 146px 宽、竞技场卡 `card_r=92`
	#   ⇒ 184px 宽）⇒ ① 先压到最长边 HERO_ART_MAX（省 16 倍显存）；② **再生成 mipmap**：
	#   512 的图缩到 ~150px 显示 = 约 3 倍缩小，没有 mipmap 时只抽 1/3 像素 ⇒ **边缘锯齿 + 细节发糊**
	#   （2026-09-27 用户实测报的"糊 + 锯齿"就是这个）。带 mipmap 后由 GPU 按 mip 层采样 ⇒ 干净。
	#   绘制方还要把 `texture_filter` 设成 `TEXTURE_FILTER_LINEAR_WITH_MIPMAPS`，否则 mipmap 不会被使用。
	if found != null:
		var img := found.get_image()
		if img != null:
			img.convert(Image.FORMAT_RGBA8)
			# ⚠️ 导入时如果烘了 mipmap，`get_image()` 会把 mip 链一起带出来 ⇒ ① 数据长度不止 w*h*4
			#   ② `has_mipmaps()` 为真会让下面的 `generate_mipmaps()` 被跳过（用的是"改之前"那套 mip）。
			#   所以要**先清掉**，处理完再重新生成。
			if img.has_mipmaps():
				img.clear_mipmaps()
			var w := img.get_width()
			var h := img.get_height()
			if maxi(w, h) > HERO_ART_MAX:
				var sc := float(HERO_ART_MAX) / float(maxi(w, h))
				img.resize(maxi(1, int(w * sc)), maxi(1, int(h * sc)), Image.INTERPOLATE_LANCZOS)
			if not img.has_mipmaps():
				img.generate_mipmaps()
			found = ImageTexture.create_from_image(img)
	_hero_art[display_name] = found
	return found

func _load_tex_any(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		var t := load(path) as Texture2D
		if t != null:
			return t
	var abs_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(abs_path):
		var img := Image.new()
		if img.load(abs_path) == OK:
			return ImageTexture.create_from_image(img)
	return null

# 数字/名字加粗：主题无粗体字体，用带中文的系统字体 + FontVariation 合成加粗（跨平台回退列表）
func stat_bold_font() -> FontVariation:
	if _stat_bold_font == null:
		var sys := SystemFont.new()
		sys.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", "Source Han Sans SC", "sans-serif"])
		_stat_bold_font = FontVariation.new()
		_stat_bold_font.base_font = sys
		_stat_bold_font.variation_embolden = 0.9
	return _stat_bold_font

# 图标纹理最长边上限（卡/棋子上最多画到 ~96px ⇒ 160 已 1.7 倍余量；原图 384² 纯属浪费）
const ICON_MAX := 160

# 把不透明像素的颜色**铺满**透明区（多源 BFS，O(N) 一趟）。
# 为什么要做：mipmap 是"缩小采样"，透明区若还是抠掉前的底色，就会把那个颜色混进边缘
#   （白底 ⇒ 白边白雾；黑底 ⇒ 黑边）。铺满后任何 mip 层取到的都是图标自己的颜色。
# 用 `get_data()` 的原始字节做，比逐像素 get_pixel/set_pixel 快很多；alpha 不动，只改 RGB。
func _fill_alpha_color(img: Image, w: int, h: int) -> void:
	if w <= 0 or h <= 0:
		return
	var data := img.get_data()
	var n := w * h
	if data.size() < n * 4:
		return
	var seen := PackedByteArray()
	seen.resize(n)
	var queue := PackedInt32Array()
	queue.resize(n)
	var qh := 0
	for i in n:
		if data[i * 4 + 3] > 0:
			seen[i] = 1
			queue[qh] = i
			qh += 1
	if qh == 0 or qh == n:
		return   # 全透明（没东西可铺）或全不透明（没什么要铺）
	var qt := 0
	while qt < qh:
		var idx := queue[qt]
		qt += 1
		var x := idx % w
		var o := idx * 4
		for d in 4:
			var nx := x + (1 if d == 0 else (-1 if d == 1 else 0))
			var ny := (idx / w) + (1 if d == 2 else (-1 if d == 3 else 0))
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			var nidx := ny * w + nx
			if seen[nidx] == 1:
				continue
			var no := nidx * 4
			data[no] = data[o]
			data[no + 1] = data[o + 1]
			data[no + 2] = data[o + 2]
			seen[nidx] = 1
			queue[qh] = nidx
			qh += 1
	img.set_data(w, h, false, Image.FORMAT_RGBA8, data)

func stat_icon(path: String) -> Dictionary:
	if _stat_icons.has(path):
		return _stat_icons[path]
	var res := { "tex": null, "w": 0, "h": 0, "cx": 0, "cy": 0 }
	var tex := load(path) as Texture2D
	if tex != null:
		var img := tex.get_image()
		if img != null:
			img.convert(Image.FORMAT_RGBA8)
			# ⚠️ 同上：导入烘的 mip 链会被 `get_image()` 带出来 ⇒ 先清掉，铺完色再重新生成
			#   （否则 `_fill_alpha_color` 里的 `set_data` 会因长度不符报错、整个铺色静默失效）。
			if img.has_mipmaps():
				img.clear_mipmaps()
			var w := img.get_width()
			var h := img.get_height()
			var minx := w
			var miny := h
			var maxx := -1
			var maxy := -1
			for y in h:
				for x in w:
					var c := img.get_pixel(x, y)
					if c.r > 0.90 and c.g > 0.86 and c.b > 0.82:
						img.set_pixel(x, y, Color(0, 0, 0, 0))
					elif c.a > 0.5:
						if x < minx:
							minx = x
						if x > maxx:
							maxx = x
						if y < miny:
							miny = y
						if y > maxy:
							maxy = y
			# 【2026-09-27·用户报"素材糊"+"图标有白底"】这里要连做三件事，顺序不能反：
			#   ① 缩到 ICON_MAX：图标在卡/棋子上最多画到 96px，而原图 384²（6~12 倍缩小）⇒ 缩小采样
			#      只抽到一小撮像素 = 又糊又锯；缩到 160 后 mip 层只需 1 层，也顺带把 ② 的开销降到 1/9。
			#   ② 把不透明像素的**颜色铺满透明区**（多源 BFS）：抠掉的白底像素 RGB 还是白的，
			#      直接生成 mipmap 会把白色混进图标边缘 ⇒ 卡上出现白边/白雾（用户看到的就是这个）。
			#      注意**不能用 `Image.fix_alpha_edges()`**：它只往外渗 1~2 像素，盖不住。
			#   ③ `generate_mipmaps()`：之后由 GPU 按 mip 层采样（还需纹理过滤开 mipmap，
			#      项目默认已设成 LinearWithMipmaps，见 project.godot）。
			var k := 1.0
			if maxi(w, h) > ICON_MAX:
				k = float(ICON_MAX) / float(maxi(w, h))
				img.resize(maxi(1, int(w * k)), maxi(1, int(h * k)), Image.INTERPOLATE_LANCZOS)
			_fill_alpha_color(img, img.get_width(), img.get_height())
			if not img.has_mipmaps():
				img.generate_mipmaps()
			res.tex = ImageTexture.create_from_image(img)
			if maxx >= minx and maxy >= miny:
				res.w = int((maxx - minx + 1) * k)
				res.h = int((maxy - miny + 1) * k)
				res.cx = (minx + maxx) / 2.0 * k
				res.cy = (miny + maxy) / 2.0 * k
		else:
			res.tex = tex
			res.w = tex.get_width()
			res.h = tex.get_height()
	_stat_icons[path] = res
	return res

# 词条 -> 中文解释（供选人/属性/工具提示共用）
func keyword_lines(skills: Array, attack_type: int) -> Array:
	var out: Array = []
	if attack_type == AttackType.RANGED:
		out.append("远程：射程为2，身边紧邻敌人时射程降为1、攻击降为1且技能效果失效")
	for s in skills:
		match s:
			Skill.SWIFT:
				out.append("疾行：移动力+1")
			Skill.TAUNT:
				out.append("嘲讽：攻击范围内有带【嘲讽】的敌人时，只能先攻击它")
			Skill.INFILTRATE:
				out.append("渗透：可穿过双方单位与障碍物（但不能落停在它们占据的格）")
			Skill.LOGISTICS:
				out.append("后勤：不能主动攻击，仅提供光环/支援效果")
			Skill.BENCH:
				out.append("替补：替补登场时触发一次技能效果")
	return out

# 技能/词条“自身标签”的中文短名（名字行挂的 [疾行 嘲讽 …]）
func hero_tag_text(def: HeroDef) -> String:
	var out := ""
	for s in def.skills:
		match s:
			Skill.TAUNT:
				out += "嘲讽 "
			Skill.SWIFT:
				out += "疾行 "
			Skill.INFILTRATE:
				out += "渗透 "
			Skill.LOGISTICS:
				out += "后勤 "
			Skill.BENCH:
				out += "替补 "
	if out != "":
		out = out.strip_edges()
	return out

# 技能原文里的“自身标签”只用于识别，展示前剔除：
# 最后一个“。”之后的 <远程>/<疾行>/<嘲讽>/<渗透>/<后勤>/<替补> 是本角色的关键词；
# 正文里出现的（如“目标有<嘲讽>”）是对他人关键词的引用，予以保留。
# <替补>：效果…… 的“<替补>：”前缀也一并去掉。
func clean_skill_desc(raw: String) -> String:
	if raw == "":
		return ""
	var dot := raw.rfind("。")
	var body := ""
	var tail := ""
	if dot >= 0:
		body = raw.substr(0, dot + 1)
		tail = raw.substr(dot + 1)
	else:
		# 只有标签没有技能正文（如“<远程>”），直接整段当尾部处理
		tail = raw
	# 尾部标签区里的自身关键词剔除（含整段只有标签的情况）
	for tag in ["<远程>", "<嘲讽>", "<疾行>", "<渗透>", "<后勤>", "<替补>"]:
		tail = tail.replace(tag, "")
	# <替补>：效果…… 的“<替补>：”前缀去掉
	if body.begins_with("<替补>"):
		body = body.trim_prefix("<替补>")
		body = body.trim_prefix("：")
		body = body.trim_prefix(":")
	var out := (body + tail).strip_edges()
	return out.replace("  ", " ")

# 技能正文中以 [方括号] 出现的状态词（对目标施加的减益/增益）-> 中文解释行。
# 与 keyword_lines 的"英雄自身关键词"互补：状态词是效果对象，不是英雄自带标签。
const STATUS_DESC := {
	"猛毒": "任一回合开始时受1点伤害（圣盾可抵挡一次该伤害）",
	"重伤": "受到的伤害+1（目标方回合结束时解除）",
	"麻痹": "攻击力-1（目标方回合结束时解除）",
	"冰冻": "移动力-1（目标方回合结束时解除）",
	"沉默": "无法主动使用技能（目标方回合结束时解除）",
	"眩晕": "无法移动与攻击（目标方回合结束时解除）",
	"圣盾": "可抵挡一次受到的伤害",
	"附体": "与施加者伤害绑定。施加者受到伤害时，目标受到同等伤害；目标方回合结束时解除（负墟免疫）",
	"坚固": "受到攻击的伤害-1（对方回合结束时解除）",
	"荆棘": "无法移动（对方回合结束时解除）",
	# 【2026-09-26 用户要求】风语者的光环单开状态 <风语>（`StatusDB.WIND`，牌面金字「风」）：
	#   角色列表里风语者的技能描述已改成「风语者在场时，所有其他队友获得[风语]」⇒ 这里补上解释行，
	#   属性框（`HUD._status_explain_lines`）与技能正文的 [方括号] 解释（`desc_status_lines`）都读它。
	"风语": "移动力+1，且移动后回复等同于本次移动距离的HP（风语者在场时赋予其他队友）",
}

# 从技能原文提取方括号状态词的解释行（按出现顺序、去重；未收录的词忽略）。
func desc_status_lines(raw: String) -> Array:
	var out: Array = []
	var text := clean_skill_desc(raw)
	var i := 0
	while i < text.length():
		var a := text.find("[", i)
		if a < 0:
			break
		var b := text.find("]", a + 1)
		if b < 0:
			break
		var status_word := text.substr(a + 1, b - a - 1)
		if STATUS_DESC.has(status_word):
			var line := "%s：%s" % [status_word, STATUS_DESC[status_word]]
			if not out.has(line):
				out.append(line)
		i = b + 1
	return out

# 实际开局数值：注册表基础值 + 生成期加成（引擎在单位出生时叠加，属性表按实际值展示）。
# 疾行：移动+1；大骑士（hero_24 冲锋）：移动+6；血锁（hero_41 直线锁链）：射程+2。
func spawn_move(def: HeroDef) -> int:
	var m := def.move_range
	if def.skills.has(Skill.SWIFT):
		m += 1
	if def.id == "hero_24":
		m += 6
	return m

func spawn_attack_range(def: HeroDef) -> int:
	var r := def.attack_range
	if def.id == "hero_41":
		r += 2
	if def.id == "hero_45":
		r = 99   # 坠炮手：全场任意目标（弹道无视阻挡由 Unit/Battle 处理）
	return r

# 属性表内容分“显示区”：①名字+近/远程+词条标签 ②基础属性 ③“技能”+技能描述 ④词条解释。
# 各区由弹框负责用贴左短线分行；本函数只负责产出各区文本。
func hero_info_zones(def: HeroDef) -> Array[String]:
	var atk_type := "近战" if def.attack_type == AttackType.MELEE else "远程"
	var head := "%s  %s" % [def.display_name, atk_type]
	var tags := hero_tag_text(def)
	if tags != "":
		head += "　[%s]" % tags
	var zones: Array[String] = []
	zones.append(head)
	# 大骑士移动＝直线冲锋任意距离，按"无限"展示（实际可沿直线冲满棋盘）
	var move_txt := "移动 %d" % spawn_move(def)
	if def.id == "hero_24":
		move_txt = "移动 ∞"
	# 坠炮手射程=全场，按"∞"展示
	var range_n := spawn_attack_range(def)
	var range_txt := "射程 ∞" if def.id == "hero_45" else "射程 %d" % range_n
	zones.append("HP %d　攻击 %d　%s　%s" % [
		def.max_hp, def.atk, move_txt, range_txt])
	var desc := clean_skill_desc(def.desc)
	if desc != "":
		zones.append("技能\n%s" % desc)
	# 词条解释 = 自身关键词 + 技能正文里 [方括号] 状态词的解释（沉默/重伤/猛毒…）
	var lines := keyword_lines(def.skills, def.attack_type)
	lines.append_array(desc_status_lines(def.desc))
	if lines.size() > 0:
		zones.append("\n".join(lines))
	return zones
