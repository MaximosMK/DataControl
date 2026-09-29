<#
.SYNOPSIS
    DataControl Network Profile & SSID Intelligence
.DESCRIPTION
    Detects current network connection profiles (e.g. cellular hotspot MiFi vs home fiber).
    Maintains per-SSID modes (Metered vs Unlimited Free) and switches enforcement policies automatically.
#>

function Get-ActiveNetworkProfile {
    try {
        $netProfile = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($netProfile) {
            $name = [string]$netProfile.Name
            $alias = [string]$netProfile.InterfaceAlias
            $cat = [string]$netProfile.NetworkCategory

            $isUnlimited = $false
            if ($script:AppConfig.network_profiles -and $script:AppConfig.network_profiles.PSObject.Properties[$name]) {
                $isUnlimited = [bool]$script:AppConfig.network_profiles.$name.is_unlimited
            }

            return [PSCustomObject]@{
                Name            = $name
                InterfaceAlias  = $alias
                Category        = $cat
                IsUnlimited     = $isUnlimited
                Mode            = if ($isUnlimited) { "Unlimited" } else { "Metered" }
            }
        }
    } catch {
        $null = $_
    }

    return [PSCustomObject]@{
        Name            = "Default"
        InterfaceAlias  = "Wi-Fi"
        Category        = "Public"
        IsUnlimited     = $false
        Mode            = "Metered"
    }
}

function Set-NetworkProfileMode ([string]$networkName, [bool]$isUnlimited) {
    if (-not $networkName) { return }
    if (-not $script:AppConfig.network_profiles) {
        $script:AppConfig | Add-Member -MemberType NoteProperty -Name "network_profiles" -Value (New-Object PSCustomObject) -Force
    }

    $profObj = [PSCustomObject]@{
        name         = $networkName
        is_unlimited = $isUnlimited
        mode         = if ($isUnlimited) { "Unlimited" } else { "Metered" }
        updated_at   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    $script:AppConfig.network_profiles | Add-Member -MemberType NoteProperty -Name $networkName -Value $profObj -Force
    Save-AppConfig $script:AppConfig
}

function Test-IsCurrentNetworkUnlimited {
    $cur = Get-ActiveNetworkProfile
    return [bool]$cur.IsUnlimited
}
