<#
.SYNOPSIS
    DataControl Network Metering Engine
.DESCRIPTION
    Queries adapter byte counters via Get-NetAdapterStatistics, performs reboot-resilient
    delta calculations, and maintains daily, monthly, and yearly consumption metrics.
#>

function Update-NetworkMetrics {
    param ([string]$AdapterName)

    if (-not $AdapterName) {
        $AdapterName = $script:AppConfig.target_adapter
    }

    try {
        $stat = Get-NetAdapterStatistics -Name $AdapterName -ErrorAction SilentlyContinue
        if (-not $stat) {
            $script:CurrentThroughputBytesPerSec = 0
            return
        }

        $now = [DateTime]::UtcNow
        $elapsedSec = ($now - $script:LastPollTime).TotalSeconds
        if ($elapsedSec -le 0) { $elapsedSec = [double]$script:AppConfig.poll_frequency_seconds }
        $script:LastPollTime = $now

        $currentRaw = [double]($stat.ReceivedBytes + $stat.SentBytes)
        $previousRaw = [double]$script:DataHistory.last_raw_total_bytes

        $delta = 0.0
        if ($previousRaw -le 0) {
            $delta = 0.0
        } elseif ($currentRaw -lt $previousRaw) {
            $delta = $currentRaw
        } else {
            $delta = $currentRaw - $previousRaw
        }

        $script:DataHistory.last_raw_total_bytes = $currentRaw

        if ($elapsedSec -gt 0) {
            $script:CurrentThroughputBytesPerSec = $delta / $elapsedSec
        } else {
            $script:CurrentThroughputBytesPerSec = 0.0
        }

        if ($delta -gt 0) {
            $dateNow = Get-Date
            $dayKey = $dateNow.ToString("yyyy-MM-dd")
            $monthKey = $dateNow.ToString("yyyy-MM")
            $yearKey = $dateNow.ToString("yyyy")

            # 1. Global Totals (Combined across all connections)
            $prevDay = 0.0
            if ($script:DataHistory.daily.PSObject.Properties[$dayKey]) {
                $prevDay = [double]$script:DataHistory.daily.$dayKey
            }
            $script:DataHistory.daily | Add-Member -MemberType NoteProperty -Name $dayKey -Value ($prevDay + $delta) -Force

            $prevMonth = 0.0
            if ($script:DataHistory.monthly.PSObject.Properties[$monthKey]) {
                $prevMonth = [double]$script:DataHistory.monthly.$monthKey
            }
            $script:DataHistory.monthly | Add-Member -MemberType NoteProperty -Name $monthKey -Value ($prevMonth + $delta) -Force

            $prevYear = 0.0
            if ($script:DataHistory.yearly.PSObject.Properties[$yearKey]) {
                $prevYear = [double]$script:DataHistory.yearly.$yearKey
            }
            $script:DataHistory.yearly | Add-Member -MemberType NoteProperty -Name $yearKey -Value ($prevYear + $delta) -Force

            # 2. Per-Network SSID / Adapter Counters
            $activeProf = Get-ActiveNetworkProfile
            $netName = $activeProf.Name
            $netType = $activeProf.Type

            if ($netName) {
                if (-not $script:DataHistory.networks) {
                    $script:DataHistory | Add-Member -MemberType NoteProperty -Name "networks" -Value (New-Object PSCustomObject) -Force
                }
                if (-not $script:DataHistory.networks.PSObject.Properties[$netName]) {
                    $newNet = [PSCustomObject]@{
                        type        = $netType
                        daily       = (New-Object PSCustomObject)
                        monthly     = (New-Object PSCustomObject)
                        total_bytes = 0.0
                        last_seen   = $dateNow.ToString("yyyy-MM-dd HH:mm:ss")
                    }
                    $script:DataHistory.networks | Add-Member -MemberType NoteProperty -Name $netName -Value $newNet -Force
                }

                $netObj = $script:DataHistory.networks.$netName
                $netObj.type = $netType
                $netObj.last_seen = $dateNow.ToString("yyyy-MM-dd HH:mm:ss")

                if (-not $netObj.daily) { $netObj | Add-Member -MemberType NoteProperty -Name "daily" -Value (New-Object PSCustomObject) -Force }
                if (-not $netObj.monthly) { $netObj | Add-Member -MemberType NoteProperty -Name "monthly" -Value (New-Object PSCustomObject) -Force }

                $netDayPrev = 0.0
                if ($netObj.daily.PSObject.Properties[$dayKey]) { $netDayPrev = [double]$netObj.daily.$dayKey }
                $netObj.daily | Add-Member -MemberType NoteProperty -Name $dayKey -Value ($netDayPrev + $delta) -Force

                $netMonthPrev = 0.0
                if ($netObj.monthly.PSObject.Properties[$monthKey]) { $netMonthPrev = [double]$netObj.monthly.$monthKey }
                $netObj.monthly | Add-Member -MemberType NoteProperty -Name $monthKey -Value ($netMonthPrev + $delta) -Force

                $netTotPrev = 0.0
                if ($netObj.total_bytes) { $netTotPrev = [double]$netObj.total_bytes }
                $netObj.total_bytes = $netTotPrev + $delta
            }

            # 3. Per Connection-Type (Wi-Fi vs Ethernet vs Cellular)
            if ($netType) {
                if (-not $script:DataHistory.connection_types) {
                    $script:DataHistory | Add-Member -MemberType NoteProperty -Name "connection_types" -Value (New-Object PSCustomObject) -Force
                }
                if (-not $script:DataHistory.connection_types.PSObject.Properties[$netType]) {
                    $newConn = [PSCustomObject]@{
                        daily       = (New-Object PSCustomObject)
                        monthly     = (New-Object PSCustomObject)
                        total_bytes = 0.0
                    }
                    $script:DataHistory.connection_types | Add-Member -MemberType NoteProperty -Name $netType -Value $newConn -Force
                }

                $connObj = $script:DataHistory.connection_types.$netType
                if (-not $connObj.daily) { $connObj | Add-Member -MemberType NoteProperty -Name "daily" -Value (New-Object PSCustomObject) -Force }
                if (-not $connObj.monthly) { $connObj | Add-Member -MemberType NoteProperty -Name "monthly" -Value (New-Object PSCustomObject) -Force }

                $connDayPrev = 0.0
                if ($connObj.daily.PSObject.Properties[$dayKey]) { $connDayPrev = [double]$connObj.daily.$dayKey }
                $connObj.daily | Add-Member -MemberType NoteProperty -Name $dayKey -Value ($connDayPrev + $delta) -Force

                $connMonthPrev = 0.0
                if ($connObj.monthly.PSObject.Properties[$monthKey]) { $connMonthPrev = [double]$connObj.monthly.$monthKey }
                $connObj.monthly | Add-Member -MemberType NoteProperty -Name $monthKey -Value ($connMonthPrev + $delta) -Force

                $connTotPrev = 0.0
                if ($connObj.total_bytes) { $connTotPrev = [double]$connObj.total_bytes }
                $connObj.total_bytes = $connTotPrev + $delta
            }

            Save-DataHistory $script:DataHistory
        }
    } catch {
        $null = $_
    }

    Update-AppProcessMetrics -ElapsedSeconds $elapsedSec
}
