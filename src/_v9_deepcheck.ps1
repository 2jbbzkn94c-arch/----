# v9 深度自检:找"残留黏连/错拆"的强证据
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\Battle.gd.v9",[System.Text.Encoding]::UTF8)
$out=New-Object System.Collections.Generic.List[string]

# A) 代码区内出现双 var/双 func 声明行(除三元/比较关键字外)
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $code=$l; $h=$code.IndexOf('#'); if($h -ge 0){$code=$code.Substring(0,$h)}
  if($code -match '^(var |const |func |signal |class |enum )'){
    # 找第二个声明:第二个 var/const/func 前有空位
    $ms=[regex]::Matches($code,'\b(var |const |func |signal |class )')
    if($ms.Count -ge 2){
      $out.Add(("A L{0}: {1}" -f ($i+1),$l.Substring(0,[Math]::Min(130,$l.Length))))
    }
  }
}
# B) 'func '/'class ' 出现在行中(不在行首/缩进后)——可能是注释吞了 func
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  if($l -match '^(\s*)#'){continue}   # 注释行跳过
  if($l -match '\b(func|class)\s+[A-Za-z_][A-Za-z0-9_]*\s*\('){
    # 确保不是行首声明
    if($l -notmatch '^\s*(func|class)\s'){
      $out.Add(("B L{0}: {1}" -f ($i+1),$l.Substring(0,[Math]::Min(130,$l.Length))))
    }
  }
}
# C) 代码行以 ","或 运算符 结尾后无续行(猜测续行缺失)?跳过。
# D) 关键字重复:行内有 'func' 且其后直接有 'var '等?粗查
# E) 行中出现 "�"(FFFD)?应已清除
$f=0; for($i=0;$i -lt $lines.Count;$i++){ if($lines[$i].Contains([char]0xFFFD)){$f++} }
Write-Output ("FFFD count: "+$f)
Write-Output ("A+B total: "+$out.Count)
$out | Select-Object -First 60 | ForEach-Object { Write-Output $_ }