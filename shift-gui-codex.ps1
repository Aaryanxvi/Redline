# shift-gui-codex.ps1 - CODEX SHIFT for the Codex CLI on Windows
# Draggable H-pattern shifter. Drag knob into a gate -> sends "/model <slug>" to your codex terminal.
# Effort levers -> "/reasoning <level>".  NOS -> "/compact" (purge context).
# Gears auto-sync from ~/.codex/models_cache.json (whatever models YOU have). Add legacy
# slugs in $script:extraModels below.  Fuel + 5H/weekly bars read straight from the
# session rollout jsonl -- no API call, no credentials.
# Run:  powershell -sta -File shift-gui-codex.ps1

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinC {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
}
"@

# ---- legacy / extra models: add any slug Codex accepts via `codex -m <slug>` ----
# these aren't in models_cache.json (Codex hides legacy models), so list them here
# and they'll appear as gears alongside the auto-detected current models.
$script:extraModels = @(
  # 'gpt-5.1-codex'
  # 'o3'
)

$CODEX = Join-Path $env:USERPROFILE '.codex'
$GATES = @(@(0,0),@(0,1),@(1,0),@(1,1),@(2,0),@(2,1))   # col,row order for gates 1..6

# read models_cache.json (visibility=list) + $extraModels, map onto H gates by priority.
# per-model reasoning levels come from the cache too. Falls back to a default set.
function Get-CodexGears {
  $models = @()
  try {
    $raw = [IO.File]::ReadAllText((Join-Path $CODEX 'models_cache.json'), [Text.Encoding]::UTF8)
    $j = $raw | ConvertFrom-Json
    $models = @($j.models | Where-Object { $_.visibility -eq 'list' } | Sort-Object priority |
               ForEach-Object {
                 [pscustomobject]@{ slug=$_.slug; efforts=@($_.supported_reasoning_levels.effort) }
               })
  } catch {}
  if (-not $models) {   # cache missing: sane default so the GUI still runs
    $models = @([pscustomobject]@{ slug='gpt-5.5'; efforts=@('low','medium','high','xhigh') })
  }
  foreach ($e in $script:extraModels) {
    if ($e -and -not ($models.slug -contains $e)) {
      $models += [pscustomobject]@{ slug=$e; efforts=@('low','medium','high','xhigh') }
    }
  }
  $gears = @()
  $i = 0
  foreach ($m in $models) {
    if ($i -ge $GATES.Count) { break }   # 6 gates max
    # short gate label: drop the "gpt-" prefix so chips don't overlap (full slug shows on the dash)
    $short = ($m.slug -replace '^gpt-','').ToUpper()
    $gears += @{ id=($i+1).ToString(); name=$short; cmd=$m.slug; efforts=$m.efforts; col=$GATES[$i][0]; row=$GATES[$i][1] }
    $i++
  }
  return $gears
}

$script:gears   = Get-CodexGears
$script:target  = [IntPtr]::Zero
$script:curGear = $null
$script:fuel    = $null
$script:tank    = $null
$script:model   = $null
$script:lim5h   = $null
$script:limWk   = $null
$script:effort  = $null
$script:lastCmd = $null

# ---- geometry ----
$COLS = @(60, 120, 180)
$ROWY = @(48, 200)
$NEUT = New-Object Drawing.Point(120,124)
$script:knob = New-Object Drawing.Point($NEUT.X,$NEUT.Y)
$script:drag = $false
$KR = 21

# ================= drawing helpers =================
function New-RoundRect([double]$x,[double]$y,[double]$w,[double]$h,[double]$r) {
  $p = New-Object Drawing.Drawing2D.GraphicsPath
  $d = $r*2
  $p.AddArc($x,$y,$d,$d,180,90)
  $p.AddArc($x+$w-$d,$y,$d,$d,270,90)
  $p.AddArc($x+$w-$d,$y+$h-$d,$d,$d,0,90)
  $p.AddArc($x,$y+$h-$d,$d,$d,90,90)
  $p.CloseAllFigures()
  return $p
}

function Draw-SoftShadow($g,$path,[int]$layers=5,[int]$offset=3) {
  for ($i=$layers; $i -ge 1; $i--) {
    $a = [int](55 * ($i/$layers) / $layers)
    $b = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb($a,0,0,0))
    $m = New-Object Drawing.Drawing2D.Matrix
    $m.Translate($offset, $offset + $i*0.6)
    $gp = $path.Clone()
    $gp.Transform($m)
    $g.FillPath($b,$gp)
    $b.Dispose(); $gp.Dispose(); $m.Dispose()
  }
}

function Draw-GlowText($g,[string]$text,$font,$x,$y,[Drawing.Color]$glow,[Drawing.Color]$core) {
  $gb = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(70,$glow.R,$glow.G,$glow.B))
  foreach ($o in @(@(-1,0),@(1,0),@(0,-1),@(0,1),@(-1,-1),@(1,1))) {
    $g.DrawString($text,$font,$gb,$x+$o[0],$y+$o[1])
  }
  $gb.Dispose()
  $cb = New-Object Drawing.SolidBrush($core)
  $g.DrawString($text,$font,$cb,$x,$y)
  $cb.Dispose()
}

function Send-Keys-To-Target([string]$text) {
  if ($script:target -eq [IntPtr]::Zero) { $script:statusLbl.Text='SET TARGET FIRST'; return $false }
  if ([WinC]::IsIconic($script:target)) { [WinC]::ShowWindow($script:target,9) | Out-Null }
  [WinC]::SetForegroundWindow($script:target) | Out-Null
  Start-Sleep -Milliseconds 300
  $script:lastCmd = $text
  # Codex slash commands: blasting the whole "/model x" line + double-Enter landed
  # as a chat message (command mode never armed). Send "/" ALONE first, pause so the
  # command palette opens, THEN type the rest, then ONE Enter.
  if ($text.StartsWith('/')) {
    [Windows.Forms.SendKeys]::SendWait('/')
    Start-Sleep -Milliseconds 350
    $rest = ($text.Substring(1)) -replace '([+^%~(){}\[\]])','{$1}'
    [Windows.Forms.SendKeys]::SendWait($rest)
    Start-Sleep -Milliseconds 250
    [Windows.Forms.SendKeys]::SendWait('{ENTER}')
  } else {
    $esc = $text -replace '([+^%~(){}\[\]])','{$1}'
    [Windows.Forms.SendKeys]::SendWait($esc)
    Start-Sleep -Milliseconds 180
    [Windows.Forms.SendKeys]::SendWait('{ENTER}')
  }
  return $true
}

# fast tail: seek to last N bytes, split lines. FileShare ReadWrite so we never
# fight codex writing the rollout file.
function Read-TailLines([string]$path,[int]$bytes=524288) {
  try {
    $fs = [IO.File]::Open($path,'Open','Read','ReadWrite')
    try {
      $take = [int][math]::Min([long]$bytes,$fs.Length)
      if ($take -le 0) { return @() }
      [void]$fs.Seek(-$take,'End')
      $buf = New-Object byte[] $take
      [void]$fs.Read($buf,0,$take)
    } finally { $fs.Dispose() }
    return @([Text.Encoding]::UTF8.GetString($buf) -split "`n" | Where-Object { $_ })
  } catch { return @() }
}

# newest rollout-*.jsonl under ~/.codex/sessions (nested YYYY/MM/DD). One rollout
# per session, so newest = the active session. Cached 15s (recursive scan is slow).
function Get-Newest-Rollout {
  if ($script:njStamp -and ((Get-Date) - $script:njStamp).TotalSeconds -lt 15) { return $script:njCache }
  try {
    $sdir = Join-Path $CODEX 'sessions'
    $script:njCache = Get-ChildItem $sdir -Recurse -Filter 'rollout-*.jsonl' -ErrorAction Stop |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
  } catch { $script:njCache = $null }
  $script:njStamp = Get-Date
  return $script:njCache
}

# one pass over the session tail: pull fuel%, tank, current model, and the
# 5h/weekly rate-limit %. Everything Codex logs in the token_count payload.
function Update-CodexState {
  try {
    $f = Get-Newest-Rollout
    if (-not $f) { return }
    $lines = Read-TailLines $f.FullName
    # newest token_count line has both context usage and rate limits
    for ($i = $lines.Count-1; $i -ge 0; $i--) {
      if ($lines[$i] -notlike '*"token_count"*') { continue }
      try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
      $p = $o.payload
      if (-not $p -or $p.type -ne 'token_count') { continue }
      if ($p.info -and $p.info.model_context_window) {
        $tot  = [long]$p.info.total_token_usage.total_tokens
        $win  = [long]$p.info.model_context_window
        $script:tank = $win
        if ($win -gt 0) { $script:fuel = [math]::Max(0, 100 - [math]::Round(100 * $tot / $win)) }
      }
      if ($p.rate_limits) {
        if ($null -ne $p.rate_limits.primary.used_percent)   { $script:lim5h = [int][math]::Round($p.rate_limits.primary.used_percent) }
        if ($null -ne $p.rate_limits.secondary.used_percent) { $script:limWk = [int][math]::Round($p.rate_limits.secondary.used_percent) }
      }
      break
    }
    # current model: newest payload carrying a model field (turn context).
    # keeps the gear indicator in sync even if you switch via the picker.
    for ($i = $lines.Count-1; $i -ge 0; $i--) {
      if ($lines[$i] -notlike '*"model"*') { continue }
      try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
      $m = $o.payload.model
      if ($m) {
        $script:model = $m
        $g = $script:gears | Where-Object { $_.cmd -eq $m } | Select-Object -First 1
        if ($g) { $script:curGear = $g.id }
        break
      }
    }
  } catch {}
}

function Engage-Gear($g) {
  if (Send-Keys-To-Target "/model $($g.cmd)") {
    $script:curGear = $g.id
    Start-Sleep -Milliseconds 900
    Update-CodexState
    if ($script:dash)  { $script:dash.Invalidate() }
    if ($script:gauge) { $script:gauge.Invalidate() }
  }
}

# ================= form =================
$f = New-Object Windows.Forms.Form
$f.Text='CODEX SHIFT'; $f.ClientSize = New-Object Drawing.Size(240, 640)
$f.TopMost=$true; $f.FormBorderStyle='FixedToolWindow'
$f.StartPosition='Manual'; $f.Location = New-Object Drawing.Point(40,40)

$f.Add_Paint({
  $g=$_.Graphics; $g.SmoothingMode='AntiAlias'
  $r = New-Object Drawing.Rectangle(0,0,$f.ClientSize.Width,$f.ClientSize.Height)
  $lg = New-Object Drawing.Drawing2D.LinearGradientBrush($r,[Drawing.Color]::FromArgb(30,30,36),[Drawing.Color]::FromArgb(10,10,13),90)
  $g.FillRectangle($lg,$r); $lg.Dispose()
  # accent LED top-left (teal for codex)
  $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(20,190,160))),10,10,8,8)
  $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(120,140,255,220))),11,11,3,3)
  $tf = New-Object Drawing.Font('Consolas',9,[Drawing.FontStyle]::Bold)
  $g.DrawString('CODEX SHIFT',$tf,(New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(190,190,198))),24,8)
})

$script:statusLbl = New-Object Windows.Forms.Label
$statusLbl = $script:statusLbl
$statusLbl.Text='NO TARGET SET'; $statusLbl.ForeColor=[Drawing.Color]::FromArgb(130,130,138)
$statusLbl.SetBounds(0,30,240,16); $statusLbl.TextAlign='MiddleCenter'
$statusLbl.Font = New-Object Drawing.Font('Consolas',7,[Drawing.FontStyle]::Bold)
$statusLbl.BackColor = [Drawing.Color]::Transparent
$f.Controls.Add($statusLbl)

$setBtn = New-Object Windows.Forms.Button
$setBtn.Text='TARGET: (focus a terminal)'; $setBtn.SetBounds(20,50,200,28)
$setBtn.FlatStyle='Flat'; $setBtn.FlatAppearance.BorderSize=1
$setBtn.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(90,90,100)
$setBtn.BackColor=[Drawing.Color]::FromArgb(52,52,60); $setBtn.ForeColor='White'
$setBtn.Font = New-Object Drawing.Font('Segoe UI',8,[Drawing.FontStyle]::Bold)
$setBtn.Enabled = $false
$f.Controls.Add($setBtn)

$focusTimer = New-Object Windows.Forms.Timer
$focusTimer.Interval = 500
$focusTimer.Add_Tick({
  $fg = [WinC]::GetForegroundWindow()
  if ($fg -eq [IntPtr]::Zero -or $fg -eq $f.Handle) { return }
  if ($fg -ne $script:target) {
    $script:target = $fg
    $sb = New-Object System.Text.StringBuilder 256
    [void][WinC]::GetWindowText($fg,$sb,256)
    $t = $sb.ToString(); if ($t.Length -gt 24) { $t = $t.Substring(0,24)+'..' }
    $setBtn.Text = "TARGET: $t"
    $statusLbl.Text='TARGET LOCKED'; $statusLbl.ForeColor=[Drawing.Color]::FromArgb(120,230,150)
  }
})
$focusTimer.Start()

# ---- tachometer dash ----
$dash = New-Object Windows.Forms.Panel
$dash.SetBounds(16,86,208,100)
$dash.GetType().GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic').SetValue($dash,$true,$null)
$dash.Add_Paint({
  $g=$_.Graphics; $g.SmoothingMode='AntiAlias'; $g.Clear([Drawing.Color]::FromArgb(20,20,25))
  $path = New-RoundRect 0 0 208 100 14
  Draw-SoftShadow $g $path
  $panelBg = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(0,0,208,100)),[Drawing.Color]::FromArgb(38,38,45),[Drawing.Color]::FromArgb(20,20,25),90)
  $g.FillPath($panelBg,$path); $panelBg.Dispose()
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(60,60,68),1)),$path)
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(15,255,255,255),1)),(New-RoundRect 1 1 206 98 13))
  $path.Dispose()

  # arc tach upper-left
  $cx=46; $cy=42; $rad=32
  $bezel = New-Object Drawing.Pen([Drawing.Color]::FromArgb(55,55,62)),9
  $g.DrawArc($bezel,$cx-$rad,$cy-$rad,2*$rad,2*$rad,135,270); $bezel.Dispose()
  $frac = if ($null -ne $script:curGear) { [array]::IndexOf(($script:gears.id),$script:curGear) / ([math]::Max(1,$script:gears.Count-1)) } else { 0 }
  $sweep = 20 + 250*$frac
  $blend = New-Object Drawing.Drawing2D.ColorBlend
  $blend.Colors = @([Drawing.Color]::FromArgb(80,220,120),[Drawing.Color]::FromArgb(230,210,70),[Drawing.Color]::FromArgb(230,70,70))
  $blend.Positions = @(0.0,0.55,1.0)
  $tachRect = New-Object Drawing.Rectangle(($cx-$rad),($cy-$rad),(2*$rad),(2*$rad))
  $sweepBrush = New-Object Drawing.Drawing2D.LinearGradientBrush($tachRect,[Drawing.Color]::White,[Drawing.Color]::White,0)
  $sweepBrush.InterpolationColors = $blend
  $arcPen2 = New-Object Drawing.Pen($sweepBrush,6); $arcPen2.StartCap='Round'; $arcPen2.EndCap='Round'
  $g.DrawArc($arcPen2,$cx-$rad,$cy-$rad,2*$rad,2*$rad,135,$sweep)
  $needleAng = (135 + $sweep) * [math]::PI/180
  $nx = $cx + ($rad-6)*[math]::Cos($needleAng); $ny = $cy + ($rad-6)*[math]::Sin($needleAng)
  $g.DrawLine((New-Object Drawing.Pen([Drawing.Color]::White,2)),$cx,$cy,$nx,$ny)
  $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(230,230,235))),$cx-3,$cy-3,6,6)
  $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(20,20,24))),$cx-1,$cy-1,2,2)
  $arcPen2.Dispose(); $sweepBrush.Dispose()

  # big green digit + model slug
  $gid  = if ($script:curGear) { $script:curGear } else { 'N' }
  $gnm  = if ($script:model) { $script:model } elseif ($script:curGear) { ($script:gears | Where-Object {$_.id -eq $script:curGear}).name } else { 'NEUTRAL' }
  $digFont = New-Object Drawing.Font('Consolas',28,[Drawing.FontStyle]::Bold)
  $nmFont  = New-Object Drawing.Font('Consolas',8,[Drawing.FontStyle]::Bold)
  $green = [Drawing.Color]::FromArgb(110,240,150)
  $sz = $g.MeasureString($gid,$digFont)
  Draw-GlowText $g $gid $digFont (196-$sz.Width) 2 $green $green
  $sz2 = $g.MeasureString($gnm,$nmFont)
  Draw-GlowText $g $gnm $nmFont (196-$sz2.Width) 40 $green $green

  # breadcrumb strip
  $bc = if ($script:lastCmd) { $script:lastCmd } else { 'awaiting shift...' }
  $bcPath = New-RoundRect 6 70 196 24 6
  $g.FillPath((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(8,8,10))),$bcPath)
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(40,40,46))),$bcPath)
  $bcPath.Dispose()
  $bcFont = New-Object Drawing.Font('Consolas',7)
  $bcBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(0,220,150))
  $g.DrawString($bc,$bcFont,$bcBrush,12,77)
  $bcBrush.Dispose()
})
$script:dash = $dash
$f.Controls.Add($dash)

# ---- fuel gauge ----
$gauge = New-Object Windows.Forms.Panel
$gauge.SetBounds(16,196,208,40)
$gauge.GetType().GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic').SetValue($gauge,$true,$null)
$gauge.Add_Paint({
  $g=$_.Graphics; $g.SmoothingMode='AntiAlias'; $g.Clear([Drawing.Color]::FromArgb(20,20,25))
  $lblFont = New-Object Drawing.Font('Consolas',7,[Drawing.FontStyle]::Bold)
  $g.DrawString('FUEL  //  CONTEXT REMAINING',$lblFont,(New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(140,140,148))),2,0)
  # tank badge: the model's context window, read from the session
  $limTxt = if ($script:tank) { "$([math]::Round($script:tank/1000))K TANK" } else { '-- TANK' }
  $limB = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(120,200,255))
  $limSz = $g.MeasureString($limTxt,$lblFont)
  $g.DrawString($limTxt,$lblFont,$limB,(204-$limSz.Width),0); $limB.Dispose()
  $track = New-RoundRect 0 14 204 20 9
  $trackBg = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(0,14,204,20)),[Drawing.Color]::FromArgb(10,10,12),[Drawing.Color]::FromArgb(26,26,30),90)
  $g.FillPath($trackBg,$track); $trackBg.Dispose()
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(55,55,62))),$track); $track.Dispose()
  if ($null -ne $script:fuel) {
    $w=[math]::Max(4,[int](198*$script:fuel/100))
    $c1,$c2 = if($script:fuel -gt 50){[Drawing.Color]::FromArgb(70,210,110),[Drawing.Color]::FromArgb(130,240,160)}
        elseif($script:fuel -gt 20){[Drawing.Color]::FromArgb(220,150,40),[Drawing.Color]::FromArgb(250,190,90)}
        else{[Drawing.Color]::FromArgb(200,40,50),[Drawing.Color]::FromArgb(240,90,90)}
    $fillPath = New-RoundRect 3 17 $w 14 6
    $fillBrush = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(3,17,$w,14)),$c1,$c2,90)
    $g.FillPath($fillBrush,$fillPath); $fillBrush.Dispose(); $fillPath.Dispose()
    for ($t=25;$t -le 75;$t+=25) { $tx=3+[int](198*$t/100); $g.DrawLine((New-Object Drawing.Pen([Drawing.Color]::FromArgb(60,0,0,0),1)),$tx,15,$tx,32) }
    $pctFont = New-Object Drawing.Font('Consolas',8,[Drawing.FontStyle]::Bold)
    $g.DrawString("$($script:fuel)%",$pctFont,[Drawing.Brushes]::White,168,17)
  } else {
    $g.DrawString('--',(New-Object Drawing.Font('Consolas',8)),[Drawing.Brushes]::Gray,96,17)
  }
})
$script:gauge = $gauge
$f.Controls.Add($gauge)

# ---- shifter: chrome disc with etched H ----
$p = New-Object Windows.Forms.Panel
$p.SetBounds(0,246,240,260)
$p.GetType().GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic').SetValue($p,$true,$null)
$CIRC_CX=120; $CIRC_CY=124; $CIRC_R=104

$p.Add_Paint({
  $g=$_.Graphics; $g.SmoothingMode='AntiAlias'; $g.Clear([Drawing.Color]::FromArgb(10,10,13))
  $discRect = New-Object Drawing.Rectangle(($CIRC_CX-$CIRC_R),($CIRC_CY-$CIRC_R),(2*$CIRC_R),(2*$CIRC_R))
  $discPath = New-Object Drawing.Drawing2D.GraphicsPath
  $discPath.AddEllipse($discRect)
  Draw-SoftShadow $g $discPath 6 4

  $chrome = New-Object Drawing.Drawing2D.LinearGradientBrush($discRect,[Drawing.Color]::White,[Drawing.Color]::White,35)
  $cb = New-Object Drawing.Drawing2D.ColorBlend
  $cb.Colors = @(
    [Drawing.Color]::FromArgb(95,97,103), [Drawing.Color]::FromArgb(150,152,158),
    [Drawing.Color]::FromArgb(235,236,240),[Drawing.Color]::FromArgb(250,251,253),
    [Drawing.Color]::FromArgb(160,162,168),[Drawing.Color]::FromArgb(210,212,216),
    [Drawing.Color]::FromArgb(110,112,118)
  )
  $cb.Positions = @(0.0,0.18,0.32,0.42,0.55,0.75,1.0)
  $chrome.InterpolationColors = $cb
  $g.FillEllipse($chrome,$discRect); $chrome.Dispose()
  $g.DrawEllipse((New-Object Drawing.Pen([Drawing.Color]::FromArgb(35,35,40),2)),$discRect)
  $g.DrawEllipse((New-Object Drawing.Pen([Drawing.Color]::FromArgb(255,255,255,70),1)),($discRect.X+2),($discRect.Y+2),($discRect.Width-4),($discRect.Height-4))

  $glossPath = New-Object Drawing.Drawing2D.GraphicsPath
  $glossPath.AddEllipse($discRect.X+14,$discRect.Y+8,$discRect.Width-28,($discRect.Height*0.55))
  $clip = $g.Clip.Clone(); $g.SetClip($discPath)
  $glossBrush = New-Object Drawing.Drawing2D.LinearGradientBrush($discRect,[Drawing.Color]::FromArgb(120,255,255,255),[Drawing.Color]::FromArgb(0,255,255,255),90)
  $g.FillEllipse($glossBrush,$discRect.X+10,$discRect.Y+6,$discRect.Width-20,[int]($discRect.Height*0.5))
  $glossBrush.Dispose(); $g.Clip = $clip; $glossPath.Dispose()
  $discPath.Dispose()

  # etched H-slot
  $slot = New-Object Drawing.Pen([Drawing.Color]::FromArgb(30,30,35)),15
  $slot.StartCap='Round'; $slot.EndCap='Round'
  foreach ($x in $COLS) { $g.DrawLine($slot,$x,$ROWY[0],$x,$ROWY[1]) }
  $g.DrawLine($slot,$COLS[0],$NEUT.Y,$COLS[2],$NEUT.Y)
  $slot.Dispose()
  $shade = New-Object Drawing.Pen([Drawing.Color]::FromArgb(90,0,0,0)),15
  $shade.StartCap='Round'; $shade.EndCap='Round'
  foreach ($x in $COLS) { $g.DrawLine($shade,$x+1,$ROWY[0]+1,$x+1,$ROWY[1]+1) }
  $shade.Dispose()
  $hi = New-Object Drawing.Pen([Drawing.Color]::FromArgb(80,255,255,255)),2
  foreach ($x in $COLS) { $g.DrawLine($hi,$x-5,$ROWY[0],$x-5,$ROWY[1]) }
  $g.DrawLine($hi,$COLS[0],$NEUT.Y-5,$COLS[2],$NEUT.Y-5)
  $hi.Dispose()

  # gate dimples only where a gear actually exists
  $dimple = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(16,16,20))
  foreach ($gr in $script:gears) {
    $g.FillEllipse($dimple,$COLS[$gr.col]-4,$ROWY[$gr.row]-4,8,8)
  }
  $dimple.Dispose()

  # gate labels: dark chips
  $chipFont = New-Object Drawing.Font('Consolas',7,[Drawing.FontStyle]::Bold)
  foreach ($gr in $script:gears) {
    $x=$COLS[$gr.col]; $y=$ROWY[$gr.row]
    $active = $script:curGear -eq $gr.id
    $txt = "$($gr.id) $($gr.name)"
    $sz = $g.MeasureString($txt,$chipFont)
    $cw = [int]$sz.Width + 8; $ch = 15
    $cx = [int]($x - $cw/2)
    if ($cx -lt 2) { $cx = 2 }; if ($cx + $cw -gt 238) { $cx = 238 - $cw }
    $cy = if ($gr.row -eq 0) { $y - 34 } else { $y + 19 }
    $chip = New-RoundRect $cx $cy $cw $ch 7
    $bg = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(235,12,12,15))
    $g.FillPath($bg,$chip); $bg.Dispose()
    $bcol = if ($active) { [Drawing.Color]::FromArgb(90,235,140) } else { [Drawing.Color]::FromArgb(70,70,78) }
    $g.DrawPath((New-Object Drawing.Pen($bcol,1)),$chip); $chip.Dispose()
    $tx = $cx + ($cw - $sz.Width)/2; $ty = $cy + 2
    if ($active) {
      Draw-GlowText $g $txt $chipFont $tx $ty ([Drawing.Color]::FromArgb(90,235,140)) ([Drawing.Color]::FromArgb(120,245,165))
    } else {
      $b = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(185,185,192))
      $g.DrawString($txt,$chipFont,$b,$tx,$ty); $b.Dispose()
    }
  }

  # knob shadow + chrome ball
  $kr2=New-Object Drawing.Rectangle(($script:knob.X-$KR),($script:knob.Y-$KR+4),(2*$KR),(2*$KR))
  $kshadow=New-Object Drawing.Drawing2D.GraphicsPath; $kshadow.AddEllipse($kr2)
  $shb=New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(90,0,0,0))
  $g.FillPath($shb,$kshadow); $shb.Dispose(); $kshadow.Dispose()

  $kb=New-Object Drawing.Drawing2D.GraphicsPath
  $r=New-Object Drawing.Rectangle(($script:knob.X-$KR),($script:knob.Y-$KR),(2*$KR),(2*$KR))
  $kb.AddEllipse($r)
  $pgb=New-Object Drawing.Drawing2D.PathGradientBrush($kb)
  $pgb.CenterColor=[Drawing.Color]::FromArgb(255,255,255)
  $pgb.SurroundColors=@([Drawing.Color]::FromArgb(80,82,90))
  $pgb.FocusScales = New-Object Drawing.PointF(0.25,0.25)
  $pgb.CenterPoint = New-Object Drawing.PointF(($script:knob.X-6),($script:knob.Y-7))
  $g.FillEllipse($pgb,$r); $pgb.Dispose(); $kb.Dispose()
  $g.DrawEllipse((New-Object Drawing.Pen([Drawing.Color]::FromArgb(25,25,30),2)),$r)
  $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(140,255,255,255))),($script:knob.X-10),($script:knob.Y-11),10,7)
})

$p.Add_MouseDown({
  $dx=$_.X-$script:knob.X; $dy=$_.Y-$script:knob.Y
  if (($dx*$dx+$dy*$dy) -le ($KR*$KR*2.5)) { $script:drag=$true }
})
$p.Add_MouseMove({
  if (-not $script:drag) { return }
  $x=$_.X; $y=$_.Y
  if ([math]::Abs($y-$NEUT.Y) -lt 22) {
    $x=[math]::Max($COLS[0],[math]::Min($COLS[2],$x)); $y=$NEUT.Y
  } else {
    $near=$COLS[0]; foreach($c in $COLS){ if([math]::Abs($x-$c) -lt [math]::Abs($x-$near)){$near=$c} }
    $x=$near; $y=[math]::Max($ROWY[0],[math]::Min($ROWY[1],$y))
  }
  $script:knob=New-Object Drawing.Point($x,$y)
  $p.Invalidate()
})
$p.Add_MouseUp({
  if (-not $script:drag) { return }
  $script:drag=$false
  $hit=$null
  foreach ($gr in $script:gears) {
    $x=$COLS[$gr.col]; $y=$ROWY[$gr.row]
    $dx=$script:knob.X-$x; $dy=$script:knob.Y-$y
    if (($dx*$dx+$dy*$dy) -lt 1600) { $hit=$gr; break }
  }
  if ($hit) {
    $script:knob=New-Object Drawing.Point($COLS[$hit.col],$ROWY[$hit.row])
    $p.Invalidate(); $p.Update()
    Engage-Gear $hit
  } else {
    $script:knob=New-Object Drawing.Point($NEUT.X,$NEUT.Y)
    $p.Invalidate()
  }
})
$f.Controls.Add($p)

# ---- effort toggle bank (sends /reasoning <level>) ----
$script:effLevels = @(
  @{ cmd='low';    lbl='LOW' }
  @{ cmd='medium'; lbl='MED' }
  @{ cmd='high';   lbl='HIGH' }
  @{ cmd='xhigh';  lbl='XHI' }
)

$eff = New-Object Windows.Forms.Panel
$eff.SetBounds(8,522,62,96)
$eff.Cursor = 'Hand'
$eff.GetType().GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic').SetValue($eff,$true,$null)
$eff.Add_Paint({
  $g=$_.Graphics; $g.SmoothingMode='AntiAlias'; $g.Clear([Drawing.Color]::FromArgb(10,10,13))
  $lblFont = New-Object Drawing.Font('Consolas',6.5,[Drawing.FontStyle]::Bold)
  for ($i=0; $i -lt 4; $i++) {
    $lv = $script:effLevels[$i]
    $y = $i*24; $on = ($script:effort -eq $lv.cmd)
    $plate = New-RoundRect 2 ($y+3) 20 18 4
    $pb = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(2,($y+3),20,18)),[Drawing.Color]::FromArgb(60,60,68),[Drawing.Color]::FromArgb(28,28,34),90)
    $g.FillPath($pb,$plate); $pb.Dispose()
    $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(15,15,20))),$plate); $plate.Dispose()
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(150,152,160))),8,($y+8),8,8)
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(40,40,46))),10,($y+10),4,4)
    $px=12; $py=$y+12
    $tipY = if ($on) { $py-8 } else { $py+8 }
    $lp = New-Object Drawing.Pen([Drawing.Color]::FromArgb(210,212,218)),3
    $lp.StartCap='Round'; $lp.EndCap='Round'
    $g.DrawLine($lp,$px,$py,$px,$tipY); $lp.Dispose()
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(235,236,240))),($px-3),($tipY-3),6,6)
    if ($on) {
      Draw-GlowText $g $lv.lbl $lblFont 26 ($y+7) ([Drawing.Color]::FromArgb(90,235,140)) ([Drawing.Color]::FromArgb(110,240,150))
    } else {
      $b = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(110,110,118))
      $g.DrawString($lv.lbl,$lblFont,$b,26,($y+7)); $b.Dispose()
    }
  }
})
$eff.Add_MouseUp({
  # Codex has no /reasoning command -- reasoning is chosen inside the /model picker.
  # Levers are inert until we wire that up; clicking just flags the status line.
  $script:statusLbl.Text = 'EFFORT: set via /model picker in codex'
  $script:statusLbl.ForeColor = [Drawing.Color]::FromArgb(200,180,90)
})
$f.Controls.Add($eff)

# ---- NOS canister (compact / purge context) ----
$nos = New-Object Windows.Forms.Panel
$nos.SetBounds(75,522,90,96)
$nos.Cursor = 'Hand'
$nos.GetType().GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic').SetValue($nos,$true,$null)

$NOS_BX=23; $NOS_BW=44; $NOS_BY=16; $NOS_BH=64

$nos.Add_Paint({
  $g=$_.Graphics; $g.SmoothingMode='AntiAlias'; $g.Clear([Drawing.Color]::FromArgb(14,14,17))
  $pulse = $script:nitroPulse

  $g.TranslateTransform(45,48); $g.RotateTransform(-10); $g.TranslateTransform(-45,-48)

  # purge blast: white spray cone from valve, fades over ~8 ticks
  if ($script:purge -gt 0) {
    $pa = [int](24 * $script:purge)
    foreach ($ang in @(-38,-26,-14)) {
      $rad = $ang*[math]::PI/180
      $len = 26 + (8-$script:purge)*5
      $x1=$NOS_BX+$NOS_BW/2; $y1=2
      $x2=$x1+$len*[math]::Sin($rad); $y2=$y1-$len*[math]::Cos($rad)*0.8
      $pp = New-Object Drawing.Pen([Drawing.Color]::FromArgb([math]::Min(255,$pa),235,245,255)),(2+$script:purge*0.5)
      $pp.StartCap='Round'; $pp.EndCap='Round'
      $g.DrawLine($pp,$x1,$y1,$x2,$y2); $pp.Dispose()
    }
  }

  $g.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(70,70,78))),($NOS_BX+$NOS_BW/2-4),0,8,8)
  $capPath = New-RoundRect ($NOS_BX+12) 5 ($NOS_BW-24) 11 4
  $capBrush = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(($NOS_BX+12),5,($NOS_BW-24),11)),[Drawing.Color]::FromArgb(225,227,233),[Drawing.Color]::FromArgb(95,97,105),90)
  $g.FillPath($capBrush,$capPath); $capBrush.Dispose()
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(40,40,44))),$capPath); $capPath.Dispose()

  $bodyPath = New-RoundRect $NOS_BX $NOS_BY $NOS_BW $NOS_BH 18
  Draw-SoftShadow $g $bodyPath 4 3
  $bodyRect = New-Object Drawing.Rectangle($NOS_BX,$NOS_BY,$NOS_BW,$NOS_BH)
  $bodyBrush = New-Object Drawing.Drawing2D.LinearGradientBrush($bodyRect,[Drawing.Color]::White,[Drawing.Color]::White,0)
  $bcBlend = New-Object Drawing.Drawing2D.ColorBlend
  $bcBlend.Colors = @([Drawing.Color]::FromArgb(25,60,110),[Drawing.Color]::FromArgb(55,110,175),
                      [Drawing.Color]::FromArgb(140,190,235),[Drawing.Color]::FromArgb(45,95,160),
                      [Drawing.Color]::FromArgb(18,45,85))
  $bcBlend.Positions = @(0.0,0.28,0.46,0.68,1.0)
  $bodyBrush.InterpolationColors = $bcBlend
  $g.FillPath($bodyBrush,$bodyPath); $bodyBrush.Dispose()
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(15,15,20),2)),$bodyPath)

  foreach ($by in @(($NOS_BY+4),($NOS_BY+$NOS_BH-12))) {
    $band = New-RoundRect ($NOS_BX+3) $by ($NOS_BW-6) 8 3
    $bb = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(($NOS_BX+3),$by,($NOS_BW-6),8)),[Drawing.Color]::FromArgb(190,192,200),[Drawing.Color]::FromArgb(90,92,100),90)
    $g.FillPath($bb,$band); $bb.Dispose(); $band.Dispose()
  }

  $ovalRect = New-Object Drawing.Rectangle(($NOS_BX+2),([int]($NOS_BY+$NOS_BH*0.34)),($NOS_BW-4),([int]($NOS_BH*0.30)))
  $ovalPath = New-Object Drawing.Drawing2D.GraphicsPath
  $ovalPath.AddEllipse($ovalRect)
  $ovalBrush = New-Object Drawing.Drawing2D.LinearGradientBrush($ovalRect,[Drawing.Color]::FromArgb(225,35,45),[Drawing.Color]::FromArgb(140,10,20),90)
  $g.FillPath($ovalBrush,$ovalPath); $ovalBrush.Dispose()
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::White,2)),$ovalPath)
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(90,0,0,0),1)),$ovalPath); $ovalPath.Dispose()
  $nosFont = New-Object Drawing.Font('Arial',9,([Drawing.FontStyle]::Bold -bor [Drawing.FontStyle]::Italic))
  $nsz = $g.MeasureString('NOS',$nosFont)
  $ntx = $ovalRect.X + ($ovalRect.Width-$nsz.Width)/2
  $nty = $ovalRect.Y + ($ovalRect.Height-$nsz.Height)/2 + 1
  $g.DrawString('NOS',$nosFont,(New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(120,0,0,0))),($ntx+1),($nty+1))
  $g.DrawString('NOS',$nosFont,[Drawing.Brushes]::White,$ntx,$nty)

  $hl = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(($NOS_BX+4),$NOS_BY,12,$NOS_BH)),[Drawing.Color]::FromArgb(130,255,255,255),[Drawing.Color]::FromArgb(0,255,255,255),0)
  $hlPath = New-RoundRect ($NOS_BX+4) ($NOS_BY+6) 10 ($NOS_BH-16) 5
  $g.FillPath($hl,$hlPath); $hl.Dispose(); $hlPath.Dispose()

  $g.ResetTransform()

  $capFont = New-Object Drawing.Font('Consolas',7,[Drawing.FontStyle]::Bold)
  $capTxt = if ($script:purge -gt 0) { '>> PURGING <<' } else { 'PURGE // /compact' }
  $capCol = if ($script:purge -gt 0) { [Drawing.Color]::FromArgb(120,220,255) } else { [Drawing.Color]::FromArgb(110,110,118) }
  $cb2 = New-Object Drawing.SolidBrush($capCol)
  $sz = $g.MeasureString($capTxt,$capFont)
  $g.DrawString($capTxt,$capFont,$cb2,(45-$sz.Width/2),85); $cb2.Dispose()
})

$nos.Add_MouseUp({
  if (Send-Keys-To-Target '/compact') {
    $script:purge = 8
    $nos.Invalidate()
  }
})
$f.Controls.Add($nos)

$script:nitroPulse = 0
$script:purge = 0
$pulseTimer = New-Object Windows.Forms.Timer
$pulseTimer.Interval = 70
$pulseTimer.Add_Tick({
  if ($script:purge -gt 0) { $script:purge--; $nos.Invalidate() }
})
$pulseTimer.Start()

# ---- fuel + limits timer (all from the rollout file, no network) ----
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
  Update-CodexState
  $gauge.Invalidate(); $dash.Invalidate(); $lim5hPanel.Invalidate(); $limWkPanel.Invalidate()
})
$timer.Start()

# ---- usage bars (5h + weekly, from the rollout's token_count.rate_limits) ----
function Draw-LimitBar($g,[string]$label,$val) {
  $g.SmoothingMode='AntiAlias'; $g.Clear([Drawing.Color]::FromArgb(10,10,13))
  $lblFont = New-Object Drawing.Font('Consolas',7,[Drawing.FontStyle]::Bold)
  $lb = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(140,140,148))
  $sz = $g.MeasureString($label,$lblFont)
  $g.DrawString($label,$lblFont,$lb,(14-$sz.Width/2),0); $lb.Dispose()
  $track = New-RoundRect 5 14 18 62 8
  $tb = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(5,14,18,62)),[Drawing.Color]::FromArgb(10,10,12),[Drawing.Color]::FromArgb(26,26,30),0)
  $g.FillPath($tb,$track); $tb.Dispose()
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(55,55,62))),$track); $track.Dispose()
  if ($null -ne $val) {
    $h = [math]::Max(3,[int](56*$val/100))
    $c1,$c2 = if($val -lt 50){[Drawing.Color]::FromArgb(70,210,110),[Drawing.Color]::FromArgb(130,240,160)}
        elseif($val -lt 80){[Drawing.Color]::FromArgb(220,150,40),[Drawing.Color]::FromArgb(250,190,90)}
        else{[Drawing.Color]::FromArgb(200,40,50),[Drawing.Color]::FromArgb(240,90,90)}
    $fillPath = New-RoundRect 8 (17+56-$h) 12 $h 5
    $fb = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(8,(17+56-$h),12,$h)),$c2,$c1,90)
    $g.FillPath($fb,$fillPath); $fb.Dispose(); $fillPath.Dispose()
  }
  $txt = if ($null -ne $val) { "$val%" } else { '--' }
  $pb = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(190,190,198))
  $sz2 = $g.MeasureString($txt,$lblFont)
  $g.DrawString($txt,$lblFont,$pb,(14-$sz2.Width/2),80); $pb.Dispose()
}

$lim5hPanel = New-Object Windows.Forms.Panel
$lim5hPanel.SetBounds(172,522,28,96)
$lim5hPanel.GetType().GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic').SetValue($lim5hPanel,$true,$null)
$lim5hPanel.Add_Paint({ Draw-LimitBar $_.Graphics '5H' $script:lim5h })
$f.Controls.Add($lim5hPanel)

$limWkPanel = New-Object Windows.Forms.Panel
$limWkPanel.SetBounds(204,522,28,96)
$limWkPanel.GetType().GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic').SetValue($limWkPanel,$true,$null)
$limWkPanel.Add_Paint({ Draw-LimitBar $_.Graphics 'WK' $script:limWk })
$f.Controls.Add($limWkPanel)

Update-CodexState   # first read before the window shows

[void]$f.ShowDialog()
$timer.Dispose()
