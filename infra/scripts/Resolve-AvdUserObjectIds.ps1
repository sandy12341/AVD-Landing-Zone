$ErrorActionPreference = 'Stop'

function Get-NormalizedItems {
  param(
    [string] $Raw
  )

  if ([string]::IsNullOrWhiteSpace($Raw)) {
    return @()
  }

  return ($Raw -split '[,\r\n]') |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

$upns = Get-NormalizedItems -Raw $env:UPN_LIST

if ($upns.Count -eq 0) {
  $DeploymentScriptOutputs = @{
    objectIdsCsv = ''
  }
  return
}

if ([string]::IsNullOrWhiteSpace($env:TENANT_ID) -or [string]::IsNullOrWhiteSpace($env:CLIENT_ID) -or [string]::IsNullOrWhiteSpace($env:CLIENT_SECRET)) {
  throw 'UPN resolution is enabled but resolver credentials are missing. Provide tenant ID, client ID, and client secret.'
}

$tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($env:TENANT_ID)/oauth2/v2.0/token" -ContentType 'application/x-www-form-urlencoded' -Body @{
  client_id     = $env:CLIENT_ID
  scope         = 'https://graph.microsoft.com/.default'
  client_secret = $env:CLIENT_SECRET
  grant_type    = 'client_credentials'
}

$headers = @{
  Authorization = "Bearer $($tokenResponse.access_token)"
}

$resolvedObjectIds = @()
$missingUpns = @()

foreach ($upn in $upns) {
  $encodedUpn = [uri]::EscapeDataString($upn)
  $requestUri = "https://graph.microsoft.com/v1.0/users/$encodedUpn?`$select=id,userPrincipalName"

  try {
    $user = Invoke-RestMethod -Method Get -Uri $requestUri -Headers $headers
    if ([string]::IsNullOrWhiteSpace($user.id)) {
      $missingUpns += $upn
    }
    else {
      $resolvedObjectIds += $user.id
    }
  }
  catch {
    $missingUpns += $upn
  }
}

if ($missingUpns.Count -gt 0) {
  throw ("Could not resolve the following UPNs: {0}" -f ($missingUpns -join ', '))
}

$uniqueObjectIds = $resolvedObjectIds | Sort-Object -Unique

$DeploymentScriptOutputs = @{
  objectIdsCsv = ($uniqueObjectIds -join ',')
}
