#Requires -Version 5.1
Set-StrictMode -Version Latest

# Private memory and working set summed over one process and all of its descendants (Windows only).
# The tree comes from one Win32_Process listing and the sums from Get-Process, so the result is a
# snapshot: a process that starts or exits during the read can be missed or counted.

function Get-ProcessTreeId {
    # Returns the root's id first, then every descendant, found by walking the parent ids.
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId
    )
    $processes = @(Get-CimInstance -ClassName Win32_Process | Select-Object ProcessId, ParentProcessId)
    $ids = New-Object 'System.Collections.Generic.List[int]'
    $ids.Add($ProcessId)
    for ($i = 0; $i -lt $ids.Count; $i++) {
        foreach ($process in $processes) {
            if ($process.ParentProcessId -eq $ids[$i] -and -not $ids.Contains([int]$process.ProcessId)) {
                $ids.Add([int]$process.ProcessId)
            }
        }
    }
    return ,$ids.ToArray()
}

function Get-ProcessTreeMemory {
    <#
    .SYNOPSIS
    Reports the memory of a process and all of its descendants as one object.
    .DESCRIPTION
    Adds up PrivateMemorySize64 (private bytes, the definition budgets are usually set in) and WorkingSet64
    over the process and every child, grandchild and so on. With -BudgetMB and -CeilingMB it also says
    whether the private total is within the budget and under the ceiling. Nothing is changed.
    .PARAMETER ProcessId
    The root process, for example the main process of a desktop app.
    .PARAMETER BudgetMB
    Optional. The budget in megabytes. Without it the budget fields are $null.
    .PARAMETER CeilingMB
    Optional. The hard ceiling in megabytes. Without it the ceiling fields are $null.
    .OUTPUTS
    One object with at, system, definition, root, processes, names, privateMB, residentMB, workingSetMB,
    budgetMB, ceilingMB, withinBudget, underCeiling and detail (one entry per process). Convert it with
    ConvertTo-Json for a file or a log line.
    .EXAMPLE
    Get-ProcessTreeMemory -ProcessId 4120 -BudgetMB 300 -CeilingMB 680 | ConvertTo-Json -Compress -Depth 4
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [double]$BudgetMB,
        [double]$CeilingMB
    )
    $hasBudget = $PSBoundParameters.ContainsKey('BudgetMB')
    $hasCeiling = $PSBoundParameters.ContainsKey('CeilingMB')

    $ids = Get-ProcessTreeId -ProcessId $ProcessId
    $processes = @(Get-Process -Id $ids -ErrorAction SilentlyContinue)
    # A loop, not Measure-Object: Measure-Object has no Sum property when nothing was piped, and strict mode would throw.
    [int64]$privateBytes = 0
    [int64]$residentBytes = 0
    foreach ($process in $processes) {
        $privateBytes += $process.PrivateMemorySize64
        $residentBytes += $process.WorkingSet64
    }
    $private = [math]::Round($privateBytes / 1MB, 1)
    $resident = [math]::Round($residentBytes / 1MB, 1)

    [pscustomobject]@{
        at           = (Get-Date -Format o)
        system       = 'windows'
        definition   = 'private bytes'
        root         = $ProcessId
        processes    = $processes.Count
        names        = @($processes | ForEach-Object ProcessName | Sort-Object -Unique)
        privateMB    = $private
        residentMB   = $resident
        workingSetMB = $resident
        budgetMB     = $(if ($hasBudget) { $BudgetMB } else { $null })
        ceilingMB    = $(if ($hasCeiling) { $CeilingMB } else { $null })
        withinBudget = $(if ($hasBudget) { $private -le $BudgetMB } else { $null })
        underCeiling = $(if ($hasCeiling) { $private -le $CeilingMB } else { $null })
        detail       = @($processes | ForEach-Object {
                [pscustomobject]@{
                    pid        = $_.Id
                    name       = $_.ProcessName
                    privateMB  = [math]::Round($_.PrivateMemorySize64 / 1MB, 1)
                    residentMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
                }
            })
    }
}

Export-ModuleMember -Function Get-ProcessTreeMemory
