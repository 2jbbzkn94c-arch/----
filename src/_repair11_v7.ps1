# 修复引擎 v7:更稳健的拆行
# 输入 _probe2.txt → 输出 Battle.gd.v7
# 规则:
#  - 逐字符扫描,跟踪 字符串("")、注释(# 到行尾的“原行”)。
#  - 关键:在原文件里 '#' 注释永远终止于行尾。因此在损坏物理行里,
#    只要出现了一个“注释外”的 '#'(即它之前的 '#' 是真正的注释起点,且其前是代码或注释文本),
#    那么从这个 '#' 起到“下一个语句起点或下一个 '#'”之间的内容= 一条原注释行。
#    之后再出现的语句起点/新 '#' => 换行。
#  - 代码行的识别:片段(以缩进+关键字或标识符赋值/调用)可以开启新行。
# 简化实现:先按 标记 切片段,再逐片段分类。
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\_probe2.txt",[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD; $Q=[char]0x3F

function Test-StmtStart($t){
  if($t.StartsWith('#')){ return $true }
  if($t -match '^(var |const |func |signal |class |extends |enum |static |if |elif |else:|else |for |while |match |return |await |break|continue|pass|@)'){ return $true }
  if($t -match '^[A-Za-z_][A-Za-z0-9_]*\s*(\(|:=|=|\[|\.)'){ return $true }
  return $false
}

function Has-CommentedLinePart($s){
  # 是否存在一个注释外 '#'(即:不是字符串内的 '#');若有则其后必为注释文本直到原行尾
  $inS=$false
  foreach($ch in $s.ToCharArray()){
    if($ch -eq '"'){ $inS=-not $inS }
    elseif($ch -eq '#' -and -not $inS){ return $true }
  }
  return $false
}

# 找注释起点(注释外)与最后一段
$out=New-Object System.Collections.Generic.List[string]
$debug=New-Object System.Collections.Generic.List[string]
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  if(-not ($l.Contains($BAD) -or $l.Contains($Q))){ $out.Add($l); continue }
  # 前导缩进
  $lead=''
  for($j=0;$j -lt $l.Length;$j++){ $ch=$l[$j]; if($ch -eq "`t" -or $ch -eq ' '){ $lead+=$ch } else { break } }
  $body=$l.Substring($lead.Length)
  # 切片段于标记
  $frags=New-Object System.Collections.Generic.List[object]
  $sb=New-Object System.Text.StringBuilder
  foreach($ch in $body.ToCharArray()){
    if($ch -eq $BAD -or $ch -eq $Q){
      if($sb.Length){ $frags.Add(@{t=$sb.ToString()}); [void]$sb.Clear() }
    } else { [void]$sb.Append($ch) }
  }
  if($sb.Length){ $frags.Add(@{t=$sb.ToString()}) }

  # 重建逻辑行
  $rows=New-Object System.Collections.Generic.List[string]
  $cur=''
  for($f=0;$f -lt $frags.Count;$f++){
    $fr=$frags[$f].t
    $frTrim=$fr.TrimStart(" ","`t")
    if($cur.Length -eq 0){ $cur=$fr; continue }
    $isStmt=Test-StmtStart $frTrim
    # cur 里是否有“注释外#”?有 → cur 在当前“物理行”里其#之后已经是注释,原行在此结束;
    # 但同一注释行内部允许被标记打断(文字延续)。当且仅当后片是 语句起点或 '#',才真正断行。
    if($isStmt -and (Has-CommentedLinePart $cur)){
      # cur 是:注释行(可能尾带碎片)或“代码+注释”行;后片开启新行
      $rows.Add($cur); $cur=$fr
    } elseif($isStmt -and $cur.Trim().Length -gt 0 -and $cur -notmatch '[\u4e00-\u9fff]$' -and ($cur.TrimEnd() -match '[\)\]\x22]$' -or $cur.TrimEnd() -match '=\s*\S+$')){
      # 纯代码行相接:上片以 ) ] " 或赋值收尾,下片是语句
      $rows.Add($cur); $cur=$fr
    } else {
      # 文字/注释延续
      $cur=$cur+$fr
    }
  }
  if($cur.Length){ $rows.Add($cur) }
  if($rows.Count -eq 0){ $rows.Add('') }
  foreach($r in $rows){ $out.Add($lead+$r) }
  if($rows.Count -gt 1){
    $debug.Add("--- L"+($i+1)+" -> "+$rows.Count)
    $debug.Add("   "+$l)
    for($r=0;$r -lt $rows.Count;$r++){ $debug.Add("   R$r : "+($lead+$rows[$r])) }
  }
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.v7",$out,(New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllLines("$src\_v7_debug.txt",$debug,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v7 lines: "+$out.Count+"  debug: "+$debug.Count)