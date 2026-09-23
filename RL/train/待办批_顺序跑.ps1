# 依次跑「待办 B 类」剂量批 —— 先等前一个批（默认 poison / T25）跑完，再逐个模式串行跑。
# 为什么串行：`难度体检` 每次开 6 个 Godot worker 已经把机器吃满，两个批并行只会互相拖慢、
#   而且两批都写 `RL\train\results` ⇒ 读数会互相污染。
# 用法：& RL\train\待办批_顺序跑.ps1            # 跑默认那 7 个模式
#       & RL\train\待办批_顺序跑.ps1 -Modes dedup,shield
# 每个模式的完整输出同时存到 RL\train\results\chain_<模式>.log（方便事后 grep 汇总表）。
param(
    [string[]]$Modes = @('dedup', 'shield', 'taunt', 'apply', 'split', 'spread', 'hpacc'),
    [string]$WaitFor = 'ladder6_pois2_L6PO',   # 等这个 run 的 measure.csv 出现（= 前一批最后一组跑完）
    [int]$WaitMaxMin = 210
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$res = Join-Path $root 'RL\train\results'
$t0 = Get-Date
Write-Host ('[chain] 启动 ' + $t0.ToString('HH:mm:ss') + ' · 等 `' + $WaitFor + '` 的 measure.csv，最多等 ' + $WaitMaxMin + ' 分钟')
$stall = $t0
while ($true) {
    if (Test-Path (Join-Path $res ($WaitFor + '\measure.csv'))) { Write-Host '[chain] 前一批已完成 ✓'; break }
    if (((Get-Date) - $t0).TotalMinutes -gt $WaitMaxMin) { Write-Host '[chain] ⚠️ 等待超时 ⇒ 直接开始（前一批可能已死）'; break }
    # 兜底：结果目录 10 分钟没有任何写入 ⇒ 判定前一批已停
    $cut = (Get-Date).AddMinutes(-10)
    $w = @(Get-ChildItem (Join-Path $res 'ladder6_pois2_*') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $cut })
    if ($w.Count -eq 0 -and (Test-Path (Join-Path $res 'ladder6_pois2_L1PO\measure.csv'))) {
        if (((Get-Date) - $stall).TotalMinutes -gt 10) { Write-Host '[chain] ⚠️ 前一批 10 分钟无写入 ⇒ 判定已停，直接开始'; break }
    } else { $stall = Get-Date }
    Start-Sleep -Seconds 60
}
foreach ($m in $Modes) {
    $tag = 'b' + $m
    $log = Join-Path $res ('chain_' + $m + '.log')
    Write-Host ('[chain] ===== 开始 -Mode ' + $m + ' -Tag ' + $tag + '  @ ' + (Get-Date).ToString('HH:mm:ss') + ' =====')
    & (Join-Path $PSScriptRoot '难度体检.ps1') -Mode $m -Tag $tag *>&1 | Tee-Object -FilePath $log | Out-Null
    Write-Host ('[chain] ===== 结束 -Mode ' + $m + '  @ ' + (Get-Date).ToString('HH:mm:ss') + '（输出：' + $log + '）=====')
}
Write-Host ('[chain] 全部模式跑完 @ ' + (Get-Date).ToString('HH:mm:ss'))