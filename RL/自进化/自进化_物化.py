"""自进化 · 物化器：把"基因组"（相对 噩梦.json 的 theta 覆盖）写成游戏实际读的
`RL/自进化/权重.json`。删掉那一份 ⇒ 难度 5 自动退回 噩梦1 ⇒ 再退回 噩梦。
用法: python RL\\自进化\\自进化_物化.py
"""
import io, json, os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
BASE = r"RL/weights/噩梦.json"
GEN = r"RL/自进化/基因组.json"
OUT = r"RL/自进化/权重.json"
base = json.load(io.open(BASE, encoding="utf-8-sig"))
ov = {}
if os.path.exists(GEN):
    ov = {k: v for k, v in (json.load(io.open(GEN, encoding="utf-8-sig")).get("overlay", {}) or {}).items() if not k.startswith("_")}
before = len(base)
base.update({k: v for k, v in ov.items() if not k.startswith("_")})
# 【2026-10-03·必须带这个键】本档的 AI 是 fork 的**子类**（`RL/自进化/AI.gd` 用
#   `extends "res://RL/ai/AI_Battle.gd"` 继承），**不是 fork 本身**；而走查台（`RL/harness/对局.gd`）
#   恒用 `preload(FORK)` 建 AI ⇒ 它只认权重文件里这个**可选键**来决定"这一侧用哪个脚本"。
#   没有它，跑批里"难度5 打 难度3"量到的其实是 fork + 这份权重 —— 与生产（难度5 走我的子类）
#   不是同一个 AI；而且录制（`search()` 重写）也不会被调用 ⇒ 采数据批会静默采到 0 条。
AI_SCRIPT = "res://RL/自进化/AI.gd"
base["_ai_script"] = AI_SCRIPT
base["_2026-10-03 _ai_script（跑批必须加载我的子类，不是 fork）"] = (
    "值 = `res://RL/自进化/AI.gd`。用途：走查台 `RL/harness/对局.gd::_ai_script_path()` 读它决定本侧用哪个 AI 脚本"
    "（缺省 = A 方 fork / B 方原版副本），`R|cfg|` 行会打出 `aiA=/aiB=/aiA_sha=/aiB_sha=` 作证据。"
    "删掉本键 ⇒ 跑批退回 fork（= 只验权重、不验我的机制）；删掉 `RL/自进化/AI.gd` 本身 ⇒ 该键失效、同样退回 fork，"
    "生产端（难度5）也退回 fork —— 两者都不影响其它档。")
base["_2026-10-02 晚·档位 5「自进化」"] = (
    "AI 自己逐轮进化出来的权重（基因组 = RL/自进化/基因组.json；账本 = RL/自进化/账本.jsonl）。"
    "删掉本文件 ⇒ 难度 5 自动退回 噩梦1.json ⇒ 再退回 噩梦.json（不影响任何其它档）。")
io.open(OUT, "w", encoding="utf-8").write(json.dumps(base, ensure_ascii=False, indent=1))
print(f"物化完成：{before} → {len(base)} 键；覆盖 {len(ov)} 项：{list(ov.keys())}")


