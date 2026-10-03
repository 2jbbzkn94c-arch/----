# 自进化 · 点子生成器（AI 自己出主意的那一半）。
# 输入：当前冠军的"基因组"（= 相对 噩梦.json 的 theta 覆盖），输出：本轮要试的若干候选（含对照）。
# 三类点子（全部可复现、可审计）：
#   ① 单键剂量：在现役值上下各走一步（步长 = 该键的量纲尺度 × STEP）
#   ② 组合扰动：随机抽 2~4 个键同向/反向各走一步（交互项 —— 单键剂量在本引擎上几乎全落噪声，
#      所以进化必须能试"多键一起动"）
#   ③ 机制开关：把"引擎默认关、只在权重文件里开"的那些机制键翻面（0↔1）
#   ④ 我自己的机制键（`ADAPT_*` / `TRAP_*`）：它们只在 `RL/自进化/AI.gd` 里解析，`src/BattleAI.gd` 一个都没有
#      ⇒ 同样"引擎默认关、只在权重文件里开"，也该由我自己试（见下面的 SCALE/TOGGLES 增补）。
#      ⚠️ `LEARNED_EVAL` **不放进开关表**：它单开没有意义（还得同时给 `LEARNED_COEF` = 系数文件路径），
#         单翻它会让评估恒 = 0（学出来的东西一个都没加载）—— 那条线由"采数据批 → 拟合 → 系数"单独管。
# 用法: python RL\自进化\自进化_点子.py --genome RL\自进化\基因组.json --k 3 --seed 12345
import io, json, os, random, sys, collections

# 可被进化的键 + 它们的量纲尺度（步长 = 尺度 × STEP）。只列"数字型、引擎已接受"的键。
SCALE = {
    "HP_VALUE_W": 0.5, "FOCUS_FIRE_WEIGHT": 15.0, "THREAT_MOVE_DISCOUNT": 0.15,
    "BUFF_TAKE_WEIGHT": 1.0, "ENGAGE_PULL_PER_CELL": 0.6,
    "MOVE_ACCEPT_DAMAGE": 2.0, "MOVE_ACCEPT_ENGAGED": 4.0, "INCOMING_POOL_W": 0.5,
    "RISK_W": 1.5, "RISK_CORE_POW": 0.5, "RISK_CORE_OUTPUT_W": 0.25,
    "FORM_COHESION_W": 2.5, "FORM_SPREAD_CELL_W": 1.5, "FORM_ESCAPE_W": 1.0,
    "SPLIT_W": 1.0, "EXPOSURE_TOTAL_W": 1.0, "EXPOSURE_HP_MAX": 3.0,
    "AOE_RIDER_TOTAL_W": 1.0, "TAUNT_SOAK_W": 0.5, "SHIELD_BREAK_W": 2.0,
    "BUFF_DENY_W": 0.5, "PULL_OPEN_W": 0.6, "PULL_ISOLATE_W": 1.0,
    "HEAL_CREDIT_W": 0.5, "IDLE_HIT_PENALTY": 1.0, "TERMINAL_W": 0.15,
    # 【2026-10-03 增补·我自己的机制键】只在 `RL/自进化/AI.gd` 里解析（引擎 0 处）⇒ 现役值 = 代码默认 0。
    "TRAP_W": 1.0,
}
# 机制开关键（0/1 翻面）
TOGGLES = ["FORM_ROLE_GATE", "FORM_ESCAPE_RANGED_ONLY", "FORM_ESCAPE_ESCAPABLE",
           "TWO_PHASE_DEDUP", "TWO_PHASE_P2_DEDUP", "SUMMON_SLOT_ONLY", "TWO_PHASE_POLISH",
           "PROMISE_REPAIR", "MOVE_ACCEPT_POOL",
           # 我自己的开关（默认 0 = 关；见 `AI.gd` 的 set_weights 重写）
           "ADAPT_PROFILE", "TRAP_FREE_TARGET"]
# 现役值（= 噩梦.json 里的值；不在表里 = 吃引擎默认）——用作剂量基准
# ⚠️ 【2026-10-03 修·自查出的 bug】`HP_VALUE_W` / `FOCUS_FIRE_WEIGHT` / `THREAT_MOVE_DISCOUNT` 这三个
#   **没写进 噩梦.json**（吃引擎 const 默认 1.0 / 30 / 0.7），而本表原来也没收录 ⇒
#   `BASE.get(key, 0.0)` 返回 **0** ⇒ 剂量变成"从 0 起算"（实测：`HP_VALUE_W 0 → 0.5` 其实是**砍半**，
#   而砍半已被配对批测成**显著有害**）。⇒ 两处一起修：① 补齐这三个键的真实默认；② 加守卫 `_cur()`：
#   **键既不在基因组、也不在本表 ⇒ 跳过**（宁可不提案，也不提一个基于 0 的错案）。
BASE = {
    "HP_VALUE_W": 1.0, "FOCUS_FIRE_WEIGHT": 30.0, "THREAT_MOVE_DISCOUNT": 0.7,
    "MOVE_ACCEPT_DAMAGE": 4, "MOVE_ACCEPT_ENGAGED": 8, "INCOMING_POOL_W": 1.0,
    "RISK_W": 3.0, "RISK_CORE_POW": 1.0, "RISK_CORE_OUTPUT_W": 0.5,
    "FORM_COHESION_W": 5.0, "FORM_SPREAD_CELL_W": 3.0, "FORM_ESCAPE_W": 2.0,
    "SPLIT_W": 2.0, "EXPOSURE_TOTAL_W": 2.0, "EXPOSURE_HP_MAX": 15,
    "AOE_RIDER_TOTAL_W": 2.0, "TAUNT_SOAK_W": 0.75, "SHIELD_BREAK_W": 4.0,
    "BUFF_DENY_W": 1.0, "PULL_OPEN_W": 1.2, "PULL_ISOLATE_W": 2.0,
    "HEAL_CREDIT_W": 1.0, "IDLE_HIT_PENALTY": 2.0, "TERMINAL_W": 0.25,
    "BUFF_TAKE_WEIGHT": 2.0, "ENGAGE_PULL_PER_CELL": 1.2, "TWO_PHASE_DEDUP": 1,
    "TWO_PHASE_P2_DEDUP": 1, "SUMMON_SLOT_ONLY": 1,
    # 【2026-10-03 增补】我自己的机制键没有"引擎默认"以外的历史值 ⇒ 现役 = 代码默认 0（关）。
    "ADAPT_PROFILE": 0, "TRAP_W": 0.0, "TRAP_FREE_TARGET": 0,
}


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--genome", default=r"RL\自进化\基因组.json")
    ap.add_argument("--k", type=int, default=3)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--step", type=float, default=1.0)
    ap.add_argument("--out", default=r".dsh\tmp\自进化_本轮.json")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    champ = {}
    if os.path.exists(a.genome):
        champ = {k: v for k, v in (json.load(io.open(a.genome, encoding="utf-8-sig")).get("overlay", {}) or {}).items() if not k.startswith("_")}
    # 守卫：任何"既不在基因组、也不在 BASE"的键 ⇒ 解析出来会是 0 ⇒ 直接跳过并告警
    unknown = [k for k in sorted(SCALE) if k not in champ and k not in BASE]
    if unknown:
        print("⚠️ 以下键没有现役基准（既不在基因组也不在 BASE），本轮跳过，避免'从 0 起算'的错案：", unknown)
    for k in list(SCALE):
        if k in unknown:
            SCALE.pop(k)

    cands = []
    # ① 单键剂量（上下各一步）
    for key in sorted(SCALE):
        cur = float(champ.get(key, BASE.get(key, 0.0)))
        step = SCALE[key] * a.step
        for delta in (step, -step):
            v = cur + delta
            if v < 0:
                continue
            if key in ("TWO_PHASE_DEDUP",) and v not in (0, 1):
                continue
            th = dict(champ)
            th[key] = round(v, 4)
            cands.append({"kind": "单键", "theta": th, "why": "%s %.3g → %.3g" % (key, cur, v)})
    # ② 组合扰动（2~4 键一起动）
    keys = sorted(SCALE)
    for _ in range(max(6, a.k * 3)):
        pick = rng.sample(keys, rng.choice([2, 3, 4]))
        th = dict(champ)
        why = []
        for key in pick:
            cur = float(champ.get(key, BASE.get(key, 0.0)))
            step = SCALE[key] * a.step * rng.choice([1.0, 1.0, 2.0])
            v = max(0.0, cur + (step if rng.random() < 0.5 else -step))
            th[key] = round(v, 4)
            why.append("%s→%.3g" % (key, v))
        cands.append({"kind": "组合", "theta": th, "why": " · ".join(why)})
    # ③ 机制开关翻面
    for key in TOGGLES:
        cur = float(champ.get(key, BASE.get(key, 0.0)))
        th = dict(champ)
        th[key] = 0 if cur else 1
        cands.append({"kind": "开关", "theta": th, "why": "%s %g → %g" % (key, cur, th[key])})

    rng.shuffle(cands)
    out = {"control": champ, "candidates": cands[: max(1, a.k)], "total_ideas": len(cands), "seed": a.seed}
    io.open(a.out, "w", encoding="utf-8").write(json.dumps(out, ensure_ascii=False, indent=1))
    print(f"本轮候选 {len(out['candidates'])}/{len(cands)}（种子 {a.seed}）→ {a.out}")
    for i, c in enumerate(out["candidates"]):
        print(f"  c{i}: [{c['kind']}] {c['why']}")


if __name__ == "__main__":
    main()


