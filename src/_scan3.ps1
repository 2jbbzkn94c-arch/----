# 近似语法自检(对修复后的 Battle.gd)
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines((Join-Path $src 'Battle.gd'),[System.Text.Encoding]::UTF8)
$issues=New-Object 'System.Collections.Generic.List[string]'

# 跨行括号深度跟踪(字符串/注释感知)
$depth=0
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $inS=$false;$com=$false
  for($j=0;$j -lt $l.Length;$j++){
    $c=$l[$j]
    if($com){break}
    if($c -eq '"'){ $inS=-not $inS; continue }
    if($c -eq '#' -and -not $inS){ $com=$true; continue }
    if(-not $inS){
      if($c -eq '('){$depth++}
      elseif($c -eq ')'){$depth--}
      elseif($c -eq '['){$depth+=5}
      elseif($c -eq ']'){$depth-=5}
      if($depth -lt 0){
        $issues.Add(("BAL L{0} depth={1}: {2}" -f ($i+1),$depth,$l.Substring(0,[Math]::Min(120,$l.Length))))
        $depth=0
      }
    }
  }
}
Write-Output ("negative-depth lines: "+($issues|Where-Object{$_ -like 'BAL*'}).Count)
# 行首合法性:非注释/空行,行首(去缩进)必须是 关键字/标识符/#/)/]/符号 等
$badstart=0
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]; $t=$l.Trim()
  if($t.Length -eq 0){continue}
  if($t -match '^[\uFF08\uFF09\uFF0C\uFF1B\uFF1A\uFF0E\u3001\uFF0F\uFF1F\uFF01\uFF08]'){ $badstart++; $issues.Add(("ILLEGAL-START L{0}: {1}" -f ($i+1),$l.Substring(0,[Math]::Min(130,$l.Length)))) }
}
Write-Output ("illegal CJK punctuation line starts: "+$badstart)
$issues | Where-Object { $_ -notlike 'BAL*' } | Select-Object -First 30 | ForEach-Object { Write-Output $_ }
Write-Output ("total issue lines listed: "+$issues.Count)