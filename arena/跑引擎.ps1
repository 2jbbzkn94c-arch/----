# 跑引擎.ps1 —— 起"竞技场外部引擎"（arena/ArenaEngine.tscn）的入口。
#
# 用法（先取得一次性令牌：竞技场网页 →「接入引擎」登记，规则版本选 tb-61ae4c19be4a4c1f）：
#   $env:ARENA_TOKEN = '粘进来的令牌'
#   & arena\跑引擎.ps1                       # 前台常驻，日志直接滚在控制台；Ctrl+C 停
#   & arena\跑引擎.ps1 -Tier 2 -Think 2500    # 换难度档 / 加思考上限
#   & arena\跑引擎.ps1 -Background            # 后台跑，日志写文件（返回文件路径与停止方法）
#
# 令牌只走环境变量（不写进命令行，免得进程列表/日志里留明文）。也可以直接 -Token 传，但会出现在命令行里。
#
# 参数：
#   -Token <str>      引擎令牌（缺省读 $env:ARENA_TOKEN，都没有就提示输入）
#   -Url <str>        API 基址（缺省 $env:ARENA_URL 或 https://tb.qiaohome.top:3333/api/arena/v1）
#   -Tier <int>       AI 难度 0=简单 1=普通 2=困难 3=噩梦（缺省 3）
#   -Think <int>      单次搜索上限毫秒（缺省 = 自动：按本局回合预算，60 秒局约 20 秒/手、120 秒局到 40 秒）
#   -Once             收到并确认一场结束通知后退出（冒烟用）
#   -MaxTasks <int>   最多处理 N 个决策任务后退出（冒烟用）
#   -Policy <str>     ai（默认）/ random（只验证连通性）
#   -Insecure         允许自签证书（TLS 握手失败时用）
#   -NoCachePlan      退回"每手都重搜"（排查用；默认走计划缓存 + 对不上就重搜）
#   -Stop             停掉正在跑的引擎（**只停 arena\引擎.pid 里那一个 PID**）
#   -Background       后台运行 + 写日志文件
[CmdletBinding()]
param(
    [string]$Token = '',
    [string]$Url = '',
    [int]$Tier = -1,
    [int]$Think = -1,
    [switch]$Once,
    [int]$MaxTasks = 0,
    [string]$Policy = '',
    [switch]$Insecure,
    [switch]$NoCachePlan,
    [switch]$Stop,
    [switch]$Background
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot          # arena -> 项目根
$pidFile = Join-Path $PSScriptRoot '引擎.pid'

# -Stop：**只停我们自己那一个**（PID 从 arena/引擎.pid 读，由引擎启动时自己写）。
# ⚠️ 绝不要写成"按进程名杀所有 headless Godot" —— 那会把用户自己起的探针/跑批/检视一起杀掉（已经犯过一次）。
if ($Stop) {
    if (-not (Test-Path -LiteralPath $pidFile)) { Write-Host '[竞技场引擎] 没有 arena\引擎.pid：引擎没在跑（或不是用本脚本起的）'; exit 0 }
    $target = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($target -notmatch '^\d+$') { Write-Host ('[竞技场引擎] pid 文件内容不对：' + $target); exit 1 }
    $proc = Get-Process -Id ([int]$target) -ErrorAction SilentlyContinue
    if ($proc) { Stop-Process -Id $proc.Id -Force; Write-Host ('[竞技场引擎] 已停：PID ' + $proc.Id + '（' + $proc.ProcessName + '）') }
    else { Write-Host ('[竞技场引擎] PID ' + $target + ' 已经不在了') }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    exit 0
}

function Find-GodotExe {
    foreach ($v in @($env:DSH_GODOT_EXE, $env:GODOT_EXE)) {
        if ($v -and (Test-Path -LiteralPath $v)) { return (Resolve-Path -LiteralPath $v).Path }
    }
    $roots = @("$env:USERPROFILE\Documents", "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", 'D:\Software', 'C:\', 'D:\')
    $hits = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $hits += @(Get-ChildItem -LiteralPath $r -Filter 'Godot*.exe' -File -ErrorAction SilentlyContinue)
        $hits += @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Filter 'Godot*.exe' -File -ErrorAction SilentlyContinue })
    }
    $cand = @($hits | Where-Object { $_.Name -notlike '*_console*' } | Sort-Object Name -Descending)
    if ($cand.Count -gt 0) { return $cand[0].FullName }
    return $null
}

$exe = Find-GodotExe
if (-not $exe) { throw '找不到 Godot 可执行文件；可用环境变量 DSH_GODOT_EXE 指定绝对路径。' }

# 令牌：参数 > 环境变量 > 交互输入（不回显）
$tok = $Token
if (-not $tok) { $tok = $env:ARENA_TOKEN }
if (-not $tok) {
    $sec = Read-Host -Prompt '粘贴引擎令牌（不回显）' -AsSecureString
    $tok = [System.Net.NetworkCredential]::new('', $sec).Password
}
if (-not $tok) { throw '没有令牌：先在竞技场网页「接入引擎」登记，拿到一次性令牌再跑。' }
$env:ARENA_TOKEN = $tok

if ($Url) { $env:ARENA_URL = $Url }
if ($Tier -ge 0) { $env:ARENA_TIER = [string]$Tier }
if ($Think -ge 0) { $env:ARENA_THINK_MS = [string]$Think }
if ($Policy) { $env:ARENA_POLICY = $Policy }
if ($Once) { $env:ARENA_ONCE = '1' }

$extra = @()
if ($MaxTasks -gt 0) { $extra += "--max-tasks=$MaxTasks" }
if ($Insecure) { $extra += '--insecure' }
if ($NoCachePlan) { $extra += '--no-cache-plan' }

# 每个实例一个独立 APPDATA：多开时不会争 user://logs（见 RL\train\跑Godot隔离.ps1 的说明）
$sand = Join-Path $env:TEMP ('dsh_arena_' + (Get-Random))
New-Item -ItemType Directory -Force -Path $sand | Out-Null
$env:APPDATA = $sand
$env:LOCALAPPDATA = $sand

$godotLog = Join-Path $sand 'godot.log'
# 令牌不进命令行（走环境变量，免得进程列表/日志留明文）
$argLine = @('--headless', '--path', "`"$root`"", '--scene', 'res://arena/ArenaEngine.tscn',
    '--log-file', "`"$godotLog`"", '--disable-crash-handler', '--') -join ' '
foreach ($e in $extra) { $argLine += ' ' + $e }

$baseShow = $env:ARENA_URL; if (-not $baseShow) { $baseShow = 'https://tb.qiaohome.top:3333/api/arena/v1' }
$tierShow = $env:ARENA_TIER; if (-not $tierShow) { $tierShow = '3' }
Write-Host '[竞技场引擎] 思考面板 = http://127.0.0.1:14330/ （浏览器打开看我方 AI 每一手在想什么）'
Write-Host ('[竞技场引擎] Godot = ' + $exe)
Write-Host ('[竞技场引擎] 基址 = ' + $baseShow + '｜难度档 = ' + $tierShow)

if ($Background) {
    $log = Join-Path $PSScriptRoot ('运行日志_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$exe`" $argLine > `"$log`" 2>&1" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Write-Host ('[竞技场引擎] 已在后台启动（cmd PID ' + $p.Id + '）')
    Write-Host ('[竞技场引擎] 日志：' + $log)
    Write-Host ('[竞技场引擎] 看日志： Get-Content -LiteralPath "' + $log + '" -Wait -Tail 30')
} else {
    Write-Host '[竞技场引擎] 前台运行中（Ctrl+C 停止）…'
    & cmd /c ('"' + $exe + '" ' + $argLine + ' 2>&1')
}
