#Requires -Version 5.1
Set-StrictMode -Version Latest

# Windows only (it drives the ScheduledTasks module). Registers a scheduled task for a program you own and
# refuses to replace one that belongs to another account or runs another program. The task is read back
# after registering.
#
# A password never travels as text through this module's own interface: the only way to run a task as an
# account that has a password is a PSCredential, and the one line that hands its password to Task Scheduler
# is inside Register-OwnedTaskRaw. Every call to the ScheduledTasks and CIM cmdlets sits in a *Raw function or in
# Get-OwnedCurrentAccount / Resolve-OwnedAccountSid, which a test replaces, so the logic runs without Windows.

$script:WellKnownAccounts = @{
    LocalService   = @{ UserId = 'NT AUTHORITY\LOCAL SERVICE'; Sid = 'S-1-5-19' }
    NetworkService = @{ UserId = 'NT AUTHORITY\NETWORK SERVICE'; Sid = 'S-1-5-20' }
    System         = @{ UserId = 'NT AUTHORITY\SYSTEM'; Sid = 'S-1-5-18' }
}

# ---- Windows calls (replaced in tests) -----------------------------------------------------------------

function Get-OwnedCurrentAccount {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    [pscustomobject]@{ Name = $identity.Name; Sid = $identity.User.Value }
}

function Resolve-OwnedAccountSid {
    param([string]$Account)
    if ($Account -match '^S-1-\d') { return ([Security.Principal.SecurityIdentifier]$Account).Value }
    if ($Account -like '.\*') { $Account = $env:COMPUTERNAME + $Account.Substring(1) }
    ([Security.Principal.NTAccount]$Account).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Get-OwnedTaskRaw {
    # The registered task in a small, plain shape, or $null when there is none.
    param([string]$TaskName, [string]$TaskPath)
    # Only "no such task" means absent. Any other failure (access denied, the service not reachable) is thrown, so a
    # task that could not be read is never treated as missing and replaced.
    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
    } catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound' -or "$($_.FullyQualifiedErrorId)" -like 'CmdletizationQuery_NotFound*') { return $null }
        throw
    }
    if (-not $task) { return $null }
    $triggers = New-Object System.Collections.Generic.List[object]
    foreach ($trigger in @($task.Triggers)) {
        $className = [string]$trigger.CimClass.CimClassName
        $kind = switch -Wildcard ($className) {
            '*LogonTrigger'  { 'Logon' }
            '*DailyTrigger'  { 'Daily' }
            '*WeeklyTrigger' { 'Weekly' }
            '*TimeTrigger'   { if ($trigger.Repetition -and $trigger.Repetition.Interval) { 'Repeat' } else { 'Once' } }
            default          { $className }
        }
        $at = $null
        if ($trigger.StartBoundary) { $at = ([datetime]$trigger.StartBoundary).ToString('HH:mm') }
        $triggers.Add([pscustomobject]@{ Kind = $kind; At = $at })
    }
    $actions = foreach ($action in @($task.Actions)) {
        [pscustomobject]@{ Execute = $action.Execute; Arguments = $action.Arguments; WorkingDirectory = $action.WorkingDirectory }
    }
    [pscustomobject]@{
        TaskName    = $task.TaskName
        TaskPath    = $task.TaskPath
        State       = [string]$task.State
        Enabled     = [bool]$task.Settings.Enabled
        UserId      = $task.Principal.UserId
        LogonType   = [string]$task.Principal.LogonType
        RunLevel    = [string]$task.Principal.RunLevel
        Description = $task.Description
        Actions     = @($actions)
        Triggers    = $triggers.ToArray()
    }
}

function Get-OwnedTaskInfoRaw {
    param([string]$TaskName, [string]$TaskPath)
    $info = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName
    [pscustomobject]@{ LastRunTime = $info.LastRunTime; LastTaskResult = $info.LastTaskResult }
}

function Register-OwnedTaskRaw {
    param($Spec, [pscredential]$Credential)
    $actionParams = @{ Execute = $Spec.Execute }
    if ($Spec.Argument) { $actionParams.Argument = $Spec.Argument }
    if ($Spec.WorkingDirectory) { $actionParams.WorkingDirectory = $Spec.WorkingDirectory }
    $action = New-ScheduledTaskAction @actionParams

    $triggers = New-Object System.Collections.Generic.List[object]
    foreach ($trigger in @($Spec.Triggers)) {
        switch ($trigger.Kind) {
            'Logon' {
                if ($trigger.User) { $triggers.Add((New-ScheduledTaskTrigger -AtLogOn -User $trigger.User)) }
                else { $triggers.Add((New-ScheduledTaskTrigger -AtLogOn)) }
            }
            'Daily' { $triggers.Add((New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add([timespan]::Parse($trigger.At))))) }
            'Weekly' { $triggers.Add((New-ScheduledTaskTrigger -Weekly -DaysOfWeek $trigger.DaysOfWeek -At ([datetime]::Today.Add([timespan]::Parse($trigger.At))))) }
            'Repeat' {
                $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval $trigger.Every
                # The cmdlet gives the repetition a finite default duration. Remove it so the recheck never stops.
                $repeat.Repetition.Duration = ''
                $repeat.Repetition.StopAtDurationEnd = $false
                $triggers.Add($repeat)
            }
        }
    }

    $settingsParams = @{
        ExecutionTimeLimit = $Spec.Settings.ExecutionTimeLimit
        MultipleInstances  = $Spec.Settings.MultipleInstances
    }
    if ($Spec.Settings.StartWhenAvailable) { $settingsParams.StartWhenAvailable = $true }
    if ($Spec.Settings.WakeToRun) { $settingsParams.WakeToRun = $true }
    if ($Spec.Settings.RunOnBatteries) { $settingsParams.AllowStartIfOnBatteries = $true; $settingsParams.DontStopIfGoingOnBatteries = $true }
    if ($Spec.Settings.RestartCount -gt 0) {
        $settingsParams.RestartCount = $Spec.Settings.RestartCount
        $settingsParams.RestartInterval = $Spec.Settings.RestartInterval
    }
    $settings = New-ScheduledTaskSettingsSet @settingsParams

    $registerParams = @{
        TaskName = $Spec.TaskName
        TaskPath = $Spec.TaskPath
        Action   = $action
        Settings = $settings
        Force    = $true
    }
    if ($Spec.Description) { $registerParams.Description = $Spec.Description }
    if ($triggers.Count -gt 0) { $registerParams.Trigger = $triggers.ToArray() }

    if ($Credential) {
        # The one place a password is read out of a PSCredential: Task Scheduler's own API takes the account's
        # password as text, once, to store it. It is held in this variable only for the call.
        $plain = $Credential.GetNetworkCredential().Password
        try {
            $null = Register-ScheduledTask @registerParams -User $Credential.UserName -Password $plain -RunLevel $Spec.Principal.RunLevel
        } finally {
            $plain = $null
        }
    } else {
        $principal = New-ScheduledTaskPrincipal -UserId $Spec.Principal.UserId -LogonType $Spec.Principal.LogonType -RunLevel $Spec.Principal.RunLevel
        $null = Register-ScheduledTask @registerParams -Principal $principal
    }
}

function Unregister-OwnedTaskRaw {
    param([string]$TaskName, [string]$TaskPath)
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
}

function Start-OwnedTaskRaw {
    param([string]$TaskName, [string]$TaskPath)
    Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
}

function Stop-OwnedTaskRaw {
    param([string]$TaskName, [string]$TaskPath)
    Stop-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
}

# ---- Pure logic ----------------------------------------------------------------------------------------

function ConvertTo-OwnedTaskPath {
    param([string]$TaskPath)
    if (-not $TaskPath.EndsWith('\')) { $TaskPath += '\' }
    $TaskPath
}

function New-OwnedTaskSpec {
    param(
        [string]$TaskName, [string]$TaskPath, [string]$Execute, [string]$Argument, [string]$WorkingDirectory,
        [string]$Description, [object[]]$Triggers, $Settings, $Principal
    )
    [pscustomobject]@{
        TaskName         = $TaskName
        TaskPath         = $TaskPath
        Execute          = $Execute
        Argument         = $Argument
        WorkingDirectory = $WorkingDirectory
        Description      = $Description
        Triggers         = @($Triggers)
        Settings         = $Settings
        Principal        = $Principal
    }
}

function ConvertTo-OwnedSid {
    # The built-in service accounts by any of the names Task Scheduler reports, otherwise a lookup.
    param([string]$Account)
    switch -Regex ($Account.Trim()) {
        '^(NT AUTHORITY\\)?LOCAL ?SERVICE$' { return 'S-1-5-19' }
        '^(NT AUTHORITY\\)?NETWORK ?SERVICE$' { return 'S-1-5-20' }
        '^(NT AUTHORITY\\)?SYSTEM$' { return 'S-1-5-18' }
    }
    Resolve-OwnedAccountSid -Account $Account
}

function Test-OwnedTaskOwner {
    # Returns $null when the registered task is ours, otherwise the reason it is not.
    param($Task, [string]$OwnerSid, [string]$Execute, [string[]]$Argument, [bool]$AdoptExisting)
    if (-not $Task.UserId) { return 'has no verifiable user principal' }
    $taskSid = $null
    try { $taskSid = ConvertTo-OwnedSid -Account $Task.UserId } catch { return "has a principal that cannot be resolved ($($Task.UserId))" }
    if ($taskSid -ne $OwnerSid) { return 'belongs to another account' }
    if ($AdoptExisting) { return $null }
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1 -or $actions[0].Execute -ine $Execute) { return 'runs another program' }
    $accepted = @($Argument | ForEach-Object { [string]$_ })
    if ($accepted.Count -eq 0) { $accepted = @('') }
    $actualArguments = [string]$actions[0].Arguments
    if (@($accepted | Where-Object { $_ -ieq $actualArguments }).Count -eq 0) { return 'runs the program with other arguments' }
    $null
}

function Get-OwnedTaskMismatch {
    # What differs between the definition that was asked for and the task that was read back. Empty when it matches.
    param($Spec, $Actual)
    $problems = New-Object System.Collections.Generic.List[string]
    if (-not $Actual) { $problems.Add('the task is not registered'); return @($problems) }
    if (-not $Actual.Enabled) { $problems.Add('the task is disabled') }
    $actions = @($Actual.Actions)
    if ($actions.Count -ne 1) { $problems.Add("it has $($actions.Count) actions, expected 1") }
    else {
        if ($actions[0].Execute -ine $Spec.Execute) { $problems.Add("it runs '$($actions[0].Execute)', expected '$($Spec.Execute)'") }
        if ([string]$actions[0].Arguments -cne [string]$Spec.Argument) { $problems.Add('its arguments differ') }
        if ($Spec.WorkingDirectory -and ([string]$actions[0].WorkingDirectory).TrimEnd('\') -ine $Spec.WorkingDirectory.TrimEnd('\')) { $problems.Add('its working directory differs') }
    }
    if ([string]$Actual.LogonType -ne $Spec.Principal.LogonType) { $problems.Add("its logon type is '$($Actual.LogonType)', expected '$($Spec.Principal.LogonType)'") }
    if ([string]$Actual.RunLevel -ne $Spec.Principal.RunLevel) { $problems.Add("its run level is '$($Actual.RunLevel)', expected '$($Spec.Principal.RunLevel)'") }
    $expectedKinds = (@($Spec.Triggers | ForEach-Object { $_.Kind }) | Sort-Object) -join ','
    $actualKinds = (@($Actual.Triggers | ForEach-Object { $_.Kind }) | Sort-Object) -join ','
    if ($expectedKinds -ne $actualKinds) { $problems.Add("its triggers are '$actualKinds', expected '$expectedKinds'") }
    foreach ($expected in @($Spec.Triggers | Where-Object { $_.Kind -in 'Daily', 'Weekly' })) {
        $found = @($Actual.Triggers | Where-Object { $_.Kind -eq $expected.Kind -and $_.At -eq $expected.At })
        if ($found.Count -eq 0) { $problems.Add("no $($expected.Kind) trigger at $($expected.At)") }
    }
    @($problems)
}

# ---- Public functions ----------------------------------------------------------------------------------

function Assert-OwnedTask {
    <#
    .SYNOPSIS
    Throws unless the registered task belongs to the given account and runs the given program.
    .DESCRIPTION
    A task is "owned" when its principal resolves to the same account (compared by security identifier, so
    DOMAIN\user, .\user and a SID all match) and, unless -AdoptExisting is given, it has exactly one action that
    runs -Execute with one of the accepted -Argument values. Returns nothing when the task is absent.
    .PARAMETER OwnerAccount
    The account that must own it. Defaults to the current user. A built-in service account is given as
    LocalService, NetworkService or System.
    .PARAMETER Argument
    The accepted argument strings. Pass the current one and any older ones a previous version registered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidatePattern('^[^\\/:*?"<>|]+$')][string]$TaskName,
        [string]$TaskPath = '\',
        [string]$OwnerAccount,
        [string]$Execute,
        [string[]]$Argument = @(),
        [switch]$AdoptExisting
    )
    $TaskPath = ConvertTo-OwnedTaskPath $TaskPath
    $task = Get-OwnedTaskRaw -TaskName $TaskName -TaskPath $TaskPath
    if (-not $task) { return }
    $ownerSid = Resolve-OwnedTaskOwnerSid -OwnerAccount $OwnerAccount
    if (-not $AdoptExisting -and -not $Execute) { throw 'Give -Execute to say which program the task should run, or -AdoptExisting to check only who owns it.' }
    $reason = Test-OwnedTaskOwner -Task $task -OwnerSid $ownerSid -Execute $Execute -Argument $Argument -AdoptExisting ([bool]$AdoptExisting)
    if ($reason) { throw "The scheduled task '$TaskPath$TaskName' $reason. It was left unchanged." }
}

function Resolve-OwnedTaskOwnerSid {
    param([string]$OwnerAccount)
    if (-not $OwnerAccount) { return (Get-OwnedCurrentAccount).Sid }
    if ($script:WellKnownAccounts.ContainsKey($OwnerAccount)) { return $script:WellKnownAccounts[$OwnerAccount].Sid }
    ConvertTo-OwnedSid -Account $OwnerAccount
}

function Stop-OwnedTask {
    <#
    .SYNOPSIS
    Stops a task and waits until it is no longer running. Never ends a process by any other means.
    .DESCRIPTION
    Throws when the task is still running after -TimeoutSeconds. Does nothing when the task is absent or idle.
    .OUTPUTS
    $true when the task was running and is now stopped, otherwise $false.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidatePattern('^[^\\/:*?"<>|]+$')][string]$TaskName,
        [string]$TaskPath = '\',
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 10
    )
    $TaskPath = ConvertTo-OwnedTaskPath $TaskPath
    $task = Get-OwnedTaskRaw -TaskName $TaskName -TaskPath $TaskPath
    if (-not $task -or $task.State -ne 'Running') { return $false }
    if (-not $PSCmdlet.ShouldProcess("$TaskPath$TaskName", 'Stop the scheduled task')) { return $false }
    Stop-OwnedTaskRaw -TaskName $TaskName -TaskPath $TaskPath
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $state = (Get-OwnedTaskRaw -TaskName $TaskName -TaskPath $TaskPath).State
        if ($state -ne 'Running') { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "The scheduled task '$TaskPath$TaskName' did not stop within $TimeoutSeconds seconds. No process was ended by other means."
}

function Register-OwnedTask {
    <#
    .SYNOPSIS
    Registers a scheduled task that runs one program, then reads it back to confirm it.
    .DESCRIPTION
    Who the task runs as is one of three choices, and none of them takes a password as text:
      - the current user, only while logged on (the default; logon type Interactive);
      - -ServiceAccount LocalService, NetworkService or System (logon type ServiceAccount, no password);
      - -Credential, a PSCredential for an account that has a password (the task runs whether or not that account
        is logged on). Task Scheduler's API needs the password as text once, to store it; the module reads it from
        the PSCredential inside one private function for that call and never writes, logs or returns it.

    The run level is Limited unless -RunLevel Highest is given.

    When a task of that name already exists it is replaced only if it is owned (see Assert-OwnedTask): its
    principal is the account this call registers, and it runs -Execute with the new -Argument or one of the
    -OwnedArgument values. Otherwise the call throws and nothing changes. A running instance is stopped first.
    -AdoptExisting skips the program check and keeps only the account check.

    Triggers: any mix of -AtLogOn, -DailyAt, -WeeklyAt with -DaysOfWeek, and -RepeatEvery. -RepeatEvery adds a
    trigger that starts one minute from now and repeats without end, which is how a server task is rechecked; give
    it with -MultipleInstances IgnoreNew (the default) so a running program is left alone.

    Afterwards the task is read back, and the call throws if the program, its arguments, the logon type, the run
    level, the triggers or the enabled state differ from what was asked for.
    .PARAMETER TaskName
    The name without a folder.
    .PARAMETER TaskPath
    The task folder, such as \ or \Example\. Defaults to \.
    .PARAMETER ExecutionTimeLimit
    How long one run may last. Defaults to one hour. [TimeSpan]::Zero means no limit.
    .PARAMETER RestartCount
    How many times Task Scheduler restarts a failed run, every -RestartInterval (default one minute). Default 0.
    .PARAMETER Start
    Starts the task after it is registered and confirmed.
    .OUTPUTS
    An object with TaskName, TaskPath, Action (Created or Updated), UserId, LogonType, RunLevel, Triggers, State
    and Started.
    .EXAMPLE
    Register-OwnedTask -TaskName 'Example Server' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' -AtLogOn -RepeatEvery (New-TimeSpan -Minutes 5) -ExecutionTimeLimit ([TimeSpan]::Zero) -Start
    .EXAMPLE
    Register-OwnedTask -TaskName 'Example Backup' -TaskPath '\Example\' -Execute 'C:\Apps\Example\backup.exe' -DailyAt '02:10' -Credential (Get-Credential)
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'CurrentUser')]
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidatePattern('^[^\\/:*?"<>|]+$')][string]$TaskName,
        [ValidatePattern('^\\([^\\/:*?"<>|]+(\\[^\\/:*?"<>|]+)*\\?)?$')][string]$TaskPath = '\',
        [Parameter(Mandatory = $true)][string]$Execute,
        [string]$Argument,
        [string]$WorkingDirectory,
        [string]$Description,

        [Parameter(ParameterSetName = 'Service', Mandatory = $true)][ValidateSet('LocalService', 'NetworkService', 'System')][string]$ServiceAccount,
        [Parameter(ParameterSetName = 'Credential', Mandatory = $true)][System.Management.Automation.Credential()][pscredential]$Credential,
        [ValidateSet('Limited', 'Highest')][string]$RunLevel = 'Limited',

        [switch]$AtLogOn,
        [ValidatePattern('^([01]?\d|2[0-3]):[0-5]\d$')][string[]]$DailyAt,
        [ValidatePattern('^([01]?\d|2[0-3]):[0-5]\d$')][string]$WeeklyAt,
        [System.DayOfWeek[]]$DaysOfWeek,
        [TimeSpan]$RepeatEvery,

        [TimeSpan]$ExecutionTimeLimit = (New-TimeSpan -Hours 1),
        [ValidateRange(0, 999)][int]$RestartCount = 0,
        [TimeSpan]$RestartInterval = (New-TimeSpan -Minutes 1),
        [bool]$StartWhenAvailable = $true,
        [switch]$WakeToRun,
        [switch]$RunOnBatteries,
        [ValidateSet('IgnoreNew', 'Parallel', 'Queue', 'StopExisting')][string]$MultipleInstances = 'IgnoreNew',

        [string[]]$OwnedArgument = @(),
        [switch]$AdoptExisting,
        [switch]$Start
    )
    $TaskPath = ConvertTo-OwnedTaskPath $TaskPath
    $fullName = "$TaskPath$TaskName"
    if ($WeeklyAt -and -not $DaysOfWeek) { throw '-WeeklyAt needs -DaysOfWeek.' }
    if ($DaysOfWeek -and -not $WeeklyAt) { throw '-DaysOfWeek needs -WeeklyAt.' }
    if ($PSBoundParameters.ContainsKey('RepeatEvery') -and $RepeatEvery -lt [TimeSpan]::FromMinutes(1)) { throw '-RepeatEvery must be at least one minute.' }
    if ($AtLogOn -and $PSCmdlet.ParameterSetName -eq 'Service') { throw 'A service account has no logon, so -AtLogOn does not apply. Use -DailyAt, -WeeklyAt or -RepeatEvery.' }

    # Who the task runs as.
    if ($PSCmdlet.ParameterSetName -eq 'Service') {
        $account = $script:WellKnownAccounts[$ServiceAccount]
        $principal = @{ Mode = 'Service'; UserId = $account.UserId; LogonType = 'ServiceAccount'; RunLevel = $RunLevel }
        $ownerSid = $account.Sid
    } elseif ($PSCmdlet.ParameterSetName -eq 'Credential') {
        $principal = @{ Mode = 'Credential'; UserId = $Credential.UserName; LogonType = 'Password'; RunLevel = $RunLevel }
        $ownerSid = ConvertTo-OwnedSid -Account $Credential.UserName
    } else {
        $current = Get-OwnedCurrentAccount
        $principal = @{ Mode = 'CurrentUser'; UserId = $current.Name; LogonType = 'Interactive'; RunLevel = $RunLevel }
        $ownerSid = $current.Sid
    }

    $triggers = New-Object System.Collections.Generic.List[object]
    if ($AtLogOn) { $triggers.Add(@{ Kind = 'Logon'; User = $principal.UserId; At = $null }) }
    foreach ($time in @($DailyAt)) { if ($time) { $triggers.Add(@{ Kind = 'Daily'; At = ([timespan]::Parse($time)).ToString('hh\:mm') }) } }
    if ($WeeklyAt) { $triggers.Add(@{ Kind = 'Weekly'; At = ([timespan]::Parse($WeeklyAt)).ToString('hh\:mm'); DaysOfWeek = $DaysOfWeek }) }
    if ($PSBoundParameters.ContainsKey('RepeatEvery')) { $triggers.Add(@{ Kind = 'Repeat'; Every = $RepeatEvery; At = $null }) }

    $settings = @{
        ExecutionTimeLimit = $ExecutionTimeLimit
        RestartCount       = $RestartCount
        RestartInterval    = $RestartInterval
        StartWhenAvailable = $StartWhenAvailable
        WakeToRun          = [bool]$WakeToRun
        RunOnBatteries     = [bool]$RunOnBatteries
        MultipleInstances  = $MultipleInstances
    }
    $spec = New-OwnedTaskSpec -TaskName $TaskName -TaskPath $TaskPath -Execute $Execute -Argument $Argument `
        -WorkingDirectory $WorkingDirectory -Description $Description -Triggers $triggers.ToArray() -Settings $settings -Principal $principal
    Write-Verbose "Scheduled task $fullName runs '$Execute' as $($principal.UserId) ($($principal.LogonType), $RunLevel) with $($triggers.Count) trigger(s)."

    $existing = Get-OwnedTaskRaw -TaskName $TaskName -TaskPath $TaskPath
    if ($existing) {
        $accepted = @($Argument) + @($OwnedArgument)
        $reason = Test-OwnedTaskOwner -Task $existing -OwnerSid $ownerSid -Execute $Execute -Argument $accepted -AdoptExisting ([bool]$AdoptExisting)
        if ($reason) { throw "The scheduled task '$fullName' $reason. It was left unchanged." }
    }

    $verb = if ($existing) { 'Replace the scheduled task' } else { 'Register the scheduled task' }
    if (-not $PSCmdlet.ShouldProcess($fullName, $verb)) { return }

    if ($existing -and $existing.State -eq 'Running') { $null = Stop-OwnedTask -TaskName $TaskName -TaskPath $TaskPath }
    if ($PSCmdlet.ParameterSetName -eq 'Credential') { Register-OwnedTaskRaw -Spec $spec -Credential $Credential }
    else { Register-OwnedTaskRaw -Spec $spec }

    $actual = Get-OwnedTaskRaw -TaskName $TaskName -TaskPath $TaskPath
    $problems = @(Get-OwnedTaskMismatch -Spec $spec -Actual $actual)
    if ($problems.Count -eq 0) {
        $reason = Test-OwnedTaskOwner -Task $actual -OwnerSid $ownerSid -Execute $Execute -Argument @($Argument) -AdoptExisting $false
        if ($reason) { $problems = @("it $reason") }
    }
    if ($problems.Count -gt 0) { throw "The scheduled task '$fullName' was registered but did not read back as asked: $($problems -join '; ')." }

    $started = $false
    if ($Start) {
        Start-OwnedTaskRaw -TaskName $TaskName -TaskPath $TaskPath
        $started = $true
    }
    [pscustomobject]@{
        TaskName  = $TaskName
        TaskPath  = $TaskPath
        Action    = $(if ($existing) { 'Updated' } else { 'Created' })
        UserId    = $actual.UserId
        LogonType = $actual.LogonType
        RunLevel  = $actual.RunLevel
        Triggers  = @($actual.Triggers | ForEach-Object { $_.Kind })
        State     = $(if ($started) { 'Started' } else { $actual.State })
        Started   = $started
    }
}

function Unregister-OwnedTask {
    <#
    .SYNOPSIS
    Removes a task that is owned (see Assert-OwnedTask), stopping it first if it is running.
    .DESCRIPTION
    Idempotent: an absent task gives Changed $false. A task that belongs to another account, or runs another
    program than -Execute, is left alone and the call throws. Give -AdoptExisting to check only the account.
    .OUTPUTS
    An object with TaskName, TaskPath, Changed and Action (Removed or Absent).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidatePattern('^[^\\/:*?"<>|]+$')][string]$TaskName,
        [ValidatePattern('^\\([^\\/:*?"<>|]+(\\[^\\/:*?"<>|]+)*\\?)?$')][string]$TaskPath = '\',
        [string]$OwnerAccount,
        [string]$Execute,
        [string[]]$Argument = @(),
        [switch]$AdoptExisting
    )
    $TaskPath = ConvertTo-OwnedTaskPath $TaskPath
    $task = Get-OwnedTaskRaw -TaskName $TaskName -TaskPath $TaskPath
    if (-not $task) { return [pscustomobject]@{ TaskName = $TaskName; TaskPath = $TaskPath; Changed = $false; Action = 'Absent' } }
    Assert-OwnedTask -TaskName $TaskName -TaskPath $TaskPath -OwnerAccount $OwnerAccount -Execute $Execute -Argument $Argument -AdoptExisting:$AdoptExisting
    if (-not $PSCmdlet.ShouldProcess("$TaskPath$TaskName", 'Remove the scheduled task')) { return }
    if ($task.State -eq 'Running') { $null = Stop-OwnedTask -TaskName $TaskName -TaskPath $TaskPath }
    Unregister-OwnedTaskRaw -TaskName $TaskName -TaskPath $TaskPath
    if (Get-OwnedTaskRaw -TaskName $TaskName -TaskPath $TaskPath) { throw "The scheduled task '$TaskPath$TaskName' is still registered after removal." }
    [pscustomobject]@{ TaskName = $TaskName; TaskPath = $TaskPath; Changed = $true; Action = 'Removed' }
}

function Get-OwnedTaskSummary {
    <#
    .SYNOPSIS
    One line per task: state, last run time, last result and the command it runs. NotInstalled when absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string[]]$TaskName,
        [string]$TaskPath = '\'
    )
    $TaskPath = ConvertTo-OwnedTaskPath $TaskPath
    foreach ($name in $TaskName) {
        $task = Get-OwnedTaskRaw -TaskName $name -TaskPath $TaskPath
        if (-not $task) {
            [pscustomobject]@{ TaskName = $name; State = 'NotInstalled'; LastRunTime = $null; LastResult = $null; Command = $null }
            continue
        }
        $info = Get-OwnedTaskInfoRaw -TaskName $name -TaskPath $TaskPath
        [pscustomobject]@{
            TaskName    = $name
            State       = $task.State
            LastRunTime = $info.LastRunTime
            LastResult  = $info.LastTaskResult
            Command     = (@($task.Actions | ForEach-Object { ("$($_.Execute) $($_.Arguments)").Trim() }) -join '; ')
        }
    }
}

Export-ModuleMember -Function Register-OwnedTask, Unregister-OwnedTask, Stop-OwnedTask, Assert-OwnedTask, Get-OwnedTaskSummary
