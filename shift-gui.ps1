# shift-gui.ps1 - MODEL SHIFT for Claude Code on Windows
# Draggable H-pattern shifter. Drag knob into a gate -> sends "/model <x>" to your claude terminal.
# NITRO button -> "/fast" (fast-mode toggle). Fuel gauge = context remaining (reads newest session jsonl).
# Run:  powershell -sta -File shift-gui.ps1
# 1) Click SET TARGET, then click your claude terminal within 2s.  2) Drag stick.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
}
"@

# ---- gears: gate position -> /model arg ----
$script:gears = @(
  @{ id='1'; name='HAIKU';     cmd='haiku';           col=0; row=0 }
  @{ id='2'; name='SONNET';    cmd='sonnet';          col=0; row=1 }
  @{ id='3'; name='SONNET 1M'; cmd='sonnet[1m]';      col=1; row=0 }
  @{ id='4'; name='OPUS';      cmd='opus';            col=1; row=1 }
  @{ id='5'; name='FABLE';     cmd='claude-fable-5';  col=2; row=0 }
  @{ id='R'; name='DEFAULT';   cmd='default';         col=2; row=1 }
)

$script:target  = [IntPtr]::Zero
$script:curGear = $null
$script:fuel    = $null
$script:nitro   = $false
$script:lastCmd = $null
$script:fileMap = @{}     # hwnd -> locked jsonl; survives focus bouncing between chats

# ---- geometry ----
# H centered on the disc (120,124 r104); corner gates sit just inside the rim
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

function Send-Keys-To-Target([string]$text, [string]$afterOpen='') {
  # $afterOpen: keystrokes sent AFTER the command's first Enter (which opens an
  # interactive menu) and BEFORE the confirm Enter. Used by /fast: '{DOWN}' moves
  # off the pre-highlighted current state so the confirm actually flips it.
  if ($script:target -eq [IntPtr]::Zero) { $script:statusLbl.Text='SET TARGET FIRST'; return $false }
  # SW_RESTORE only when minimized -- unconditional restore un-maximized the target
  if ([Win]::IsIconic($script:target)) { [Win]::ShowWindow($script:target,9) | Out-Null }
  [Win]::SetForegroundWindow($script:target) | Out-Null
  Start-Sleep -Milliseconds 250
  $script:lastCmd = $text
  $esc = $text -replace '([+^%~(){}\[\]])','{$1}'
  [Windows.Forms.SendKeys]::SendWait($esc)
  Start-Sleep -Milliseconds 180
  [Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Milliseconds 120
  if ($afterOpen) {
    [Windows.Forms.SendKeys]::SendWait($afterOpen)
    Start-Sleep -Milliseconds 120
  }
  [Windows.Forms.SendKeys]::SendWait('{ENTER}')
  return $true
}

$script:curLimit = 200000   # best-effort: jsonl never logs context-window size,
                            # so derive it from the model id (see Get-Tank)

# model id / alias -> context window. Verified against /context: fable, opus,
# and BOTH sonnet variants (plain and [1m]) report ~1M (967k usable after the
# 33k autocompact buffer). Only haiku runs 200k. Unknown -> keep current guess.
function Get-Tank([string]$m) {
  if (-not $m) { return $script:curLimit }
  if ($m -match 'haiku') { return 200000 }
  if ($m -match '\[1m\]|fable|mythos|opus|sonnet') { return 1000000 }
  return $script:curLimit
}

# fast tail: seek to last N bytes and split lines. Get-Content -Tail took
# ~160s on a 2MB transcript (huge single-line JSON entries) and froze the UI.
# FileShare ReadWrite so we never fight claude writing the file.
function Read-TailLines([string]$path,[int]$bytes=1048576) {
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

# The target session's transcript logs the /model command we just typed.
# Scan recently-touched jsonl files for that exact command -> that file IS
# the target session. Content-match beats "newest file" (which was usually
# a different, busier session and made the gauge read the wrong chat).
function Lock-FuelFile([string]$cmdArg) {
  try {
    $proj = Join-Path $env:USERPROFILE '.claude\projects'
    $recent = Get-ChildItem $proj -Recurse -Filter *.jsonl -ErrorAction Stop |
              Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-8) }
    foreach ($file in $recent) {
      $tail = Read-TailLines $file.FullName 65536
      if ($tail -match [regex]::Escape($cmdArg)) {
        $script:fuelFile = $file
        $script:fileMap[$script:target] = $file   # remember per-terminal: focus can come back
        return $true
      }
    }
  } catch {}
  return $false
}

# ---- procedural sound: 16-bit PCM WAVs synthesized in memory, no asset files ----
# Build-Wav runs a generator (t, rnd) -> sample [-1,1] over $dur seconds and
# packs a WAV. A click/switch/hiss are broadband transients, not tones, so
# [console]::Beep can't make them -- we build the waveform sample by sample.
$twoPi = 2 * [math]::PI
function Build-Wav([double]$dur, [scriptblock]$gen) {
  $rate = 44100; $n = [int]($rate * $dur)
  $ms = New-Object IO.MemoryStream
  $bw = New-Object IO.BinaryWriter $ms
  $dataLen = $n * 2
  # pass GetBytes() directly to Write() -- a scriptblock return would unroll the
  # byte[] into loose objects and hit the wrong Write overload (corrupt header).
  $bw.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $bw.Write([int](36+$dataLen)); $bw.Write([Text.Encoding]::ASCII.GetBytes('WAVE'))
  $bw.Write([Text.Encoding]::ASCII.GetBytes('fmt ')); $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1)
  $bw.Write([int]$rate); $bw.Write([int]($rate*2)); $bw.Write([int16]2); $bw.Write([int16]16)
  $bw.Write([Text.Encoding]::ASCII.GetBytes('data')); $bw.Write([int]$dataLen)
  $rnd = New-Object Random
  for ($i=0; $i -lt $n; $i++) {
    $t = $i / $rate
    $s = & $gen $t $rnd
    if ($s -gt 1) { $s = 1 } elseif ($s -lt -1) { $s = -1 }
    $bw.Write([int16]($s * 30000))
  }
  $bw.Flush()
  return $ms.ToArray()
}

# voice generators: t = seconds since attack, r = Random for noise
$script:sfxVoices = @{
  # gear shift: the real recorded shifter clunk (decoded MP3 -> 16-bit WAV,
  # trimmed + normalized). A 664ms multi-transient mechanical sound no handful
  # of oscillators reproduces, so we play the sample itself.
  click  = @{ file = 'gear-shift.wav' }
  # effort lever: real recorded button click (decoded MP3 -> 16-bit WAV,
  # spectral-gated, isolated to the click + its ring, trimmed).
  switch = @{ file = 'switch-click.wav' }
  # NOS purge: pressurized gas -- broadband noise, sharp attack, long decay tail
  nos    = @{ dur = 0.5; gen = {
    param($t,$r)
    $env = if ($t -lt 0.006) { $t/0.006 } else { [math]::Exp(-($t-0.006)*6) }
    ($r.NextDouble()-0.5) * 2 * $env * 0.3
  }}
}
$script:sfxPlayers = @{}

function Play-Sfx([string]$name) {
  # SoundPlayer.Play() streams on a background thread -- never blocks the UI.
  try {
    if (-not $script:sfxPlayers[$name]) {
      $v = $script:sfxVoices[$name]
      $p = New-Object Media.SoundPlayer
      if ($v.file) {
        # sample on disk, next to the script; SoundPlayer needs 16-bit PCM WAV
        $p.SoundLocation = Join-Path $PSScriptRoot $v.file
      } else {
        $p.Stream = New-Object IO.MemoryStream (,(Build-Wav $v.dur $v.gen))
      }
      $p.Load()
      $script:sfxPlayers[$name] = $p
    }
    $script:sfxPlayers[$name].Play()
  } catch {}
}

function Engage-Gear($g) {
  # re-shift into same gear still re-sends when fuel is unlocked -- that's how
  # you re-bind the gauge to a different terminal without changing model
  if ($script:curGear -eq $g.id -and $script:fuelFile) { return }
  if (Send-Keys-To-Target "/model $($g.cmd)") {
    Play-Sfx 'click'
    $script:curGear  = $g.id
    $script:curLimit = Get-Tank $g.cmd
    Start-Sleep -Milliseconds 900          # give target session time to log the command
    [void](Lock-FuelFile $g.cmd)
    $script:fuel = Get-Fuel
    if ($script:dash)  { $script:dash.Invalidate() }
    if ($script:gauge) { $script:gauge.Invalidate() }
  }
}

function Get-Newest-Jsonl {
  # cached 15s: full recursive scan on every tick froze the UI thread
  if ($script:njStamp -and ((Get-Date) - $script:njStamp).TotalSeconds -lt 15) { return $script:njCache }
  try {
    $proj = Join-Path $env:USERPROFILE '.claude\projects'
    $script:njCache = Get-ChildItem $proj -Recurse -Filter *.jsonl -ErrorAction Stop |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
  } catch { $script:njCache = $null }
  $script:njStamp = Get-Date
  return $script:njCache
}

# reads $script:fuelFile (locked at shift time) so the gauge tracks the target
# terminal's session; falls back to newest jsonl when nothing is locked yet
# (single-chat case: newest IS the target, and a dead gauge helped nobody).
function Get-Fuel {
  try {
    $f = $script:fuelFile
    if (-not $f) { $f = Get-Newest-Jsonl }
    if (-not $f) { return $null }
    $lines = Read-TailLines $f.FullName   # last 1MB; first line may be partial, parse skips it

    # only usage-bearing lines are worth parsing. Tool-heavy turns can fill the
    # tail with 60+ usage-less entries -- the old fixed-count walk found nothing
    # and fell through to "100%", which read as the tank randomly resetting.
    $cand = @($lines | Where-Object { $_ -like '*"input_tokens"*' })
    $tries = 0
    for ($i = $cand.Count-1; $i -ge 0; $i--) {
      if (++$tries -gt 40) { break }   # cap parse work per tick
      try { $o = $cand[$i] | ConvertFrom-Json } catch { continue }
      if ($o.isSidechain) { continue }   # subagent turns have their own context window
      $u = $o.message.usage
      if ($u -and $null -ne $u.input_tokens) {
        # limit from this entry's own model id -- the transcript never logs
        # "/model x" as plain text (it's XML-wrapped), but every usage entry
        # carries message.model. Catches hand-typed /model switches too.
        $script:curLimit = Get-Tank $o.message.model
        $tot = [long]$u.input_tokens + [long]$u.cache_creation_input_tokens +
               [long]$u.cache_read_input_tokens + [long]$u.output_tokens
        # /context subtracts the 33k autocompact buffer only on sonnet (967k);
        # fable/opus/haiku are shown against the flat tank
        $usable = if ($o.message.model -match 'sonnet') { $script:curLimit - 33000 } else { $script:curLimit }
        return [math]::Max(0, 100 - [math]::Round(100 * $tot / $usable))
      }
    }
    # no usage entry in the tail window: keep last reading rather than lie.
    # only a genuinely tiny file (fresh chat) counts as a full tank.
    if ($lines.Count -lt 20 -and -not $cand) { return 100 }
    return $script:fuel
  } catch {}
  return $script:fuel
}

# ================= form =================
$f = New-Object Windows.Forms.Form
$f.Text='MODEL SHIFT'; $f.ClientSize = New-Object Drawing.Size(240, 640)
$f.TopMost=$true; $f.FormBorderStyle='FixedToolWindow'
$f.StartPosition='Manual'; $f.Location = New-Object Drawing.Point(40,40)

$f.Add_Paint({
  $g=$_.Graphics; $g.SmoothingMode='AntiAlias'
  $r = New-Object Drawing.Rectangle(0,0,$f.ClientSize.Width,$f.ClientSize.Height)
  $lg = New-Object Drawing.Drawing2D.LinearGradientBrush($r,[Drawing.Color]::FromArgb(30,30,36),[Drawing.Color]::FromArgb(10,10,13),90)
  $g.FillRectangle($lg,$r); $lg.Dispose()
  # accent LED top-left
  $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(220,70,70))),10,10,8,8)
  $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(120,255,120,120))),11,11,3,3)
  $tf = New-Object Drawing.Font('Consolas',9,[Drawing.FontStyle]::Bold)
  $g.DrawString('MODEL SHIFT',$tf,(New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(190,190,198))),24,8)
})

$script:statusLbl = New-Object Windows.Forms.Label
$statusLbl = $script:statusLbl
$statusLbl.Text='NO TARGET SET'; $statusLbl.ForeColor=[Drawing.Color]::FromArgb(130,130,138)
$statusLbl.SetBounds(0,30,240,16); $statusLbl.TextAlign='MiddleCenter'
$statusLbl.Font = New-Object Drawing.Font('Consolas',7,[Drawing.FontStyle]::Bold)
$statusLbl.BackColor = [Drawing.Color]::Transparent
$f.Controls.Add($statusLbl)

# target readout: auto-follows the last window you focused before the shifter.
# Jump between terminals freely -- last one touched is the target; fuel re-syncs on next shift.
$setBtn = New-Object Windows.Forms.Button
$setBtn.Text='TARGET: (focus a terminal)'; $setBtn.SetBounds(20,50,200,28)
$setBtn.FlatStyle='Flat'; $setBtn.FlatAppearance.BorderSize=1
$setBtn.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(90,90,100)
$setBtn.BackColor=[Drawing.Color]::FromArgb(52,52,60); $setBtn.ForeColor='White'
$setBtn.Font = New-Object Drawing.Font('Segoe UI',8,[Drawing.FontStyle]::Bold)
$setBtn.Enabled = $false                 # display only; targeting is automatic
$f.Controls.Add($setBtn)

# poll foreground window; any non-shifter window becomes the target
$focusTimer = New-Object Windows.Forms.Timer
$focusTimer.Interval = 500
$focusTimer.Add_Tick({
  $fg = [Win]::GetForegroundWindow()
  if ($fg -eq [IntPtr]::Zero -or $fg -eq $f.Handle) { return }
  if ($fg -ne $script:target) {
    $script:target = $fg
    # known terminal: restore its session file instead of going blank.
    # unknown: null -> Get-Fuel falls back to newest jsonl until a shift locks it.
    $script:fuelFile = $script:fileMap[$fg]
    $script:fuel = Get-Fuel
    $sb = New-Object System.Text.StringBuilder 256
    [void][Win]::GetWindowText($fg,$sb,256)
    $t = $sb.ToString(); if ($t.Length -gt 24) { $t = $t.Substring(0,24)+'..' }
    $setBtn.Text = "TARGET: $t"
    if ($script:fuelFile) { $statusLbl.Text='TARGET LOCKED - FUEL SYNCED' }
    else { $statusLbl.Text='TARGET AUTO-LOCKED - SHIFT TO SYNC FUEL' }
    $statusLbl.ForeColor=[Drawing.Color]::FromArgb(120,230,150)
    if ($script:gauge) { $script:gauge.Invalidate() }
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

  # big green digit + name
  $gid  = if ($script:curGear) { $script:curGear } else { 'N' }
  $gnm  = if ($script:curGear) { ($script:gears | Where-Object {$_.id -eq $script:curGear}).name } else { 'NEUTRAL' }
  $digFont = New-Object Drawing.Font('Consolas',28,[Drawing.FontStyle]::Bold)
  $nmFont  = New-Object Drawing.Font('Consolas',9,[Drawing.FontStyle]::Bold)
  $green = [Drawing.Color]::FromArgb(110,240,150)
  $sz = $g.MeasureString($gid,$digFont)
  Draw-GlowText $g $gid $digFont (196-$sz.Width) 2 $green $green
  $sz2 = $g.MeasureString($gnm,$nmFont)
  Draw-GlowText $g $gnm $nmFont (196-$sz2.Width) 38 $green $green

  # breadcrumb strip
  $bc = if ($script:lastCmd) { "/model $($script:lastCmd -replace '^/model ','')" } else { 'awaiting shift...' }
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
  # tank-size badge: which context window the % runs against
  $limTxt = if ($script:curLimit -ge 1000000) { '1M TANK' } else { '200K TANK' }
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

  # brushed-metal chrome: diagonal band gradient
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

  # specular gloss sweep across top
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

  # gate dimples at each slot end
  $dimple = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(16,16,20))
  foreach ($gr in $script:gears) {
    $g.FillEllipse($dimple,$COLS[$gr.col]-4,$ROWY[$gr.row]-4,8,8)
  }
  $dimple.Dispose()

  # gate labels: dark chips -- bare gray text vanished against the chrome and
  # the bottom row clipped off the panel edge
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
    $bc = if ($active) { [Drawing.Color]::FromArgb(90,235,140) } else { [Drawing.Color]::FromArgb(70,70,78) }
    $g.DrawPath((New-Object Drawing.Pen($bc,1)),$chip); $chip.Dispose()
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
    $script:curGear=$null; $script:dash.Invalidate()
    $p.Invalidate()
  }
})
$f.Controls.Add($p)

# ---- usage limits (5h session + weekly) ----
# same oauth endpoint /usage uses; token from the CLI's credentials file.
# async HttpClient: a blocking Invoke-RestMethod on the UI thread hung the window.
Add-Type -AssemblyName System.Net.Http
$script:lim5h = $null; $script:limWk = $null
$script:http = New-Object Net.Http.HttpClient
$script:http.Timeout = [TimeSpan]::FromSeconds(10)
$script:limTask = $null

function Start-LimitsFetch {
  if ($script:limTask) { return }   # one in flight at a time
  try {
    $cred = Get-Content (Join-Path $env:USERPROFILE '.claude\.credentials.json') -Raw | ConvertFrom-Json
    $req = New-Object Net.Http.HttpRequestMessage 'Get','https://api.anthropic.com/api/oauth/usage'
    $req.Headers.TryAddWithoutValidation('Authorization',"Bearer $($cred.claudeAiOauth.accessToken)") | Out-Null
    $req.Headers.TryAddWithoutValidation('anthropic-beta','oauth-2025-04-20') | Out-Null
    $script:limTask = $script:http.SendAsync($req)
  } catch { $script:limTask = $null }
}

# poll from the timer; instant when nothing / not done, never blocks
function Complete-LimitsFetch {
  if (-not $script:limTask -or -not $script:limTask.IsCompleted) { return $false }
  $task = $script:limTask; $script:limTask = $null
  try {
    $r = $task.Result.Content.ReadAsStringAsync().Result | ConvertFrom-Json
    $script:lim5h = [int][math]::Round($r.five_hour.utilization)
    $script:limWk = [int][math]::Round($r.seven_day.utilization)
    return $true
  } catch { return $false }   # expired token / offline: keep last known values
}

function Draw-LimitBar($g,[string]$label,$val) {
  $g.SmoothingMode='AntiAlias'; $g.Clear([Drawing.Color]::FromArgb(10,10,13))
  $lblFont = New-Object Drawing.Font('Consolas',7,[Drawing.FontStyle]::Bold)
  $lb = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(140,140,148))
  $sz = $g.MeasureString($label,$lblFont)
  $g.DrawString($label,$lblFont,$lb,(14-$sz.Width/2),0); $lb.Dispose()
  # vertical track, fills bottom-up with USED %
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

# ---- effort toggle bank (sends /effort <level>) ----
$script:effLevels = @(
  @{ cmd='low';    lbl='LOW' }
  @{ cmd='medium'; lbl='MED' }
  @{ cmd='high';   lbl='HIGH' }
  @{ cmd='xhigh';  lbl='XHI' }
)
$script:effort = $null   # unknown until first click; jsonl doesn't log effort

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
    # bracket plate
    $plate = New-RoundRect 2 ($y+3) 20 18 4
    $pb = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(2,($y+3),20,18)),[Drawing.Color]::FromArgb(60,60,68),[Drawing.Color]::FromArgb(28,28,34),90)
    $g.FillPath($pb,$plate); $pb.Dispose()
    $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(15,15,20))),$plate); $plate.Dispose()
    # chrome collar
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(150,152,160))),8,($y+8),8,8)
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(40,40,46))),10,($y+10),4,4)
    # lever: up = on, down = off
    $px=12; $py=$y+12
    $tipY = if ($on) { $py-8 } else { $py+8 }
    $lp = New-Object Drawing.Pen([Drawing.Color]::FromArgb(210,212,218)),3
    $lp.StartCap='Round'; $lp.EndCap='Round'
    $g.DrawLine($lp,$px,$py,$px,$tipY); $lp.Dispose()
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(235,236,240))),($px-3),($tipY-3),6,6)
    # label, glows when engaged
    if ($on) {
      Draw-GlowText $g $lv.lbl $lblFont 26 ($y+7) ([Drawing.Color]::FromArgb(90,235,140)) ([Drawing.Color]::FromArgb(110,240,150))
    } else {
      $b = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(110,110,118))
      $g.DrawString($lv.lbl,$lblFont,$b,26,($y+7)); $b.Dispose()
    }
  }
})
$eff.Add_MouseUp({
  $i = [math]::Floor($_.Y/24)
  if ($i -lt 0 -or $i -gt 3) { return }
  $lv = $script:effLevels[$i]
  if ($script:effort -eq $lv.cmd) { return }
  if (Send-Keys-To-Target "/effort $($lv.cmd)") {
    Play-Sfx 'switch'
    $script:effort = $lv.cmd
    $eff.Invalidate()
    if ($script:dash) { $script:dash.Invalidate() }   # breadcrumb shows last cmd
  }
})
$f.Controls.Add($eff)

# ---- NOS canister (nitro / fast-mode toggle) ----
$nos = New-Object Windows.Forms.Panel
$nos.SetBounds(75,522,90,96)
$nos.Cursor = 'Hand'
$nos.GetType().GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic').SetValue($nos,$true,$null)

$NOS_BX=23; $NOS_BW=44; $NOS_BY=16; $NOS_BH=64   # bottle body rect within panel

$nos.Add_Paint({
  $g=$_.Graphics; $g.SmoothingMode='AntiAlias'; $g.Clear([Drawing.Color]::FromArgb(14,14,17))
  $on = $script:nitro
  $pulse = $script:nitroPulse

  # tilt the whole bottle like it's mounted on a bracket
  $g.TranslateTransform(45,48); $g.RotateTransform(-10); $g.TranslateTransform(-45,-48)

  # outer glow bloom when engaged
  if ($on) {
    for ($i=5; $i -ge 1; $i--) {
      $a = [int]((16 + 9*[math]::Sin($pulse/2.5)) * $i)
      $gp = New-RoundRect ($NOS_BX-$i*3) ($NOS_BY-$i*3) ($NOS_BW+$i*6) ($NOS_BH+$i*6) (16+$i*2)
      $gb = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb([math]::Min(255,$a),60,200,255))
      $g.FillPath($gb,$gp); $gb.Dispose(); $gp.Dispose()
    }
  }

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

  # valve + cap assembly
  $g.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(70,70,78))),($NOS_BX+$NOS_BW/2-4),0,8,8)
  $capPath = New-RoundRect ($NOS_BX+12) 5 ($NOS_BW-24) 11 4
  $capBrush = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(($NOS_BX+12),5,($NOS_BW-24),11)),[Drawing.Color]::FromArgb(225,227,233),[Drawing.Color]::FromArgb(95,97,105),90)
  $g.FillPath($capBrush,$capPath); $capBrush.Dispose()
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(40,40,44))),$capPath); $capPath.Dispose()

  # bottle body
  $bodyPath = New-RoundRect $NOS_BX $NOS_BY $NOS_BW $NOS_BH 18
  Draw-SoftShadow $g $bodyPath 4 3
  $bodyRect = New-Object Drawing.Rectangle($NOS_BX,$NOS_BY,$NOS_BW,$NOS_BH)
  $bodyBrush = New-Object Drawing.Drawing2D.LinearGradientBrush($bodyRect,[Drawing.Color]::White,[Drawing.Color]::White,0)
  $bcBlend = New-Object Drawing.Drawing2D.ColorBlend
  if ($on) {
    $bcBlend.Colors = @([Drawing.Color]::FromArgb(15,55,125),[Drawing.Color]::FromArgb(60,150,235),
                        [Drawing.Color]::FromArgb(200,240,255),[Drawing.Color]::FromArgb(45,130,215),
                        [Drawing.Color]::FromArgb(10,40,95))
  } else {
    $bcBlend.Colors = @([Drawing.Color]::FromArgb(25,60,110),[Drawing.Color]::FromArgb(55,110,175),
                        [Drawing.Color]::FromArgb(140,190,235),[Drawing.Color]::FromArgb(45,95,160),
                        [Drawing.Color]::FromArgb(18,45,85))
  }
  $bcBlend.Positions = @(0.0,0.28,0.46,0.68,1.0)
  $bodyBrush.InterpolationColors = $bcBlend
  $g.FillPath($bodyBrush,$bodyPath); $bodyBrush.Dispose()
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(15,15,20),2)),$bodyPath)

  # neck band + bottom band (brushed steel)
  foreach ($by in @(($NOS_BY+4),($NOS_BY+$NOS_BH-12))) {
    $band = New-RoundRect ($NOS_BX+3) $by ($NOS_BW-6) 8 3
    $bb = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(($NOS_BX+3),$by,($NOS_BW-6),8)),[Drawing.Color]::FromArgb(190,192,200),[Drawing.Color]::FromArgb(90,92,100),90)
    $g.FillPath($bb,$band); $bb.Dispose(); $band.Dispose()
  }

  # red oval badge, classic NOS style
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
  if ($on) { Draw-GlowText $g 'NOS' $nosFont $ntx $nty ([Drawing.Color]::FromArgb(160,230,255)) ([Drawing.Color]::White) }
  else     { $g.DrawString('NOS',$nosFont,[Drawing.Brushes]::White,$ntx,$nty) }

  # glass highlight down the left edge
  $hl = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(($NOS_BX+4),$NOS_BY,12,$NOS_BH)),[Drawing.Color]::FromArgb(130,255,255,255),[Drawing.Color]::FromArgb(0,255,255,255),0)
  $hlPath = New-RoundRect ($NOS_BX+4) ($NOS_BY+6) 10 ($NOS_BH-16) 5
  $g.FillPath($hl,$hlPath); $hl.Dispose(); $hlPath.Dispose()

  $g.ResetTransform()

  # status caption (unrotated)
  $capFont = New-Object Drawing.Font('Consolas',7,[Drawing.FontStyle]::Bold)
  $capTxt = if ($on) { '>> FAST MODE ENGAGED <<' } else { 'PRESS TO PURGE // /fast' }
  $capCol = if ($on) { [Drawing.Color]::FromArgb(120,220,255) } else { [Drawing.Color]::FromArgb(110,110,118) }
  $cb2 = New-Object Drawing.SolidBrush($capCol)
  $sz = $g.MeasureString($capTxt,$capFont)
  $g.DrawString($capTxt,$capFont,$cb2,(45-$sz.Width/2),85); $cb2.Dispose()
})

$nos.Add_MouseUp({
  # /fast opens a 2-item On/Off menu with the current state pre-highlighted; it
  # wraps, so one {DOWN} always lands on the opposite -> confirm Enter flips it.
  # ponytail: nitro LED tracks flips relative to itself; if it ever drifts from
  # the real state the toggle still flips correctly, only the light reads wrong.
  if (Send-Keys-To-Target '/fast' '{DOWN}') {
    Play-Sfx 'nos'
    $script:nitro = -not $script:nitro
    $script:purge = 8                    # spray burst animation
    $nos.Invalidate()
  }
})
$f.Controls.Add($nos)

$script:nitroPulse = 0
$script:purge = 0
$pulseTimer = New-Object Windows.Forms.Timer
$pulseTimer.Interval = 70
$pulseTimer.Add_Tick({
  $dirty = $false
  if ($script:nitro) { $script:nitroPulse++; $dirty = $true }
  if ($script:purge -gt 0) { $script:purge--; $dirty = $true }
  if ($dirty) { $nos.Invalidate() }
})
$pulseTimer.Start()

# ---- fuel + limits timer ----
$script:limTick = 0
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
  $script:fuel = Get-Fuel; $gauge.Invalidate()
  if (Complete-LimitsFetch) { $lim5hPanel.Invalidate(); $limWkPanel.Invalidate() }
  $script:limTick++
  if ($script:limTick -ge 60) { $script:limTick = 0; Start-LimitsFetch }   # every 5 min
})
$timer.Start()
$script:fuel = Get-Fuel
Start-LimitsFetch   # first result lands on an early tick

[void]$f.ShowDialog()
$timer.Dispose()
