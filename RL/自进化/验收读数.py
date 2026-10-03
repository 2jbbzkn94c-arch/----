"""自进化 · 验收读数器（把"难度5 打 难度3"这一批读成能交付的结论）。

为什么要单独一份（`.dsh/tmp/agg_multi.py` 已经有了）：那个在**临时区**（会被清掉），而验收证据要能
在任何时候重跑出来。本文件只读 `RL/train/results/<run>/measure.csv`（含 `w*/` 分片的），不动任何状态。

判据（用户口径 · 与本档全程一致）：
  ① **Wilson 95% 下界 > 0.5**（胜率，平局算半胜）
  ② **配对 Δpts 的 95% CI 不含 0 且点估 > 0**（Δpts = 每局 ptsA − ptsB；同一批的逐格配对）
两条**都要**满足才算"显著更强"。参考基线：难度4 打 难度3 = **0.5807 [0.5308, 0.6290]**（384 局）。

用法：python RL\\自进化\\验收读数.py evo_ace_s32 [更多 run ...] [--config ace] [--baseline 0.5807]
"""
import io, os, sys, csv, glob, math, argparse, collections

sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def load(run, want_cfg=""):
    root = os.path.join("RL/train/results", run)
    files = [os.path.join(root, "measure.csv")] + sorted(glob.glob(os.path.join(root, "w*", "measure.csv")))
    seen = {}
    for f in files:
        if not os.path.exists(f):
            continue
        with io.open(f, encoding="utf-8-sig", newline="") as fh:
            for r in csv.DictReader(fh):
                if want_cfg and (r.get("config") or "") != want_cfg:
                    continue
                k = (r.get("config"), r.get("seed"), r.get("first"), r.get("a_side"))
                seen.setdefault(k, r)          # 同一格重复测量只取第一条（与训练器的"一格一行"口径一致）
    return seen


def wilson(k, n, z=1.959963985):
    if n <= 0:
        return (0.0, 0.0)
    ph = k / n
    d = 1 + z * z / n
    c = ph + z * z / (2 * n)
    m = z * math.sqrt(ph * (1 - ph) / n + z * z / (4 * n * n))
    return (max(0.0, (c - m) / d), min(1.0, (c + m) / d))


def ci95(xs):
    n = len(xs)
    if n < 2:
        return (0.0, 0.0, 0.0)
    mu = sum(xs) / n
    sd = math.sqrt(sum((x - mu) ** 2 for x in xs) / (n - 1))
    se = sd / math.sqrt(n)
    return (mu, mu - 1.959963985 * se, mu + 1.959963985 * se)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--config", default="", help="只读某个臂（例：ace）；默认读全部臂")
    ap.add_argument("--baseline", type=float, default=0.5807, help="参照胜率（难度4 打 难度3 = 0.5807）")
    a = ap.parse_args()
    print("| run | 臂 | N | W | L | D | 胜率(平=半胜) | Wilson 95% | Δpts | Δpts 95% CI | 平均回合 |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    verdicts = []
    for run in a.runs:
        seen = load(run, a.config)
        if not seen:
            print(f"| {run} | (无数据) | | | | | | | | | |")
            verdicts.append((run, None))
            continue
        by = collections.defaultdict(lambda: {"W": 0, "L": 0, "D": 0, "pts": [], "rounds": []})
        for r in seen.values():
            c = r.get("config") or "?"
            res = (r.get("res") or "").strip().upper()[:1]
            if res not in ("W", "L", "D"):
                res = "D"
            b = by[c]
            b[res] += 1
            try:
                b["pts"].append(float(r.get("ptsA") or 0) - float(r.get("ptsB") or 0))
            except Exception:
                pass
            try:
                b["rounds"].append(float(r.get("rounds") or 0))
            except Exception:
                pass
        for c, b in sorted(by.items()):
            n = b["W"] + b["L"] + b["D"]
            k = b["W"] + 0.5 * b["D"]
            rh = k / n if n else 0.0
            lo, hi = wilson(k, n)
            mu, plo, phi = ci95(b["pts"])
            mr = sum(b["rounds"]) / len(b["rounds"]) if b["rounds"] else 0.0
            print(f"| {run} | {c} | {n} | {b['W']} | {b['L']} | {b['D']} | {rh:.4f} | [{lo:.4f}, {hi:.4f}] | "
                  f"{mu:+.2f} | [{plo:+.2f}, {phi:+.2f}] | {mr:.1f} |")
            verdicts.append((f"{run}/{c}", {"n": n, "rate": rh, "lo": lo, "hi": hi, "d": mu, "dlo": plo, "dhi": phi}))

    print("")
    print("判据：① Wilson 95% 下界 > 0.5  ② 配对 Δpts 的 95% CI 不含 0 且点估 > 0  —— 两条都要满足")
    for tag, v in verdicts:
        if not v:
            print(f"  {tag}: 无数据")
            continue
        c1 = v["lo"] > 0.5
        c2 = (v["dlo"] > 0.0)
        print(f"  {tag}: N={v['n']} 胜率 {v['rate']:.4f}（下界 {v['lo']:.4f} {'✓' if c1 else '✗'}）· "
              f"Δpts {v['d']:+.2f} [{v['dlo']:+.2f}, {v['dhi']:+.2f}] {'✓' if c2 else '✗'}"
              f" ⇒ {'**显著更强**' if (c1 and c2) else '不达标'}"
              + (f"（参照基线 {a.baseline:.4f}）" if a.baseline else ""))


if __name__ == "__main__":
    main()
