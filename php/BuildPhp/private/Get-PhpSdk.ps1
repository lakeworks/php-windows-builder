function Get-PhpSdk {
    <#
    .SYNOPSIS
        Get the PHP SDK.
    #>
    [OutputType()]
    param (
    )
    begin {
        $sdkVersion = "php-sdk-2.6.0"
        $url = "https://github.com/php/php-sdk-binary-tools/archive/$sdkVersion.zip"
    }
    process {
        # Use local cache if available (avoids GitHub download on every build — TEMP gets wiped)
        $cacheBase = if ($env:PHPBUILD_ROOT) { "$env:PHPBUILD_ROOT\deps-src" } else { "D:\phpbuild8\deps-src" }
        $cachePath = "$cacheBase\$sdkVersion.zip"
        if (Test-Path $cachePath) {
            Copy-Item $cachePath "php-sdk.zip"
        } else {
            Get-File -Url $url -OutFile "php-sdk.zip"
            $cacheDir = Split-Path $cachePath
            if (Test-Path $cacheDir) {
                Copy-Item "php-sdk.zip" $cachePath -ErrorAction SilentlyContinue
            }
        }
        Expand-Archive -Path php-sdk.zip -DestinationPath .
        Rename-Item -Path php-sdk-binary-tools-$sdkVersion php-sdk
    }
    end {
    }
}