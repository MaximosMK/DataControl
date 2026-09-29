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

            Save-DataHistory $script:DataHistory
        }
    } catch {
        $null = $_
    }

    Update-AppProcessMetrics -ElapsedSeconds $elapsedSec
}
