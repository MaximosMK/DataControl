@{
    # PSScriptAnalyzer Settings for DataControl
    # Standalone desktop application configuration:
    # 1. Exclude module cmdlet naming conventions (cmdlets are internal UI routines).
    # 2. Allow Write-Host in CLI setup/maintenance scripts.
    ExcludeRules = @(
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingWriteHost'
    )
}
