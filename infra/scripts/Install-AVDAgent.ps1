param(
    [Parameter(Mandatory=$true)]
    [string]$HostPoolResourceId
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Azure's internal DNS (168.63.129.16) is always reachable inside any Azure VNet.
# If the VNet uses a custom DNS server that cannot forward public queries, inject
# Azure DNS as a fallback on the NIC so that public Microsoft hostnames resolve.
function Ensure-AzureDnsFallback {
    $azureDns = '168.63.129.16'
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } | Select-Object -First 1
    if (-not $adapter) { Write-Output "No active adapter found; skipping DNS fallback injection."; return }

    $current = (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4).ServerAddresses
    if ($azureDns -notin $current) {
        $updated = @($current) + $azureDns
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $updated
        Write-Output "Injected Azure DNS ($azureDns) as fallback on adapter '$($adapter.Name)'. Current list: $($updated -join ', ')"
        # Flush the cache so the new server is tried immediately
        Clear-DnsClientCache
    } else {
        Write-Output "Azure DNS ($azureDns) already present; DNS fallback not needed."
    }
}

function Download-WithFallback {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$Uris,
        [Parameter(Mandatory=$true)]
        [string]$OutFile,
        [Parameter(Mandatory=$true)]
        [string]$ArtifactName
    )

    $errors = @()
    $dnsFallbackApplied = $false

    foreach ($uri in $Uris) {
        # Retry each URI up to twice: once normally, once after Azure DNS injection if the
        # first attempt is a name-resolution failure.
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                Write-Output "Downloading $ArtifactName from $uri (attempt $attempt)"
                Invoke-WebRequest -Uri $uri -OutFile $OutFile -UseBasicParsing
                if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) {
                    Write-Output "Downloaded $ArtifactName ($((Get-Item $OutFile).Length) bytes)"
                    return
                }
                $errors += "${uri}: downloaded empty file"
                break
            } catch {
                $msg = $_.Exception.Message
                $isDnsFailure = ($msg -match 'remote name could not be resolved' -or $msg -match 'NameResolutionFailure' -or $msg -match 'DNS')
                if ($isDnsFailure -and -not $dnsFallbackApplied -and $attempt -eq 1) {
                    Write-Output "DNS failure detected for $uri - injecting Azure DNS fallback and retrying..."
                    Ensure-AzureDnsFallback
                    $dnsFallbackApplied = $true
                    # continue loop to attempt == 2
                } else {
                    $errors += "${uri} (attempt $attempt): $msg"
                    break
                }
            }
        }
    }

    $errorsJoined = ($errors -join [Environment]::NewLine)
    throw ("Failed to download {0}. Attempts:{1}{2}" -f $ArtifactName, [Environment]::NewLine, $errorsJoined)
}

$bootLoaderUris = @(
    'https://go.microsoft.com/fwlink/?linkid=2311028',
    'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH'
)

$rdAgentUris = @(
    'https://go.microsoft.com/fwlink/?linkid=2310011',
    'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv'
)

# Proactively inject Azure DNS fallback when the VM is being provisioned.
Write-Output "Ensuring Azure DNS fallback is configured before AVD downloads..."
Ensure-AzureDnsFallback

# Download AVD agent MSIs first (before token retrieval, so token is as fresh as possible)
Download-WithFallback -Uris $bootLoaderUris -OutFile "$env:TEMP\BootLoader.msi" -ArtifactName 'AVD BootLoader'
Download-WithFallback -Uris $rdAgentUris -OutFile "$env:TEMP\RDAgent.msi" -ArtifactName 'AVD RD Agent'
Write-Output "Both MSIs downloaded."

# Retrieve registration token from host pool using VM managed identity
Write-Output "Retrieving registration token via managed identity..."
$registrationToken = $null
for ($retry = 1; $retry -le 18; $retry++) {
    try {
        $imdsUrl = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/'
        $tokenResponse = Invoke-RestMethod -Uri $imdsUrl -Headers @{Metadata='true'} -Method GET
        $accessToken = $tokenResponse.access_token
        $apiUrl = "https://management.azure.com${HostPoolResourceId}/retrieveRegistrationToken?api-version=2024-04-08-preview"
        $headers = @{ Authorization = "Bearer $accessToken"; 'Content-Type' = 'application/json' }
        $regResponse = Invoke-RestMethod -Uri $apiUrl -Method POST -Headers $headers -Body '{}'
        $registrationToken = $regResponse.token
        if ($registrationToken) {
            Write-Output "Registration token retrieved (attempt $retry)."
            break
        }
    } catch {
        Write-Output "Attempt $retry failed: $($_.Exception.Message)"
        if ($retry -lt 18) { Start-Sleep -Seconds 10 }
    }
}
if (-not $registrationToken) {
    Write-Error "Failed to retrieve registration token after 18 attempts."
    exit 1
}

# Install AVD BootLoader (MSI already downloaded)
Write-Output "Installing AVD BootLoader..."
Start-Process msiexec.exe -Wait -ArgumentList '/i', "$env:TEMP\BootLoader.msi", '/quiet', '/norestart'

# Install AVD RD Agent (MSI already downloaded)
Write-Output "Installing AVD RD Agent..."
Start-Process msiexec.exe -Wait -ArgumentList '/i', "$env:TEMP\RDAgent.msi", '/quiet', '/norestart'

# Configure registration via registry
Write-Output "Configuring AVD agent registration..."
Stop-Service RDAgentBootLoader -Force -ErrorAction SilentlyContinue
Stop-Service RdAgent -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -Name RegistrationToken -Value $registrationToken
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -Name IsRegistered -Value 0

Set-Service RdAgent -StartupType Automatic
Set-Service RDAgentBootLoader -StartupType Automatic
Start-Service RdAgent
Start-Sleep -Seconds 5
Start-Service RDAgentBootLoader

# Wait for registration with retry (up to 3 attempts, 120s each, 30s pause between)
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Output "Registration attempt $attempt of 3..."
    for ($wait = 0; $wait -lt 120; $wait += 10) {
        Start-Sleep -Seconds 10
        $isReg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -ErrorAction SilentlyContinue).IsRegistered
        $rdAgentStatus = (Get-Service RdAgent -ErrorAction SilentlyContinue).Status
        $bootLoaderStatus = (Get-Service RDAgentBootLoader -ErrorAction SilentlyContinue).Status
        if ($isReg -eq 1) {
            Start-Sleep -Seconds 20
            $rdAgentStatus = (Get-Service RdAgent -ErrorAction SilentlyContinue).Status
            $bootLoaderStatus = (Get-Service RDAgentBootLoader -ErrorAction SilentlyContinue).Status
            if ($rdAgentStatus -eq 'Running' -and $bootLoaderStatus -eq 'Running') {
                Write-Output "AVD agent registered successfully (attempt $attempt)."
                exit 0
            }

            Write-Output "Registered, but agent services are not healthy: RdAgent=$rdAgentStatus RDAgentBootLoader=$bootLoaderStatus"
            break
        }

        if ($rdAgentStatus -ne 'Running' -or $bootLoaderStatus -ne 'Running') {
            Write-Output "Agent services unhealthy during registration wait: RdAgent=$rdAgentStatus RDAgentBootLoader=$bootLoaderStatus"
            break
        }
    }

    if ($attempt -lt 3) {
        Write-Output "Not registered yet. Waiting 30s before retry..."
        Start-Sleep -Seconds 30
        Stop-Service RDAgentBootLoader -Force -ErrorAction SilentlyContinue
        Stop-Service RdAgent -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -Name IsRegistered -Value 0
        Start-Service RdAgent
        Start-Sleep -Seconds 5
        Start-Service RDAgentBootLoader
    }
}

$finalStatus = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -ErrorAction SilentlyContinue).IsRegistered
$finalRdAgentStatus = (Get-Service RdAgent -ErrorAction SilentlyContinue).Status
$finalBootLoaderStatus = (Get-Service RDAgentBootLoader -ErrorAction SilentlyContinue).Status
Write-Output "Final registration status: IsRegistered=$finalStatus"
Write-Output "Final service status: RdAgent=$finalRdAgentStatus RDAgentBootLoader=$finalBootLoaderStatus"
if ($finalStatus -ne 1 -or $finalRdAgentStatus -ne 'Running' -or $finalBootLoaderStatus -ne 'Running') { exit 1 }
exit 0
