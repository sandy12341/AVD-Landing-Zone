param(
    [Parameter(Mandatory=$true)]
    [string]$HostPoolResourceId
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

# Download and install AVD BootLoader
Write-Output "Downloading AVD BootLoader..."
Invoke-WebRequest -Uri 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH' -OutFile "$env:TEMP\BootLoader.msi"
Write-Output "Installing AVD BootLoader..."
Start-Process msiexec.exe -Wait -ArgumentList '/i', "$env:TEMP\BootLoader.msi", '/quiet', '/norestart'

# Download and install AVD RD Agent
Write-Output "Downloading AVD RD Agent..."
Invoke-WebRequest -Uri 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv' -OutFile "$env:TEMP\RDAgent.msi"
Write-Output "Installing AVD RD Agent..."
Start-Process msiexec.exe -Wait -ArgumentList '/i', "$env:TEMP\RDAgent.msi", '/quiet', '/norestart'

# Configure registration via registry
Write-Output "Configuring AVD agent registration..."
Stop-Service RDAgentBootLoader -Force -ErrorAction SilentlyContinue
Stop-Service RdAgent -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -Name RegistrationToken -Value $registrationToken
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -Name IsRegistered -Value 0

Start-Service RdAgent
Start-Sleep -Seconds 5
Start-Service RDAgentBootLoader

# Wait for registration with retry (up to 3 attempts, 90s each)
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Output "Registration attempt $attempt of 3..."
    for ($wait = 0; $wait -lt 90; $wait += 10) {
        Start-Sleep -Seconds 10
        $isReg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -ErrorAction SilentlyContinue).IsRegistered
        if ($isReg -eq 1) {
            Write-Output "AVD agent registered successfully (attempt $attempt)."
            exit 0
        }
    }

    if ($attempt -lt 3) {
        Write-Output "Not registered yet. Restarting services for retry..."
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
Write-Output "Final registration status: IsRegistered=$finalStatus"
exit 0
