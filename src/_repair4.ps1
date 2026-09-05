# Battle.gd 修复主引擎:把损坏行还原为多条逻辑行
# 输入 src/_recovered_probe.txt → 输出 src/Battle.gd.repaired
#
# 损坏行结构:若干条“原行”被黏成一行,换行处变成 U+FFFD/? 记号。
# 拆行规则:
#  对每个记号位置,把行拆成片段;随后按“片段是否是独立语句/注释行”重建。
#  判定依据:片段去首空白后以语句关键字开头,且前一片段已是完整语句/注释。
# 由于前一行常有行尾注释(#...),注释本应到行尾——但在损坏行里,被黏进来的
# 片段跟在注释文本后,所以“注释到行尾”已被破坏。重建时,若片段形似代码起点
# 且其前是注释文本的结尾 → 断行。对无法确定的场景保守处理(合并/去记号),
# 交由人工复查清单。
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\_recovered_probe.txt",[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD
$Q=[char]0x3F

# 片段起始“看起来是代码语句开头”
$codeStartRe = [regex]'^(\s*)(#|var\s+|func\s+|signal\s+|class\s+|const\s+|enum\s+|static\s+|extends\s+|if\s+|elif\s+|else:|else\s+if|for\s+|while\s+|return\s+|match\s+|await\s+|break|continue|pass|@|[A-Za-z_][A-Za-z0-9_.]*\s*(\:=|=|\(|\[)|')'
# 片段起始“看起来是注释延续(中文/普通文本)”
$cnRe = [regex]'^([\u4e00-\u9fff])'
# 已闭合语句结尾(代码语句 + 可选行尾注释之后,记号前的片段应以此为尾)
$endStmtRe = [regex]'[\)\]\uFF08\uFF09\u3002\uFF1B\uFF1A\uFF0C]+$'

# 逐行处理
$out=New-Object System.Collections.Generic.List[string]
$audit=New-Object System.Collections.Generic.List[string]
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  if(-not ($l.Contains($BAD) -or $l.Contains($Q))){ $out.Add($l); continue }
  # 提取前导空白
  $lead=$l -replace '^(\s*).*$','$1'
  $body=$l.Substring($lead.Length)

  # 切片段(记号视为分隔符,丢弃)
  $frags=New-Object System.Collections.Generic.List[string]
  $sb=New-Object System.Text.StringBuilder
  foreach($ch in $body.ToCharArray()){
    if($ch -eq $BAD -or $ch -eq $Q){ if($sb.Length -gt 0){$frags.Add($sb.ToString())}; [void]$sb.Clear(); continue }
    [void]$sb.Append($ch)
  }
  if($sb.Length -gt 0){ $frags.Add($sb.ToString()) }

  # 逐片段重建逻辑行。cur = 正在累积的逻辑行。
  # 判断在 frag 前是否断行:仅当 cur 非空且 frag 是新的语句/注释起点,且 cur 看起来可结束。
  $rows=New-Object System.Collections.Generic.List[string]
  $cur=''
  for($f=0;$f -lt $frags.Count;$f++){
    $fr=$frags[$f]
    if($cur.Length -eq 0){ $cur=$fr; continue }
    # 若 cur 中最后一个 '#' 到 cur 末尾都是注释文本,而 fr 是代码起点 → cur 是注释行,断行
    $hashIdx=$cur.LastIndexOf('#')
    $curTailComment = $hashIdx -ge 0   # cur 含有 #(把其后都视为注释)
    $frTrim=$fr.TrimStart(" ","`t")
    $mCode=$codeStartRe.Match($frTrim)
    if($mCode.Success -and $curTailComment){
      # 注释/代码行黏连:cur 收尾(可能缺末尾汉字),新起一行
      $rows.Add($cur)
      $cur=$fr
    } elseif($mCode.Success -and $cur -match '[\)\]\uFF09\u3002\uFF1B]$'){
      # 代码语句 + 下一语句黏连
      $rows.Add($cur)
      $cur=$fr
    } elseif($cnRe.IsMatch($frTrim) -or $curTailComment){
      # 注释延续或中文延续:并入 cur
      $cur=$cur+$fr
    } else {
      # 保守:并入
      $cur=$cur+$fr
    }
  }
  if($cur.Length -gt 0){ $rows.Add($cur) }

  if($rows.Count -eq 0){ $rows.Add('') }
  for($r=0;$r -lt $rows.Count;$r++){
    $out.Add($lead+$rows[$r])
  }
  $audit.Add(("L{0} frags={1} rows={2}" -f ($i+1),$frags.Count,$rows.Count))
  if($rows.Count -gt 1){
    $audit.Add("    ORIG: "+$l)
    for($r=0;$r -lt $rows.Count;$r++){ $audit.Add(("    R{0}: {1}" -f $r,($lead+$rows[$r]))) }
  }
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.repaired",$out,(New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllLines("$src\_repair_audit.txt",$audit,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("repaired lines: "+$out.Count+"  audit entries: "+$audit.Count)