# v6 自检:扫描 v4a 修复文件,列出高概率结构错误行,供人工复核
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\Battle.gd.v4a",[System.Text.Encoding]::UTF8)
$bad=[char]0xFFFD; $q=[char]0x3F
$issues=New-Object System.Collections.Generic.List[string]

# A) 一行含两个顶层声明/两条语句:检测行内有 'var ' 或 'signal ' 出现两次且不在注释内
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $t=$l.Trim()
  if($t.Length -eq 0 -or $t.StartsWith('#')){ continue }
  # 去注释
  $code=$l; $hash=$code.IndexOf('#'); if($hash -ge 0){ $code=$code.Substring(0,$hash) }
  # 粗略数语句起点(在缩进之后出现)
  $starts=[regex]::Matches($code,'(^|[^A-Za-z0-9_])(var|const|signal|func|return|break|continue|if |for |while )\s')
  if($starts.Count -ge 2){
    $issues.Add(("A L{0} multistmt: {1}" -f ($i+1),$l.Substring(0,[Math]::Min(150,$l.Length))))
  }
}
# B) 引号奇数(整行含注释外)
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $inS=$false;$com=$false;$n=0
  foreach($ch in $l.ToCharArray()){
    if($com){continue}
    if($ch -eq '"'){ $inS=-not $inS }
    if($ch -eq '#' -and -not $inS){ $com=$true }
  }
  if($inS){ $issues.Add(("B L{0} openquote: {1}" -f ($i+1),$l.Substring(0,[Math]::Min(150,$l.Length)))) }
}
# C) 括号不配平(代码区粗略,跳过注释)
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $inS=$false;$com=$false;$bal=0
  foreach($ch in $l.ToCharArray()){
    if($com){continue}
    if($ch -eq '"'){ $inS=-not $inS; continue }
    if($ch -eq '#' -and -not $inS){ $com=$true; continue }
    if(-not $inS){ if($ch -eq '('){$bal++}; if($ch -eq ')'){$bal--}; if($ch -eq '['){$bal+=2}; if($ch -eq ']'){$bal-=2} }
  }
  if($bal -ne 0){ $issues.Add(("C L{0} parenbal={1}: {2}" -f ($i+1),$bal,$l.Substring(0,[Math]::Min(150,$l.Length)))) }
}
[System.IO.File]::WriteAllLines("$src\_v6_issues.txt",$issues,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("issues found: "+$issues.Count)
$issues | Select-Object -First 120 | ForEach-Object { Write-Output $_ }