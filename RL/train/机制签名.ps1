# 机制签名.ps1 —— 【2026-09-18 新增】除胜率之外，看"结构指标"有没有变。
#
# 为什么要有它：用户第 2/3 条要的是"最优平衡 / 分摊 / 保核心 / 肉盾抗伤"，这些**未必先体现在胜率上**
#   （192 局的胜率分辨力只有 ±7 个百分点），但一定会先体现在**局内结构**上：
#     · 我方阵亡数（`TERMINAL_W` 该压它；`RISK_W` 该压它）
#     · "零死亡取胜"的局数（AI 毫发无伤地赢 —— 这正是"分摊+肉盾"做对了的样子）
#     · "被剃光头"的局数（我方 3 人全灭 = 判负；`TERMINAL_W` 该显著压它）
#     · 平均回合数（保守/激进会改变战斗长度）
#     · 平均剩余血量差（换血划不划算）
#
# 口径：只取 `a_side=1` 的行（= 候选 AI 的视角；同一局另一行 a_side=0 是玩家的视角，重复）。
#   `res` 是候选视角的胜负；`killsA/killsB` = A/B 两侧各击杀了几人 ⇒ 候选阵亡 = killsB。
#
# 用法：
#   & RL\train\机制签名.ps1 -Runs mechA,mechC,mechD,mechE -Control m0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Runs,
    [Parameter(Mandatory = $false)][string]$Control = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> 项目根
$resRoot = Join-Path $root 'RL\train\results'

function Get-Rows([string]$run) {
    $csv = Join-Path (Join-Path $resRoot $run) 'measure.csv'
    if (-not (Test-Path $csv)) { return @() }
    return @(Import-Csv $csv | Where-Object { [string]$_.a_side -eq '1' })
}

$all = @()
foreach ($r in $Runs) {
    $rows = Get-Rows $r
    if ($rows.Count -eq 0) { Write-Host ("[skip] " + $r + " 无 measure.csv（或还没 merge）"); continue }
    foreach ($cfg in ($rows | Group-Object config)) {
        $g = @($cfg.Group)
        $mineDead = @($g | ForEach-Object { [int]$_.killsB })
        $foeDead  = @($g | ForEach-Object { [int]$_.killsA })
        $rounds   = @($g | ForEach-Object { [int]$_.rounds })
        $hpDiff   = @($g | ForEach-Object { [double]$_.hpA - [double]$_.hpB })
        $wins     = @($g | Where-Object { $_.res -eq 'W' })
        $zero     = @($g | Where-Object { $_.res -eq 'W' -and [int]$_.killsB -eq 0 })
        $wipe     = @($g | Where-Object { [int]$_.killsB -ge 3 })
        $all += [pscustomobject]@{
            Run = $r; Arm = $cfg.Name; N = $g.Count
            WinRate = [Math]::Round($wins.Count / [double]$g.Count, 4)
            MyDead = [Math]::Round(($mineDead | Measure-Object -Average).Average, 3)
            FoeDead = [Math]::Round(($foeDead | Measure-Object -Average).Average, 3)
            ZeroDeathWin = [Math]::Round($zero.Count / [double]$g.Count, 4)
            Wiped = [Math]::Round($wipe.Count / [double]$g.Count, 4)
            Rounds = [Math]::Round(($rounds | Measure-Object -Average).Average, 1)
            HpDiff = [Math]::Round(($hpDiff | Measure-Object -Average).Average, 2)
        }
    }
}
if ($all.Count -eq 0) { throw '机制签名: 没有可用的行' }

Write-Host ''
Write-Host '== 逐队逐臂（a_side=1 视角）=='
$all | Sort-Object Arm, Run | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

Write-Host '== 跨队汇总（按臂等权平均；括号里是各队取值）=='
$agg = $all | Group-Object Arm | ForEach-Object {
    $g = $_.Group
    [pscustomobject]@{
        Arm = $_.Name
        Teams = $g.Count
        WinRate = [Math]::Round((($g | Measure-Object WinRate -Average).Average), 4)
        MyDead = [Math]::Round((($g | Measure-Object MyDead -Average).Average), 3)
        FoeDead = [Math]::Round((($g | Measure-Object FoeDead -Average).Average), 3)
        ZeroDeathWin = [Math]::Round((($g | Measure-Object ZeroDeathWin -Average).Average), 4)
        Wiped = [Math]::Round((($g | Measure-Object Wiped -Average).Average), 4)
        Rounds = [Math]::Round((($g | Measure-Object Rounds -Average).Average), 1)
        HpDiff = [Math]::Round((($g | Measure-Object HpDiff -Average).Average), 2)
        PerTeam = (($g | Sort-Object Run | ForEach-Object { ('{0}:{1}' -f $_.Run, $_.WinRate) }) -join ' ')
    }
} | Sort-Object Arm
$agg | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

if ($Control) {
    Write-Host ('== 相对控制臂 ' + $Control + ' 的结构差（正 = 比控制臂好）==')
    $c = $agg | Where-Object { $_.Arm -eq $Control }
    if ($c) {
        $agg | Where-Object { $_.Arm -ne $Control } | ForEach-Object {
            [pscustomobject]@{
                Arm = $_.Arm
                dWinRate = [Math]::Round($_.WinRate - $c.WinRate, 4)
                dMyDead = [Math]::Round($_.MyDead - $c.MyDead, 3)
                dFoeDead = [Math]::Round($_.FoeDead - $c.FoeDead, 3)
                dZeroDeathWin = [Math]::Round($_.ZeroDeathWin - $c.ZeroDeathWin, 4)
                dWiped = [Math]::Round($_.Wiped - $c.Wiped, 4)
                dRounds = [Math]::Round($_.Rounds - $c.Rounds, 1)
                dHpDiff = [Math]::Round($_.HpDiff - $c.HpDiff, 2)
            }
        } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    } else {
        Write-Host ('[warn] 控制臂 ' + $Control + ' 不在结果里')
    }
}
