"""自进化 · 通用采纳器（把"配对批里赢了的那个臂"写进基因组 = 这一轮的进化落地）。

与 `采纳系数.py` 的分工：那个只管"学出来的评估"那对键（`LEARNED_EVAL`/`LEARNED_COEF`，还要复查留出增益）；
本脚本管**任意臂**：`--plan <计划.json> --arm c1`，把该臂的 `theta` 整体写进 `基因组.json` 的 `overlay`
（`_` 开头的说明性键保留旧的、数值键换成该臂的）⇒ 再跑物化就是新冠军。
**只在配对批判定通过后才用它**（判据：配对 Δpts 的 95% CI 不含 0 且为正 —— 见 `自进化_判定.py`）。

用法：
  python RL\\自进化\\采纳臂.py --plan .dsh\\tmp\\ab.json --arm c1            # 只看会写什么（不落盘）
  python RL\\自进化\\采纳臂.py --plan .dsh\\tmp\\ab.json --arm c1 --commit   # 真写（账本记一行）
"""
import io, os, sys, json, argparse, hashlib, datetime

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
GEN = r"RL/自进化/基因组.json"
LEDGER = r"RL/自进化/账本.jsonl"
WEIGHTS = r"RL/自进化/权重.json"


def sha12(p):
    return hashlib.sha256(io.open(p, "rb").read()).hexdigest()[:12] if os.path.exists(p) else "-"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--arm", required=True, help="ctl / c0 / c1 …")
    ap.add_argument("--genome", default=GEN)
    ap.add_argument("--commit", action="store_true")
    a = ap.parse_args()
    real = (os.path.normpath(a.genome) == os.path.normpath(GEN))

    plan = json.load(io.open(a.plan, encoding="utf-8-sig"))
    if a.arm == "ctl":
        th = plan["control"]
    else:
        th = plan["candidates"][int(a.arm[1:])]["theta"]
    th = {k: v for k, v in (th or {}).items() if not str(k).startswith("_")}

    g = json.load(io.open(a.genome, encoding="utf-8-sig"))
    old = dict(g.get("overlay", {}) or {})
    notes = {k: v for k, v in old.items() if str(k).startswith("_")}
    new = dict(notes)
    new.update(th)
    oldnum = {k: v for k, v in old.items() if not str(k).startswith("_")}

    print(f"臂 {a.arm} 的覆盖 {len(th)} 项；基因组现在 {len(oldnum)} 项")
    add = [k for k in th if k not in oldnum or oldnum[k] != th[k]]
    gone = [k for k in oldnum if k not in th]
    print("  改动：" + (", ".join(f"{k}={th[k]}" for k in add) if add else "(无)"))
    print("  移除：" + (", ".join(gone) if gone else "(无)"))
    if not a.commit:
        print("（没带 --commit ⇒ 只打印，不落盘）")
        return
    g["overlay"] = new
    g["accepted"] = "配对批采纳：" + a.arm
    g["last_run"] = "第二轮"
    io.open(a.genome, "w", encoding="utf-8").write(json.dumps(g, ensure_ascii=False, indent=1))
    print(f"✅ 已写进基因组 {a.genome}；下一步 python RL\\自进化\\自进化_物化.py")
    if real:
        row = {"round": "第二轮", "kind": "采纳臂", "arm": a.arm, "added": add, "removed": gone,
               "plan": a.plan, "genome_sha12": sha12(GEN), "champion_sha12_before": sha12(WEIGHTS),
               "when": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")}
        with io.open(LEDGER, "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
