# 修复引擎 v4:补回被吞的闭合引号/括号,并逐行词法校验
# 输入 src/Battle.gd.repaired(v3 输出) → 输出 src/Battle.gd.v4
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\Battle.gd.repaired",[System.Text.Encoding]::UTF8)

function Fix-Quotes($line){
  # 扫描:跳过注释(# 起,到行尾),只处理注释外的代码区;统计 " 数量,若奇数,
  # 说明字符串未闭合 → 在行尾前补一个 " (常见于 action_info.emit("...)) 场景,原始以 ...!" ) 结尾)
  $code=''
  $inStr=$false
  for($i=0;$i -lt $line.Length;$i++){
    $ch=$line[$i]
    if($ch -eq '#'){ break }          # 注释:忽略其后内容
    $code += $ch
  }
  # 统计注释外引号
  $quotes=@()
  for($i=0;$i -lt $code.Length;$i++){ if($code[$i] -eq '"'){ $quotes+=$i } }
  if(($quotes.Count % 2) -eq 1){
    # 字符串未闭合:在行尾(code 区末尾,即注释前)补 '"'
    $insPos=$code.Length
    $newCode=$code.Substring(0,$insPos)+'"'
    $newLine=$newCode+$line.Substring($code.Length)
    return $newLine
  }
  return $line
}

$out=New-Object System.Collections.Generic.List[string]
$fixed=0
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $t=$l.Trim()
  if($t.Length -gt 0 -and -not $t.StartsWith('#')){
    $r=Fix-Quotes $l
    if($r -ne $l){ $fixed++ }
    $l=$r
  }
  $out.Add($l)
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.v4",$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("quote-fixed lines: "+$fixed+"  total: "+$out.Count)