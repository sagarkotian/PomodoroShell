#requires -Version 5.1

<#
.SYNOPSIS
    A minimal, keyboard-driven Pomodoro timer for the terminal.

.EXAMPLE
    .\PomodoroShell.ps1

.EXAMPLE
    .\PomodoroShell.ps1 -FocusMinutes 50 -ShortBreakMinutes 10 -AutoStart

.EXAMPLE
    .\PomodoroShell.ps1 -Task 'Write project proposal'
#>

[CmdletBinding()]
param(
    [ValidateRange(0.0167, 1440)]
    [double] $FocusMinutes = 25,

    [ValidateRange(0.0167, 1440)]
    [double] $ShortBreakMinutes = 5,

    [ValidateRange(0.0167, 1440)]
    [double] $LongBreakMinutes = 15,

    [ValidateRange(1, 20)]
    [int] $SessionsBeforeLongBreak = 4,

    [switch] $AutoStart,

    [switch] $NoSound,

    [switch] $NoNotification,

    [AllowEmptyString()]
    [ValidateLength(0, 120)]
    [string] $Task = '',

    [ValidateNotNullOrEmpty()]
    [string] $DataDirectory,

    [switch] $NoPersistence
)

Set-StrictMode -Version 2.0

function Get-PomodoroDataDirectory {
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localData)) {
        $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    }
    if ([string]::IsNullOrWhiteSpace($localData)) {
        $localData = [IO.Path]::GetTempPath()
    }
    return [IO.Path]::Combine($localData, 'PomodoroShell')
}

function New-DefaultPomodoroSettings {
    return [ordered]@{
        Version                   = 1
        FocusMinutes              = 25.0
        ShortBreakMinutes         = 5.0
        LongBreakMinutes          = 15.0
        SessionsBeforeLongBreak   = 4
        AutoStart                 = $false
        Sound                     = $true
        Notifications             = $true
        LastTask                  = ''
    }
}

function Get-ObjectPropertyValue {
    param(
        [object] $InputObject,
        [string] $Name,
        [object] $DefaultValue
    )

    if (($null -ne $InputObject) -and ($null -ne $InputObject.PSObject.Properties[$Name])) {
        return $InputObject.$Name
    }
    return $DefaultValue
}

function Read-PomodoroSettings {
    param([string] $Path)

    $settings = New-DefaultPomodoroSettings
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $settings
    }

    try {
        $saved = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

        $focus = [double](Get-ObjectPropertyValue $saved 'FocusMinutes' $settings.FocusMinutes)
        if (($focus -ge 0.0167) -and ($focus -le 1440)) { $settings.FocusMinutes = $focus }

        $short = [double](Get-ObjectPropertyValue $saved 'ShortBreakMinutes' $settings.ShortBreakMinutes)
        if (($short -ge 0.0167) -and ($short -le 1440)) { $settings.ShortBreakMinutes = $short }

        $long = [double](Get-ObjectPropertyValue $saved 'LongBreakMinutes' $settings.LongBreakMinutes)
        if (($long -ge 0.0167) -and ($long -le 1440)) { $settings.LongBreakMinutes = $long }

        $sessions = [int](Get-ObjectPropertyValue $saved 'SessionsBeforeLongBreak' $settings.SessionsBeforeLongBreak)
        if (($sessions -ge 1) -and ($sessions -le 20)) { $settings.SessionsBeforeLongBreak = $sessions }

        $settings.AutoStart = [bool](Get-ObjectPropertyValue $saved 'AutoStart' $settings.AutoStart)
        $settings.Sound = [bool](Get-ObjectPropertyValue $saved 'Sound' $settings.Sound)
        $settings.Notifications = [bool](Get-ObjectPropertyValue $saved 'Notifications' $settings.Notifications)

        $lastTask = [string](Get-ObjectPropertyValue $saved 'LastTask' '')
        $settings.LastTask = (ConvertTo-SafeTaskLabel -Value $lastTask)
    }
    catch {
        # A damaged settings file should never prevent the timer from starting.
    }
    return $settings
}

function Write-PomodoroSettings {
    param(
        [string] $Path,
        [System.Collections.IDictionary] $Settings
    )

    try {
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop
        }
        $json = $Settings | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
        return $true
    }
    catch {
        return $false
    }
}

function ConvertTo-SafeTaskLabel {
    param([AllowEmptyString()][string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $safe = [Text.RegularExpressions.Regex]::Replace($Value, '[\x00-\x1F\x7F]', ' ')
    $safe = [Text.RegularExpressions.Regex]::Replace($safe, '\s+', ' ').Trim()
    if ($safe.Length -gt 120) {
        $safe = $safe.Substring(0, 120).TrimEnd()
    }
    return $safe
}

function Get-TodayHistorySummary {
    param([string] $Path)

    $summary = [ordered]@{ Count = 0; Seconds = 0 }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $summary
    }

    $today = [DateTime]::Today
    try {
        foreach ($line in [IO.File]::ReadLines($Path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json -ErrorAction Stop
                $timestamp = [DateTimeOffset]::Parse([string]$entry.timestamp).LocalDateTime
                if ($timestamp.Date -eq $today) {
                    $summary.Count++
                    $summary.Seconds += [int](Get-ObjectPropertyValue $entry 'durationSeconds' 0)
                }
            }
            catch {
                # Ignore a malformed line while preserving the rest of the history.
            }
        }
    }
    catch {
        # History is optional; return an empty summary when it cannot be read.
    }
    return $summary
}

function Add-PomodoroHistoryEntry {
    param(
        [string] $Path,
        [string] $TaskLabel,
        [int] $DurationSeconds,
        [int] $SessionNumber
    )

    try {
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop
        }
        $entry = [ordered]@{
            timestamp       = [DateTimeOffset]::Now.ToString('o')
            task            = $TaskLabel
            durationSeconds = $DurationSeconds
            sessionNumber   = $SessionNumber
        }
        $jsonLine = ($entry | ConvertTo-Json -Compress) + [Environment]::NewLine
        [IO.File]::AppendAllText($Path, $jsonLine, (New-Object Text.UTF8Encoding($false)))
        return $true
    }
    catch {
        return $false
    }
}

function ConvertTo-WholeSeconds {
    param([double] $Minutes)

    return [Math]::Max(1, [int][Math]::Round($Minutes * 60))
}

function New-PomodoroState {
    param(
        [int] $FocusSeconds,
        [int] $ShortBreakSeconds,
        [int] $LongBreakSeconds,
        [int] $LongBreakEvery,
        [string] $TaskLabel = '',
        [int] $TodayFocusCount = 0,
        [long] $TodayFocusSeconds = 0
    )

    $now = [DateTime]::UtcNow
    return [ordered]@{
        Mode                 = 'FOCUS'
        DurationSeconds      = $FocusSeconds
        RemainingSeconds     = [double]$FocusSeconds
        IsRunning            = $true
        Deadline             = $now.AddSeconds($FocusSeconds)
        CompletedFocus       = 0
        IntervalNumber       = 1
        FocusSeconds         = $FocusSeconds
        ShortBreakSeconds    = $ShortBreakSeconds
        LongBreakSeconds     = $LongBreakSeconds
        SessionsBeforeLong   = $LongBreakEvery
        Task                 = $TaskLabel
        TodayFocus           = $TodayFocusCount
        TodaySeconds         = $TodayFocusSeconds
        Notice               = 'FLOW STATE ACTIVE'
        NoticeExpires        = $now.AddSeconds(2)
    }
}

function Start-PomodoroClock {
    param([System.Collections.IDictionary] $State)

    if (-not $State.IsRunning) {
        $State.IsRunning = $true
        $State.Deadline = [DateTime]::UtcNow.AddSeconds($State.RemainingSeconds)
        $State.Notice = 'RESUMED'
        $State.NoticeExpires = [DateTime]::UtcNow.AddSeconds(1.5)
    }
}

function Stop-PomodoroClock {
    param([System.Collections.IDictionary] $State)

    if ($State.IsRunning) {
        $State.RemainingSeconds = [Math]::Max(
            0,
            ($State.Deadline - [DateTime]::UtcNow).TotalSeconds
        )
        $State.IsRunning = $false
        $State.Notice = 'PAUSED'
        $State.NoticeExpires = [DateTime]::MaxValue
    }
}

function Reset-PomodoroClock {
    param([System.Collections.IDictionary] $State)

    $State.RemainingSeconds = [double]$State.DurationSeconds
    $State.IsRunning = $true
    $State.Deadline = [DateTime]::UtcNow.AddSeconds($State.DurationSeconds)
    $State.Notice = 'INTERVAL RESET'
    $State.NoticeExpires = [DateTime]::UtcNow.AddSeconds(1.5)
}

function Add-PomodoroTime {
    param(
        [System.Collections.IDictionary] $State,
        [int] $Seconds
    )

    $newRemaining = [Math]::Max(1, $State.RemainingSeconds + $Seconds)
    $actualChange = $newRemaining - $State.RemainingSeconds
    $State.RemainingSeconds = $newRemaining
    $State.DurationSeconds = [Math]::Max(1, [int]($State.DurationSeconds + $actualChange))

    if ($State.IsRunning) {
        $State.Deadline = [DateTime]::UtcNow.AddSeconds($State.RemainingSeconds)
    }

    if ($actualChange -ge 0) {
        $State.Notice = '+1 MINUTE'
    }
    else {
        $State.Notice = '-1 MINUTE'
    }
    $State.NoticeExpires = [DateTime]::UtcNow.AddSeconds(1.5)
}

function Move-ToNextInterval {
    param(
        [System.Collections.IDictionary] $State,
        [bool] $Completed,
        [bool] $StartImmediately
    )

    $previousMode = $State.Mode

    if (($previousMode -eq 'FOCUS') -and $Completed) {
        $State.CompletedFocus++
    }

    if ($previousMode -eq 'FOCUS') {
        if ($Completed -and
            ($State.CompletedFocus -gt 0) -and
            (($State.CompletedFocus % $State.SessionsBeforeLong) -eq 0)) {
            $State.Mode = 'LONG BREAK'
            $State.DurationSeconds = $State.LongBreakSeconds
        }
        else {
            $State.Mode = 'SHORT BREAK'
            $State.DurationSeconds = $State.ShortBreakSeconds
        }
    }
    else {
        $State.Mode = 'FOCUS'
        $State.DurationSeconds = $State.FocusSeconds
    }

    $State.IntervalNumber++
    $State.RemainingSeconds = [double]$State.DurationSeconds
    $State.IsRunning = $StartImmediately

    if ($StartImmediately) {
        $State.Deadline = [DateTime]::UtcNow.AddSeconds($State.DurationSeconds)
        $State.Notice = 'NEXT INTERVAL ACTIVE'
        $State.NoticeExpires = [DateTime]::UtcNow.AddSeconds(2)
    }
    else {
        $State.Deadline = [DateTime]::MaxValue
        $State.Notice = 'READY // PRESS SPACE'
        $State.NoticeExpires = [DateTime]::MaxValue
    }
}

function Invoke-IntervalAlert {
    param([switch] $Muted)

    if ($Muted) {
        return
    }

    $beepSucceeded = $false
    try {
        $tones = @(
            @(880, 130),
            @(1100, 130),
            @(1320, 220),
            @(1100, 130),
            @(1320, 300)
        )
        foreach ($tone in $tones) {
            [Console]::Beep([int]$tone[0], [int]$tone[1])
        }
        $beepSucceeded = $true
    }
    catch {
        # Some terminals and non-Windows hosts do not implement Console.Beep.
    }

    if (-not $beepSucceeded) {
        try {
            [Console]::Write([char]7)
            [System.Media.SystemSounds]::Exclamation.Play()
        }
        catch {
            # Sound is best-effort; the visual state still changes on completion.
        }
    }
}

function Test-IsWindowsPlatform {
    if ($PSVersionTable.PSVersion.Major -le 5) {
        return $true
    }
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Invoke-DesktopNotification {
    param(
        [bool] $Enabled,
        [string] $Title,
        [string] $Message
    )

    if ((-not $Enabled) -or (-not (Test-IsWindowsPlatform))) {
        return $null
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $notification = New-Object System.Windows.Forms.NotifyIcon
        $notification.Icon = [System.Drawing.SystemIcons]::Information
        $notification.Visible = $true
        $notification.Text = 'PomodoroShell'
        $notification.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $notification.BalloonTipTitle = $Title
        $notification.BalloonTipText = $Message
        $notification.ShowBalloonTip(5000)
        return $notification
    }
    catch {
        if ($null -ne (Get-Variable -Name notification -ValueOnly -ErrorAction SilentlyContinue)) {
            $notification.Visible = $false
            $notification.Dispose()
        }
        return $null
    }
}

function Close-DesktopNotification {
    param([object] $Notification)

    if ($null -eq $Notification) {
        return
    }

    try {
        $Notification.Visible = $false
        $Notification.Dispose()
    }
    catch {
        # Notification cleanup must not interrupt the timer or terminal cleanup.
    }
}

function Test-VirtualTerminalSupport {
    try {
        if ($null -ne $Host.UI.PSObject.Properties['SupportsVirtualTerminal']) {
            return [bool]$Host.UI.SupportsVirtualTerminal
        }
    }
    catch {
        # Fall through to environment-based detection.
    }
    return (-not [string]::IsNullOrWhiteSpace($env:WT_SESSION)) -or
        (($env:TERM) -and ($env:TERM -ne 'dumb'))
}

function Enter-PomodoroTerminalScreen {
    if (-not (Test-VirtualTerminalSupport)) {
        return $false
    }

    try {
        $escape = [char]27
        [Console]::Write("$escape[?1049h$escape[2J$escape[H$escape[?25l")
        return $true
    }
    catch {
        return $false
    }
}

function Exit-PomodoroTerminalScreen {
    param([bool] $UsingAlternateScreen)

    if (-not $UsingAlternateScreen) {
        return
    }

    try {
        $escape = [char]27
        [Console]::Write("$escape[0m$escape[?25h$escape[?1049l")
    }
    catch {
        # Console state is also restored by the caller's finally block.
    }
}

function Get-ModeColor {
    param([string] $Mode)

    switch ($Mode) {
        'FOCUS'       { return [ConsoleColor]::Cyan }
        'SHORT BREAK' { return [ConsoleColor]::Green }
        'LONG BREAK'  { return [ConsoleColor]::Magenta }
        default       { return [ConsoleColor]::Gray }
    }
}

function Get-CyclePosition {
    param([System.Collections.IDictionary] $State)

    if ($State.Mode -eq 'FOCUS') {
        return ($State.CompletedFocus % $State.SessionsBeforeLong) + 1
    }

    if ($State.CompletedFocus -eq 0) {
        return 1
    }
    return (($State.CompletedFocus - 1) % $State.SessionsBeforeLong) + 1
}

function Format-ClockValue {
    param([double] $Seconds)

    $wholeSeconds = [Math]::Max(0, [int][Math]::Ceiling($Seconds))
    $hours = [Math]::Floor($wholeSeconds / 3600)
    $minutes = [Math]::Floor(($wholeSeconds % 3600) / 60)
    $secondsPart = $wholeSeconds % 60

    if ($hours -gt 0) {
        return '{0:00}:{1:00}:{2:00}' -f $hours, $minutes, $secondsPart
    }
    return '{0:00}:{1:00}' -f $minutes, $secondsPart
}

function Get-ProgressBar {
    param(
        [System.Collections.IDictionary] $State,
        [int] $Width
    )

    $safeDuration = [Math]::Max(1, $State.DurationSeconds)
    $progress = 1 - ($State.RemainingSeconds / $safeDuration)
    $progress = [Math]::Max(0, [Math]::Min(1, $progress))
    $filled = [int][Math]::Floor($Width * $progress)
    return '[' + ('=' * $filled) + ('-' * ($Width - $filled)) + ']'
}

function Write-CenteredConsoleLine {
    param(
        [string] $Text,
        [int] $Row,
        [int] $ConsoleWidth,
        [ConsoleColor] $Color
    )

    $drawableWidth = [Math]::Max(1, $ConsoleWidth - 1)
    if ($Text.Length -gt $drawableWidth) {
        $Text = $Text.Substring(0, $drawableWidth)
    }

    $left = [Math]::Max(0, [int][Math]::Floor(($drawableWidth - $Text.Length) / 2))
    [Console]::SetCursorPosition(0, $Row)
    [Console]::Write(' ' * $drawableWidth)
    [Console]::SetCursorPosition($left, $Row)
    [Console]::ForegroundColor = $Color
    [Console]::Write($Text)
}

function Show-PomodoroFrame {
    param(
        [System.Collections.IDictionary] $State,
        [ref] $LastWidth,
        [ref] $LastHeight,
        [ref] $LastSignature
    )

    $width = [Console]::WindowWidth
    $height = [Console]::WindowHeight
    if (($width -lt 28) -or ($height -lt 13)) {
        $smallSignature = 'SMALL:{0}:{1}' -f $width, $height
        if ($smallSignature -eq $LastSignature.Value) {
            return
        }
        $LastSignature.Value = $smallSignature
        [Console]::SetCursorPosition(0, 0)
        [Console]::ForegroundColor = [ConsoleColor]::Yellow
        [Console]::Write(('Resize terminal to at least 28 x 13. Current: {0} x {1}' -f $width, $height).PadRight([Math]::Max(1, $width - 1)))
        return
    }

    if (($width -ne $LastWidth.Value) -or ($height -ne $LastHeight.Value)) {
        [Console]::Clear()
        $LastWidth.Value = $width
        $LastHeight.Value = $height
    }

    $barWidth = [Math]::Max(16, [Math]::Min(46, $width - 10))
    $modeColor = Get-ModeColor -Mode $State.Mode
    $status = if ($State.IsRunning) { 'RUNNING' } else { 'STANDBY' }
    $notice = $status
    if ([DateTime]::UtcNow -lt $State.NoticeExpires) {
        $notice = $State.Notice
    }

    $cyclePosition = Get-CyclePosition -State $State
    $taskText = if ([string]::IsNullOrWhiteSpace($State.Task)) { 'TASK // UNLABELED' } else { 'TASK // ' + $State.Task }
    $todayMinutes = [int][Math]::Floor($State.TodaySeconds / 60)
    $lines = @(
        @{ Text = 'P O M O D O R O'; Color = [ConsoleColor]::DarkGray },
        @{ Text = $taskText; Color = [ConsoleColor]::DarkGray },
        @{ Text = ''; Color = [ConsoleColor]::Gray },
        @{ Text = ('{0}  //  {1:00}' -f $State.Mode, $State.IntervalNumber); Color = $modeColor },
        @{ Text = (Format-ClockValue -Seconds $State.RemainingSeconds); Color = [ConsoleColor]::White },
        @{ Text = (Get-ProgressBar -State $State -Width $barWidth); Color = $modeColor },
        @{ Text = ''; Color = [ConsoleColor]::Gray },
        @{ Text = ('CYCLE {0:00}/{1:00}    TODAY {2:00} / {3}M' -f $cyclePosition, $State.SessionsBeforeLong, $State.TodayFocus, $todayMinutes); Color = [ConsoleColor]::DarkGray },
        @{ Text = $notice; Color = $modeColor },
        @{ Text = ''; Color = [ConsoleColor]::Gray },
        @{ Text = 'SPACE pause/resume   R reset   S skip   Q quit'; Color = [ConsoleColor]::DarkGray },
        @{ Text = 'LEFT -1m   RIGHT +1m'; Color = [ConsoleColor]::DarkGray }
    )

    $signatureParts = @($width, $height)
    $signatureParts += @($lines | ForEach-Object { $_.Text })
    $signature = $signatureParts -join '|'
    if ($signature -eq $LastSignature.Value) {
        return
    }
    $LastSignature.Value = $signature

    $top = [Math]::Max(0, [int][Math]::Floor(($height - $lines.Count) / 2))
    for ($row = 0; $row -lt ($height - 1); $row++) {
        if (($row -lt $top) -or ($row -ge ($top + $lines.Count))) {
            [Console]::SetCursorPosition(0, $row)
            [Console]::Write(' ' * ($width - 1))
        }
    }

    for ($index = 0; $index -lt $lines.Count; $index++) {
        Write-CenteredConsoleLine `
            -Text $lines[$index].Text `
            -Row ($top + $index) `
            -ConsoleWidth $width `
            -Color $lines[$index].Color
    }
}

function Start-PomodoroShell {
    param(
        [double] $FocusLength,
        [double] $ShortBreakLength,
        [double] $LongBreakLength,
        [int] $LongBreakEvery,
        [bool] $StartNextAutomatically,
        [bool] $Mute,
        [bool] $EnableNotifications,
        [string] $TaskLabel,
        [bool] $Persist,
        [string] $HistoryPath
    )

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'PomodoroShell needs an interactive terminal for its keyboard-driven interface.'
    }

    $todaySummary = if ($Persist) {
        Get-TodayHistorySummary -Path $HistoryPath
    }
    else {
        [ordered]@{ Count = 0; Seconds = 0 }
    }

    $state = New-PomodoroState `
        -FocusSeconds (ConvertTo-WholeSeconds $FocusLength) `
        -ShortBreakSeconds (ConvertTo-WholeSeconds $ShortBreakLength) `
        -LongBreakSeconds (ConvertTo-WholeSeconds $LongBreakLength) `
        -LongBreakEvery $LongBreakEvery `
        -TaskLabel $TaskLabel `
        -TodayFocusCount $todaySummary.Count `
        -TodayFocusSeconds $todaySummary.Seconds

    $originalCursorVisible = [Console]::CursorVisible
    $originalForeground = [Console]::ForegroundColor
    $originalTitle = [Console]::Title
    $lastWidth = -1
    $lastHeight = -1
    $lastSignature = ''
    $quit = $false
    $usingAlternateScreen = $false
    $activeNotification = $null
    $notificationExpires = [DateTime]::MinValue

    try {
        $titleTask = if ([string]::IsNullOrWhiteSpace($TaskLabel)) { '' } else { ' - ' + $TaskLabel }
        [Console]::Title = 'PomodoroShell' + $titleTask
        $usingAlternateScreen = Enter-PomodoroTerminalScreen
        [Console]::CursorVisible = $false
        if (-not $usingAlternateScreen) {
            [Console]::Clear()
        }

        while (-not $quit) {
            $now = [DateTime]::UtcNow
            if (($null -ne $activeNotification) -and ($now -ge $notificationExpires)) {
                Close-DesktopNotification -Notification $activeNotification
                $activeNotification = $null
            }

            if ($state.IsRunning) {
                $state.RemainingSeconds = [Math]::Max(0, ($state.Deadline - $now).TotalSeconds)
                if ($state.RemainingSeconds -le 0) {
                    $completedMode = $state.Mode
                    $completedDuration = $state.DurationSeconds
                    $completedSessionNumber = $state.CompletedFocus + 1

                    if ($completedMode -eq 'FOCUS') {
                        if ($Persist) {
                            $null = Add-PomodoroHistoryEntry `
                                -Path $HistoryPath `
                                -TaskLabel $state.Task `
                                -DurationSeconds $completedDuration `
                                -SessionNumber $completedSessionNumber
                        }
                        $state.TodayFocus++
                        $state.TodaySeconds += $completedDuration
                    }

                    Move-ToNextInterval `
                        -State $state `
                        -Completed $true `
                        -StartImmediately $StartNextAutomatically

                    if ($completedMode -eq 'FOCUS') {
                        $notificationTitle = 'Focus interval complete'
                        $notificationMessage = 'Time for a {0}.' -f $state.Mode.ToLowerInvariant()
                    }
                    else {
                        $notificationTitle = 'Break complete'
                        $notificationMessage = if ([string]::IsNullOrWhiteSpace($state.Task)) {
                            'Your next focus interval is ready.'
                        }
                        else {
                            'Ready to focus on: ' + $state.Task
                        }
                    }

                    Show-PomodoroFrame -State $state -LastWidth ([ref]$lastWidth) -LastHeight ([ref]$lastHeight) -LastSignature ([ref]$lastSignature)
                    Close-DesktopNotification -Notification $activeNotification
                    $activeNotification = Invoke-DesktopNotification `
                        -Enabled $EnableNotifications `
                        -Title $notificationTitle `
                        -Message $notificationMessage
                    $notificationExpires = [DateTime]::UtcNow.AddSeconds(6)
                    Invoke-IntervalAlert -Muted:$Mute
                }
            }

            Show-PomodoroFrame -State $state -LastWidth ([ref]$lastWidth) -LastHeight ([ref]$lastHeight) -LastSignature ([ref]$lastSignature)

            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'Spacebar' {
                        if ($state.IsRunning) {
                            Stop-PomodoroClock -State $state
                        }
                        else {
                            Start-PomodoroClock -State $state
                        }
                    }
                    'R' { Reset-PomodoroClock -State $state }
                    'S' {
                        Move-ToNextInterval -State $state -Completed $false -StartImmediately $true
                    }
                    'LeftArrow' { Add-PomodoroTime -State $state -Seconds -60 }
                    'RightArrow' { Add-PomodoroTime -State $state -Seconds 60 }
                    'Q' { $quit = $true }
                }
            }

            Start-Sleep -Milliseconds 100
        }
    }
    finally {
        Close-DesktopNotification -Notification $activeNotification
        [Console]::ForegroundColor = $originalForeground
        [Console]::Title = $originalTitle
        Exit-PomodoroTerminalScreen -UsingAlternateScreen $usingAlternateScreen
        [Console]::CursorVisible = $originalCursorVisible
        if (-not $usingAlternateScreen) {
            [Console]::Clear()
        }
        Write-Host ('PomodoroShell closed. This run: {0} focus interval(s). Today: {1} ({2} min).' -f $state.CompletedFocus, $state.TodayFocus, [int][Math]::Floor($state.TodaySeconds / 60))
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $persistData = -not $NoPersistence.IsPresent
    $resolvedDataDirectory = if ($PSBoundParameters.ContainsKey('DataDirectory')) {
        [IO.Path]::GetFullPath($DataDirectory)
    }
    else {
        Get-PomodoroDataDirectory
    }
    $settingsPath = [IO.Path]::Combine($resolvedDataDirectory, 'settings.json')
    $historyPath = [IO.Path]::Combine($resolvedDataDirectory, 'history.jsonl')
    $savedSettings = if ($persistData) {
        Read-PomodoroSettings -Path $settingsPath
    }
    else {
        New-DefaultPomodoroSettings
    }

    $effectiveFocus = if ($PSBoundParameters.ContainsKey('FocusMinutes')) { $FocusMinutes } else { $savedSettings.FocusMinutes }
    $effectiveShortBreak = if ($PSBoundParameters.ContainsKey('ShortBreakMinutes')) { $ShortBreakMinutes } else { $savedSettings.ShortBreakMinutes }
    $effectiveLongBreak = if ($PSBoundParameters.ContainsKey('LongBreakMinutes')) { $LongBreakMinutes } else { $savedSettings.LongBreakMinutes }
    $effectiveLongBreakEvery = if ($PSBoundParameters.ContainsKey('SessionsBeforeLongBreak')) { $SessionsBeforeLongBreak } else { $savedSettings.SessionsBeforeLongBreak }
    $effectiveAutoStart = if ($PSBoundParameters.ContainsKey('AutoStart')) { $AutoStart.IsPresent } else { [bool]$savedSettings.AutoStart }
    $effectiveSound = if ($PSBoundParameters.ContainsKey('NoSound')) { -not $NoSound.IsPresent } else { [bool]$savedSettings.Sound }
    $effectiveNotifications = if ($PSBoundParameters.ContainsKey('NoNotification')) { -not $NoNotification.IsPresent } else { [bool]$savedSettings.Notifications }
    $effectiveTask = if ($PSBoundParameters.ContainsKey('Task')) { ConvertTo-SafeTaskLabel $Task } else { ConvertTo-SafeTaskLabel ([string]$savedSettings.LastTask) }

    if ($persistData) {
        $effectiveSettings = [ordered]@{
            Version                 = 1
            FocusMinutes            = [double]$effectiveFocus
            ShortBreakMinutes       = [double]$effectiveShortBreak
            LongBreakMinutes        = [double]$effectiveLongBreak
            SessionsBeforeLongBreak = [int]$effectiveLongBreakEvery
            AutoStart               = [bool]$effectiveAutoStart
            Sound                   = [bool]$effectiveSound
            Notifications           = [bool]$effectiveNotifications
            LastTask                = $effectiveTask
        }
        if (-not (Write-PomodoroSettings -Path $settingsPath -Settings $effectiveSettings)) {
            Write-Warning "Settings could not be saved to '$settingsPath'."
        }
    }

    Start-PomodoroShell `
        -FocusLength $effectiveFocus `
        -ShortBreakLength $effectiveShortBreak `
        -LongBreakLength $effectiveLongBreak `
        -LongBreakEvery $effectiveLongBreakEvery `
        -StartNextAutomatically $effectiveAutoStart `
        -Mute (-not $effectiveSound) `
        -EnableNotifications $effectiveNotifications `
        -TaskLabel $effectiveTask `
        -Persist $persistData `
        -HistoryPath $historyPath
}
