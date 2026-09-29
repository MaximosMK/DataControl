<#
.SYNOPSIS
    Per-Process Network I/O & Socket Tracking Engine
.DESCRIPTION
    Samples active TCP/UDP socket connections, retrieves per-PID I/O transfer bytes via
    Win32 GetProcessIoCounters, calculates instantaneous speeds, and persists cumulative data.
#>

function Update-AppProcessMetrics ([double]$ElapsedSeconds) {
    try {
        $tcpConns = Get-NetTCPConnection -State Established, CloseWait, TimeWait -ErrorAction SilentlyContinue
        $udpConns = Get-NetUDPEndpoint -ErrorAction SilentlyContinue
        $pids = @($tcpConns.OwningProcess + $udpConns.OwningProcess | Where-Object { $_ -gt 4 } | Select-Object -Unique)

        $currentPids = @{}
        $nowStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $historyUpdated = $false

        foreach ($pidNum in $pids) {
            $p = Get-Process -Id $pidNum -ErrorAction SilentlyContinue
            if (-not $p) { continue }

            $pName = $p.ProcessName + ".exe"
            $pPath = ""
            try { $pPath = $p.Path } catch {}

            $connCount = ($tcpConns | Where-Object { $_.OwningProcess -eq $pidNum }).Count + ($udpConns | Where-Object { $_.OwningProcess -eq $pidNum }).Count
            $rawBytes = [Win11Native]::GetProcessBytes($pidNum)
            $prevBytes = 0
            $sessionBytes = 0.0
            $speedBps = 0.0

            if ($script:ProcStateCache.ContainsKey($pidNum)) {
                $cacheItem = $script:ProcStateCache[$pidNum]
                $prevBytes = [double]$cacheItem.LastBytes
                $sessionBytes = [double]$cacheItem.SessionBytes

                if ($rawBytes -ge $prevBytes -and $prevBytes -gt 0) {
                    $procDelta = $rawBytes - $prevBytes
                    $sessionBytes += $procDelta
                    if ($ElapsedSeconds -gt 0) { $speedBps = $procDelta / $ElapsedSeconds }
                }
            }

            $currentPids[$pidNum] = @{
                PID          = $pidNum
                Name         = $pName
                Path         = $pPath
                LastBytes    = $rawBytes
                SessionBytes = $sessionBytes
                SpeedBps     = $speedBps
                Connections  = $connCount
                LastSeen     = $nowStr
            }

            if ($pName) {
                $curHistTotal = 0.0
                if ($script:AppHistory.PSObject.Properties[$pName]) {
                    $curHistTotal = [double]$script:AppHistory.$pName.TotalBytes
                }
                
                $deltaToAdd = 0.0
                if ($rawBytes -gt $prevBytes -and $prevBytes -gt 0) {
                    $deltaToAdd = $rawBytes - $prevBytes
                }

                $record = [PSCustomObject]@{
                    DisplayName = $p.ProcessName
                    Path        = if ($pPath) { $pPath } else { if ($script:AppHistory.PSObject.Properties[$pName]) { $script:AppHistory.$pName.Path } else { "" } }
                    TotalBytes  = ($curHistTotal + $deltaToAdd)
                    LastSeen    = $nowStr
                }
                $script:AppHistory | Add-Member -MemberType NoteProperty -Name $pName -Value $record -Force
                if ($deltaToAdd -gt 0) { $historyUpdated = $true }
            }
        }

        $script:ProcStateCache = $currentPids
        if ($historyUpdated) {
            Save-AppHistory $script:AppHistory
        }
    } catch {}
}
