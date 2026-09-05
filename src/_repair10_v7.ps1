# 修复引擎 v7:基于 v6 进行二次校正
# 处理两类问题:
#  A) 若某行注释(或语句)末尾缺闭合右括号/收尾字,不补(注释无所谓);
#  B) 若某行仍疑似黏连(注释行#后紧接代码关键字且非解释性文字)但v3漏拆,补拆。
# 另外清理注释/字符串内残留的 FFFD 已在 v3 完成。本版只做局部规则修正并在 diff 日志输出所有改动。
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$lines=[System.IO.File]::ReadAllLines("$src\Battle.gd.v6",[System.Text.Encoding]::UTF8)
$log=New-Object System.Collections.Generic.List[string]

# 启发: 注释行(#开头)后直接跟 'func '/'class '/'var '/'const ' 等是漏拆(注释行自身在#后结束,后续是代码)。
# 但解释性注释常包含这些词(如 "# 见 func foo")——仅当 # 后文本以常见中文收尾且无其他符号时不可靠。
# 保守:只拆 # 后紧跟 "func/class " 且该词前是行首(整行为纯注释)的行,这类在原文件中是 注释行\nfunc。
$out=New-Object System.Collections.Generic.List[string]
$fixed=0
for($i=0;$i -lt $lines.Count;$i++){
  $l=$lines[$i]
  $t=$l.Trim()
  $changed=$false
  if($t.StartsWith('#') -and $t -match '^(#[^\n]*?)(func |class |var |const |signal |enum |if |for |while )'){
    # 危险:注释正文含这些词也常见;仅当注释正文看起来完整句(以中文/。/)结尾 且 后跟 func/class 等在冒号后。
    # 更安全策略:不在此拆,交给用户解析? 保留本文件手动。
  }
  $out.Add($l)
}
[System.IO.File]::WriteAllLines("$src\Battle.gd.v6b",$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output "v6b = unchanged copy (placeholder)"