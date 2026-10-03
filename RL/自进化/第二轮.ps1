# 自进化 · 第二轮（2026-10-03 白天）：补完数据 → 重拟合 → **多臂 A/B** → 过判定才采纳 → 复测验收
#
# 为什么有第二轮：第一轮（`全流程.ps1`）跑到 ⑥ 拿到了**验收读数**（难度5 打 难度3 = 0.5898
# [0.5032,0.6712]、Δpts +11.11 [+1.75,+20.47] ⇒ 两条判据都过），但 ①采数据 与 ④A/B **两次被
# 整批预算砍掉**：`-TimeoutSec 900` ⇒ 训练器的整批预算 = 900×2+300 = **2100s = 35 分钟**
# （实测两次都恰好跑 35.3 分钟就 `only 0 of 10 worker(s) reported a result`）。训练器自己的默认是
# 3600（注释里写着"900s 会静默截断真实跑批"）⇒ 本轮所有批一律 `-TimeoutSec 7200`（预算 4 小时）。
#
# 本轮要验的"我自己出的点子"（全部走配对批 + CI 判定）：
#   ctl    当前冠军（对照）
#   c0     **学出来的评估**（重拟合的系数；上一轮因 ④ 被砍只跑到 84/128 对 ⇒ 本轮补足）
#   c1     **机制 2「下套」轻剂量**：`TRAP_W = 1.0`
#   c2     **机制 2「下套」重剂量 + 只算原本能自由行动的**：`TRAP_W = 2.0` + `TRAP_FREE_TARGET = 1`
# 判据：每臂 vs ctl 的**配对 Δpts 的 95% CI 不含 0 且为正**才采纳（`自进化_判定.py`）。
#
# 用法：powershell -File RL\自进化\第二轮.ps1 [-Seeds 32] [-Workers 12]
param([int]$Seeds = 32, [int]$Workers = 12)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$mine = "RL\自进化"
$run_ab = "evo2_ab"
$run_ace = "evo2_ace"
$plan = ".dsh\tmp\第二轮_计划.json"
$spec = "$mine\spec_第二轮.json"

function Log([string]$m) { Write-Host ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }
function Train([string]$task, [string]$run, [string]$sp, [string]$cfg, [string]$extra) {
    $cmd = "& 'RL\train\Train.ps1' -Task $task -Run $run -Spec '$sp' -Configs $cfg $extra"
    powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 |
        Select-String -Pattern '\[gen\]|TOTAL wall|completeness|FATAL|ERROR' | ForEach-Object { Log ([string]$_.Line) }
}

Log "===== 第二轮开始（A/B 每臂 $Seeds 种子 = $($Seeds*4) 局 · 线程 $Workers）====="

# ---------------- ① 补完采数据批（断了就续，只补缺的格） ----------------
Log "① 补完采数据批 evo_data_s100（目标 100 种子 = 400 局；训练器只补缺的格）"
$env:DSH_EVO_RECORD = (Join-Path (Get-Location) ".dsh\tmp\rec")
Train 'run' 'evo_data_s100' "$mine\spec_evo_data.json" 'data' "-SeedSet train -MaxSeeds 100 -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec 7200"
$games = 0; $recs = 0
$csv = "RL\train\results\evo_data_s100\measure.csv"
if (Test-Path $csv) { $games = (Import-Csv $csv -Encoding UTF8).Count }
$recs = (Get-ChildItem ".dsh\tmp\rec.*.jsonl" -ErrorAction SilentlyContinue | Get-Content | Measure-Object -Line).Lines
Log "  现在：measure.csv $games 行 · 录制 $recs 行"

# ---------------- ② 重拟合（按 seed 整组留出 = 更严的闸门） ----------------
Log "② 重拟合（--group-by seed）"
python "$mine\拟合.py" --records ".dsh\tmp\rec" --run evo_data_s100 --out "$mine\系数.json" --group-by seed 2>&1 |
    ForEach-Object { Log ("  " + [string]$_) }
$fit_rc = $LASTEXITCODE
if ($fit_rc -ne 0) {
    Log "② 没过闸（退出码 $fit_rc）⇒ 本轮只验机制臂（c1/c2），不验学系数臂"
}

# ---------------- ③ 出四臂计划（学系数那臂视闸门结果决定要不要） ----------------
Log "③ 出计划：ctl + (学系数) + 下套轻 + 下套重"
$py = @"
import io, json
mine = r'$mine'
gen = json.load(io.open(mine + r'\基因组.json', encoding='utf-8-sig')).get('overlay', {}) or {}
ctl = {k: v for k, v in gen.items() if not str(k).startswith('_')}
cands = []
pass_gate = ($fit_rc -eq 0)
if pass_gate:
    ll = dict(ctl); ll['LEARNED_EVAL'] = 1; ll['LEARNED_COEF'] = 'res://RL/自进化/系数.json'
    cands.append({'kind': '学系数', 'theta': ll, 'why': 'LEARNED_EVAL=1 + 重拟合系数'})
t1 = dict(ctl); t1['TRAP_W'] = 1.0
cands.append({'kind': '机制2', 'theta': t1, 'why': '下套 TRAP_W 0 -> 1.0'})
t2 = dict(ctl); t2['TRAP_W'] = 2.0; t2['TRAP_FREE_TARGET'] = 1
cands.append({'kind': '机制2', 'theta': t2, 'why': '下套 TRAP_W 0 -> 2.0 + 只算原本能动的'})
plan = {'control': ctl, 'candidates': cands, '_readme': '自进化 第二轮：学系数 + 下套两档'}
io.open(r'$plan', 'w', encoding='utf-8').write(json.dumps(plan, ensure_ascii=False, indent=1))
print('臂:', ['ctl'] + ['c%d' % i for i in range(len(cands))], '|', [c['why'] for c in cands])
"@
$py | Out-File -FilePath ".dsh\tmp\出计划.py" -Encoding UTF8
python ".dsh\tmp\出计划.py" 2>&1 | ForEach-Object { Log ("  " + [string]$_) }
python "$mine\自进化_spec.py" $plan $spec 2>&1 | ForEach-Object { Log ("  " + [string]$_) }
$arms = python -c "import io,json; p=json.load(io.open(r'$plan',encoding='utf-8-sig')); print(','.join(['ctl']+['c%d'%i for i in range(len(p['candidates']))]))"
Log "  臂列表: $arms"

# ---------------- ④ 配对批（多臂一次跑完） ----------------
Log "④ 配对批 $arms（每臂 $($Seeds*4) 局）"
Train 'gen' $run_ab $spec $arms ''
Train 'run' $run_ab $spec $arms "-SeedSet train -MaxSeeds $Seeds -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec 7200"

# ---------------- ⑤ 判定 → 采纳 ----------------
Log "⑤ 判定（每臂 vs ctl：配对 Δpts 的 95% CI 不含 0 且为正才采纳）"
$cand_arms = ($arms -split ',' | Where-Object { $_ -ne 'ctl' }) -join ','
$verdict = python "$mine\自进化_判定.py" --run $run_ab --control ctl --arms $cand_arms 2>&1 | Select-Object -Last 1
Log ("  " + [string]$verdict)
$winner = $null
try { $winner = ($verdict | ConvertFrom-Json).winner } catch { $winner = $null }
if ($winner) {
    Log "  采纳 $winner"
    python "$mine\采纳臂.py" --plan $plan --arm $winner --commit 2>&1 | ForEach-Object { Log ("  " + [string]$_) }
    python "$mine\自进化_物化.py" 2>&1 | ForEach-Object { Log ("  " + [string]$_) }
    $newsha = (Get-FileHash "$mine\权重.json" -Algorithm SHA256).Hash.Substring(0,12).ToLower()
    Log "  新冠军权重 sha12 = $newsha（⚠️ 用户实机要重启游戏进程）"
} else {
    Log "  没有臂过判据 ⇒ 基因组不动（难度 5 保持原冠军）"
}

# ---------------- ⑥ 复测验收（只在冠军换了的时候才有必要） ----------------
if ($winner) {
    Log "⑥ 复测验收：难度5 打 难度3（128 局）"
    Train 'gen' $run_ace "$mine\spec_evo_ace.json" 'ace' ''
    Train 'run' $run_ace "$mine\spec_evo_ace.json" 'ace' "-SeedSet train -MaxSeeds 32 -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec 7200"
    python "$mine\验收读数.py" $run_ace 2>&1 | ForEach-Object { Log ("  " + [string]$_) }
} else {
    Log "⑥ 冠军没换 ⇒ 不用复测（上一轮 13:05 的验收读数仍然有效：0.5898 [0.5032,0.6712]、Δpts +11.11 [+1.75,+20.47]）"
}

Log "===== 第二轮结束（账本 = $mine\账本.jsonl）====="
