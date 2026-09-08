# 自动同步：监听 角色列表.xlsx 变化 -> 自动生成 角色列表.json
# 保持此窗口运行；关闭窗口即停止监听。启动方式见 tools\启动自动同步.bat
param([string]$ProjectRoot = "D:\Game creating\战旗")

$src = Join-Path $ProjectRoot "角色列表.xlsx"
$conv = Join-Path $ProjectRoot "tools\角色列表转Json.ps1"
$last = [datetime]::MinValue

Write-Host "自动同步已启动：修改并保存 角色列表.xlsx 即可自动生成 角色列表.json"
Write-Host "关闭此窗口停止监听。Ctrl+C 亦可。"

while ($true) {
  Start-Sleep -Seconds 2
  if (-not (Test-Path $src)) {
    $last = [datetime]::MinValue
    continue
  }
  try { $lw = (Get-Item $src).LastWriteTime } catch { continue }
  if ($lw -eq $last) { continue }
  # 等文件可写(Excel 未锁定)再转换；最多等 ~16s
  $locked = $true
  $tries = 0
  while ($locked -and $tries -lt 20) {
    $locked = $false
    try {
      $fs = [System.IO.File]::Open($src, 'Open', 'Read', 'None')
      $fs.Close()
    } catch {
      $locked = $true
      Start-Sleep -Milliseconds 800
      $tries++
    }
  }
  if (-not $locked) {
    powershell -NoProfile -ExecutionPolicy Bypass -File $conv | Out-Null
    Write-Host ("[" + (Get-Date -Format HH:mm:ss) + "] 已同步 -> 角色列表.json")
    $last = $lw
  } else {
    # 一直锁着(可能正在编辑中)，下次再试
    $last = $lw
  }
}
