# 配音整理.ps1 —— 台词表 -> Godot 用的 ogg + 索引 JSON（**不删文件、不改游戏代码**）
#
# 干什么：
#   ① 读 `Data/Voice/台词表.csv`（表头：id,英雄,事件,文本,情绪,音色,文件名）
#   ② 去 `-Src` 目录里找同名源音频（TTS 产出的 wav/mp3/flac…，文件名 = 该行的 `文件名` 或 `id`）
#   ③ 用仓库里自带的 ffmpeg 转成**单声道 opus/ogg** 落到 `-Out`（默认 assets/audio/voice）
#   ④ 生成 `Data/Voice/voice_index.json`（Godot 侧 `JSON.parse_string` 直接读）
#   ⑤ 打印：总句数 / 已就绪 / **缺哪些** / 目录里**多余**的文件（多余只提示，不删）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\配音整理.ps1                 # 正式跑
#   powershell -ExecutionPolicy Bypass -File tools\配音整理.ps1 -DryRun         # 只看清单，不转码不写索引
#   powershell -ExecutionPolicy Bypass -File tools\配音整理.ps1 -Src D:\tts\out # 换源目录
# 退出码：0 = 全部就绪；2 = 有缺句（方便串进批处理）

param(
	[string]$Table  = 'Data\Voice\台词表.csv',
	[string]$Src    = 'Data\Voice\源音频',
	[string]$Out    = 'assets\audio\voice',
	[string]$Index  = 'Data\Voice\voice_index.json',
	[string]$Ffmpeg = 'ffmpeg-9.0-full_build\bin\ffmpeg.exe',
	[int]$BitrateK  = 48,
	[switch]$DryRun,
	# 【2026-09-28】按英雄分子目录输出（= 现有约定 assets/音效/英雄音效_整理后/<英雄名>/）
	[switch]$HeroOut
)

$ErrorActionPreference = 'Stop'
# 所有相对路径都按**仓库根**（= 本脚本所在目录的上一级）解析，任何 cwd 下跑都一样
$root = Split-Path -Parent $PSScriptRoot
function Abs([string]$p) {
	if ([System.IO.Path]::IsPathRooted($p)) { return $p }
	return (Join-Path $root $p)
}

$tablePath = Abs $Table
$srcDir    = Abs $Src
$outDir    = Abs $Out
$indexPath = Abs $Index
$ffmpegExe = Abs $Ffmpeg

if (-not (Test-Path $tablePath)) { throw "找不到台词表：$tablePath" }
if (-not $DryRun -and -not (Test-Path $ffmpegExe)) { throw "找不到 ffmpeg：$ffmpegExe" }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
if (-not (Test-Path $srcDir)) { Write-Host "（提示）源音频目录还不存在：$srcDir —— TTS 产出丢这里即可" -ForegroundColor Yellow }

$rows = @(Import-Csv $tablePath -Encoding UTF8)
if ($rows.Count -eq 0) { throw "台词表里一行都没有：$tablePath" }

$srcExts = @('.wav', '.mp3', '.flac', '.m4a', '.aac', '.ogg', '.opus')
$seen    = @{}
$okList  = New-Object System.Collections.ArrayList
$missing = New-Object System.Collections.ArrayList
$bad     = New-Object System.Collections.ArrayList

foreach ($r in $rows) {
	$id = ([string]$r.id).Trim()
	if ($id -eq '') { [void]$bad.Add('（有一行 id 是空的）'); continue }
	if ($seen.ContainsKey($id)) { [void]$bad.Add("$id（id 重复，已跳过后面这条）"); continue }
	$seen[$id] = $true
	$file = ([string]$r.文件名).Trim()
	if ($file -eq '') { $file = $id }
	$text = ([string]$r.文本).Trim()
	if ($text -eq '') { [void]$bad.Add("$id（文本是空的）") }

	# 找源音频：优先 <文件名>，其次 <id>
	$srcFile = $null
	foreach ($base in @($file, $id)) {
		foreach ($ext in $srcExts) {
			$cand = Join-Path $srcDir ($base + $ext)
			if (Test-Path $cand) { $srcFile = $cand; break }
		}
		if ($srcFile -ne $null) { break }
	}
	if ($HeroOut) {
		$sub = Join-Path $outDir ([string]$r.英雄).Trim()
		if (-not (Test-Path $sub)) { New-Item -ItemType Directory -Force -Path $sub | Out-Null }
		$target = Join-Path $sub ($file + '.ogg')
	} else {
		$target = Join-Path $outDir ($file + '.ogg')
	}
	if ($srcFile -eq $null) {
		[void]$missing.Add($id)
		continue
	}
	if (-not $DryRun) {
		$args = @('-y', '-loglevel', 'error', '-i', $srcFile, '-ac', '1', '-ar', '48000',
			'-c:a', 'libopus', '-b:a', "$($BitrateK)k", $target)
		& $ffmpegExe @args
		if ($LASTEXITCODE -ne 0) { [void]$bad.Add("$id（ffmpeg 转码失败）"); continue }
	}
	[void]$okList.Add([pscustomobject]@{
		id = $id; hero = ([string]$r.英雄).Trim(); event = ([string]$r.事件).Trim()
		text = $text; mood = ([string]$r.情绪).Trim(); voice = ([string]$r.音色).Trim()
		path = 'res://' + ($target.Substring($root.Length + 1).Replace('\', '/'))
	})
}

# 目录里多余的文件（表里没登记）：只提示
$extra = @()
if (Test-Path $outDir) {
	$known = @{}
	foreach ($o in $okList) { $known[(Split-Path -Leaf $o.path)] = $true }
	$extra = @(Get-ChildItem $outDir -File -Recurse -Filter *.ogg | Where-Object { -not $known.ContainsKey($_.Name) } |
		Select-Object -ExpandProperty Name)
}

# 索引 JSON（无 BOM：Godot JSON.parse_string 最省事）
if (-not $DryRun) {
	$lines = [ordered]@{}
	foreach ($o in $okList) {
		$lines[$o.id] = [ordered]@{
			hero = $o.hero; event = $o.event; text = $o.text; mood = $o.mood
			voice = $o.voice; path = $o.path
		}
	}
	$doc = [ordered]@{
		_说明 = '由 tools/配音整理.ps1 自动生成，别手改；改台词请改 Data/Voice/台词表.csv'
		_生成时间 = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
		lines = $lines
	}
	$json = $doc | ConvertTo-Json -Depth 6
	[System.IO.File]::WriteAllText($indexPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ---- 汇总 ----
Write-Host ''
Write-Host ("台词表：{0} 行（唯一 id {1} 个）" -f $rows.Count, $seen.Count)
Write-Host ("已就绪：{0} 句" -f $okList.Count) -ForegroundColor Green
if ($missing.Count -gt 0) {
	Write-Host ("缺音频：{0} 句 —— {1}" -f $missing.Count, ($missing -join '、')) -ForegroundColor Yellow
}
if ($bad.Count -gt 0) {
	Write-Host ("有问题的行：{0}" -f ($bad -join '；')) -ForegroundColor Red
}
if ($extra.Count -gt 0) {
	Write-Host ("目录里多余（表里没登记，没动它）：{0}" -f ($extra -join '、')) -ForegroundColor DarkYellow
}
if ($DryRun) { Write-Host '（-DryRun：没有转码、没有写索引）' -ForegroundColor DarkGray }
else { Write-Host ("索引：{0}（{1} 条）" -f $indexPath, $okList.Count) }

if ($missing.Count -gt 0 -or $bad.Count -gt 0) { exit 2 }
exit 0
