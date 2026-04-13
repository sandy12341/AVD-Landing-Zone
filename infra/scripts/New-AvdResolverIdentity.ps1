param(
  [Parameter(Mandatory = $false)]
  [string] $DisplayName = 'avd-upn-resolver',

  [Parameter(Mandatory = $false)]
  [ValidateRange(1, 5)]
  [int] $SecretYears = 1,

  [Parameter(Mandatory = $false)]
  [string] $SecretDisplayName = '',

  [Parameter(Mandatory = $false)]
  [switch] $SkipAdminConsent,

  [Parameter(Mandatory = $false)]
  [ValidateSet('json', 'env')]
  [string] $OutputFormat = 'json'
)

$ErrorActionPreference = 'Stop'

$graphAppId = '00000003-0000-0000-c000-000000000000'
$userReadAllAppRoleId = 'df021288-bdef-4463-88db-98f22de89214'

function Invoke-AzCli {
  param(
    [Parameter(Mandatory = $true)]
    [string[]] $Args
  )

  $output = & az @Args 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "az $($Args -join ' ') failed: $output"
  }

  return $output
}

Write-Output 'Checking Azure CLI sign-in context...'
$tenantId = (Invoke-AzCli -Args @('account', 'show', '--query', 'tenantId', '-o', 'tsv')).Trim()

if ([string]::IsNullOrWhiteSpace($tenantId)) {
  throw 'No tenant context found. Run az login first.'
}

Write-Output "Tenant: $tenantId"
Write-Output "Ensuring app registration exists: $DisplayName"

$appJson = Invoke-AzCli -Args @('ad', 'app', 'list', '--display-name', $DisplayName, '-o', 'json')
$appList = $appJson | ConvertFrom-Json
$app = $appList | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1

if (-not $app) {
  $created = Invoke-AzCli -Args @('ad', 'app', 'create', '--display-name', $DisplayName, '--sign-in-audience', 'AzureADMyOrg', '-o', 'json')
  $app = $created | ConvertFrom-Json
  Write-Output "Created app registration: $DisplayName"
}
else {
  Write-Output "Using existing app registration: $DisplayName"
}

$appId = $app.appId
$appObjectId = $app.id

if ([string]::IsNullOrWhiteSpace($appId)) {
  throw 'Could not determine appId for resolver app registration.'
}

Write-Output 'Ensuring service principal exists...'
$spExists = $true
try {
  $null = Invoke-AzCli -Args @('ad', 'sp', 'show', '--id', $appId, '-o', 'none')
}
catch {
  $spExists = $false
}

if (-not $spExists) {
  $null = Invoke-AzCli -Args @('ad', 'sp', 'create', '--id', $appId, '-o', 'none')
  Write-Output 'Created service principal.'
}
else {
  Write-Output 'Service principal already exists.'
}

Write-Output 'Ensuring Microsoft Graph User.Read.All application permission is present...'
$permissionsJson = Invoke-AzCli -Args @('ad', 'app', 'permission', 'list', '--id', $appId, '-o', 'json')
$permissions = $permissionsJson | ConvertFrom-Json

$hasUserReadAllRole = $false
foreach ($perm in $permissions) {
  if ($perm.resourceAppId -eq $graphAppId) {
    foreach ($ra in $perm.resourceAccess) {
      if ($ra.id -eq $userReadAllAppRoleId -and $ra.type -eq 'Role') {
        $hasUserReadAllRole = $true
      }
    }
  }
}

if (-not $hasUserReadAllRole) {
  $null = Invoke-AzCli -Args @(
    'ad', 'app', 'permission', 'add',
    '--id', $appId,
    '--api', $graphAppId,
    '--api-permissions', "$userReadAllAppRoleId=Role"
  )
  Write-Output 'Added Microsoft Graph User.Read.All application permission.'
}
else {
  Write-Output 'Microsoft Graph User.Read.All application permission already present.'
}

if (-not $SkipAdminConsent) {
  Write-Output 'Granting admin consent for application permissions...'
  $null = Invoke-AzCli -Args @('ad', 'app', 'permission', 'admin-consent', '--id', $appId, '-o', 'none')
  Write-Output 'Admin consent granted.'
}
else {
  Write-Output 'Skipped admin consent by request.'
}

if ([string]::IsNullOrWhiteSpace($SecretDisplayName)) {
  $SecretDisplayName = "avd-upn-resolver-$(Get-Date -Format 'yyyyMMddHHmmss')"
}

Write-Output 'Creating client secret...'
$clientSecret = (Invoke-AzCli -Args @(
  'ad', 'app', 'credential', 'reset',
  '--id', $appId,
  '--append',
  '--display-name', $SecretDisplayName,
  '--years', $SecretYears,
  '--query', 'password',
  '-o', 'tsv'
)).Trim()

if ([string]::IsNullOrWhiteSpace($clientSecret)) {
  throw 'Client secret creation returned an empty value.'
}

$result = [ordered]@{
  appDisplayName = $DisplayName
  appObjectId = $appObjectId
  resolverTenantId = $tenantId
  resolverClientId = $appId
  resolverClientSecret = $clientSecret
  resolveAvdUsersFromUpns = $true
  note = 'Store resolverClientSecret securely (Key Vault recommended).'
}

if ($OutputFormat -eq 'env') {
  Write-Output "resolverTenantId=$($result.resolverTenantId)"
  Write-Output "resolverClientId=$($result.resolverClientId)"
  Write-Output "resolverClientSecret=$($result.resolverClientSecret)"
  Write-Output "resolveAvdUsersFromUpns=true"
}
else {
  $result | ConvertTo-Json -Depth 4
}
