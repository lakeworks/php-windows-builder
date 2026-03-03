function Get-OciSdk {
    <#
    .SYNOPSIS
        Add the OCI SDK for building oci and pdo_oci extensions

    .PARAMETER Arch
        The architecture of the OCI sdk.
    #>
    [OutputType()]
    param (
        [Parameter(Mandatory = $true, Position = 0, HelpMessage = 'The architecture of the OCI sdk.')]
        [string]$Arch
    )
    begin {
        $suffix = if ($Arch -eq 'x86') { 'nt' } else { 'windows' }
        $url = "https://download.oracle.com/otn_software/nt/instantclient/instantclient-sdk-$suffix.zip"
    }
    process {
        # Use local cache if available (avoids firewall issues on hardened servers)
        $cacheBase = if ($env:PHPBUILD_ROOT) { "$env:PHPBUILD_ROOT\deps-src" } else { "D:\phpbuild8\deps-src" }
        $cachePath = "$cacheBase\instantclient-sdk.zip"
        if (Test-Path $cachePath) {
            Copy-Item $cachePath "instantclient-sdk.zip"
        } else {
            Get-File -Url $url -OutFile "instantclient-sdk.zip"
            # Cache for next build
            $cacheDir = Split-Path $cachePath
            if (Test-Path $cacheDir) {
                Copy-Item "instantclient-sdk.zip" $cachePath -ErrorAction SilentlyContinue
            }
        }
        Expand-Archive -Path "instantclient-sdk.zip" -DestinationPath "."
        Move-Item "instantclient_*" "instantclient"
    }
    end {
    }
}
