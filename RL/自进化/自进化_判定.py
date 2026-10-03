"""自进化 · 单轮判定器。
输入：`--run <run>`（本轮所有臂都在这个 run 里，config 名 = 臂名）+ `--control <臂名>`；
输出（stdout 最后一行 JSON）：每个臂 vs 对照的配对 Δpts/CI/翻转，以及"该采纳哪个臂"。
判据（项目纪律）：**配对 Δpts 的 95% CI 不含 0** 才算"有差别"；只有点估 > 0 且 CI 不含 0 才采纳。
"""
import csv, glob, io, os, sys, json, math, collections, argparse
sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def load(run, cfg):
    root = os.path.join("RL/train/results", run)
    files = [os.path.join(root, "measure.csv")] + sorted(glob.glob(os.path.join(root, "w*", "measure.csv")))
    seen = {}
    for f in files:
        if not os.path.exists(f):
            continue
        with io.open(f, encoding="utf-8-sig", newline="") as fh:
            for r in csv.DictReader(fh):
                if (r.get("config") or "") != cfg:
                    continue
                seen.setdefault((r.get("seed"), r.get("first"), r.get("a_side")), r)
    return seen


def pts(r):
    try:
        return float(r.get("ptsA") or 0) - float(r.get("ptsB") or 0)
    except Exception:
        return 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--control", required=True)
    ap.add_argument("--arms", required=True, help="逗号分隔的臂名（不含对照）")
    ap.add_argument("--min-gain", type=float, default=0.0)
    a = ap.parse_args()

    ctl = load(a.run, a.control)
    out = {"run": a.run, "control": a.control, "n_control": len(ctl), "arms": {}, "winner": None}
    best = None
    for arm in [x for x in a.arms.split(",") if x.strip()]:
        d = load(a.run, arm)
        common = sorted(set(ctl) & set(d), key=lambda k: (str(k[0]), str(k[1]), str(k[2])))
        if len(common) < 40:
            out["arms"][arm] = {"n": len(common), "verdict": "样本不足"}
            continue
        diffs = [pts(d[k]) - pts(ctl[k]) for k in common]
        n = len(diffs)
        mean = sum(diffs) / n
        sd = math.sqrt(sum((x - mean) ** 2 for x in diffs) / (n - 1)) if n > 1 else 0.0
        se = sd / math.sqrt(n) if n else 0.0
        lo, hi = mean - 1.959963985 * se, mean + 1.959963985 * se
        w = sum(1 for x in diffs if x > 0)
        l = sum(1 for x in diffs if x < 0)
        rec = {"n": n, "d_pts": round(mean, 3), "ci": [round(lo, 3), round(hi, 3)],
               "sd": round(sd, 2), "win": w, "loss": l, "tie": n - w - l}
        ok = (lo > 0.0 or hi < 0.0)          # CI 不含 0
        rec["verdict"] = ("显著更好" if (ok and mean > 0) else ("显著更差" if ok else "量不到差别"))
        out["arms"][arm] = rec
        if ok and mean > a.min_gain and (best is None or mean > best[1]):
            best = (arm, mean)
    if best:
        out["winner"] = best[0]
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
