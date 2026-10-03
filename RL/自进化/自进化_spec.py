"""自进化 · spec 生成器：克隆一份现成 spec（保留 lineups/params/measurement 等全部协议块），
只替换 `_readme` 与 `configs`。用法: python RL\\自进化\\自进化_spec.py <plan.json> <out_spec.json>

【2026-10-03 改·每臂自带完整权重文件，不再用 theta】
  为什么必须改：训练器的 `theta` 只认它自己那份白名单（自动搜索键 / 规则键 / 钉住键）
  ⇒ 我自己的键（`LEARNED_EVAL` / `LEARNED_COEF` / `TRAP_W` / `ADAPT_*` …）一注入就整批拒收：
  `FATAL: RuntimeException :: theta key not accepted by AI_Battle.set_weights: LEARNED_EVAL`
  （实测；这也意味着本驱动器从前**从来没法**注入我的机制键）。
  改走哪条路：`Resolve-Configs` 支持每个 config 的 **`weights`** 字段 = **直接用一份现成的权重文件**
  （`if ($c.PSObject.Properties.Name -contains 'weights') { $wf = <那份文件> }`）⇒ 由本脚本自己把
  「冠军权重 + 本臂覆盖」物化成一份完整文件，我的键就写在文件里 —— 这正是我的 AI 读键的通道，
  **不需要改用户训练器的任何一行**（也修好了驱动器对机制键的 A/B）。
"""
import io, json, os, sys, collections
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
TEMPLATE = r"RL\train\spec_nm1_b5_200.json"
BASE_WEIGHTS = r"RL/自进化/权重.json"      # 冠军权重（难度 5 实际读的那一份）
ARM_DIR = r"RL/自进化/臂"

plan_path, out_path = sys.argv[1], sys.argv[2]
plan = json.load(io.open(plan_path, encoding="utf-8-sig"))
spec = json.load(io.open(TEMPLATE, encoding="utf-8-sig"), object_pairs_hook=collections.OrderedDict)
spec["_readme"] = plan.get("_readme", "自进化（档位 5）")
# 【2026-10-03·必须强制这两项】① 对手恒为**难度3**（`opp=cand` + `league.checkpoint=噩梦.json`；
#   写 `base` 是"原版脚本 + 常量" = 困难档，根本不读 噩梦.json）② base 指向我的权重文件。
spec["base_weights"] = BASE_WEIGHTS
spec["opponent"] = "cand"
spec["league"]["checkpoint"] = "RL/weights/噩梦.json"

base = json.load(io.open(BASE_WEIGHTS, encoding="utf-8-sig"))
tag = os.path.splitext(os.path.basename(plan_path))[0]
if not os.path.isdir(ARM_DIR):
    os.makedirs(ARM_DIR)


def materialize(arm):
    """冠军权重 + 本臂覆盖 ⇒ 一份完整权重文件（我的键就写在里面）。"""
    th = plan["control"] if arm == "ctl" else plan["candidates"][int(arm[1:])]["theta"]
    w = dict(base)
    for k, v in (th or {}).items():
        if str(k).startswith("_"):
            continue                      # 说明性键不进权重文件（只在基因组里当注释）
        w[k] = v
    p = os.path.join(ARM_DIR, f"{tag}_{arm}.json").replace("\\", "/")
    io.open(p, "w", encoding="utf-8").write(json.dumps(w, ensure_ascii=False, indent=1))
    return p


cfgs = [collections.OrderedDict([("name", "ctl"), ("note", "champion control"), ("weights", materialize("ctl"))])]
for i, c in enumerate(plan["candidates"]):
    cfgs.append(collections.OrderedDict([("name", f"c{i}"), ("note", c["why"]), ("weights", materialize(f"c{i}"))]))
spec["configs"] = cfgs
io.open(out_path, "w", encoding="utf-8").write(json.dumps(spec, ensure_ascii=False, indent=4))
print("spec →", out_path, "｜臂:", [(c["name"], c["weights"]) for c in cfgs])
