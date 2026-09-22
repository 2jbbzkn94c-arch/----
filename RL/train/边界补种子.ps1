# 边界补种子.ps1 —— 【2026-09-22 新增·用户拍板"② 档位边界补种子确认"】
#
# 干什么：切档线附近的候选，**换一个种子（= 换一张盘面）把 8 支对手再打一遍**，把新行**追加**进
#   原来那个 run 目录 ⇒ `队伍强度拟合.ps1` 会自动把这些候选的多局一起用掉（它按行聚合，不按格）。
#   为什么要它：每格原来只有 1 局、1 张盘面 ⇒ 一局翻转 = 12.5 个百分点；档位边界上最容易切错。
#
# 口径：
#   · 候选 = 拟合结果里的 `boundary`（切档线 ±N 名，见 `队伍强度拟合.ps1 -BoundaryBand`）；
#   · 每支候选 × 8 支对手（**沿用原 spec 里的牌组** —— 直接读 `spec_<Tag>_c###_o##.json`，
#     不重新推导，避免"对手换了"这种静默漂移）；
#   · 元数据：新种子 = `-SeedStart`（默认 70 ⇒ 与主批的 41~48 不重叠，换一张盘面）；
#     写在 `-RunTag`（默认 `<Tag>b`）的 run 名里 ⇒ 主批结果**一个字节都不动**。
#     之后用 `队伍强度拟合.ps1 -Tags <Tag>,<RunTag>` 把两批并起来算（它按行聚合、不按格）。
#   · 【2026-09-22 更正】原来这里写"同一个 run 名 ⇒ 新种子会追加"，**当时并不成立**：
#     `cand_<run>_<cfg>.json` 自带生成时间戳 ⇒ 文件 sha256 每次调用都变，而版本指纹闸门比的
#     就是它 ⇒ 重入会把该 run 已有行全判成"另一版本"丢掉（实测：那 80 格的旧行被删、只剩新种子）。
#     现在闸门已改成"sha12 不同时再看**语义指纹** `weights_fp`"（跨调用稳定）⇒ 换 run 名依旧是最
#     稳的口径，但即使同 run 重入也不会再无脑全量重测。
# 用法：
#   & RL\train\边界补种子.ps1 -FitJson RL\train\results\_fit_pool3.json -Tag pool3 -RunTag pool3b -SeedStart 70
[CmdletBinding()]
param(
    [string]$FitJson = 'RL\train\results\_fit_pool3.json',
    [string]$Tag = 'pool3',
    [int]$SeedStart = 70,
    [int]$Groups = 8,
    [int]$MaxSlots = 8,
    [int]$Band = 0,                 # >0 时覆盖：取切档线 ±Band 名（默认用拟合结果里已有的 boundary）
    # ⚠️【2026-09-22】补种子默认写到**新的 run 名**（`<Tag>b`）：与主批的测量在物理上分开，
    #   谁也不会覆盖谁；拟合时用 `-Tags a,b` 合并。见文件头关于"时间戳 sha 导致全量重测"的更正。
    [string]$RunTag = '',
    [string]$BaseWeights = 'RL\weights\噩梦.json',
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
if (-not $RunTag) { $RunTag = $Tag + 'b' }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$results = Join-Path $PSScriptRoot 'results'
$env:RL_SLOT_MAX = [string][Math]::Max(1, $MaxSlots)
$env:RL_SLOT_SLEEP_S = '5'
$fitPath = if ([System.IO.Path]::IsPathRooted($FitJson)) { $FitJson } else { Join-Path $root $FitJson }
if (-not (Test-Path $fitPath)) { throw ('找不到拟合结果：' + $fitPath) }
$fit = Get-Content $fitPath -Raw -Encoding UTF8 | ConvertFrom-Json

# 候选列表：默认用 boundary；`-Band` 覆盖时按名次重新算边界带
$idxList = @($fit.boundary | ForEach-Object { [int]$_.idx } | Sort-Object -Unique)
if ($Band -gt 0) {
    $all = @($fit.candidates | Sort-Object rank)
    $n = $all.Count
    $n3 = [int][Math]::Floor($n / 3)
    $idxList = @()
    foreach ($c in @($n3, (2 * $n3))) {
        for ($i = [Math]::Max(0, $c - $Band); $i -le [Math]::Min($n - 1, $c + $Band); $i++) { $idxList += [int]$all[$i].idx }
    }
    $idxList = @($idxList | Sort-Object -Unique)
}
if ($idxList.Count -eq 0) { throw '边界带为空（拟合结果里没有 boundary，且没给 -Band）' }
Write-Host ('[补种子] 边界候选 {0} 支：{1}' -f $idxList.Count, (($idxList | ForEach-Object { 'C{0:D3}' -f $_ }) -join ' '))

# 组装每一格：沿用原 spec 的牌组（读出来当"事实"）
$cells = @()
foreach ($idx in $idxList) {
    for ($o = 1; $o -le 8; $o++) {
        $srcRun = '{0}_c{1:D3}_o{2:D2}' -f $Tag, $idx, $o          # 源 spec（读牌组）
        $run = '{0}_c{1:D3}_o{2:D2}' -f $RunTag, $idx, $o          # 新 run 名（写结果）
        $specPath = Join-Path $PSScriptRoot ('spec_{0}.json' -f $srcRun)
        if (-not (Test-Path $specPath)) { Write-Host ('[补种子] !! 缺 spec：' + $specPath + ' ⇒ 跳过'); continue }
        $sp = Get-Content $specPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cells += [ordered]@{
            run = $run; a = $idx; b = (1000 + $o)
            enemy = $idx; player = (1000 + $o)
            deckEnemy = [string]$sp.decks.enemy; deckPlayer = [string]$sp.decks.player
            seedIndex = $SeedStart
        }
    }
}
Write-Host ('[补种子] 待跑 {0} 格（种子 index {1} ⇒ 换一张盘面）' -f $cells.Count, $SeedStart)
if ($PlanOnly) { Write-Host '[补种子] -PlanOnly：只列计划，不跑'; exit 0 }

# 分块并行（同一套：每块一个 _瑞士轮单批.ps1 子进程串行跑；轮间不需要同步，一次跑完即可）
$chunks = @(); for ($g = 0; $g -lt $Groups; $g++) { $chunks += , @() }
for ($i = 0; $i -lt $cells.Count; $i++) { $chunks[$i % $Groups] += , $cells[$i] }
$worker = Join-Path $PSScriptRoot '_瑞士轮单批.ps1'
$kids = @()
for ($g = 0; $g -lt $Groups; $g++) {
    if ($chunks[$g].Count -eq 0) { continue }
    $planPath = Join-Path $results ('_bandplan_{0}_s{1}_g{2:D2}.json' -f $Tag, $SeedStart, ($g + 1))
    [System.IO.File]::WriteAllText($planPath, (($chunks[$g] | ConvertTo-Json -Depth 8)), (New-Object System.Text.UTF8Encoding($false)))
    $argline = '-NoProfile -ExecutionPolicy Bypass -File "' + $worker + '" -Plan "' + $planPath + '" -Beam 100 -BaseWeights "' + $BaseWeights + '"'
    $kids += Start-Process -FilePath 'powershell' -ArgumentList $argline -PassThru -WindowStyle Hidden
}
Write-Host ('[补种子] 起了 {0} 个子进程，等齐…' -f $kids.Count)
$t0 = Get-Date
while ($true) {
    $alive = @($kids | Where-Object { Get-Process -Id $_.Id -ErrorAction SilentlyContinue })
    if ($alive.Count -eq 0) { break }
    Start-Sleep -Seconds 60
    Write-Host ('[补种子]   还剩 {0}/{1} 个子进程（已 {2:N1} 分钟）' -f $alive.Count, $kids.Count, ((Get-Date) - $t0).TotalMinutes)
}
Write-Host ('[补种子] 完成（{0:N1} 分钟）⇒ 重新跑一次 队伍强度拟合.ps1 即可把新行算进去' -f ((Get-Date) - $t0).TotalMinutes)
