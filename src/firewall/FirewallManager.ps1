<#
.SYNOPSIS
    Windows Defender Firewall Outbound Isolation Manager
.DESCRIPTION
    Creates, queries, and removes application outbound block rules in Windows Defender Firewall.
#>

function Block-ApplicationPath ([string]$appPath, [string]$description = "Blocked by DataControl") {
    if (-not $appPath -or -not (Test-Path $appPath)) {
        throw "Executable path '$appPath' not found or invalid."
    }

    $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($appPath)
    $ruleName = "DataControl-Block-$cleanName"

    # Remove any preexisting rule with the same name to prevent duplicates
    Remove-NetFirewallRule -DisplayName $ruleName -Confirm:$false -ErrorAction SilentlyContinue

    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Name $ruleName `
        -Direction Outbound `
        -Program $appPath `
        -Action Block `
        -Profile Any `
        -Description $description `
        -ErrorAction Stop | Out-Null

    return $ruleName
}

function Unblock-ApplicationRule ([string]$ruleName) {
    if (-not $ruleName) { return }
    $clean = $ruleName.Replace("DataControl-Block-", "")
    $noExt = [System.IO.Path]::GetFileNameWithoutExtension($clean)
    $variants = @($ruleName, "DataControl-Block-$noExt", "DataControl-Block-$noExt.exe") | Select-Object -Unique
    foreach ($v in $variants) {
        try {
            Remove-NetFirewallRule -DisplayName $v -Confirm:$false -ErrorAction SilentlyContinue
        } catch {}
    }
}

function Get-DataControlFirewallRules {
    $rules = @()
    try {
        $fwRules = Get-NetFirewallRule -DisplayName "DataControl-Block-*" -ErrorAction SilentlyContinue
        foreach ($r in $fwRules) {
            $progPath = ""
            try {
                $filter = $r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
                if ($filter -and $filter.Program) { $progPath = $filter.Program }
            } catch {}

            $rules += [PSCustomObject]@{
                RuleName    = $r.DisplayName
                ProgramPath = $progPath
                Action      = $r.Action.ToString()
            }
        }
    } catch {}
    return $rules
}
