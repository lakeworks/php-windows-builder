Function Set-NetSecurityProtocolType {
    <#
    .Synopsis
    Configure the SecurityProtocol of the Net.ServicePointManager.
    #>
    [OutputType()]
    param (
    )
    begin {
    }
    process {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        } catch {
            Write-Debug '[Net.ServicePointManager] or [Net.SecurityProtocolType] not found in current environment'
        }
    }
    end {
    }
}
