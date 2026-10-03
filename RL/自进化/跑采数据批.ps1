# 自进化 · 采数据批（我的方法第 A 步）：跑一批带记录的对局，给拟合器准备样本。
# ⚠️ 规模：100 种子 × 双先后手 × 双 aside = 400 局（≈70 分钟）。为什么这么大：**同一局的样本共享同一个
#    胜负标签** ⇒ 真正独立的标签数 = 局数 ⇒ 32 局只能给 ~32 个标签，拟合出来的东西不可信。
# ⚠️ 录制开关走**环境变量** `DSH_EVO_RECORD`（值 = 输出前缀），不走 spec 的 theta：
#    训练器的 theta 只认它自己那份键表（自动搜索键/规则键/钉住键），我的键会在解析阶段就
#    `FATAL: theta key not accepted by AI_Battle.set_weights: RECORD_PATH` 直接整批失败。
#    环境变量由父进程传下去、Godot 子进程继承（训练器自己就是这么把 APPDATA 传下去的）。
# ⚠️ 对手 = 难度3：spec 里 `opponent=cand` + `league.checkpoint=噩梦.json`（同 fork + 噩梦权重）。
# 用法：powershell -File RL\自进化\跑采数据批.ps1
$Seeds = 100
$Workers = 12
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$run = "evo_data_s$Seeds"
$rec = Join-Path (Get-Location) ".dsh\tmp\rec"
Remove-Item "$rec.*.jsonl" -ErrorAction SilentlyContinue
$env:DSH_EVO_RECORD = $rec
Write-Output "=== 录制前缀（环境变量 DSH_EVO_RECORD）: $rec ==="
Write-Output "=== gen ($run) ==="
powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task gen -Run $run -Spec 'RL\自进化\spec_evo_data.json' -Configs data" 2>&1 | Select-String -Pattern '\[gen\]|FATAL' | ForEach-Object { $_.Line }
Write-Output "=== run ($run) ==="
powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task run -Run $run -Spec 'RL\自进化\spec_evo_data.json' -Configs data -SeedSet train -MaxSeeds $Seeds -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec 7200" 2>&1 | Select-String -Pattern 'TOTAL wall|completeness|FATAL|ERROR' | ForEach-Object { $_.Line }
$n = (Get-ChildItem "$rec.*.jsonl" -ErrorAction SilentlyContinue | Get-Content | Measure-Object -Line).Lines
Write-Output "=== 采到样本 $n 条 ⇒ 拟合 ==="
python "RL\自进化\拟合.py" --records "$rec" --run $run --out "RL\自进化\系数.json"
