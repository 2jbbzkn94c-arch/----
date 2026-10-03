"""自进化 · 采纳系数（把学出来的评估接进档位 5 的那一步，也是唯一的开关）。

为什么单独一个脚本：`LEARNED_EVAL=1` 是把**整段评分函数**换成 `_bias + Σ 系数×特征`（见 `AI.gd::_learned_score`），
所以它必须像别的机制一样走"**配对批 + CI 判定**"才能采纳，而不是拟合完就直接生效。三种用法：

  ① 出 A/B 计划（不改进化状态）：   python RL\\自进化\\采纳系数.py --plan .dsh\\tmp\\学系数_ab.json
     ⇒ 写一份两臂计划：`ctl` = 当前冠军（基因组原样）· `cand` = 冠军 + {LEARNED_EVAL:1, LEARNED_COEF:系数}
     然后照常跑：`自进化_spec.py` → `Train.ps1 -Task gen/run` → `自进化_判定.py --control ctl --arms cand`
  ② 判定通过后采纳（改基因组 + 物化）：python RL\\自进化\\采纳系数.py --commit
     ⇒ 把两个键写进 `基因组.json` 并重跑物化 ⇒ 打印新的冠军权重 sha12（账本另记一行）
  ③ 回退（用户口径：不好用要能轻松删）：python RL\\自进化\\采纳系数.py --revert
     ⇒ 从基因组里摘掉那两个键并重新物化 ⇒ 难度 5 立刻回到"没接学出来的评估"的状态

⚠️ `--commit` **默认过闸才写**：要求 `系数.json` 的 `_meta.holdout_gain > --min-gain`（默认 0.03，
   与 `拟合.py` 同一把尺子）—— 拟合器没写文件就说明没过闸，这里再挡一次（防手滑 / 防旧文件）。
用法：python RL\\自进化\\采纳系数.py [--coef 系数.json] [--min-gain 0.03] [--commit | --revert | --plan 路径] [--force]
"""
import io, os, sys, json, argparse, hashlib, datetime

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
GEN = r"RL/自进化/基因组.json"
COEF_DEFAULT = r"RL/自进化/系数.json"
COEF_RES = "res://RL/自进化/系数.json"
KEYS = ("LEARNED_EVAL", "LEARNED_COEF")


def sha12(p):
    if not os.path.exists(p):
        return "-"
    return hashlib.sha256(io.open(p, "rb").read()).hexdigest()[:12]


def load_json(p):
    return json.load(io.open(p, encoding="utf-8-sig")) if os.path.exists(p) else {}


def read_genome(path):
    g = load_json(path)
    ov = {k: v for k, v in (g.get("overlay", {}) or {}).items()}
    return g, ov


def write_genome(path, g, ov, note):
    g["overlay"] = ov
    g["accepted"] = note
    g["last_run"] = "learned_eval"
    io.open(path, "w", encoding="utf-8").write(json.dumps(g, ensure_ascii=False, indent=1))


def ledger(row):
    row["when"] = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    with io.open(r"RL/自进化/账本.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--coef", default=COEF_DEFAULT)
    ap.add_argument("--genome", default=GEN, help="默认就是真基因组；指向副本时**不写账本**（用于自检/实验）")
    ap.add_argument("--min-gain", type=float, default=0.03)
    ap.add_argument("--plan", default="")
    ap.add_argument("--commit", action="store_true")
    ap.add_argument("--revert", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--materialize", action="store_true", help="改完基因组后重跑物化")
    a = ap.parse_args()
    real = (os.path.normpath(a.genome) == os.path.normpath(GEN))

    g, ov = read_genome(a.genome)
    print(f"基因组 = {a.genome}（覆盖 {len([k for k in ov if not k.startswith('_')])} 项）"
          f"{'' if real else ' ⚠️ 副本 ⇒ 不写账本'}")
    cur = {k: ov.get(k, "-") for k in KEYS}
    print(f"当前学系数状态：LEARNED_EVAL={cur['LEARNED_EVAL']} · LEARNED_COEF={cur['LEARNED_COEF']}")

    if a.plan:
        coef = load_json(a.coef)
        if not coef:
            print(f"❌ 找不到系数文件 {a.coef}（拟合器没过闸时不会写它）")
            sys.exit(2)
        # ⚠️【2026-10-03 预检抓到的坑】`theta` 里**不能带说明性键**（基因组里的 `_起点说明` 那种）：
        #   训练器会 `FATAL: theta key not accepted by AI_Battle.set_weights: _起点说明` 整批拒收
        #   （`自进化_点子.py` 读基因组时已经滤掉 `_` 开头的键，这里必须同样滤 —— 否则第④步在采完
        #   70 分钟数据之后才崩）。
        base_th = {k: v for k, v in ov.items() if not str(k).startswith("_")}
        cand = dict(base_th)
        cand["LEARNED_EVAL"] = 1
        cand["LEARNED_COEF"] = COEF_RES
        plan = {"control": base_th, "candidates": [{"kind": "学系数", "theta": cand,
                "why": "LEARNED_EVAL=1 + LEARNED_COEF=%s（留出增益 %s）" % (COEF_RES, coef.get("_meta", {}).get("holdout_gain", "?"))}],
                "_readme": "自进化 · 学出来的评估 A/B（对照 = 当前冠军）"}
        io.open(a.plan, "w", encoding="utf-8").write(json.dumps(plan, ensure_ascii=False, indent=1))
        print(f"→ 两臂计划已写 {a.plan}（ctl = 冠军 · c0 = 冠军 + 学系数；theta 共 {len(base_th)} 个真键）")
        print("  跑法：python RL\\自进化\\自进化_spec.py %s RL\\自进化\\spec_学系数.json" % a.plan)
        print("        powershell -File RL\\train\\Train.ps1 -Task gen -Run evo_ll_r1 -Spec RL\\自进化\\spec_学系数.json -Configs ctl,c0")
        print("        powershell -File RL\\train\\Train.ps1 -Task run -Run evo_ll_r1 -Spec ... -Configs ctl,c0 -SeedSet train -MaxSeeds 32 -Firsts e,p -Asides e,p -Workers 12")
        print("        python RL\\自进化\\自进化_判定.py --run evo_ll_r1 --control ctl --arms c0")
        return

    if a.revert:
        for k in KEYS:
            ov.pop(k, None)
        write_genome(a.genome, g, ov, "回退：摘掉学出来的评估（LEARNED_EVAL/LEARNED_COEF）")
        print("✅ 已从基因组摘掉 LEARNED_EVAL/LEARNED_COEF")
        if a.materialize:
            print("   下一步：python RL\\自进化\\自进化_物化.py")
        if real:
            ledger({"round": "采纳系数", "kind": "回退", "removed": list(KEYS),
                    "champion_sha12": sha12(r"RL/自进化/权重.json"), "genome_sha12": sha12(GEN)})
        return

    if a.commit:
        coef = load_json(a.coef)
        if not coef:
            print(f"❌ 找不到系数文件 {a.coef}（拟合器没过闸时不会写它）⇒ 不采纳")
            sys.exit(2)
        meta = coef.get("_meta", {})
        gain = float(meta.get("holdout_gain", -9))
        acc, base = meta.get("holdout_acc", "?"), meta.get("holdout_base", "?")
        print(f"系数元数据：留出集 {acc} vs 基线 {base} ⇒ 增益 {gain:+.4f}（要求 > {a.min_gain}）· 局数 {meta.get('games','?')} · 特征 {meta.get('features','?')}")
        if gain <= a.min_gain and not a.force:
            print("❌ 增益不达标 ⇒ 不采纳（--force 可强行写，但那就不是'过闸'了）")
            sys.exit(2)
        ov["LEARNED_EVAL"] = 1
        ov["LEARNED_COEF"] = COEF_RES
        write_genome(a.genome, g, ov, "学出来的评估（留出增益 %+.4f · %s 局）" % (gain, meta.get("games", "?")))
        print("✅ 已写进基因组：LEARNED_EVAL=1 · LEARNED_COEF=%s" % COEF_RES)
        if a.materialize:
            print("   下一步：python RL\\自进化\\自进化_物化.py")
        if real:
            ledger({"round": "采纳系数", "kind": "采纳", "coef": a.coef, "meta": meta,
                    "champion_sha12": sha12(r"RL/自进化/权重.json"), "genome_sha12": sha12(GEN)})
        return

    print("（没有 --plan / --commit / --revert ⇒ 只打印现状，什么都没改）")


if __name__ == "__main__":
    main()
