# Battle.gd 修复引擎 v3:拆回被吞换行(更精细)
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\_recovered_probe.txt",[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD
$Q=[char]0x3F

function Get-LeadWs($s){ $n=0; while($n -lt $s.Length -and ($s[$n]-eq "`t" -or $s[$n]-eq ' ')){$n++}; return $s.Substring(0,$n) }

# 去除连续标记:把 FFFD/? 连续串归一为单个分隔记号
$rowsAll=New-Object System.Collections.Generic.List[string]
$note=New-Object System.Collections.Generic.List[string]
$kept=0;$split=0
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  if(-not ($l.Contains($BAD) -or $l.Contains($Q))){ $rowsAll.Add($l); continue }
  $lead=Get-LeadWs $l
  $body=$l.Substring($lead.Length)

  # 归一记号序列:把 body 拆成 tokens:tokens = 文本 | #M#
  $toks=New-Object System.Collections.Generic.List[string]
  $sb=New-Object System.Text.StringBuilder
  foreach($ch in $body.ToCharArray()){
    if($ch -eq $BAD -or $ch -eq $Q){
      if($sb.Length){$toks.Add($sb.ToString());[void]$sb.Clear()}
      # 合并相邻记号,避免重复 #M#
      if($toks.Count -gt 0 -and $toks[$toks.Count-1] -eq '#M#'){ continue }
      $toks.Add('#M#')
    } else { [void]$sb.Append($ch) }
  }
  if($sb.Length){$toks.Add($sb.ToString())}

  # 状态机重排
  # 输出行列表 outLines;cur 缓冲;状态 inComment? inString?
  $outLines=New-Object System.Collections.Generic.List[string]
  $cur=New-Object System.Text.StringBuilder
  $inString=$false
  function Flush([System.Text.StringBuilder]$cb,[System.Collections.Generic.List[string]]$ol){
    if($cb.Length -gt 0){ $ol.Add($cb.ToString()); [void]$cb.Clear() }
  }
  for($t=0;$t -lt $toks.Count;$t++){
    $tk=$toks[$t]
    if($tk -eq '#M#'){ continue }   # 记号在拆行判定后直接丢弃(断行点由逻辑决定)
    # 分析 tk:是否以语句关键字开头(去前导空白)
    $tkTrim=$tk.TrimStart(" ","`t")
    $isStmt = $tkTrim -match '^(var |const |signal |func |class |extends |enum |static |if |elif |else|for |while |match |return |await |break|continue|pass|@|#|\b[A-Za-z_][A-Za-z0-9_]*\s*(:=|=|\(|\[))' -or $tkTrim.StartsWith('#')
    $isCommentStart = $tkTrim.StartsWith('#')
    $curTxt=$cur.ToString()
    # cur 是否"看起来完整结束"
    $ct=$curTxt.TrimEnd()
    $curComplete = $ct.Length -gt 0 -and ($ct -match '[\)\]\x22\uFF09]$' -or $ct -match '=\s*\S+$' -or $ct -match '^\s*(var|const|signal|func|class|enum|extends)\s+\S+.*\S$' -or $ct.EndsWith(':') )
    # 注释结尾(cur 最后一个非空 token 是注释)?简化:cur 含 '#' 且其后没有代码标志
    $hashPos=$ct.LastIndexOf('#')
    $curIsCommentLine = $curTxt.TrimStart().StartsWith('#')
    # 若 cur 是一整行注释(以#开头)并且 tk 是新语句/新注释 → 断行
    if($curIsCommentLine){
      if($isCommentStart -or $isStmt){
        Flush $cur $outLines
        [void]$cur.Append($tk)
      } else {
        # 中文注释丢字延续
        [void]$cur.Append($tk)
      }
      continue
    }
    # cur 是代码行。若 tk 是 # 注释续行(新注释)或 tk 是语句开头且 cur 已完整 → 断行
    if($isCommentStart){
      Flush $cur $outLines
      [void]$cur.Append($tk)
      continue
    }
    if($isStmt -and $curComplete -and $curTxt.Trim().Length -gt 0){
      Flush $cur $outLines
      [void]$cur.Append($tk)
      continue
    }
    # 默认并入(cur 可能还在字符串/表达式中)
    [void]$cur.Append($tk)
  }
  Flush $cur $outLines
  if($outLines.Count -le 0){ $outLines.Add('') }
  if($outLines.Count -gt 1){ $split++ } else { $kept++ }
  foreach($ol in $outLines){
    $rowsAll.Add($lead+$ol)
  }
  if($outLines.Count -gt 1){
    $note.Add(("L{0}: ->{1}" -f ($i+1),$outLines.Count))
  }
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.repaired",$rowsAll,(New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllLines("$src\_note3.txt",$note,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("repaired lines: "+$rowsAll.Count+"  split-lines: "+$split+"  single-kept damaged: "+$kept)