# v8:改进引号闭合。输入 Battle.gd.v7 → Battle.gd.v8
# 未闭合字符串判定:代码区(注释外)引号奇数。
# 闭合位置选择:
#   1) 若字符串内容后存在 " % "(格式串)→ 在 % 前闭合(最可靠)。
#   2) 否则在行尾(或注释前)闭合。
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\Battle.gd.v7",[System.Text.Encoding]::UTF8)

function Get-QuoteState($line){
  # return code-length (pos of first '#' outside string, or line length)
  $inS=$false
  for($i=0;$i -lt $line.Length;$i++){
    $ch=$line[$i]
    if($ch -eq '"'){ $inS=-not $inS; continue }
    if($ch -eq '#' -and -not $inS){ return @{end=$i; open=$inS} }
  }
  return @{end=$line.Length; open=$inS}
}

$out=New-Object System.Collections.Generic.List[string]
$fixed=0
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $st=Get-QuoteState $l
  if(-not $st.open){ $out.Add($l); continue }
  # 未闭合。找内容中的 " % "(空格百分号空格)的最后一次出现
  $codeEnd=$st.end
  $contentEnd=0  # 字符串内容区末尾(不含闭合引号)
  # 找最后一个 " % " 或 " %"
  $pct=-1
  for($j=0;$j -lt $codeEnd;$j++){
    if($l[$j] -eq '%'){ $pct=$j }
  }
  # 插入位置:若有 % 且其后是 ' ' 或行尾边界,闭合于 % 前;否则行尾
  if($pct -ge 0){
    # 确认是格式用法: % 前应有空格,或直接 ' % ['/' % ident'/' % game'
    $insert=$pct
  } else {
    $insert=$codeEnd
  }
  $new=$l.Substring(0,$insert)+'"'+$l.Substring($insert)
  $out.Add($new); $fixed++
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.v8",$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v8 fixed quotes: "+$fixed)