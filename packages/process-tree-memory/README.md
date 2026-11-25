# ProcessTreeMemory

A PowerShell module that reports the memory of a Windows process and all of its descendants as one object: private bytes and working set summed over the process, its children, grandchildren and so on. With an optional budget and ceiling, it also says whether the private total is within them. It changes nothing.

## What runs where

Everything here is PowerShell, and the module only works on Windows.

| Part | Language | Runs on |
| --- | --- | --- |
| The `ProcessTreeMemory` module | PowerShell | Windows PowerShell 5.1 and PowerShell 7 on Windows |
| The tests | PowerShell with Pester 5 or later | Windows. They replace `Get-CimInstance` and `Get-Process` with a fake process table, so no real process is read |

Commands in this README are PowerShell. There is no macOS or Linux equivalent in this package.

## Install

From the PowerShell Gallery, once a release is published there:

```powershell
Install-PSResource ProcessTreeMemory          # PSResourceGet, in PowerShell 7
Install-Module ProcessTreeMemory -Scope CurrentUser   # PowerShellGet, in Windows PowerShell 5.1
```

From a clone of the repository:

```powershell
Import-Module ./packages/process-tree-memory/ProcessTreeMemory/ProcessTreeMemory.psd1
```

## Example

```powershell
# The main process of a desktop app, with the budget and ceiling for that app.
$memory = Get-ProcessTreeMemory -ProcessId $appPid -BudgetMB 300 -CeilingMB 680
"private memory $($memory.privateMB) MB over $($memory.processes) processes"
if (-not $memory.underCeiling) { throw 'over the ceiling' }

# One line of JSON for a log or a result file.
Get-ProcessTreeMemory -ProcessId $appPid | ConvertTo-Json -Compress -Depth 4
```

## Functions

| Function | What it does |
| --- | --- |
| `Get-ProcessTreeMemory -ProcessId [-BudgetMB] [-CeilingMB]` | Returns one object: `at`, `system`, `definition` (`private bytes`), `root`, `processes`, `names`, `privateMB`, `residentMB`, `workingSetMB`, `budgetMB`, `ceilingMB`, `withinBudget`, `underCeiling` and `detail` (one entry per process with `pid`, `name`, `privateMB` and `residentMB`) |

The budget and ceiling fields are `$null` when the matching parameter is not given. A total equal to the budget or the ceiling counts as within it.

## Behavior

- The tree is found by reading `Win32_Process` once and walking parent ids from the root. A process that is not in the listing is not counted.
- Private memory is `PrivateMemorySize64`, which is the definition budgets are usually written against. `residentMB` and `workingSetMB` are both the summed `WorkingSet64`.
- Megabytes are rounded to one decimal place.
- The result is a snapshot. A process that starts or exits during the read can be missed or counted.
- A root that no longer exists gives `processes` 0 and `privateMB` 0. It does not throw.

## Tests

The tests use Pester 5 or later and replace `Get-CimInstance` and `Get-Process` inside the module, so they need no real processes:

```powershell
Invoke-Pester ./packages/process-tree-memory/tests
```

## License

MIT
