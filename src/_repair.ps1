# Repair pipeline for Battle.gd recovered text
# Reads src/_recovered_probe.txt (correct Chinese, lines merged by lost newlines marked with U+FFFD/?),
# splits merged lines back at statement boundaries, restores indentation,
# writes src/_repaired.txt
$ErrorActionPreference = 'Stop'
$src = 'D:\Game creating\战旗\src'
$lines = [System.IO.File]::ReadAllLines("$src\_recovered_probe.txt", [System.Text.Encoding]::UTF8)

$BAD = [char]0xFFFD
$Q = [char]0x3F

# Statement starters we can reliably begin a NEW line with (used to detect merge boundaries)
$kwStarters = '^(var |func |signal |class |const |enum |static func|if |for |while |return |match |await |elif |else|break|continue|pass|@|extends )'

function Get-Indent($s) {
  $n = 0
  while ($n -lt $s.Length -and ($s[$n] -eq "`t" -or $s[$n] -eq ' ')) { $n++ }
  return $s.Substring(0, $n)
}

function Has-Markers($s) { return $s.Contains($BAD) -or $s.Contains($Q) }

# ---------------------------------------------------------------
# Pass 1: tokenize each damaged line into candidate fragments at every marker run.
# Markers: runs of BAD/Q. Each run = one "loss site".
# We first decide, per loss site, whether it was a LINE BREAK (original newline + maybe indent eaten)
# or inline char loss (no newline).
# ---------------------------------------------------------------

$out = New-Object System.Collections.Generic.List[string]
$changed = 0

for ($ln = 0; $ln -lt $lines.Count; $ln++) {
  $line = $lines[$ln]
  if (-not (Has-Markers $line)) { $out.Add($line); continue }

  $indent = Get-Indent $line
  $rest = $line.Substring($indent.Length)

  # Build fragment list: (text) split at marker runs
  $frags = New-Object System.Collections.Generic.List[object]  # @{t=...; brk=bool?}
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $rest.Length; $i++) {
    $ch = $rest[$i]
    if ($ch -eq $BAD -or $ch -eq $Q) {
      if ($sb.Length -gt 0) { $frags.Add(@{ t = $sb.ToString() }); [void]$sb.Clear() }
      # marker run ends when next char is not marker
      while ($i + 1 -lt $rest.Length -and ($rest[$i+1] -eq $BAD -or $rest[$i+1] -eq $Q)) { $i++ }
    } else {
      [void]$sb.Append($ch)
    }
  }
  if ($sb.Length -gt 0) { $frags.Add(@{ t = $sb.ToString() }) }

  # Decide break between consecutive frags. Reconstruct by scanning: we treat the concatenation
  # of all fragments as one long text where breaks are unknown; then we attempt to parse it as a
  # sequence of GDScript logical lines using structural cues.
  # Strategy: simple heuristic pass producing human-reviewable output with proposed breaks.
  # For each adjacent pair, propose break if left ends like a complete statement/comment tail
  # and right starts like a statement starter.

  $result = New-Object System.Collections.Generic.List[string]
  $result.Add($frags[0].t)
  for ($k = 1; $k -lt $frags.Count; $k++) {
    $prevText = $result[$result.Count - 1]
    $curText = $frags[$k].t
    $curTrim = $curText.TrimStart()
    $prevTrim = $prevText.TrimEnd()
    # placeholder: append to previous fragment for now; splitting decided in later pass
    $result[$result.Count - 1] = $prevTrim + $curText
  }
  $out.Add($indent + $result[0])
}
[System.IO.File]::WriteAllLines("$src\_pass1_joined.txt", $out, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("pass1 wrote joined fragments: " + $out.Count)
