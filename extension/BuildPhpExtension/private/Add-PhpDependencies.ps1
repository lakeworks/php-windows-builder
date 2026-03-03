Function Add-PhpDependencies {
    <#
    .SYNOPSIS
        Add PHP dependencies.
    .PARAMETER Config
        Configuration for the extension.
    #>
    [OutputType()]
    param(
        [Parameter(Mandatory = $true, Position=0, HelpMessage='Configuration for the extension')]
        [PSCustomObject] $Config
    )
    begin {
    }
    process {
        if($Config.php_libraries.Count -ne 0) {
            Add-StepLog "Adding libraries (core)"
        }
        $phpBaseUrl = 'https://downloads.php.net/~windows/php-sdk/deps'
        $phpTrunkBaseUrl = "https://downloads.php.net/~windows/php-sdk/deps/$($Config.vs_version)/$($Config.arch)"
        # Staging file uses branch version (e.g. "8.3"), not full version ("8.3.30")
        $phpBranch = if ($Config.php_version -match '^\d+\.\d+$') { $Config.php_version } else { $Config.php_version -replace '^(\d+\.\d+)\..*$', '$1' }
        $phpSeries = Get-File -Url "$phpBaseUrl/series/packages-$phpBranch-$($Config.vs_version)-$($Config.arch)-staging.txt"
        $phpTrunk = Get-File -Url $phpTrunkBaseUrl
        foreach ($library in $Config.php_libraries) {
            try {
                $matchesFound = $phpSeries.Content | Select-String -Pattern "(^|\n)$library.*"
                if ($matchesFound.Count -eq 0) {
                    foreach ($file in $phpTrunk.Links.Href) {
                        if ($file -match "^$library") {
                            $matchesFound = $file | Select-String -Pattern '.*'
                            break
                        }
                    }
                }
                if ($matchesFound.Count -eq 0) {
                    throw "Failed to find $library"
                }
                $file = $matchesFound.Matches[0].Value.Trim()
                Get-File -Url "$phpBaseUrl/$($Config.vs_version)/$($Config.arch)/$file" -OutFile $library
                Expand-Archive $library "../deps" -Force
                Add-BuildLog tick "$library" "Added $($file -replace '\.zip$')"
            } catch {
                Add-BuildLog cross "$library" "Failed to download $library"
                throw
            }
        }
    }
    end {
    }
}
