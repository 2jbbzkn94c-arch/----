# 自动同步：监听 角色列表.xlsx 变化 -> 自动生成 角色列表.json
# Excel 打开时也允许共享读取,XLSX 一保存即转换(即使 Excel 还开着)。
param([string]$ProjectRoot = "D:\Game creating\战旗")

$src = Join-Path $ProjectRoot "角色列表.xlsx"
$conv = Join-Path $ProjectRoot "tools\角色列表转Json.ps1"
$last = [datetime]::MinValue

Write-Host "自动同步已启动：修改并保存 角色列表.xlsx 即自动生成 角色列表.json"
Write-Host "关闭此窗口停止监听。Ctrl+C 亦可。"

while ($true) {
  Start-Sleep -Seconds 2
  if (-not (Test-Path $src)) {
    $last = [datetime]::MinValue
    continue
  }
  try { $lw = (Get-Item $src).LastWriteTime } catch { continue }
  if ($lw -eq $last) { continue }

  # 用共享读探测:Excel 打开时也可读(不再死等解锁)
  $canRead = $false
  try {
    $fs = [System.IO.File]::Open($src, 'Open', 'Read', [System.IO.FileShare]::ReadWrite)
    $fs.Close()
    $canRead = $true
  } catch {
    $canRead = $false
  }

  if ($canRead) {
    $ok = $true
    try {
      powershell -NoProfile -ExecutionPolicy Bypass -File $conv | Out-Null
    } catch {
      $ok = $false
    }
    if ($ok) {
      Write-Host ("[" + (Get-Date -Format HH:mm:ss) + "] 已同步 -> 角色列表.json")
      $last = $lw
    } else {
      Start-Sleep -Seconds 2   # 转换异常:下次再试(不推进)
    }
  } else {
    Start-Sleep -Seconds 1     # 暂时读不到:稍后重试
  }
}
