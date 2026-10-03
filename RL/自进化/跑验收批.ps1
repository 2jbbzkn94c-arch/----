# 档位 5「自进化」验收批：难度5（`RL/自进化/权重.json` 原样）打 难度3（`RL/weights/噩梦.json`）。
#   难度5 这一侧由权重文件里的 `_ai_script` 决定加载 `RL/自进化/AI.gd`（我的子类，不是 fork）；
#   难度3 这一侧是同一 fork + 噩梦权重（spec 里 `opponent=cand` + `league.checkpoint=噩梦.json`）。
# 判据：Wilson 95% 下界 > 0.5（对照基线：噩梦1 打 难度3 = 0.5807 [0.5308,0.6290] @ N=384）。
# 用法：powershell -File RL\自进化\跑验收批.ps1 （默认 32 种子 = 128 局；改 $Seeds 即改规模）
$Seeds = 32
$Workers = 12
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$run = "evo_ace_s$Seeds"
Write-Output "=== gen ($run) ==="
powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task gen -Run $run -Spec 'RL\自进化\spec_evo_ace.json' -Configs ace" 2>&1 | Select-String -Pattern '\[gen\]|FATAL' | ForEach-Object { $_.Line }
Write-Output "=== run ($run) ==="
powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task run -Run $run -Spec 'RL\自进化\spec_evo_ace.json' -Configs ace -SeedSet train -MaxSeeds $Seeds -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec 7200" 2>&1 | Select-String -Pattern 'TOTAL wall|completeness|FATAL|ERROR' | ForEach-Object { $_.Line }
Write-Output "=== 读数（Wilson 95% 下界 > 0.5 才算显著更强） ==="
python ".dsh\tmp\agg_multi.py" $run
