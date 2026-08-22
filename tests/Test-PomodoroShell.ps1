#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'PomodoroShell.ps1')

function Assert-Equal {
    param(
        [object] $Actual,
        [object] $Expected,
        [string] $Because
    )

    if ($Actual -ne $Expected) {
        throw "Assertion failed: $Because. Expected '$Expected', got '$Actual'."
    }
}

$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('PomodoroShell.Tests.' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testDirectory -Force

try {
    $state = New-PomodoroState `
        -FocusSeconds 1500 `
        -ShortBreakSeconds 300 `
        -LongBreakSeconds 900 `
        -LongBreakEvery 4 `
        -TaskLabel 'Test task'

    foreach ($cycle in 1..3) {
        Move-ToNextInterval -State $state -Completed $true -StartImmediately $false
        Assert-Equal $state.Mode 'SHORT BREAK' "focus $cycle should lead to a short break"
        Assert-Equal (Get-CyclePosition $state) $cycle "break $cycle should retain its cycle number"
        Move-ToNextInterval -State $state -Completed $true -StartImmediately $false
        Assert-Equal $state.Mode 'FOCUS' "break $cycle should lead back to focus"
    }

    Move-ToNextInterval -State $state -Completed $true -StartImmediately $false
    Assert-Equal $state.Mode 'LONG BREAK' 'the fourth completed focus should lead to a long break'
    Move-ToNextInterval -State $state -Completed $true -StartImmediately $false
    Move-ToNextInterval -State $state -Completed $false -StartImmediately $false
    Assert-Equal $state.Mode 'SHORT BREAK' 'a skipped focus should not trigger another long break'

    Assert-Equal (Format-ClockValue 65) '01:05' 'minute clock formatting should be stable'
    Assert-Equal (ConvertTo-SafeTaskLabel "  Build`n  version 2  ") 'Build version 2' 'task labels should be terminal-safe'

    $settingsPath = Join-Path $testDirectory 'settings.json'
    $settings = New-DefaultPomodoroSettings
    $settings.FocusMinutes = 50
    $settings.AutoStart = $true
    $settings.LastTask = 'Deep work'
    Assert-Equal (Write-PomodoroSettings -Path $settingsPath -Settings $settings) $true 'settings should be written'
    $loaded = Read-PomodoroSettings -Path $settingsPath
    Assert-Equal $loaded.FocusMinutes 50 'focus duration should survive a settings round trip'
    Assert-Equal $loaded.AutoStart $true 'auto-start should survive a settings round trip'
    Assert-Equal $loaded.LastTask 'Deep work' 'task should survive a settings round trip'

    [IO.File]::WriteAllText($settingsPath, '{not-json')
    $fallback = Read-PomodoroSettings -Path $settingsPath
    Assert-Equal $fallback.FocusMinutes 25 'damaged settings should fall back to defaults'

    $historyPath = Join-Path $testDirectory 'history.jsonl'
    Assert-Equal (Add-PomodoroHistoryEntry -Path $historyPath -TaskLabel 'One' -DurationSeconds 1500 -SessionNumber 1) $true 'first history row should append'
    Assert-Equal (Add-PomodoroHistoryEntry -Path $historyPath -TaskLabel 'Two' -DurationSeconds 3000 -SessionNumber 2) $true 'second history row should append'
    $summary = Get-TodayHistorySummary -Path $historyPath
    Assert-Equal $summary.Count 2 'today summary should count completed focus intervals'
    Assert-Equal $summary.Seconds 4500 'today summary should total completed focus seconds'

    Write-Host 'All PomodoroShell tests passed.' -ForegroundColor Green
}
finally {
    if ((Test-Path -LiteralPath $testDirectory) -and
        ([IO.Path]::GetFullPath($testDirectory).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase))) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}
