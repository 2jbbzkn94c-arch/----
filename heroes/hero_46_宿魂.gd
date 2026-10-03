extends HeroBase
## 宿魂（hero_46）：攻击后，令敌人获得[附体]——施加者(宿魂)受伤时，附体目标受到同等伤害。
## 附体不叠加；目标方回合结束时解除。绑定与镜像结算在 Battle._possess_attach/_possess_mirror。
class_name HeroSoul

func on_attack(target: Unit) -> void:
	if target == null or not target.alive:
		return
	# 【2026-09-30·用户口径「宿魂要"附体"」】`_possess_attach()` 现在回一个 bool（**真的挂上了才 true**）
	#   ⇒ 只有真挂上才弹「附体」（一点血都没打掉 / 被负墟免疫 / 打的是队友 —— 都不弹）。
	#   ⚠️【2026-10-01·口径反转】[圣盾]**不在**其列了：盾只挡伤害，带盾挨打照样[附体]。
	#   颜色与文案走 `HERO_FX["hero_46"]`（原来这条整条没登记 ⇒ 查表拿到白字空文案 = 什么都不弹）。
	if battle._possess_attach(unit, target):
		fx()

## 【2026-09-30·用户报「怎么宿魂打有圣盾的单位也能附体」】[附体] 是"命中附加的负面状态"
##   ⇒ 与毒蛇淑女[猛毒]/战锤麻痹/沉默术士同一类：认这一项，`Battle._apply_attack()` 才会在
##   "一点血都没打掉（[坚固]减到 0 等，不算打中）"时置 `Unit._shield_block_status`；
##   `Battle._possess_attach()` 读那个标记 ⇒ 那种情况下**不挂[附体]、不建魂线绑定**。
##   ⚠️【2026-10-01·用户口径「盾不能挡技能效果，只能挡伤害」+ 对齐原版】[圣盾] **已从这道门里摘掉**：
##   盾挡下伤害 ≠ 没打中 ⇒ 带盾单位照样被[附体]（盾只被消耗掉而已）。
##   （宿魂的普攻伤害本身仍由 Battle 结算：打盾时盾照旧被消耗掉。）
func applies_status_on_hit() -> bool:
	return true

## 【2026-10-03·用户「宿魂的附体伤害也没有击杀特效」】击杀预告：**我挨的这一下会镜像给谁**。
##   判据与 `Battle._possess_mirror()` 的结算**逐条同一把尺**：当前绑定到我身上、且**还活着**的
##   那些目标（`battle._possess_targets_of()` 就是那趟循环的纯查询版），伤害数 = 我实际掉的血
##   （调用方已按重伤/坚固/塔盾代扛算好），`atk = false`（镜像那句 `take_damage(dmg, false, false, "附体")`
##   用的是默认 `is_attack = false`）。
##   ⇒ `Battle._do_attack()` / `_play_counter()` 在开打前拿它播完这些人的击杀卡面，之后镜像才落地。
##   ⚠️ 纯查询：不改绑定表、不结算、不动随机源。
func mirror_hits_on_damage(amount: int) -> Array:
	var out: Array = []
	if amount <= 0 or unit == null or not is_instance_valid(unit):
		return out
	for t in battle._possess_targets_of(unit):
		out.append({ "v": t, "dmg": amount, "atk": false })
	return out
