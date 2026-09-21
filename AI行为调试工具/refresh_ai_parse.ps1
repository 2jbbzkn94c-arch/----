# 一键刷新 AI 解析（由 一键刷新AI解析.bat 调用；也可直接右键"使用 PowerShell 运行"）
#
#   1) 角色列表.xlsx  ->  角色列表.json           （AI 运行时读的就是这份）
#   2) tools/生成解析体检.gd   ->  英雄相关/解析体检.txt
#   3) tools/生成协同解析.gd   ->  英雄相关/角色协同解析.txt（开头列出本次变化）
#
# 为什么要有这个 .ps1：Godot 的 --script 参数在 .bat 里传中文脚本名会被编码搞坏，
# 由 PowerShell 传同样的参数则正常，所以 bat 只负责把活交给这里。

param(
  [string]$Godot = ""   # 留空=自动找：桌面 godot.exe / 桌面 Godot*.exe / 文档里的 Godot 目录
)

# 引擎路径可能被移动/改名（如桌面 Godot_v4.7.1-stable_win64.exe → godot.exe），这里按候选依次找
function Resolve-GodotPath {
  $cands = @(
    (Join-Path $env:USERPROFILE 'Desktop\godot.exe'),
    (Join-Path $env:USERPROFILE 'Desktop\Godot_v4.7.1-stable_win64.exe'),
    (Join-Path $env:USERPROFILE 'Documents\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64.exe')
  )
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }
  $hit = Get-ChildItem (Join-Path $env:USERPROFILE 'Desktop') -Filter 'Godot*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($hit) { return $hit.FullName }
  return ''
}
if ([string]::IsNullOrWhiteSpace($Godot)) { $Godot = Resolve-GodotPath }

$ErrorActionPreference = 'Continue'
# 项目根目录：从本脚本所在目录往上找 project.godot —— 这样脚本放哪儿都能用
$root = $null
$probe = $PSScriptRoot
for ($i = 0; $i -lt 4 -and $probe; $i++) {
  if (Test-Path (Join-Path $probe 'project.godot')) { $root = $probe; break }
  $probe = Split-Path -Parent $probe
}
if (-not $root) {
  Write-Host "[错误] 从 $PSScriptRoot 往上找不到 project.godot，无法定位项目根目录。" -ForegroundColor Red
  exit 1
}
$heroDir = Join-Path $root '英雄相关'
$jsonPath = Join-Path $heroDir '角色列表.json'
$checkTxt = Join-Path $heroDir '解析体检.txt'
$synTxt   = Join-Path $heroDir '角色协同解析.txt'

function Show([string]$msg, [string]$color = 'Gray') {
  Write-Host $msg -ForegroundColor $color
}

Show "============================================================" 'Cyan'
Show "  一键刷新 AI 解析" 'Cyan'
Show "    1. 角色列表.xlsx  ->  角色列表.json" 'Cyan'
Show "    2. 解析体检.txt" 'Cyan'
Show "    3. 角色协同解析.txt（开头 = 本次变化）" 'Cyan'
Show "============================================================" 'Cyan'
Write-Host ""

if (-not (Test-Path $Godot)) {
  Show "[错误] 找不到 Godot：$Godot" 'Red'
  Show "请编辑本目录下的 refresh_ai_parse.ps1，把 `$Godot 改成实际路径。" 'Red'
  exit 1
}
if (-not (Test-Path $jsonPath)) {
  Show "[错误] 找不到 $jsonPath" 'Red'
  exit 1
}

# ---- 1/3 xlsx -> json ----
Show "[1/3] 从 角色列表.xlsx 生成 角色列表.json ..." 'Yellow'
$conv = Join-Path $heroDir '角色列表转Json.ps1'
if (Test-Path $conv) {
  $before = (Get-Item $jsonPath).LastWriteTime
  & powershell -NoProfile -ExecutionPolicy Bypass -File $conv | ForEach-Object { Write-Host "      $_" }
  $after = (Get-Item $jsonPath).LastWriteTime
  if ($after -gt $before) { Show "      OK：json 已更新（$after）" 'Green' }
  else { Show "      提示：json 时间戳没变（xlsx 可能没保存过改动）" 'DarkYellow' }
} else {
  Show "      [跳过] 没找到 $conv" 'DarkYellow'
}

# ---- 2/3 解析体检 ----
Write-Host ""
Show "[2/3] 生成 解析体检.txt ..." 'Yellow'
$t0 = (Get-Item $checkTxt).LastWriteTime
& $Godot --headless --path $root --script "res://tools/生成解析体检.gd" --log-file (Join-Path $root 'log\godot_check.log') 2>&1 |
  Where-Object { $_ -notmatch 'Failed to read the root certificate store|get_system_ca_certificates' } |
  ForEach-Object { Write-Host "      $_" }
$log = Join-Path $root 'log\godot_check.log'
if (Test-Path $log) { Remove-Item $log -Force }
$ok2 = (Get-Item $checkTxt).LastWriteTime -gt $t0
if ($ok2) { Show "      OK：解析体检.txt 已刷新" 'Green' } else { Show "      [失败] 解析体检.txt 没有更新" 'Red' }

# ---- 3/3 角色协同解析 ----
Write-Host ""
Show "[3/3] 生成 角色协同解析.txt ..." 'Yellow'
$t1 = (Get-Item $synTxt).LastWriteTime
& $Godot --headless --path $root --script "res://tools/生成协同解析.gd" --log-file (Join-Path $root 'log\godot_syn.log') 2>&1 |
  Where-Object { $_ -notmatch 'Failed to read the root certificate store|get_system_ca_certificates' } |
  ForEach-Object { Write-Host "      $_" }
$log = Join-Path $root 'log\godot_syn.log'
if (Test-Path $log) { Remove-Item $log -Force }
$ok3 = (Get-Item $synTxt).LastWriteTime -gt $t1
if ($ok3) { Show "      OK：角色协同解析.txt 已刷新（开头就是本次变化）" 'Green' } else { Show "      [失败] 角色协同解析.txt 没有更新" 'Red' }

# ---- 结果 ----
Write-Host ""
Show "完成：" 'Cyan'
Show "  $checkTxt"
Show "  $synTxt"
Show "  $(Join-Path $heroDir '协同解析快照.json')   （供下次对比用，可随时删）"
Write-Host ""
if ($ok2 -and $ok3) { Show "两份报告都已更新 √" 'Green' } else { Show "有步骤失败，请看上面的红字。" 'Red' }
Show "注意：游戏内的 AI 读的是 角色列表.json，改动要【重启游戏】才生效。" 'Yellow'
