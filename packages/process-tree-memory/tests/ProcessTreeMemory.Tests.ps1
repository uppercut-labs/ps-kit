#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'ProcessTreeMemory') 'ProcessTreeMemory.psd1') -Force

    # A fake process table. 100 is the root, 200 its child, 300 the child's child; 400 is unrelated.
    # Private bytes are in MB here and converted to bytes for Get-Process.
    $global:PtmProcesses = @(
        [pscustomobject]@{ Id = 100; ParentProcessId = 1;   ProcessName = 'app';     PrivateMB = 100; WorkingMB = 80 }
        [pscustomobject]@{ Id = 200; ParentProcessId = 100; ProcessName = 'helper';  PrivateMB = 50;  WorkingMB = 40 }
        [pscustomobject]@{ Id = 300; ParentProcessId = 200; ProcessName = 'service'; PrivateMB = 25;  WorkingMB = 20 }
        [pscustomobject]@{ Id = 400; ParentProcessId = 1;   ProcessName = 'other';   PrivateMB = 900; WorkingMB = 900 }
    )
    $global:PtmTable = $global:PtmProcesses

    Mock -ModuleName ProcessTreeMemory Get-CimInstance {
        $global:PtmTable | ForEach-Object { [pscustomobject]@{ ProcessId = $_.Id; ParentProcessId = $_.ParentProcessId; Name = $_.ProcessName } }
    }
    Mock -ModuleName ProcessTreeMemory Get-Process {
        param([int[]]$Id)
        $global:PtmTable | Where-Object { $Id -contains $_.Id } | ForEach-Object {
            [pscustomobject]@{
                Id                 = $_.Id
                ProcessName        = $_.ProcessName
                PrivateMemorySize64 = [int64]($_.PrivateMB * 1MB)
                WorkingSet64       = [int64]($_.WorkingMB * 1MB)
            }
        }
    }
}

AfterAll {
    Remove-Variable -Name PtmProcesses, PtmTable -Scope Global -ErrorAction SilentlyContinue
    Remove-Module ProcessTreeMemory -ErrorAction SilentlyContinue
}

Describe 'Get-ProcessTreeMemory' {
    BeforeEach {
        $global:PtmTable = $global:PtmProcesses
    }

    It 'sums the root and every descendant, and no unrelated process' {
        $result = Get-ProcessTreeMemory -ProcessId 100
        $result.processes | Should -Be 3
        $result.names | Should -Be @('app', 'helper', 'service')
        $result.privateMB | Should -Be 175
        $result.residentMB | Should -Be 140
        $result.workingSetMB | Should -Be $result.residentMB
    }

    It 'reports the root alone when it has no children' {
        $result = Get-ProcessTreeMemory -ProcessId 400
        $result.processes | Should -Be 1
        $result.privateMB | Should -Be 900
    }

    It 'lists one detail entry per process with its own numbers' {
        $result = Get-ProcessTreeMemory -ProcessId 100
        $result.detail.Count | Should -Be 3
        ($result.detail | Where-Object { $_.pid -eq 200 }).privateMB | Should -Be 50
        ($result.detail | Where-Object { $_.pid -eq 300 }).name | Should -Be 'service'
    }

    It 'writes the fields that the desktop-app checks read' {
        $result = Get-ProcessTreeMemory -ProcessId 100 -BudgetMB 300 -CeilingMB 680
        $result.system | Should -Be 'windows'
        $result.definition | Should -Be 'private bytes'
        $result.root | Should -Be 100
        $result.budgetMB | Should -Be 300
        $result.ceilingMB | Should -Be 680
        $result.at | Should -Not -BeNullOrEmpty
    }

    It 'compares the private total with the budget and the ceiling' {
        $within = Get-ProcessTreeMemory -ProcessId 100 -BudgetMB 300 -CeilingMB 680
        $within.withinBudget | Should -BeTrue
        $within.underCeiling | Should -BeTrue

        $over = Get-ProcessTreeMemory -ProcessId 100 -BudgetMB 150 -CeilingMB 170
        $over.withinBudget | Should -BeFalse
        $over.underCeiling | Should -BeFalse
    }

    It 'treats a total exactly at the budget as within it' {
        $result = Get-ProcessTreeMemory -ProcessId 100 -BudgetMB 175 -CeilingMB 175
        $result.withinBudget | Should -BeTrue
        $result.underCeiling | Should -BeTrue
    }

    It 'leaves the budget and ceiling fields empty when they are not given' {
        $result = Get-ProcessTreeMemory -ProcessId 100
        $result.budgetMB | Should -BeNullOrEmpty
        $result.ceilingMB | Should -BeNullOrEmpty
        $result.withinBudget | Should -BeNullOrEmpty
        $result.underCeiling | Should -BeNullOrEmpty
    }

    It 'returns a shape that converts to compact JSON' {
        $json = Get-ProcessTreeMemory -ProcessId 100 -BudgetMB 300 -CeilingMB 680 | ConvertTo-Json -Compress -Depth 4
        $parsed = $json | ConvertFrom-Json
        $parsed.privateMB | Should -Be 175
        $parsed.detail.Count | Should -Be 3
    }

    It 'returns zero processes when the root no longer exists' {
        $global:PtmTable = @()
        $result = Get-ProcessTreeMemory -ProcessId 100
        $result.processes | Should -Be 0
        $result.privateMB | Should -Be 0
    }

    It 'rejects a process id that is not a number' {
        { Get-ProcessTreeMemory -ProcessId 'abc' } | Should -Throw
    }
}
