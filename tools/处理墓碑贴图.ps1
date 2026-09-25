# 处理墓碑贴图.ps1 —— 把用户提供的原图处理成棋盘素材（口径与 金矿 / 障碍 / 地块 一致：去白底透明化 + 裁到图案边界）
#   输入：assets\美术资源\墓碑_原图.jpg（384×324，白底 + 右下角"豆包AI生成"水印；2026-09-25 换成带花与土的版本）
#   输出：assets\美术资源\墓碑.png（32 位带 alpha）
#   做法：**从四边洪水填充"亮度 ≥ 205"的像素 ⇒ alpha = 0**，然后裁到不透明像素的边界。
#     · 为什么用洪水填充而不是"亮度阈值一把切"：碑面/花瓣上的浅色高光被黑描边围住、填充到不了 ⇒ 不会被打成半透明。
#     · 阈值取 205（而不是只切纯白）：右下角那行"豆包AI生成"是**浅灰字（亮度 224~250）**，压在花瓣与泥土右侧；
#       若只切纯白，它会整行留在图里 ⇒ 205 这档正好把它连同白边一起吃掉，而不会碰到深色描边与泥土。
#     · 实测：384×324 的水印原图 ⇒ 裁框 (52,13)-(334,310) = **283×298**，水印整行被去掉（右下角采样 alpha=0）。
#   若以后换回没有水印的原图，本脚本同样适用（205 只会多去掉一圈白边，视觉上更干净）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tools\处理墓碑贴图.ps1
#   ⚠️ 控制台会刷一大片 True/False —— 那是 PowerShell 把循环里的布尔结果打到**成功流**上的老毛病，**无害**；
#      只看最后两行 `[处理] …` 即可，想干净就加 `| Out-Null`（`Write-Host` 的两行照样打印）。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'assets\美术资源\墓碑_原图.jpg'
$dst = Join-Path $root 'assets\美术资源\墓碑.png'
$THRESH = 205         # **亮度** >= 这个值 = "背景/水印" ⇒ 透明
#   为什么用亮度而不是"三通道最小值 ≥ 215"：水印是浅灰字，JPEG 色度会让某个通道掉到 215 以下 ⇒ 只看最小值会把它漏掉。
#   ⚠️ 别把它命名成 `$LIGHT`：PowerShell 变量名**大小写不敏感**，会和下面的掩码数组 `$light` 撞成同一个变量
#      （第一次写就是这么踩的：`$light` 一赋值，比较式里的 `$LIGHT` 也变成了数组 ⇒ 报"Boolean[] 不能转 Byte"）。
if (-not (Test-Path $src)) { throw ('找不到原图：' + $src) }

$bmp = [System.Drawing.Bitmap]::FromFile($src)
$w = $bmp.Width; $h = $bmp.Height
$rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
$bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $bd.Stride
$buf = New-Object byte[] ($stride * $h)
[System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
$bmp.UnlockBits($bd); $bmp.Dispose()

# ① 洪水填充（从四边）——直接把背景的 alpha 写成 0
$light = New-Object bool[] ($w * $h)
for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
        $i = $y * $stride + $x * 4
        # ⚠️ 数组元素赋值（`$arr[$i] = v`）在 PowerShell 里**会把值输出到管道**（12 万个 True/False 刷屏）
        #   ⇒ 这里用 .NET 的 `SetValue()`（返回 void）代替下标赋值。
        $light.SetValue(((0.299 * $buf[$i + 2]) + (0.587 * $buf[$i + 1]) + (0.114 * $buf[$i]) -ge $THRESH), $y * $w + $x)
    }
}
$seen = New-Object bool[] ($w * $h)
$stack = New-Object System.Collections.Generic.Stack[int]
for ($x = 0; $x -lt $w; $x++) {
    if ($light[$x]) { $stack.Push($x) }
    if ($light[($h - 1) * $w + $x]) { $stack.Push(($h - 1) * $w + $x) }
}
for ($y = 0; $y -lt $h; $y++) {
    if ($light[$y * $w]) { $stack.Push($y * $w) }
    if ($light[$y * $w + $w - 1]) { $stack.Push($y * $w + $w - 1) }
}
$painted = 0
while ($stack.Count -gt 0) {
    $p = $stack.Pop()
    if ($seen[$p]) { continue }
    [void]($seen[$p] = $true)
    $x = $p % $w; $y = [int](($p - $x) / $w)
    [void]($buf[($y * $stride) + ($x * 4) + 3] = 0)
    $painted++
    if ($x -gt 0) { $n = $p - 1; if (-not $seen[$n] -and $light[$n]) { $stack.Push($n) } }
    if ($x -lt $w - 1) { $n = $p + 1; if (-not $seen[$n] -and $light[$n]) { $stack.Push($n) } }
    if ($y -gt 0) { $n = $p - $w; if (-not $seen[$n] -and $light[$n]) { $stack.Push($n) } }
    if ($y -lt $h - 1) { $n = $p + $w; if (-not $seen[$n] -and $light[$n]) { $stack.Push($n) } }
}

# ② 裁到不透明像素的边界（+1px 余量）
$minx = $w; $maxx = -1; $miny = $h; $maxy = -1
for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
        if ($buf[($y * $stride) + ($x * 4) + 3] -ne 0) {
            if ($x -lt $minx) { $minx = $x }; if ($x -gt $maxx) { $maxx = $x }
            if ($y -lt $miny) { $miny = $y }; if ($y -gt $maxy) { $maxy = $y }
        }
    }
}
if ($maxx -lt 0) { throw '整张图都被判成背景了；把 $THRESH 调小再试' }
$cx0 = [Math]::Max(0, $minx - 1); $cy0 = [Math]::Max(0, $miny - 1)
$cx1 = [Math]::Min($w - 1, $maxx + 1); $cy1 = [Math]::Min($h - 1, $maxy + 1)
$cw = $cx1 - $cx0 + 1; $ch = $cy1 - $cy0 + 1

# ③ 写出 PNG
$out = New-Object System.Drawing.Bitmap $cw, $ch, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$od = $out.LockBits((New-Object System.Drawing.Rectangle 0, 0, $cw, $ch),
    [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$ostride = $od.Stride
$obuf = New-Object byte[] ($ostride * $ch)
for ($y = 0; $y -lt $ch; $y++) {
    for ($x = 0; $x -lt $cw; $x++) {
        $si = (($cy0 + $y) * $stride) + (($cx0 + $x) * 4)
        $di = ($y * $ostride) + ($x * 4)
        $obuf[$di] = $buf[$si]; $obuf[$di + 1] = $buf[$si + 1]; $obuf[$di + 2] = $buf[$si + 2]; $obuf[$di + 3] = $buf[$si + 3]
    }
}
[System.Runtime.InteropServices.Marshal]::Copy($obuf, 0, $od.Scan0, $obuf.Length)
$out.UnlockBits($od)
$out.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png)
$out.Dispose()
Write-Host ('[处理] 去背景像素 ' + $painted + ' / ' + ($w * $h) + '（阈值 ' + $LIGHT + '）')
Write-Host ('[处理] 裁框 = (' + $cx0 + ',' + $cy0 + ')-(' + $cx1 + ',' + $cy1 + ') ⇒ ' + $cw + 'x' + $ch + ' ⇒ ' + $dst)
