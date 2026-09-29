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

            $type = if ($alias -match "Wi-Fi|Wireless|802\.11") {
                "Wi-Fi"
            } elseif ($alias -match "Ethernet|LAN") {
                "Ethernet"
            } elseif ($alias -match "Cellular|Mobile") {
                "Cellular"
            } else {
                "Wi-Fi"
            }

            $isUnlimited = $false
            $dailyLimit = 0.0
            $monthlyLimit = 0.0
            $autoCutoffDaily = $true
            $autoCutoffMonthly = $true

            if ($script:AppConfig.network_profiles -and $script:AppConfig.network_profiles.PSObject.Properties[$name]) {
                $saved = $script:AppConfig.network_profiles.$name
                $isUnlimited = [bool]$saved.is_unlimited
                if ($saved.daily_limit_gb) { $dailyLimit = [double]$saved.daily_limit_gb }
                if ($saved.monthly_limit_gb) { $monthlyLimit = [double]$saved.monthly_limit_gb }
                if ($null -ne $saved.auto_disconnect_daily) { $autoCutoffDaily = [bool]$saved.auto_disconnect_daily }
                if ($null -ne $saved.auto_disconnect_monthly) { $autoCutoffMonthly = [bool]$saved.auto_disconnect_monthly }
            }

            return [PSCustomObject]@{
                Name                 = $name
                InterfaceAlias       = $alias
                Type                 = $type
                Category             = $cat
                IsUnlimited          = $isUnlimited
                Mode                 = if ($isUnlimited) { "Unlimited" } else { "Metered" }
                DailyLimitGB         = $dailyLimit
                MonthlyLimitGB       = $monthlyLimit
                AutoDisconnectDaily  = $autoCutoffDaily
                AutoDisconnectMonthly= $autoCutoffMonthly
            }
        }
    } catch {
        $null = $_
    }

    return [PSCustomObject]@{
        Name                 = "Default"
        InterfaceAlias       = "Wi-Fi"
        Type                 = "Wi-Fi"
        Category             = "Public"
        IsUnlimited          = $false
        Mode                 = "Metered"
        DailyLimitGB         = 0.0
        MonthlyLimitGB       = 0.0
        AutoDisconnectDaily  = $true
        AutoDisconnectMonthly= $true
    }
}

function Set-NetworkProfileMode ([string]$networkName, [bool]$isUnlimited) {
    if (-not $networkName) { return }
    if (-not $script:AppConfig.network_profiles) {
        $script:AppConfig | Add-Member -MemberType NoteProperty -Name "network_profiles" -Value (New-Object PSCustomObject) -Force
    }

    if ($script:AppConfig.network_profiles.PSObject.Properties[$networkName]) {
        $profObj = $script:AppConfig.network_profiles.$networkName
        $profObj.is_unlimited = $isUnlimited
        $profObj.mode = if ($isUnlimited) { "Unlimited" } else { "Metered" }
        $profObj.updated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    } else {
        $profObj = [PSCustomObject]@{
            name                    = $networkName
            is_unlimited            = $isUnlimited
            mode                    = if ($isUnlimited) { "Unlimited" } else { "Metered" }
            daily_limit_gb          = 0.0
            monthly_limit_gb        = 0.0
            auto_disconnect_daily   = $true
            auto_disconnect_monthly = $true
            updated_at              = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        $script:AppConfig.network_profiles | Add-Member -MemberType NoteProperty -Name $networkName -Value $profObj -Force
    }

    Save-AppConfig $script:AppConfig
}

function Set-NetworkProfileLimits {
    param (
        [string]$networkName,
        [double]$dailyLimitGB,
        [double]$monthlyLimitGB,
        [bool]$autoCutoffDaily = $true,
        [bool]$autoCutoffMonthly = $true,
        [bool]$isUnlimited = $false
    )
    if (-not $networkName) { return }
    if (-not $script:AppConfig.network_profiles) {
        $script:AppConfig | Add-Member -MemberType NoteProperty -Name "network_profiles" -Value (New-Object PSCustomObject) -Force
    }

    if ($script:AppConfig.network_profiles.PSObject.Properties[$networkName]) {
        $profObj = $script:AppConfig.network_profiles.$networkName
        $profObj | Add-Member -MemberType NoteProperty -Name "is_unlimited" -Value $isUnlimited -Force
        $profObj | Add-Member -MemberType NoteProperty -Name "mode" -Value (if ($isUnlimited) { "Unlimited" } else { "Metered" }) -Force
        $profObj | Add-Member -MemberType NoteProperty -Name "daily_limit_gb" -Value $dailyLimitGB -Force
        $profObj | Add-Member -MemberType NoteProperty -Name "monthly_limit_gb" -Value $monthlyLimitGB -Force
        $profObj | Add-Member -MemberType NoteProperty -Name "auto_disconnect_daily" -Value $autoCutoffDaily -Force
        $profObj | Add-Member -MemberType NoteProperty -Name "auto_disconnect_monthly" -Value $autoCutoffMonthly -Force
        $profObj.updated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    } else {
        $profObj = [PSCustomObject]@{
            name                    = $networkName
            is_unlimited            = $isUnlimited
            mode                    = if ($isUnlimited) { "Unlimited" } else { "Metered" }
            daily_limit_gb          = $dailyLimitGB
            monthly_limit_gb        = $monthlyLimitGB
            auto_disconnect_daily   = $autoCutoffDaily
            auto_disconnect_monthly = $autoCutoffMonthly
            updated_at              = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        $script:AppConfig.network_profiles | Add-Member -MemberType NoteProperty -Name $networkName -Value $profObj -Force
    }

    Save-AppConfig $script:AppConfig
}

function Get-AllKnownNetworks {
    $now = Get-Date
    $dayKey = $now.ToString("yyyy-MM-dd")
    $monthKey = $now.ToString("yyyy-MM")

    $active = Get-ActiveNetworkProfile
    $activeName = $active.Name

    $names = @()
    if ($script:AppConfig.network_profiles) {
        foreach ($prop in $script:AppConfig.network_profiles.PSObject.Properties) {
            $names += $prop.Name
        }
    }
    if ($script:DataHistory.networks) {
        foreach ($prop in $script:DataHistory.networks.PSObject.Properties) {
            if ($names -notcontains $prop.Name) {
                $names += $prop.Name
            }
        }
    }
    if ($activeName -and $names -notcontains $activeName) {
        $names += $activeName
    }

    $list = @()
    foreach ($n in ($names | Sort-Object)) {
        $isActive = ($n -eq $activeName)
        $type = "Wi-Fi"
        $isUnlimited = $false
        $dLimit = 0.0
        $mLimit = 0.0
        $autoCutoffDaily = $true
        $autoCutoffMonthly = $true

        if ($script:AppConfig.network_profiles -and $script:AppConfig.network_profiles.PSObject.Properties[$n]) {
            $pCfg = $script:AppConfig.network_profiles.$n
            $isUnlimited = [bool]$pCfg.is_unlimited
            if ($pCfg.daily_limit_gb) { $dLimit = [double]$pCfg.daily_limit_gb }
            if ($pCfg.monthly_limit_gb) { $mLimit = [double]$pCfg.monthly_limit_gb }
            if ($null -ne $pCfg.auto_disconnect_daily) { $autoCutoffDaily = [bool]$pCfg.auto_disconnect_daily }
            if ($null -ne $pCfg.auto_disconnect_monthly) { $autoCutoffMonthly = [bool]$pCfg.auto_disconnect_monthly }
        }

        $dBytes = 0.0
        $mBytes = 0.0
        $totBytes = 0.0
        $lastSeen = ""

        if ($script:DataHistory.networks -and $script:DataHistory.networks.PSObject.Properties[$n]) {
            $nHist = $script:DataHistory.networks.$n
            if ($nHist.type) { $type = [string]$nHist.type }
            if ($nHist.daily -and $nHist.daily.PSObject.Properties[$dayKey]) {
                $dBytes = [double]$nHist.daily.$dayKey
            }
            if ($nHist.monthly -and $nHist.monthly.PSObject.Properties[$monthKey]) {
                $mBytes = [double]$nHist.monthly.$monthKey
            }
            if ($nHist.total_bytes) { $totBytes = [double]$nHist.total_bytes }
            if ($nHist.last_seen) { $lastSeen = [string]$nHist.last_seen }
        }

        if ($isActive) {
            $type = $active.Type
            $lastSeen = "Connected (Now)"
        }

        $list += [PSCustomObject]@{
            Name                  = $n
            Type                  = $type
            Status                = if ($isActive) { "Connected (Active)" } else { "Saved" }
            IsActive              = $isActive
            IsUnlimited           = $isUnlimited
            DailyLimitGB          = $dLimit
            MonthlyLimitGB        = $mLimit
            AutoDisconnectDaily   = $autoCutoffDaily
            AutoDisconnectMonthly = $autoCutoffMonthly
            TodayBytes            = $dBytes
            MonthBytes            = $mBytes
            TotalBytes            = $totBytes
            LastSeen              = $lastSeen
        }
    }

    return ,$list
}

function Get-ConnectionTypesSummary {
    $now = Get-Date
    $dayKey = $now.ToString("yyyy-MM-dd")
    $monthKey = $now.ToString("yyyy-MM")

    $summary = @()
    $types = @("Wi-Fi", "Ethernet", "Cellular")

    foreach ($t in $types) {
        $dBytes = 0.0
        $mBytes = 0.0
        $totBytes = 0.0

        if ($script:DataHistory.connection_types -and $script:DataHistory.connection_types.PSObject.Properties[$t]) {
            $cHist = $script:DataHistory.connection_types.$t
            if ($cHist.daily -and $cHist.daily.PSObject.Properties[$dayKey]) {
                $dBytes = [double]$cHist.daily.$dayKey
            }
            if ($cHist.monthly -and $cHist.monthly.PSObject.Properties[$monthKey]) {
                $mBytes = [double]$cHist.monthly.$monthKey
            }
            if ($cHist.total_bytes) {
                $totBytes = [double]$cHist.total_bytes
            }
        }

        $summary += [PSCustomObject]@{
            Type       = $t
            TodayBytes = $dBytes
            MonthBytes = $mBytes
            TotalBytes = $totBytes
        }
    }

    return ,$summary
}

function Test-IsCurrentNetworkUnlimited {
    $cur = Get-ActiveNetworkProfile
    return [bool]$cur.IsUnlimited
}
