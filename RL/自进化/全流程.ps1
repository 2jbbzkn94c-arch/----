# 自进化 · 全流程（一条命令走完"采数据 → 学系数 → A/B → 采纳 → 验收"）
#
# 用户口径：「你先停下，等我要睡觉了再找你」⇒ 本脚本就是**他发话之后按一下就走完**的那条链。
# 顺序不能改（每一步都为下一步造前提）：
#   ① 采数据批：400 局带记录的对局（`DSH_EVO_RECORD` 环境变量开录制）≈70 分钟
#   ② 拟合：**按局留出验证**，留出增益不达标就**不出系数文件**（exit 2）⇒ 后面全跳过（这就是闸门）
#   ③ 出 A/B 计划：`ctl` = 当前冠军 · `c0` = 冠军 + 学出来的评估（只差两个键）
#   ④ 配对批：ctl vs c0（默认 32 种子 = 128 局），判据 = 配对 Δpts 的 95% CI 不含 0
#   ⑤ 判定过了才采纳（写基因组 + 物化）⇒ 冠军权重换人；没过就什么都不动
#   ⑥ 验收批：**难度5 打 难度3**（Wilson 95% 下界 > 0.5 才算显著更强）⇒ 读数交用户实机验收
#
# 用法：
#   powershell -File RL\自进化\全流程.ps1 -DryRun          # 只打印每一步要跑什么（不占机器、不写任何东西）
#   powershell -File RL\自进化\全流程.ps1                  # 真跑（12 线程，约 3 小时）
#   powershell -File RL\自进化\全流程.ps1 -Seeds 24 -AceSeeds 8   # 小规模试跑（先看链路通不通）
param([int]$Seeds = 100, [int]$Workers = 12, [int]$AceSeeds = 32, [int]$AbSeeds = 32, [switch]$DryRun)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$mine = "RL\自进化"
$run_data = "evo_data_s$Seeds"
$run_ab = "evo_ll_r1"
$run_ace = "evo_ace_s$AceSeeds"
$coef = "$mine\系数.json"
$plan = ".dsh\tmp\学系数_ab.json"
$spec_ab = "$mine\spec_学系数.json"

Write-Host "===== 自进化 全流程（采数据 $Seeds 种子 · 线程 $Workers · A/B $AbSeeds 种子 · 验收 $AceSeeds 种子）====="
Write-Host "  ① 采数据批 → $run_data（$($Seeds*4) 局）"
Write-Host "  ② 拟合 → $coef（不达标不出文件 ⇒ 全流程停在闸门）"
Write-Host "  ③ A/B 计划 → $plan + $spec_ab"
Write-Host "  ④ 配对批 ctl vs c0 → $run_ab（$($AbSeeds*4) 局）"
Write-Host "  ⑤ 判定过了才采纳（改基因组 + 物化）"
Write-Host "  ⑥ 验收批 难度5 打 难度3 → $run_ace（$($AceSeeds*4) 局）"
if ($DryRun) { Write-Host "  （-DryRun：下面只打印命令行，不执行、不写文件）" }

# ---------------- ① 采数据 ----------------
Write-Host ""
Write-Host "===== ① 采数据 ====="
if ($DryRun) {
    Write-Host "  `$env:DSH_EVO_RECORD = <项目>\.dsh\tmp\rec ; 清空旧记录"
    Write-Host "  Train.ps1 -Task gen -Run $run_data -Spec $mine\spec_evo_data.json -Configs data"
    Write-Host "  Train.ps1 -Task run -Run $run_data -Spec $mine\spec_evo_data.json -Configs data -SeedSet train -MaxSeeds $Seeds -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec 7200"
} else {
    $env:DSH_EVO_RECORD = (Join-Path (Get-Location) ".dsh\tmp\rec")
    Remove-Item ".dsh\tmp\rec.*.jsonl" -ErrorAction SilentlyContinue
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task gen -Run $run_data -Spec '$mine\spec_evo_data.json' -Configs data" 2>&1 | Select-String -Pattern '\[gen\]|FATAL' | ForEach-Object { $_.Line }
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task run -Run $run_data -Spec '$mine\spec_evo_data.json' -Configs data -SeedSet train -MaxSeeds $Seeds -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec 7200" 2>&1 | Select-String -Pattern 'TOTAL wall|completeness|FATAL|ERROR' | ForEach-Object { $_.Line }
    $nrec = (Get-ChildItem ".dsh\tmp\rec.*.jsonl" -ErrorAction SilentlyContinue | Get-Content | Measure-Object -Line).Lines
    Write-Host "  采到样本 $nrec 条"
}

# ---------------- ② 拟合（闸门） ----------------
Write-Host ""
Write-Host "===== ② 拟合（闸门：按局留出验证） ====="
$fit_rc = 0
if ($DryRun) {
    Write-Host "  python $mine\拟合.py --records .dsh\tmp\rec --run $run_data --out $coef"
    Write-Host "  ⇒ 退出码 0 = 过闸（写了系数文件）· 2 = 没过闸（不写文件，全流程在此结束）"
} else {
    python "$mine\拟合.py" --records ".dsh\tmp\rec" --run $run_data --out $coef 2>&1 | ForEach-Object { Write-Host ("  " + $_.ToString()) }
    $fit_rc = $LASTEXITCODE
}
if (-not $DryRun -and $fit_rc -ne 0) {
    Write-Host ""
    Write-Host "❌ 拟合没过闸（退出码 $fit_rc）⇒ 留出集上量不到信号：**不采纳、不改任何东西**。"
    Write-Host "   下一步该做的不是调超参，而是换更彻底的特征（英雄种类×格子一热 / 局面阶段 / 目标血线）。"
    Write-Host "===== 全流程结束（停在闸门）====="
    exit 0
}

# ---------------- ③ A/B 计划 ----------------
Write-Host ""
Write-Host "===== ③ A/B 计划（ctl = 冠军 · c0 = 冠军 + 学系数） ====="
if ($DryRun) {
    Write-Host "  python $mine\采纳系数.py --coef $coef --plan $plan"
    Write-Host "  python $mine\自进化_spec.py $plan $spec_ab"
} else {
    python "$mine\采纳系数.py" --coef $coef --plan $plan 2>&1 | ForEach-Object { Write-Host ("  " + $_.ToString()) }
    python "$mine\自进化_spec.py" $plan $spec_ab 2>&1 | ForEach-Object { Write-Host ("  " + $_.ToString()) }
}

# ---------------- ④ 配对批 ----------------
Write-Host ""
Write-Host "===== ④ 配对批 ctl vs c0 ====="
if ($DryRun) {
    Write-Host "  Train.ps1 -Task gen -Run $run_ab -Spec $spec_ab -Configs ctl,c0"
    Write-Host "  Train.ps1 -Task run -Run $run_ab -Spec $spec_ab -Configs ctl,c0 -SeedSet train -MaxSeeds $AbSeeds -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec 7200"
} else {
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task gen -Run $run_ab -Spec '$spec_ab' -Configs ctl,c0" 2>&1 | Select-String -Pattern '\[gen\]|FATAL' | ForEach-Object { $_.Line }
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task run -Run $run_ab -Spec '$spec_ab' -Configs ctl,c0 -SeedSet train -MaxSeeds $AbSeeds -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec 7200" 2>&1 | Select-String -Pattern 'TOTAL wall|completeness|FATAL|ERROR' | ForEach-Object { $_.Line }
}

# ---------------- ⑤ 判定 → 采纳 / 不动 ----------------
Write-Host ""
Write-Host "===== ⑤ 判定（配对 Δpts 的 95% CI 不含 0 且为正才采纳） ====="
if ($DryRun) {
    Write-Host "  python $mine\自进化_判定.py --run $run_ab --control ctl --arms c0"
    Write-Host "  winner = c0 ⇒ python $mine\采纳系数.py --coef $coef --commit --materialize + 物化"
    Write-Host "  否则 ⇒ 基因组不动（难度 5 保持原冠军）"
} else {
    $verdict = python "$mine\自进化_判定.py" --run $run_ab --control ctl --arms c0 2>&1 | Select-Object -Last 1
    Write-Host ("  " + $verdict)
    $win = $null
    try { $win = ($verdict | ConvertFrom-Json).winner } catch { $win = $null }
    if ($win -eq 'c0') {
        Write-Host "  判定通过（c0 显著更好）⇒ 采纳"
        python "$mine\采纳系数.py" --coef $coef --commit 2>&1 | ForEach-Object { Write-Host ("  " + $_.ToString()) }
        python "$mine\自进化_物化.py" 2>&1 | ForEach-Object { Write-Host ("  " + $_.ToString()) }
        Write-Host "  ⚠️ 改完必须重启游戏进程（权重是 load() 进资源缓存的）"
    } else {
        Write-Host "  判定没过（跨 0 或无增益）⇒ 基因组不动、难度 5 保持原冠军"
    }
}

# ---------------- ⑥ 验收批 ----------------
Write-Host ""
Write-Host "===== ⑥ 验收批：难度5 打 难度3 ====="
if ($DryRun) {
    Write-Host "  Train.ps1 -Task gen -Run $run_ace -Spec $mine\spec_evo_ace.json -Configs ace"
    Write-Host "  Train.ps1 -Task run -Run $run_ace -Spec $mine\spec_evo_ace.json -Configs ace -SeedSet train -MaxSeeds $AceSeeds -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec 7200"
    Write-Host "  python $mine\验收读数.py $run_ace   （Wilson 95% 下界 > 0.5 **且** 配对 Δpts CI 不含 0）"
} else {
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task gen -Run $run_ace -Spec '$mine\spec_evo_ace.json' -Configs ace" 2>&1 | Select-String -Pattern '\[gen\]|FATAL' | ForEach-Object { $_.Line }
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task run -Run $run_ace -Spec '$mine\spec_evo_ace.json' -Configs ace -SeedSet train -MaxSeeds $AceSeeds -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec 7200" 2>&1 | Select-String -Pattern 'TOTAL wall|completeness|FATAL|ERROR' | ForEach-Object { $_.Line }
    Write-Host "--- 读数 ---"
    python "$mine\验收读数.py" $run_ace 2>&1 | ForEach-Object { Write-Host ("  " + $_.ToString()) }
}

Write-Host ""
Write-Host "===== 全流程结束（账本 = $mine\账本.jsonl）====="
