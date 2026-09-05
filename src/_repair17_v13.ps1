# v13:修复拆分缩进 —— 后续行:若片段自带前导空白则用之,否则继承物理行前缀
# 输入 _probe2.txt → Battle.gd.v13
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\_probe2.txt",[System.Text.Encoding]::UTF8)
$BAD=[char]0xFFFD; $Q=[char]0x3F

function Get-Indent($s){ $n=0; while($n -lt $s.Length -and ($s[$n]-eq "`t" -or $s[$n]-eq ' ')){$n++}; return $s.Substring(0,$n) }
function Has-CJK($s){ foreach($ch in $s.ToCharArray()){ if($ch -ge [int]0x4E00 -and $ch -le [int]0x9FFF){return $true} }; return $false }

$kwRe=[regex]'^(var |const |func |signal |class |extends |enum |static |if |elif |else:|else |for |while |return |match |await |break|continue|pass|@|#)'
$codeRe=[regex]'^[A-Za-z_][A-Za-z0-9_]*\s*(\(|:=|=|\[|\.)'

$out=New-Object System.Collections.Generic.List[string]
$debug=New-Object System.Collections.Generic.List[string]
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  if(-not ($l.Contains($BAD) -or $l.Contains($Q))){ $out.Add($l); continue }
  $lead=Get-Indent $l
  $body=$l.Substring($lead.Length)
  $bodyIsComment=$body.TrimStart(" ","`t").StartsWith('#')

  $frags=New-Object System.Collections.Generic.List[string]
  $sb=New-Object System.Text.StringBuilder
  foreach($ch in $body.ToCharArray()){
    if($ch -eq $BAD -or $ch -eq $Q){ if($sb.Length){$frags.Add($sb.ToString())};[void]$sb.Clear() } else {[void]$sb.Append($ch)}
  }
  if($sb.Length){$frags.Add($sb.ToString())}

  # 每片段保留其自带前导(因原行可能自带缩进存活)
  $rows=New-Object System.Collections.Generic.List[string]
  $cur=$null  # 对象 {text, indent}
  for($f=0;$f -lt $frags.Count;$f++){
    $fr=$frags[$f]
    $frIndent=Get-Indent $fr
    $frText=$fr.Substring($frIndent.Length)
    $ft=$frText.TrimStart(" ","`t")   # frText 已无前导;ft 即文本
    if($null -eq $cur){
      # 首个片段:使用物理行前缀作为其缩进(除非片段自带——但首个已剥走 lead,故用 lead)
      $cur=@{ text=$fr; indent=$lead }
      continue
    }
    $isKw=$kwRe.IsMatch($frText)
    $isCode=$codeRe.IsMatch($frText)
    $cjk=Has-CJK $frText
    $curText=$cur.text; $curIndent=$cur.indent
    $cut=$false
    if($bodyIsComment){
      if($isKw){ $cut=$true }
      elseif($isCode -and -not $cjk){ $cut=$true }
    } else {
      if($isKw){ $cut=$true }
      elseif($curText.Contains('#') -and ($isCode -or $isKw)){ $cut=$true }
      elseif($isCode -and -not $cjk -and $curText.TrimEnd() -match '[\)\]\x22\uFF09]$'){ $cut=$true }
    }
    if($cut){
      # 新行缩进:片段自带前导(存活)优先;否则沿用当前行 indent(注释与代码多同级)再加?注释在代码之上说明同级
      # 但若前一段是“代码+行尾注释”(cur 以注释结尾),后续语句通常同级 → 沿用 curIndent 或 frIndent
      $newIndent=$frIndent
      if($newIndent.Length -eq 0){ $newIndent=$curIndent }
      # 特殊情况:上一物理行以代码结尾且带尾注释,第二段如 else:/代码同级 → 用 curIndent
      if($curText.TrimStart().StartsWith('#')){
        # 注释行为首:其注释描述的代码通常同级;若 frIndent 空,用 curIndent
        if($frIndent.Length -eq 0){ $newIndent=$curIndent }
      }
      $rows.Add($cur)
      $cur=@{ text=$fr; indent=$newIndent }
    } else {
      $cur.text=$cur.text+$fr   # 注释延续合并(注意 fr 可能自带前导,中文注释里多为续字,去前导?)
      # 若 frIndent 存在且 cur 非注释开头,保留?注释延续通常不该有 tab;简化:删除续行自带缩进
      $cur.text=$curText+$frText
    }
  }
  if($null -ne $cur){ $rows.Add($cur) }
  if($rows.Count -eq 0){ $rows.Add(@{text='';indent=''}) }
  foreach($r in $rows){ $out.Add($r.indent+$r.text) }
  if($rows.Count -gt 1){
    $debug.Add(("--- L{0} rows={1}" -f ($i+1),$rows.Count))
    $debug.Add("   "+$l)
    foreach($r in $rows){ $debug.Add(("   R: ["+$r.indent.Replace("`t",'<T>')+"]"+$r.text)) }
  }
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.v13",$out,(New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllLines("$src\_v13_debug.txt",$debug,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v13 lines: "+$out.Count+"  splits: "+$debug.Count)