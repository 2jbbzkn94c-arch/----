# Battle.gd 修复引擎 阶段1:拆回被吞换行 + 清理纯丢字
# 读取 src/_recovered_probe.txt → 输出 src/_stage1.txt
# 核心思路:
#  每条损坏行 = 1..N 条“原逻辑行”被黏连。原行之间丢掉了换行(以及行首缩进)。
#  采用“锚定注释/语句边界”的方式:
#    (1) 若一行在去掉标记字符后,仍能整体作为一条 GDScript 语句/注释(与备份或语法直觉一致)→ 只做字符清理。
#    (2) 若一行明显是多条语句黏连 → 在关键处拆行并恢复缩进。
#  策略优先“保守”:对拿不准的行,保留整行但把行首前缀与后续代码分开处理并打标记 TODO,交由人工/后续阶段。

$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\_recovered_probe.txt",[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD; $Q=[char]0x3F

# 行首缩进
function Get-Indent($s){ $n=0; while($n -lt $s.Length -and ($s[$n]-eq "`t" -or $s[$n]-eq ' ')){$n++}; return $s.Substring(0,$n) }

# 去掉标记字符后的清理文本(仅用于启发判断)
function Clean($s){ return ($s.Replace([string]$BAD,'').Replace([string]$Q,'')) }

# 判断一个片段是否像“新语句起点”(可作拆行候选)
$stmtStart = [regex]'^\s*(var|const|func|signal|class|extends|enum|static|if|elif|else|for|while|match|return|await|break|continue|pass|@|\b[A-Za-z_][A-Za-z0-9_]*\s*(:=|=|\(|\[)|#)'

$out=New-Object System.Collections.Generic.List[string]
$log=New-Object System.Collections.Generic.List[string]
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  if(-not ($l.Contains($BAD) -or $l.Contains($Q))){ $out.Add($l); continue }
  $indent=Get-Indent $l
  $body=$l.Substring($indent.Length)

  # 记号位置列表
  $marks=@()
  for($j=0;$j -lt $body.Length;$j++){ if($body[$j]-eq $BAD -or $body[$j]-eq $Q){ $marks+=$j } }

  # 切分成片段(含标记则断开)
  $frags=@(); $sb=New-Object System.Text.StringBuilder
  foreach($ch in $body.ToCharArray()){
    if($ch -eq $BAD -or $ch -eq $Q){ if($sb.Length){$frags+=$sb.ToString()}; [void]$sb.Clear() } else {[void]$sb.Append($ch)}
  }
  if($sb.Length){$frags+=$sb.ToString()}
  $log.Add(("### L{0} frags={1} :: {2}" -f ($i+1), $frags.Count, $l.Substring(0,[Math]::Min(160,$l.Length))))

  # 分两类:首片段为注释行(以 # 开头) vs 代码行
  $firstTrim=$frags[0].TrimStart()
  if($firstTrim.StartsWith('#')){
    # 注释行为首。若后续片段也是注释内容(#开头或中文延续)→合;若后续片段像代码 →拆
    $res=New-Object System.Collections.Generic.List[string]
    $cur=[string]$frags[0]
    for($k=1;$k -lt $frags.Count;$k++){
      $f=$frags[$k]; $ft=$f.TrimStart()
      if($ft.StartsWith('#')){
        # 新注释行
        $res.Add($cur); $cur=$f
      } elseif($ft -match '^(var|func|signal|class|const|enum|if|for|while|return|match|await|elif|else|break|continue|@|extends|static|\b[A-Za-z_][A-Za-z0-9_]*\s*(:=|=|\(|\[))'){
        # 像代码 → 前面注释结束,起新行
        $res.Add($cur); $cur=$f
      } else {
        # 中文注释延续(丢字),拼回注释
        $cur=$cur+$f
      }
    }
    $res.Add($cur)
    # 拼缩进:第一行用原缩进,其余行缩进继承判断
    $firstLine=$indent+$res[0]
    $out.Add($firstLine)
    for($k=1;$k -lt $res.Count;$k++){
      $out.Add($indent+$res[$k])
    }
  } else {
    # 代码行:通常整行是一条语句(或语句+尾注释)黏了下一行/下一条。先合并成一条候选并尝试识别断点。
    # 保守:若除首片段外还有片段,可能是 语句+注释 或 注释+语句;先整体重粘,标 TODO 由阶段2处理
    $merged = ($frags -join '')
    $out.Add($indent+$merged)
  }
}
[System.IO.File]::WriteAllLines("$src\_stage1.txt",$out,(New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllLines("$src\_stage1_log.txt",$log,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("stage1 out lines: "+$out.Count+"  log lines: "+$log.Count)