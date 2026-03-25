# Ensure-AVDAgentHealthy.ps1 — runs at VM startup via Scheduled Task
# Waits for outbound connectivity, then verifies the AVD agent is heartbeating.
# If the agent isn't registered after boot, restarts the BootLoader service.

$logFile = 'C:\AVD\health-check.log'
function Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -Append -FilePath $logFile
}

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

# 3. Check if agent services are running; start if needed
$rdAgent = Get-Service RdAgent -ErrorAction SilentlyContinue
$bootLoader = Get-Service RDAgentBootLoader -ErrorAction SilentlyContinue

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
