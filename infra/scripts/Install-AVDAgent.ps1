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

# ── Create startup health-check script and scheduled task ──
Write-Output "Setting up AVD Agent startup health check..."

$healthCheckDir = 'C:\AVD'
if (-not (Test-Path $healthCheckDir)) { New-Item -Path $healthCheckDir -ItemType Directory -Force | Out-Null }

$healthCheckScript = @'
# Ensure-AVDAgentHealthy.ps1 — runs at VM startup
# Waits for outbound connectivity, then verifies the AVD agent is heartbeating.
# If the agent isn't registered after boot, restarts the BootLoader service.

$logFile = 'C:\AVD\health-check.log'
function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -Append -FilePath $logFile }

Log "AVD Agent health check started."

# 1. Wait for outbound connectivity to AVD broker (up to 5 minutes)
$maxWait = 300
$elapsed = 0
while ($elapsed -lt $maxWait) {
    $test = Test-NetConnection -ComputerName rdbroker.wvd.microsoft.com -Port 443 -WarningAction SilentlyContinue
    if ($test.TcpTestSucceeded) {
        Log "Outbound connectivity confirmed after ${elapsed}s."
        break
    }
    Start-Sleep -Seconds 10
    $elapsed += 10
}
if ($elapsed -ge $maxWait) {
    Log "ERROR: No outbound connectivity after ${maxWait}s. Exiting."
    exit 1
}

# 2. Give the agent time to heartbeat after boot
Start-Sleep -Seconds 30

# 3. Check if agent services are running; restart if needed
$bootLoader = Get-Service RDAgentBootLoader -ErrorAction SilentlyContinue
$rdAgent = Get-Service RdAgent -ErrorAction SilentlyContinue

if ($rdAgent.Status -ne 'Running') {
    Log "RdAgent not running (Status=$($rdAgent.Status)). Starting..."
    Start-Service RdAgent -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
}

if ($bootLoader.Status -ne 'Running') {
    Log "RDAgentBootLoader not running (Status=$($bootLoader.Status)). Starting..."
    Start-Service RDAgentBootLoader -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
}

# 4. Wait up to 2 minutes for registration
$registered = $false
for ($i = 0; $i -lt 12; $i++) {
    $isReg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -ErrorAction SilentlyContinue).IsRegistered
    if ($isReg -eq 1) {
        $registered = $true
        Log "Agent is registered and healthy."
        break
    }
    Start-Sleep -Seconds 10
}

# 5. If still not registered, restart BootLoader as a recovery step
if (-not $registered) {
    Log "Agent not registered after waiting. Restarting RDAgentBootLoader..."
    Restart-Service RDAgentBootLoader -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 30
    $isReg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -ErrorAction SilentlyContinue).IsRegistered
    Log "Post-restart registration status: IsRegistered=$isReg"
}

Log "Health check complete."
'@

Set-Content -Path "$healthCheckDir\Ensure-AVDAgentHealthy.ps1" -Value $healthCheckScript -Force

# Register scheduled task to run at startup as SYSTEM
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File C:\AVD\Ensure-AVDAgentHealthy.ps1'
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$existing = Get-ScheduledTask -TaskName 'AVD-Agent-Health-Check' -ErrorAction SilentlyContinue
if ($existing) { Unregister-ScheduledTask -TaskName 'AVD-Agent-Health-Check' -Confirm:$false }
Register-ScheduledTask -TaskName 'AVD-Agent-Health-Check' -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Write-Output "Startup health check task registered."

exit 0
