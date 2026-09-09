# Installs the anchor keeper as a scheduled task running every 5 minutes (elevated shell).
param([string]$ScriptPath = (Join-Path $PSScriptRoot 'anchor-keeper.ps1'), [string]$NtfyTopic = '', [string]$TaskName = 'DGB Anchor Keeper')
$args = "-NoProfile -File `"$ScriptPath`"" + ($(if ($NtfyTopic) { " -NtfyTopic $NtfyTopic" } else { '' }))
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force | Out-Null
Write-Output "Installed '$TaskName': every 5 min, 15-min limit, IgnoreNew. Test first: powershell -NoProfile -File $ScriptPath -InduceFailure -ProbeSeconds 2"
