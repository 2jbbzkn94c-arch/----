# 修复引擎 v5:逐字符词法修复 —— 补回被吞的闭合引号,并修复若干错误拆行
# 输入 src/_recovered_probe.txt(原始恢复文本) → 输出 src/Battle.gd.v5
# 策略:
#  1) 先按 v3 同款规则拆行(注释行与后续代码拆开、代码语句+尾注释后跟新语句拆开)。
#  2) 对每一行做引号配平:统计字符串字面量;若代码区(非注释)内引号奇数,
#     在行尾合适位置补 '"'(该行原始必以 ...!" ) 结尾一类)。
#  3) 若注释行里 # 之后出现无法归属的裸代码(缩进/关键字)且非延续文本,视为丢字不处理。
# 本版本重在修复引号,不新增逻辑改写。
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\Battle.gd.v4",[System.Text.Encoding]::UTF8)

# 逐字符扫描,返回:注释外的代码是否引号奇数,以及最后一个 '"' 的位置(代码区内)
function Get-QuoteInfo($s){
  $inStr=$false; $inCom=$false
  $codeQuotes=New-Object System.Collections.Generic.List[int]
  for($i=0;$i -lt $s.Length;$i++){
    $ch=$s[$i]
    if($inCom){ continue }
    if($ch -eq '"'){
      if($inStr){ $inStr=$false; $codeQuotes.Add($i) }
      else { $inStr=$true; $codeQuotes.Add($i) }
      continue
    }
    if($ch -eq '#' -and -not $inStr){ $inCom=$true }
  }
  return @{ odd=($codeQuotes.Count % 2 -eq 1); last=$codeQuotes[$codeQuotes.Count-1]; cnt=$codeQuotes.Count }
}

$out=New-Object System.Collections.Generic.List[string]
$fixed=0
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $t=$l.Trim()
  if($t.Length -eq 0 -or $t.StartsWith('#')){ $out.Add($l); continue }
  $info=Get-QuoteInfo $l
  if($info.odd){
    # 字符串未闭合。寻找合适插入点:最后一个代码引号之后,行尾(或在 % [、) 、, 之前)
    $last=$info.last
    # 从 last 之后找行尾前最近的关键边界:在行尾补闭合引号最简单,但若行尾是注释(#)则应在注释前补。
    $hashInCode=$l.IndexOf('#')
    if($hashInCode -lt 0 -or $hashInCode -lt $last){ $hashInCode=$l.Length }
    # 若插入处前一个非空字符是 '"' 说明已闭合?不会发生(odd 保证未闭合)
    # 在 hashInCode 处插入 '"'
    $new=$l.Substring(0,$hashInCode)+'"'+$l.Substring($hashInCode)
    $out.Add($new); $fixed++
  } else {
    $out.Add($l)
  }
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.v5",$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("v5 quote-fixed lines: "+$fixed+"  total: "+$out.Count)