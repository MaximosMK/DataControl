<#
.SYNOPSIS
    DataControl Interactive 30-Second "Ask to Connect" Prompt Engine
.DESCRIPTION
    Presents an interactive Windows 11 Fluent dark card at the bottom-right corner
    of the display when an unrecognized application initiates network communication.
    Supports Allow (Unlimited), Allow (Quota-Bounded), Block, and 30-second auto-block.
#>

$script:PromptQueue = New-Object System.Collections.Queue
$script:IsPromptActive = $false
$script:CurrentPromptWindow = $null
$script:PromptCountdownTimer = $null

function Get-AppIconSource ([string]$exePath) {
    try {
        if ($exePath -and (Test-Path $exePath)) {
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
            if ($icon) {
                $bmp = $icon.ToBitmap()
                $hBmp = $bmp.GetHbitmap()
                $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
                    $hBmp,
                    [IntPtr]::Zero,
                    [System.Windows.Int32Rect]::Empty,
                    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
                )
                return $src
            }
        }
    } catch {}
    return $null
}

function Request-AppNetworkPermission ([string]$appName, [string]$path, [int]$pidNum) {
    if (-not $appName) { return }
    $pKey = $appName.ToLower()

    # 1. Skip system core processes
    if ($script:SystemWhitelist -contains $pKey) { return }

    # 2. Skip if current connected network is Unlimited
    if (Test-IsCurrentNetworkUnlimited) { return }

    # 3. Skip if prompting disabled in config
    if (-not $script:AppConfig.prompt_on_new_apps) { return }

    # 4. Check if rule already exists
    $existing = Get-AppRule $appName
    if ($existing) { return }

    # 5. Avoid duplicate queueing
    foreach ($q in $script:PromptQueue) {
        if ($q.Name.ToLower() -eq $pKey) { return }
    }
    if ($script:CurrentPromptItem -and $script:CurrentPromptItem.Name.ToLower() -eq $pKey) { return }

    # Enqueue new permission request
    $item = @{
        Name = $appName
        Path = $path
        PID  = $pidNum
    }
    $script:PromptQueue.Enqueue($item)

    Process-NextPromptQueue
}

function Process-NextPromptQueue {
    if ($script:IsPromptActive -or $script:PromptQueue.Count -eq 0) { return }

    $item = $script:PromptQueue.Dequeue()
    $script:CurrentPromptItem = $item
    $script:IsPromptActive = $true

    Show-PromptWindow $item
}

function Show-PromptWindow ($item) {
    $promptXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DataControl Sentry Alert"
        Width="440" Height="270"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False">
    <Border Background="#101626" BorderBrush="#38BDF8" BorderThickness="1.5" CornerRadius="12" Padding="18">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- Header -->
            <Grid Grid.Row="0">
                <StackPanel Orientation="Horizontal">
                    <TextBlock Text="🛡️" FontSize="14" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock Text="NEW OUTBOUND ACCESS REQUEST" Foreground="#38BDF8" FontWeight="Bold" FontSize="11" VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock x:Name="TxtSeconds" Text="30s" Foreground="#F59E0B" FontWeight="Bold" FontSize="13" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>

            <!-- App Info Card -->
            <Border Grid.Row="1" Background="#0C101A" BorderBrush="#1E2D4A" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,12,0,0">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="38"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Image x:Name="AppIcon" Grid.Column="0" Width="32" Height="32" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                    <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,0,0">
                        <TextBlock x:Name="AppTitle" Text="Google Chrome" Foreground="#F8FAFC" FontWeight="Bold" FontSize="14"/>
                        <TextBlock x:Name="AppPath" Text="C:\Program Files\..." Foreground="#64748B" FontSize="10.5" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Countdown Bar -->
            <StackPanel Grid.Row="2" Margin="0,10,0,0">
                <Grid>
                    <TextBlock Text="Auto-blocks outbound access if unconfirmed:" Foreground="#94A3B8" FontSize="11"/>
                    <TextBlock x:Name="TxtRemainingLabel" Text="30s remaining" Foreground="#94A3B8" FontSize="11" HorizontalAlignment="Right"/>
                </Grid>
                <ProgressBar x:Name="BarCountdown" Value="30" Maximum="30" Height="4" Margin="0,6,0,0" Foreground="#38BDF8" Background="#1E293B"/>
            </StackPanel>

            <!-- Action Buttons -->
            <Grid Grid.Row="3" Margin="0,14,0,0" VerticalAlignment="Bottom">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="1*"/>
                    <ColumnDefinition Width="6"/>
                    <ColumnDefinition Width="1*"/>
                    <ColumnDefinition Width="6"/>
                    <ColumnDefinition Width="1*"/>
                </Grid.ColumnDefinitions>

                <Button x:Name="BtnAllowUnlimited" Grid.Column="0" Content="✓ Allow Free" Background="#059669" Foreground="#F8FAFC" FontWeight="SemiBold" FontSize="11.5" Height="32" Cursor="Hand">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border Background="{TemplateBinding Background}" CornerRadius="6">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </ControlTemplate>
                    </Button.Template>
                </Button>

                <Button x:Name="BtnAllowQuota" Grid.Column="2" Content="⚙️ Set Quota" Background="#0284C7" Foreground="#F8FAFC" FontWeight="SemiBold" FontSize="11.5" Height="32" Cursor="Hand">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border Background="{TemplateBinding Background}" CornerRadius="6">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </ControlTemplate>
                    </Button.Template>
                </Button>

                <Button x:Name="BtnBlockOutbound" Grid.Column="4" Content="🚫 Block" Background="#E11D48" Foreground="#F8FAFC" FontWeight="SemiBold" FontSize="11.5" Height="32" Cursor="Hand">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border Background="{TemplateBinding Background}" CornerRadius="6">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </Grid>
        </Grid>
    </Border>
</Window>
'@

    $sr = New-Object System.IO.StringReader($promptXaml)
    $xr = [System.Xml.XmlReader]::Create($sr)
    $pWin = [System.Windows.Markup.XamlReader]::Load($xr)

    # Position in bottom-right corner above taskbar
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $pWin.Left = $workArea.Right - 460
    $pWin.Top = $workArea.Bottom - 290

    $script:CurrentPromptWindow = $pWin

    # Controls
    $txtSeconds = $pWin.FindName("TxtSeconds")
    $txtRemaining = $pWin.FindName("TxtRemainingLabel")
    $barCountdown = $pWin.FindName("BarCountdown")
    $appTitle = $pWin.FindName("AppTitle")
    $appPathText = $pWin.FindName("AppPath")
    $appIconImg = $pWin.FindName("AppIcon")

    $btnAllow = $pWin.FindName("BtnAllowUnlimited")
    $btnQuota = $pWin.FindName("BtnAllowQuota")
    $btnBlock = $pWin.FindName("BtnBlockOutbound")

    $appTitle.Text = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
    $appPathText.Text = if ($item.Path) { $item.Path } else { "PID: $($item.PID)" }

    $iconSrc = Get-AppIconSource $item.Path
    if ($iconSrc) { $appIconImg.Source = $iconSrc }

    $timeout = [int]$script:AppConfig.prompt_timeout_seconds
    if ($timeout -lt 10) { $timeout = 30 }
    $barCountdown.Maximum = $timeout
    $barCountdown.Value = $timeout
    $script:RemainingSeconds = $timeout

    # Button: Allow Unlimited
    $btnAllow.Add_Click({
        Set-AppRule -appName $item.Name -status "Allowed" -quotaMB 0 -path $item.Path | Out-Null
        Close-ActivePrompt
    })

    # Button: Allow with Quota (Default 500 MB)
    $btnQuota.Add_Click({
        Set-AppRule -appName $item.Name -status "Quota" -quotaMB 500 -path $item.Path | Out-Null
        Show-Toast "Google Chrome permitted with a 500 MB quota." "#0284C7"
        Close-ActivePrompt
    })

    # Button: Block Outbound
    $btnBlock.Add_Click({
        if ($item.Path -and (Test-Path $item.Path)) {
            Block-ApplicationPath -appPath $item.Path -description "Blocked by User Prompt" | Out-Null
        }
        Set-AppRule -appName $item.Name -status "Blocked" -quotaMB 0 -path $item.Path | Out-Null
        Close-ActivePrompt
    })

    # 30-Second Countdown Timer
    $script:PromptCountdownTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PromptCountdownTimer.Interval = [TimeSpan]::FromSeconds(1)

    $script:PromptCountdownTimer.Add_Tick({
        $script:RemainingSeconds--
        $txtSeconds.Text = "$($script:RemainingSeconds)s"
        $txtRemaining.Text = "$($script:RemainingSeconds)s remaining"
        $barCountdown.Value = $script:RemainingSeconds

        if ($script:RemainingSeconds -le 0) {
            # Auto-Block Action on Expiration
            if ($item.Path -and (Test-Path $item.Path)) {
                try {
                    Block-ApplicationPath -appPath $item.Path -description "Auto-Blocked (Prompt Expired - 30s Timeout)" | Out-Null
                } catch {}
            }
            Set-AppRule -appName $item.Name -status "AutoBlocked" -quotaMB 0 -path $item.Path | Out-Null

            $NotifyIcon.ShowBalloonTip(
                4000,
                "DataControl: Auto-Blocked $($item.Name)",
                "Outbound access blocked after 30-second prompt expiration. Click to review in dashboard.",
                [System.Windows.Forms.ToolTipIcon]::Warning
            )

            Close-ActivePrompt
        }
    })

    $script:PromptCountdownTimer.Start()
    $pWin.Show()
}

function Close-ActivePrompt {
    if ($script:PromptCountdownTimer) {
        $script:PromptCountdownTimer.Stop()
        $script:PromptCountdownTimer = $null
    }
    if ($script:CurrentPromptWindow) {
        $script:CurrentPromptWindow.Close()
        $script:CurrentPromptWindow = $null
    }
    $script:IsPromptActive = $false
    $script:CurrentPromptItem = $null

    # Process next item if queued
    Process-NextPromptQueue
}
