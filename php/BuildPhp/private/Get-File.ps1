Function Get-File {
    <#
    .SYNOPSIS
        Downloads a file from a URL with retries and an optional fallback URL.
        Uses System.Net.WebClient which is more reliable than Invoke-WebRequest
        on servers with strict outbound firewall rules or WPAD auto-detection.
    .PARAMETER Url
        The primary URL to download the file from.
    .PARAMETER FallbackUrl
        An optional fallback URL to use if the primary URL fails.
    .PARAMETER OutFile
        The output file path where the downloaded content will be saved.
    .PARAMETER Retries
        The number of times to retry the download if it fails. Default is 3.
    .PARAMETER TimeoutSec
        The timeout in seconds for each download attempt. Default is 0 (no timeout).
    #>
    [OutputType()]
    param (
        [Parameter(Mandatory = $true, Position=0, HelpMessage='Primary URL to download the file from')]
        [ValidateNotNullOrEmpty()]
        [string] $Url,

        [Parameter(Mandatory = $false, Position=1, HelpMessage='Fallback URL to use if the primary URL fails')]
        [string] $FallbackUrl,

        [Parameter(Mandatory = $false, Position=2, HelpMessage='Output file path for the downloaded content')]
        [string] $OutFile = '',

        [Parameter(Mandatory = $false, Position=3, HelpMessage='Number of retries for download attempts')]
        [int] $Retries = 3,

        [Parameter(Mandatory = $false, Position=4, HelpMessage='Timeout in seconds for each download attempt')]
        [int] $TimeoutSec = 0
    )

    function Invoke-Download {
        param([string]$DownloadUrl, [string]$TargetFile)
        $wc = New-Object System.Net.WebClient
        $wc.Proxy = $null
        try {
            if ($TargetFile -ne '') {
                $absolutePath = Join-Path (Get-Location).Path $TargetFile
                $wc.DownloadFile($DownloadUrl, $absolutePath)
            } else {
                $wc.DownloadString($DownloadUrl)
            }
        } finally {
            $wc.Dispose()
        }
    }

    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            Invoke-Download -DownloadUrl $Url -TargetFile $OutFile
            break;
        } catch {
            if ($i -eq ($Retries - 1)) {
                if($FallbackUrl) {
                    try {
                        Invoke-Download -DownloadUrl $FallbackUrl -TargetFile $OutFile
                    } catch {
                        throw "Failed to download the file from $Url and $FallbackUrl - $($_.Exception.Message)"
                    }
                } else {
                    throw "Failed to download the file from $Url - $($_.Exception.Message)"
                }
            }
        }
    }
}
