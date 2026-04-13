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

if ([string]::IsNullOrWhiteSpace($env:TENANT_ID) -or [string]::IsNullOrWhiteSpace($env:CLIENT_ID)) {
  throw 'UPN resolution is enabled but resolver credentials are missing. Provide tenant ID and client ID.'
}

# Determine which secret source to use
$clientSecret = $null
if (-not [string]::IsNullOrWhiteSpace($env:CLIENT_SECRET)) {
  $clientSecret = $env:CLIENT_SECRET
} elseif (-not [string]::IsNullOrWhiteSpace($env:KEYVAULT_ID) -and -not [string]::IsNullOrWhiteSpace($env:KEYVAULT_SECRET_NAME)) {
  # Fetch secret from Key Vault using deployment script's managed identity
  $vaultName = ($env:KEYVAULT_ID -split '/')[-1]
  $secretResp = az keyvault secret show --vault-name $vaultName --name $env:KEYVAULT_SECRET_NAME --query 'value' -o tsv 2>$null
  if ($LASTEXITCODE -eq 0) {
    $clientSecret = $secretResp
  } else {
    throw "Failed to retrieve secret '$($env:KEYVAULT_SECRET_NAME)' from Key Vault '$vaultName'. Verify the deployment script managed identity has Key Vault Reader permissions."
  }
} else {
  throw 'UPN resolution is enabled but no client secret source provided. Provide CLIENT_SECRET or KEYVAULT_ID + KEYVAULT_SECRET_NAME.'
}

$tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($env:TENANT_ID)/oauth2/v2.0/token" -ContentType 'application/x-www-form-urlencoded' -Body @{
  client_id     = $env:CLIENT_ID
  scope         = 'https://graph.microsoft.com/.default'
  client_secret = $clientSecret
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
