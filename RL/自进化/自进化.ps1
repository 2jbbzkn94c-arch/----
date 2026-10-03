# 自进化 · 单轮驱动器（AI 自己进化的一轮）：
#   ① 出点子（自进化_点子.py）→ ② 生成 spec（自进化_spec.py **克隆现成 spec 的协议块**，只换 configs）
#   → ③ 逐个跑配对批（对照 = 当前冠军 + 候选）→ ④ 判定（自进化_判定.py：配对 Δpts 的 95% CI 不含 0 且为正 ⇒ 采纳）
#   → ⑤ 采纳则更新基因组 + 物化 RL/自进化/权重.json，并把本轮记进账本（jsonl，含冠军权重 sha12）。
# 【2026-10-03 搬迁】本脚本与它用到的全部文件都住 `RL/自进化/`（用户口径：你的东西另一个文件夹）。
#   权重文件也已搬进来：游戏里难度 5 读的是 `res://RL/自进化/权重.json`。
# 用法: powershell -File RL\自进化\自进化.ps1 [-K 3] [-Seed 1] [-Step 1.0] [-Rounds 1] [-MaxSeeds 32]
param([int]$K = 3, [int]$Seed = 1, [double]$Step = 1.0, [int]$Rounds = 1,
      [int]$MaxSeeds = 32, [int]$Workers = 12, [int]$TimeoutSec = 900)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$mine = "RL\自进化"
$genome = "$mine\基因组.json"
$ledger = "$mine\账本.jsonl"
$weights = "$mine\权重.json"
function Get-Sha12([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return "-" }
    return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
}
for ($r = 1; $r -le $Rounds; $r++) {
    $tag  = "evo_s${Seed}_r${r}"
    $plan = ".dsh\tmp\evo_plan_$tag.json"
    Write-Output "===== 自进化 第 $r 轮（种子 $Seed · 每臂 $MaxSeeds 种子）====="
    python "$mine\自进化_点子.py" --genome $genome --k $K --seed $Seed --step $Step --out $plan 2>&1 | ForEach-Object { $_.ToString() }
    $p = Get-Content $plan -Raw -Encoding UTF8 | ConvertFrom-Json
    $arms = @('ctl')
    for ($i = 0; $i -lt $p.candidates.Count; $i++) { $arms += "c$i" }
    $spec = "$mine\spec_$tag.json"
    $p | Add-Member -NotePropertyName _readme -NotePropertyValue "自进化（档位5）第 $r 轮 · 种子 $Seed · 对照 = 当前冠军" -Force
    ($p | ConvertTo-Json -Depth 10) | Set-Content $plan -Encoding UTF8
    python "$mine\自进化_spec.py" $plan $spec 2>&1 | ForEach-Object { $_.ToString() }
    $armList = $arms -join ','
    Write-Output "--- arms: $armList ---"
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task gen -Run $tag -Spec '$spec' -Configs $armList" 2>&1 | Select-String -Pattern '\[gen\]|FATAL' | ForEach-Object { $_.Line }
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'RL\train\Train.ps1' -Task run -Run $tag -Spec '$spec' -Configs $armList -SeedSet train -MaxSeeds $MaxSeeds -Firsts e,p -Asides e,p -Workers $Workers -TimeoutSec $TimeoutSec" 2>&1 | Select-String -Pattern 'TOTAL wall|completeness|FATAL|ERROR' | ForEach-Object { $_.Line }
    $cand = ($arms | Where-Object { $_ -ne 'ctl' }) -join ','
    $verdict = python "$mine\自进化_判定.py" --run $tag --control ctl --arms $cand 2>&1 | Select-Object -Last 1
    Write-Output $verdict
    $v = $null
    try { $v = $verdict | ConvertFrom-Json } catch { $v = $null }
    $winner = $null
    if ($v -ne $null) { $winner = $v.winner }
    $adopted = $false
    $why = ""
    if ($winner) {
        $idx = [int]($winner -replace 'c', '')
        $why = $p.candidates[$idx].why
        Write-Output "采纳 $winner（$why）⇒ 更新基因组 + 物化"
        ([ordered]@{ overlay = $p.candidates[$idx].theta; last_round = $r; last_run = $tag; accepted = $why } |
            ConvertTo-Json -Depth 8) | Set-Content $genome -Encoding UTF8
        python "$mine\自进化_物化.py" 2>&1 | ForEach-Object { $_.ToString() }
        $adopted = $true
    } else {
        Write-Output "本轮无可采纳的候选（全部跨 0）⇒ 基因组不变"
    }
    # 【2026-10-03】账本要能回答"这一轮之后冠军是谁、它的权重长什么样" ⇒ 记 sha12（目标③：可审计、可回退）。
    $ledger_row = [ordered]@{ round = $r; seed = $Seed; max_seeds = $MaxSeeds; run = $tag
                              control_n = $(if ($v) { $v.n_control } else { 0 })
                              arms = $(if ($v) { $v.arms } else { $null })
                              winner = $winner; adopted = $adopted; why = $why
                              champion_sha12 = (Get-Sha12 $weights)
                              genome_sha12 = (Get-Sha12 $genome)
                              when = (Get-Date -Format 's') }
    ($ledger_row | ConvertTo-Json -Depth 8 -Compress) | Add-Content $ledger -Encoding UTF8
}
Write-Output "===== 自进化结束 ====="
