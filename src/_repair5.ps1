# Battle.gd 修复引擎 v2:拆回被吞换行,保留缩进
# 读取 src/_recovered_probe.txt → 输出 src/Battle.gd.repaired
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\_recovered_probe.txt",[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD
$Q=[char]0x3F

# 若片段(去首空白)以“语句起点”开头且不是中文注释延续,则判定可断行
function Test-StmtStart($t){
  if($t.StartsWith('#')){ return $true }           # 新注释行
  if($t -match '^(var |const |func |signal |class |extends |enum |static |if |elif |else\b|else:|for |while |match |return |await |break|continue|pass|@|@export|@onready|@icon)'){ return $true }
  if($t -match '^[A-Za-z_][A-Za-z0-9_]*\s*(\(|:=|=|\[|\.)'){ return $true }  # 赋值/调用
  return $false
}

function Get-LeadWs($s){ $n=0; while($n -lt $s.Length -and ($s[$n]-eq "`t" -or $s[$n]-eq ' ')){$n++}; return $s.Substring(0,$n) }

$out=New-Object System.Collections.Generic.List[string]
$audit=New-Object System.Collections.Generic.List[string]
$mergedCount=0; $leftover=0

for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  if(-not ($l.Contains($BAD) -or $l.Contains($Q))){ $out.Add($l); continue }
  $lead=Get-LeadWs $l
  $body=$l.Substring($lead.Length)

  # 切片段
  $frags=New-Object System.Collections.Generic.List[object]  # each: @{t=text; mark=bool had marker before}
  $sb=New-Object System.Text.StringBuilder
  $hadMark=$false
  foreach($ch in $body.ToCharArray()){
    if($ch -eq $BAD -or $ch -eq $Q){
      if($sb.Length -gt 0){ $frags.Add(@{t=$sb.ToString(); mark=$hadMark}); [void]$sb.Clear() }
      $hadMark=$true
    } else {
      [void]$sb.Append($ch)
    }
  }
  if($sb.Length -gt 0){ $frags.Add(@{t=$sb.ToString(); mark=$hadMark}) }

  # 逐片段重建。跟踪:当前是否在注释文本流中(遇到 '#' 且之后未出现代码起点)
  # 简化稳健策略:
  #  遍历片段,cur 累积。若 frag 是语句起点:
  #     若 cur 以 '#' 注释开头且 frag 前不是注释延续 → 断行(cur 行尾)
  #     若 cur 是完整代码语句(以 ) 或 ] 或 引号 或 var初始化 结尾)→ 断行
  #  否则并入。
  $rows=New-Object System.Collections.Generic.List[string]
  $cur=''
  for($f=0;$f -lt $frags.Count;$f++){
    $fr=$frags[$f].t
    $frTrim=$fr.TrimStart(" ","`t")
    $frLead=Get-LeadWs $fr
    if($cur.Length -eq 0){ $cur=$fr; continue }
    $isStmt=Test-StmtStart $frTrim
    # cur 是纯注释(以 # 开头)? 判定 cur 从第一个 '#' 起至末尾是否只含注释(即没有代码结构)
    $hashIdx=($cur).IndexOf('#')
    $curIsComment=$false
    if($hashIdx -ge 0){
      $after=$cur.Substring($hashIdx)
      # 近似:注释后没有出现 ':=','=('等代码;只按常识保留
      $curIsComment=$true
    }
    $curTrim=$cur.TrimEnd(" ","`t")
    $curEndsCode=$curTrim -match '[\)\]\x22\uFF09]$'
    $curEndsVar=$curTrim -match '^(var|const|@)\s+\S+.*\S$' -or $curTrim -match '=\s*(\S+|\{|\[)$'
    $cut=$false
    if($isStmt){
      if($curIsComment){ $cut=$true }
      elseif($curEndsCode -or $curEndsVar){ $cut=$true }
      elseif($cur -match '^\s*$'){ $cut=$true }
    }
    if($cut){
      $rows.Add($cur)
      $cur=$fr
    } else {
      # 注释续流/文字丢字:并入(保留相对位置)。若 frag 自带缩进且 cur 不是注释,说明原本换行被吃但缩进留存
      if($frLead.Length -gt 0 -and -not $curIsComment -and $cur.Trim().Length -gt 0){
        $rows.Add($cur)
        $cur=$fr
      } else {
        $cur=$cur+$fr
      }
    }
  }
  if($cur.Length -gt 0){ $rows.Add($cur) }
  if($rows.Count -eq 0){ $rows.Add('') }
  if($rows.Count -gt 1){ $mergedCount++ } else { $leftover++ }

  for($r=0;$r -lt $rows.Count;$r++){
    $out.Add($lead+$rows[$r])
  }
  if($rows.Count -gt 1){
    $audit.Add("--- L"+($i+1))
    $audit.Add("  ORIG: "+$l)
    for($r=0;$r -lt $rows.Count;$r++){ $audit.Add(("  R{0}: {1}" -f $r,($lead+$rows[$r]))) }
  }
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.repaired",$out,(New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllLines("$src\_repair_audit.txt",$audit,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("repaired lines: "+$out.Count+"  split lines: "+$mergedCount+"  untouched-single damaged: "+$leftover)