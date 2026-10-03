"""自进化 · 拟合器（我的方法·第 B 步）：**用胜负去学评估的系数**，而不是我手调。

输入：① `--records <前缀>` 采集出的 `<前缀>.<pid>.jsonl`（我 AI 的记录模式产出）
      ② `--run <run>` 该批的 `RL/train/results/<run>/measure.csv`（拿这一局的胜负当标签）
输出：`--out 系数.json` = `{特征: 权重, "_bias": b, "_meta": {...}}`（纯 Python 逻辑回归，无 numpy 依赖）

标签口径：候选方（A）赢 = 1、输 = 0、平局丢弃；若这条记录来自**对手侧**的 AI（`is_cand=false`）⇒ 标签取反。

⚠️ 【2026-10-03 加的两道闸】① **按"局"分组留出验证**：同一局里的几十条样本共享**同一个胜负标签**
   ⇒ 随机切样本会让"同局样本"落在两边、把过拟合当成本事；本器改成**按局切**（`--holdout` 比例的局整局留出）。
   ② **不达标就不出文件**：留出集准确率必须比**留出集的多数类基线**高出 `--min-gain`（默认 0.03）；
   否则打印判据并 **exit 2**（配 `系数.json` 不落盘）—— 因为 `LEARNED_EVAL=1` 是**整段替换**评估函数，
   喂一份噪声系数进去 = 档位 5 直接变傻（"缺文件安全退回父类"那条路只在**文件缺失**时生效）。

用法：python RL\\自进化\\拟合.py --records .dsh/tmp/rec --run evo_data_s100 --out RL/自进化/系数.json
"""
import io, os, sys, json, glob, math, csv, random, argparse
sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def _i(v):
    """把 '10001' / '10001.0' / 10001 统一成 '10001' —— 否则和 measure.csv 配不上（实测坑）。"""
    try:
        return str(int(float(v)))
    except Exception:
        return str(v)


def _side(v):
    """⚠️【2026-10-03 实测抓到的第二个配不上的坑】`measure.csv` 的 `first` 列是**字母**（`E`/`P`），
    而记录里的 `first` 是**整数**（`GameState.SIDE_PLAYER=0` / `SIDE_ENEMY=1`，harness 的原始
    `R|m|` 行同样是 `first=1`）。⇒ `(seed, first, aside)` 三元组里这一格永远是 `'1' vs 'E'`
    ⇒ **一条都配不上**（实测：20 条记录 0 条配上）。`a_side` 两边都是整数（`Faction{PLAYER=0,ENEMY=1}`）
    所以只差 `first` 这一格；这里统一归一化，两边都过这个函数。"""
    s = str(v).strip().upper()
    if s in ("E", "ENEMY", "1"):
        return "1"
    if s in ("P", "PLAYER", "0"):
        return "0"
    return _i(v)


def load_labels(run):
    lab = {}
    root = os.path.join("RL/train/results", run)
    for f in [os.path.join(root, "measure.csv")] + sorted(glob.glob(os.path.join(root, "w*", "measure.csv"))):
        if not os.path.exists(f):
            continue
        with io.open(f, encoding="utf-8-sig", newline="") as fh:
            for r in csv.DictReader(fh):
                res = (r.get("res") or "").strip().upper()[:1]
                if res not in ("W", "L"):
                    continue
                k = (_i(r.get("seed")), _side(r.get("first")), _side(r.get("a_side")))
                lab[k] = 1.0 if res == "W" else 0.0
    return lab


def load_records(prefix, labels):
    """⚠️ 特征名取**所有样本的并集**：`_eval_breakdown` 只列非零项 ⇒ 各样本的键集不同，
    只按第一条记录定特征名会**丢掉后面才出现的项**（实测坑）。"""
    rows = []
    keys = []
    files = sorted(glob.glob(prefix + ".*.jsonl")) + ([prefix] if os.path.exists(prefix) else [])
    names = set()
    n_read = 0
    n_nolabel = 0
    for f in files:
        for line in io.open(f, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line:
                continue
            n_read += 1
            try:
                r = json.loads(line)
            except Exception:
                continue
            k = (_i(r.get("seed")), _side(r.get("first")), _side(r.get("aside")))
            if k not in labels:
                n_nolabel += 1
                continue
            lab = labels[k]
            if not r.get("is_cand", True):
                lab = 1.0 - lab
            # ⚠️ 优先用 `feat`（含**位置一热**等升级特征，见 AI.gd::_feature_vec）；
            #    老记录只有 `terms` ⇒ 退回用它（两种记录可混着拟合，取并集）。
            terms = r.get("feat") or r.get("terms") or {}
            names.update(terms.keys())
            keys.append(k)
            rows.append((terms, lab))
    names = sorted(names)
    X = [[float(t.get(n, 0.0)) for n in names] for t, _ in rows]
    y = [lab for _, lab in rows]
    return X, y, names, keys, {"files": len(files), "read": n_read, "no_label": n_nolabel,
                               "labels": len(labels)}


def fit(X, y, epochs=400, lr=0.35, l2=1e-3):
    n, d = len(X), len(X[0]) if X else 0
    mu = [sum(row[j] for row in X) / n for j in range(d)]
    sd = [math.sqrt(sum((row[j] - mu[j]) ** 2 for row in X) / n) or 1.0 for j in range(d)]
    Z = [[(row[j] - mu[j]) / sd[j] for j in range(d)] for row in X]
    w = [0.0] * d
    b = 0.0
    for ep in range(epochs):
        gw = [0.0] * d
        gb = 0.0
        for i in range(n):
            z = b + sum(w[j] * Z[i][j] for j in range(d))
            p = 1.0 / (1.0 + math.exp(-max(-30.0, min(30.0, z))))
            e = p - y[i]
            gb += e
            for j in range(d):
                gw[j] += e * Z[i][j]
        for j in range(d):
            w[j] -= lr * (gw[j] / n + l2 * w[j])
        b -= lr * gb / n
    return w, b, mu, sd


def accuracy(X, y, w, b, mu, sd):
    if not X:
        return 0.0
    ok = 0
    for i in range(len(X)):
        z = b + sum(w[j] * (X[i][j] - mu[j]) / sd[j] for j in range(len(w)))
        p = 1.0 / (1.0 + math.exp(-max(-30.0, min(30.0, z))))
        ok += int((p >= 0.5) == (y[i] >= 0.5))
    return ok / len(X)


def majority(y):
    if not y:
        return 0.0
    return max(sum(y), len(y) - sum(y)) / len(y)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--records", required=True)
    ap.add_argument("--run", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--holdout", type=float, default=0.25, help="按[局]留出的比例")
    ap.add_argument("--group-by", choices=("seed", "game"), default="seed",
                    help="留出分组键：seed（默认·更严）= 同一 seed 的所有盘（同队伍同对手，四个格）整组同边；"
                         "game = 单个 (seed,first,aside)。⚠️ 用 game 会把'同一个 seed 的另外三格'留在训练集里，"
                         "等于让模型见过同一场对决 ⇒ 留出准确率会虚高（2026-10-03 复核时发现，故默认改成 seed）")
    ap.add_argument("--min-gain", type=float, default=0.03, help="留出集准确率必须比多数类基线高出这么多")
    ap.add_argument("--split-seed", type=int, default=20261003)
    ap.add_argument("--force", action="store_true", help="即使没过闸也写文件（只在做对照实验时用）")
    a = ap.parse_args()

    labels = load_labels(a.run)
    X, y, names, keys, diag = load_records(a.records, labels)
    games = sorted(set(keys))
    print(f"[读入] 记录文件 {diag['files']} 个 · 读到 {diag['read']} 行 · 配上标签 {len(X)} 条 "
          f"（配不上 {diag['no_label']} 条）· 标签总表 {diag['labels']} 局 ⇒ 涉及 {len(games)} 局")
    if diag["read"] and len(X) == 0:
        print("❌ 一条都对不上 ⇒ 检查：① 录制前缀对不对 ② run 名对不对 ③ 记录里的 seed/first/aside 与 measure.csv 是否同一批")
        sys.exit(2)
    if len(X) < 100:
        print(f"样本太少（{len(X)} 条）⇒ 不拟合。检查：记录前缀对不对、run 名对不对、标签能不能配上。")
        sys.exit(2)

    print(f"样本 {len(X)} 条 · 特征 {len(names)} 项 · 正例率 {sum(y)/len(y):.3f}")
    print(f"⚠️ 有效独立性：这些样本只来自 {len(games)} 局（同局的样本共享同一个胜负标签）"
          f"⇒ 真正独立的只有 {len(games)} 个标签，别被样本条数骗了")

    # ---- 按"局"或按"种子"分组留出：训练集 / 留出集 ----
    # ⚠️ 默认按 **seed** 分：同一个 seed 的四个格（first×aside）用的是同一对队伍 ⇒ 若按 game 分，
    #    训练集里会有"同一个 seed 的另外三格"，模型等于见过同一场对决 ⇒ 留出准确率虚高。
    gkey = [(k[0] if a.group_by == "seed" else k) for k in keys]
    gs = sorted(set(gkey))
    random.Random(a.split_seed).shuffle(gs)
    n_ho = max(1, int(round(len(gs) * a.holdout)))
    ho = set(gs[:n_ho])
    itr = [i for i, k in enumerate(gkey) if k not in ho]
    iho = [i for i, k in enumerate(gkey) if k in ho]
    Xtr = [X[i] for i in itr]; ytr = [y[i] for i in itr]
    Xho = [X[i] for i in iho]; yho = [y[i] for i in iho]
    print(f"[留出] 分组键 = {a.group_by}（{len(gs)} 组）· 训练 {len(gs) - len(ho)} 组/{len(Xtr)} 条 · "
          f"留出 {len(ho)} 组/{len(Xho)} 条（同组样本不跨边）")
    w, b, mu, sd = fit(Xtr, ytr)
    acc_tr = accuracy(Xtr, ytr, w, b, mu, sd)
    acc_ho = accuracy(Xho, yho, w, b, mu, sd)
    base_ho = majority(yho)
    print(f"[判据] 留出集准确率 {acc_ho:.3f} vs 留出集多数类基线 {base_ho:.3f}"
          f"（差 {acc_ho - base_ho:+.3f}，要求 > {a.min_gain:.3f}）· 训练集准确率 {acc_tr:.3f}（仅供参考，会过拟合）")
    passed = (acc_ho - base_ho) > a.min_gain
    if not passed and not a.force:
        print("❌ 留出集上量不到信号 ⇒ **不写系数文件**（写了就是拿噪声替换整段评估）")
        print("   下一步该做的不是调超参，而是**换更彻底的特征**（例：英雄种类 × 格子一热、局面阶段、目标血线）")
        sys.exit(2)
    if not passed:
        print("⚠️ --force：没过闸也写（只用于对照实验）")

    # ---- 过闸 ⇒ 用**全部**数据重拟合再落盘（多一个局就多一点信息）----
    w, b, mu, sd = fit(X, y)
    raw = {names[j]: w[j] / sd[j] for j in range(len(names))}
    raw["_bias"] = b - sum(w[j] * mu[j] / sd[j] for j in range(len(names)))
    raw["_meta"] = {"n": len(X), "games": len(games), "features": len(names),
                    "holdout_acc": round(acc_ho, 4), "holdout_base": round(base_ho, 4),
                    "holdout_gain": round(acc_ho - base_ho, 4), "holdout_games": len(ho),
                    "train_acc": round(acc_tr, 4), "pos_rate": round(sum(y) / len(y), 4),
                    "run": a.run, "records": a.records, "split_seed": a.split_seed}
    io.open(a.out, "w", encoding="utf-8").write(json.dumps(raw, ensure_ascii=False, indent=1))
    top = sorted(((k, v) for k, v in raw.items() if not k.startswith("_")), key=lambda kv: -abs(kv[1]))[:10]
    print("学出来的系数（按绝对值前 10；正 = 这一项越大越容易赢）：")
    for k, v in top:
        print(f"   {k:<22} {v:+.4f}")
    print("→", a.out)


if __name__ == "__main__":
    main()
