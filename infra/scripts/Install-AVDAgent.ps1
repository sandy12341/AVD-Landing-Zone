param(
    [Parameter(Mandatory=$true)]
    [string]$HostPoolResourceId
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Download AVD agent MSIs first (before token retrieval, so token is as fresh as possible)
Write-Output "Downloading AVD BootLoader..."
Invoke-WebRequest -Uri 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH' -OutFile "$env:TEMP\BootLoader.msi"
Write-Output "Downloading AVD RD Agent..."
Invoke-WebRequest -Uri 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv' -OutFile "$env:TEMP\RDAgent.msi"
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
