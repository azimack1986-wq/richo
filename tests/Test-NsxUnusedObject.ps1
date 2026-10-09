<#
.SYNOPSIS
    Tests the NSX unused-object audit's API handling and classification, offline.

.DESCRIPTION
    Extracts the helpers from scripts/nsx/Get-NsxUnusedObject.ps1 by AST and runs them under
    StrictMode against canned responses shaped the way the NSX 4.2 API Guide documents them:

      - the last page of a list carries no "cursor" property at all;
      - optional empty fields are left out of objects (an overlay segment has no vlan_ids, an
        isolated one has no connectivity_path).

    Under StrictMode both are terminating errors for code that reads the property directly, and
    the script this replaced did exactly that on every list call and every overlay segment.

    Also checks statically that the script stays read only: the only POSTs it can send are to
    /api/session/create and /api/session/destroy.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-NsxUnusedObject.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/nsx/Get-NsxUnusedObject.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) {
    $errors | ForEach-Object { Write-Host "  PARSE  line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    exit 1
}

$wanted = @(
    'Get-NsxProperty', 'ConvertTo-NsxManagerHost', 'ConvertTo-NsxApiPath', 'Get-NsxHttpStatus',
    'Get-NsxPagedResult', 'Resolve-NsxSegmentUsage', 'Resolve-NsxTier1Usage', 'Get-NsxOwnershipNote',
    'Get-NsxDisplayName', 'ConvertTo-NsxAuditRow', 'Get-NsxResponseHeader'
)
$definitions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { $wanted -contains $_.Name })
$missing = @($wanted | Where-Object { @($definitions.Name) -notcontains $_ })
if ($missing.Count -gt 0) { throw "Not found in the script: $($missing -join ', ')" }
foreach ($definition in $definitions) { Invoke-Expression $definition.Extent.Text }

# ---- Stubs -----------------------------------------------------------------------------------
$ScriptVersion = 'test'
$script:Nsx = @{ BaseUri = 'https://nsx.test' }
function Write-RichoLog { param([string]$Message, [string]$Level = 'INFO') }

# Canned responses by request path. 'NOTFOUND' answers like an HTTP 404.
$script:responses = @{}
$script:requests = New-Object System.Collections.Generic.List[string]
function Invoke-NsxRequest {
    param([string]$Path, [string]$Method = 'GET', [switch]$AllowNotFound, [switch]$NoReauthenticate)
    $script:requests.Add($Path)
    if (-not $script:responses.ContainsKey($Path)) { throw "unexpected request: $Path" }
    $canned = $script:responses[$Path]
    if ($canned -eq 'NOTFOUND') {
        if ($AllowNotFound) { return $null }
        throw "HTTP 404 for $Path"
    }
    return ($canned | ConvertFrom-Json)
}
function Initialize-Stub { param([hashtable]$Responses) $script:responses = $Responses; $script:requests.Clear() }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}
function Assert-Throws {
    param([string]$Name, [scriptblock]$Script)
    try { & $Script; $script:fail++; Write-Host "  FAIL  $Name (did not throw)" -ForegroundColor Red }
    catch { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
}
function Assert-NoThrow {
    param([string]$Name, [scriptblock]$Script)
    try { $null = & $Script; $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    catch { $script:fail++; Write-Host "  FAIL  $Name ($($_.Exception.Message))" -ForegroundColor Red }
}

# ---- Pagination ------------------------------------------------------------------------------
Write-Host "`n=== Pagination follows the cursor and stops when it is absent ===" -ForegroundColor Cyan
Initialize-Stub @{
    '/x?page_size=1000' = '{"results":[{"id":"a"},{"id":"b"}],"result_count":3,"cursor":"c1/=+"}'
    '/x?page_size=1000&cursor=c1%2F%3D%2B' = '{"results":[{"id":"c"}],"result_count":3,"sort_by":"display_name","sort_ascending":true}'
}
$items = Get-NsxPagedResult -Path '/x'
Assert-Equal 'all pages collected'                 3       $items.Count
Assert-Equal 'in order'                            'a,b,c' (($items | ForEach-Object { $_.id }) -join ',')
Assert-Equal 'two requests, cursor escaped'        2       $script:requests.Count

Initialize-Stub @{ '/y?filter=1&page_size=1000' = '{"results":[{"id":"only"}]}' }
$items = Get-NsxPagedResult -Path '/y?filter=1'
Assert-Equal 'page_size joins an existing query'   1       $items.Count
Assert-Equal 'one item is still an array'          'Object[]' $items.GetType().Name

Initialize-Stub @{ '/empty?page_size=1000' = '{"results":[],"result_count":0}' }
$items = Get-NsxPagedResult -Path '/empty'
Assert-Equal 'empty list is an array, not $null'   $false  ($null -eq $items)
Assert-Equal 'empty list has no items'             0       $items.Count

Initialize-Stub @{ '/noresults?page_size=1000' = '{"result_count":0}' }
Assert-Equal 'missing results property is empty'   0       (Get-NsxPagedResult -Path '/noresults').Count

Initialize-Stub @{ '/gone?page_size=1000' = 'NOTFOUND' }
Assert-Equal '404 with -AllowNotFound is $null'    $true   ($null -eq (Get-NsxPagedResult -Path '/gone' -AllowNotFound))
Assert-Throws '404 without -AllowNotFound throws' { Get-NsxPagedResult -Path '/gone' }

Initialize-Stub @{
    '/loop?page_size=1000' = '{"results":[{"id":"a"}],"cursor":"same"}'
    '/loop?page_size=1000&cursor=same' = '{"results":[{"id":"b"}],"cursor":"same"}'
}
Assert-Throws 'a repeated cursor stops instead of looping' { Get-NsxPagedResult -Path '/loop' }

Write-Host "`n=== -FirstItemOnly answers 'is there anything?' cheaply ===" -ForegroundColor Cyan
Initialize-Stub @{ '/ports?page_size=1' = '{"results":[{"id":"default:1"}],"result_count":500,"cursor":"next"}' }
$items = Get-NsxPagedResult -Path '/ports' -PageSize 1 -FirstItemOnly
Assert-Equal 'stops after the first item'          1       $items.Count
Assert-Equal 'one request for a busy segment'      1       $script:requests.Count

Initialize-Stub @{
    '/sparse?page_size=1' = '{"results":[],"cursor":"next"}'
    '/sparse?page_size=1&cursor=next' = '{"results":[{"id":"late"}]}'
}
Assert-Equal 'an empty page with a cursor is not the end' 1 (Get-NsxPagedResult -Path '/sparse' -PageSize 1 -FirstItemOnly).Count

# ---- Optional fields -------------------------------------------------------------------------
Write-Host "`n=== Optional fields that NSX omits read as `$null under StrictMode ===" -ForegroundColor Cyan
$overlay = '{"id":"web","path":"/infra/segments/web"}' | ConvertFrom-Json
$vlan = '{"id":"up","path":"/infra/segments/up","vlan_ids":["100","200"]}' | ConvertFrom-Json
Assert-NoThrow 'absent connectivity_path does not throw' { Get-NsxProperty $overlay 'connectivity_path' }
Assert-Equal 'absent property is $null'            $true   ($null -eq (Get-NsxProperty $overlay 'connectivity_path'))
Assert-Equal 'present property is returned'        'web'   (Get-NsxProperty $overlay 'id')
Assert-Equal '$null input is $null'                $true   ($null -eq (Get-NsxProperty $null 'id'))
Assert-Equal 'absent vlan_ids count 0'             0       @(Get-NsxProperty $overlay 'vlan_ids' | Where-Object { $null -ne $_ }).Count
Assert-Equal 'present vlan_ids count 2'            2       @(Get-NsxProperty $vlan 'vlan_ids' | Where-Object { $null -ne $_ }).Count
Assert-Equal 'display name falls back to id'       'web'   (Get-NsxDisplayName -InputObject $overlay)

# ---- Paths and input -------------------------------------------------------------------------
Write-Host "`n=== Policy paths become escaped request paths ===" -ForegroundColor Cyan
Assert-Equal 'space in an ID'      '/policy/api/v1/infra/segments/Web%20Tier/ports' (ConvertTo-NsxApiPath -PolicyPath '/infra/segments/Web Tier' -Suffix '/ports')
Assert-Equal 'project path'        '/policy/api/v1/orgs/default/projects/p1/infra/tier-1s/t1' (ConvertTo-NsxApiPath -PolicyPath '/orgs/default/projects/p1/infra/tier-1s/t1')
Assert-Equal 'non-ASCII ID'        '/policy/api/v1/infra/segments/caf%C3%A9' (ConvertTo-NsxApiPath -PolicyPath ('/infra/segments/caf' + [char]0x00E9))
Assert-Equal 'reserved characters' '/policy/api/v1/infra/segments/a%23b%3Fc' (ConvertTo-NsxApiPath -PolicyPath '/infra/segments/a#b?c')

Write-Host "`n=== Manager input is normalised or rejected ===" -ForegroundColor Cyan
foreach ($case in @(
        @('nsx01.example.com', 'nsx01.example.com'),
        @('  https://nsx01.example.com/  ', 'nsx01.example.com'),
        @('https://nsx01.example.com/login.jsp', 'nsx01.example.com'),
        @('HTTPS://NSX01.example.com', 'NSX01.example.com'),
        @('10.0.0.10', '10.0.0.10'),
        @('nsx01:8443', 'nsx01:8443'),
        @('[fd00::10]', '[fd00::10]'),
        @('', ''),
        @('   ', ''),
        @('admin:secret@nsx01', ''),
        @('nsx 01.example.com', '')
    )) {
    Assert-Equal "'$($case[0])'" $case[1] (ConvertTo-NsxManagerHost -Value $case[0])
}

# ---- HTTP status -----------------------------------------------------------------------------
Write-Host "`n=== Status extraction survives failures with no HTTP response ===" -ForegroundColor Cyan
$noResponse = [System.Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('No such host is known.'), 'dns', 'ConnectionError', $null)
Assert-NoThrow 'no Response property does not throw' { Get-NsxHttpStatus -ErrorRecord $noResponse }
Assert-Equal 'and yields $null'                    $true   ($null -eq (Get-NsxHttpStatus -ErrorRecord $noResponse))

$withResponse = [InvalidOperationException]::new('Too Many Requests')
$withResponse | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = [Net.HttpStatusCode]429 })
$rateLimited = [System.Management.Automation.ErrorRecord]::new($withResponse, 'http', 'InvalidOperation', $null)
Assert-Equal 'HTTP status is read from Response'   429     (Get-NsxHttpStatus -ErrorRecord $rateLimited)

Write-Host "`n=== XSRF header is read on 5.1 (string) and 7 (string[]) shapes ===" -ForegroundColor Cyan
Assert-Equal 'PowerShell 7 shape'      'abc' (Get-NsxResponseHeader -Response ([pscustomobject]@{ Headers = @{ 'X-XSRF-TOKEN' = [string[]]@('abc') } }) -Name 'X-XSRF-TOKEN')
Assert-Equal 'Windows PowerShell shape' 'abc' (Get-NsxResponseHeader -Response ([pscustomobject]@{ Headers = @{ 'X-XSRF-TOKEN' = 'abc' } }) -Name 'X-XSRF-TOKEN')
Assert-Equal 'case-insensitive name'   'abc' (Get-NsxResponseHeader -Response ([pscustomobject]@{ Headers = @{ 'x-xsrf-token' = 'abc' } }) -Name 'X-XSRF-TOKEN')
Assert-Equal 'missing header is $null' $true ($null -eq (Get-NsxResponseHeader -Response ([pscustomobject]@{ Headers = @{} }) -Name 'X-XSRF-TOKEN'))

# ---- Classification --------------------------------------------------------------------------
Write-Host "`n=== Segment usage ===" -ForegroundColor Cyan
$bare = '{"id":"s","path":"/infra/segments/s"}' | ConvertFrom-Json
Assert-Equal 'nothing at all is unused'            $true  (Resolve-NsxSegmentUsage -Segment $bare -HasPort $false -GatewayInterfaceCount 0).Unused
Assert-Equal 'a port means in use'                 $false (Resolve-NsxSegmentUsage -Segment $bare -HasPort $true -GatewayInterfaceCount 0).Unused
Assert-Equal 'a gateway interface means in use'    $false (Resolve-NsxSegmentUsage -Segment $bare -HasPort $false -GatewayInterfaceCount 1).Unused
$bridged = '{"id":"s","path":"/infra/segments/s","bridge_profiles":[{"bridge_profile_path":"/x","vlan_ids":["10"]}]}' | ConvertFrom-Json
Assert-Equal 'an edge bridge means in use'         $false (Resolve-NsxSegmentUsage -Segment $bridged -HasPort $false -GatewayInterfaceCount 0).Unused
$noBridge = '{"id":"s","path":"/infra/segments/s","bridge_profiles":[]}' | ConvertFrom-Json
Assert-Equal 'an empty bridge list does not count' $true  (Resolve-NsxSegmentUsage -Segment $noBridge -HasPort $false -GatewayInterfaceCount 0).Unused
$extended = '{"id":"s","path":"/infra/segments/s","l2_extension":{"tunnel_id":10}}' | ConvertFrom-Json
Assert-Equal 'an L2VPN extension means in use'     $false (Resolve-NsxSegmentUsage -Segment $extended -HasPort $false -GatewayInterfaceCount 0).Unused

Write-Host "`n=== Tier-1 usage ===" -ForegroundColor Cyan
Assert-Equal 'nothing at all is unused'   $true  (Resolve-NsxTier1Usage -ConnectedSegmentCount 0 -ServiceInterfaceCount 0 -LoadBalancerCount 0 -VpnServiceCount 0).Unused
Assert-Equal 'a segment means in use'     $false (Resolve-NsxTier1Usage -ConnectedSegmentCount 1 -ServiceInterfaceCount 0 -LoadBalancerCount 0 -VpnServiceCount 0).Unused
Assert-Equal 'an interface means in use'  $false (Resolve-NsxTier1Usage -ConnectedSegmentCount 0 -ServiceInterfaceCount 1 -LoadBalancerCount 0 -VpnServiceCount 0).Unused
Assert-Equal 'a load balancer means in use' $false (Resolve-NsxTier1Usage -ConnectedSegmentCount 0 -ServiceInterfaceCount 0 -LoadBalancerCount 1 -VpnServiceCount 0).Unused
Assert-Equal 'a VPN service means in use' $false (Resolve-NsxTier1Usage -ConnectedSegmentCount 0 -ServiceInterfaceCount 0 -LoadBalancerCount 0 -VpnServiceCount 1).Unused

Write-Host "`n=== Ownership notes ===" -ForegroundColor Cyan
$owned = '{"id":"t","_protection":"PROTECTED","_create_user":"ncp/cluster-1"}' | ConvertFrom-Json
$ownedNotes = Get-NsxOwnershipNote -InputObject $owned
Assert-Equal 'principal identity is named'  $true  ([bool]($ownedNotes -match 'ncp/cluster-1'))
$plainNotes = Get-NsxOwnershipNote -InputObject $bare
Assert-Equal 'no metadata, no notes'        0      $plainNotes.Count
$system = '{"id":"t","_system_owned":true}' | ConvertFrom-Json
$systemNotes = Get-NsxOwnershipNote -InputObject $system
Assert-Equal 'system-owned is flagged'      'System-owned' ($systemNotes -join '')

# ---- CSV rows --------------------------------------------------------------------------------
Write-Host "`n=== CSV rows ===" -ForegroundColor Cyan
$header = (ConvertTo-NsxAuditRow -ObjectType '' -InputObject $null | ConvertTo-Csv -NoTypeInformation)[0]
Assert-Equal 'header-only row for an empty report' 22 ($header -split ',').Count
Assert-Throws 'an unknown column is refused' { ConvertTo-NsxAuditRow -ObjectType 'Segment' -InputObject $bare -Values @{ NoSuchColumn = 1 } }
$tagged = '{"id":"s","path":"/infra/segments/s","_last_modified_time":0,"tags":[{"scope":"env","tag":"prod"},{"tag":"bare"}]}' | ConvertFrom-Json
$row = ConvertTo-NsxAuditRow -ObjectType 'Segment' -InputObject $tagged -Space 'default' -Notes @('one', '', 'two')
Assert-Equal 'tags are scope:tag'          'env:prod; bare'       $row.Tags
Assert-Equal 'epoch milliseconds to UTC'   '1970-01-01 00:00:00Z' $row.LastModifiedUtc
Assert-Equal 'blank notes are dropped'     'one; two'             $row.Notes
Assert-Equal 'version stamped on the row'  'test'                 $row.ScriptVersion

# ---- Read only -------------------------------------------------------------------------------
Write-Host "`n=== The script can only POST to the session endpoints ===" -ForegroundColor Cyan
$commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
$posts = @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-NsxRequest' -and $_.Extent.Text -match '-Method\s+POST' })
$badPosts = @($posts | Where-Object { $_.Extent.Text -notmatch "-Path\s+'/api/session/(create|destroy)'" })
Assert-Equal 'every Invoke-NsxRequest POST targets /api/session/*' 0 $badPosts.Count
$methodSets = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AttributeAst] -and $n.TypeName.Name -eq 'ValidateSet' }, $true) |
        Where-Object { $_.Parent.Extent.Text -match '\$Method' })
Assert-Equal 'Invoke-NsxRequest accepts GET and POST only' "'GET', 'POST'" (($methodSets | ForEach-Object { ($_.PositionalArguments | ForEach-Object { $_.Extent.Text }) -join ', ' }) -join '|')
$rawCalls = @($commands | Where-Object { @('Invoke-RestMethod', 'Invoke-WebRequest') -contains $_.GetCommandName() })
$gateways = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { @('Invoke-NsxRequest', 'Connect-NsxApi') -contains $_.Name })
$rawOutside = @($rawCalls | Where-Object {
        $call = $_
        $inside = @($gateways | Where-Object { $call.Extent.StartOffset -ge $_.Extent.StartOffset -and $call.Extent.EndOffset -le $_.Extent.EndOffset })
        $inside.Count -eq 0
    })
Assert-Equal 'raw web calls only in Invoke-NsxRequest and Connect-NsxApi' 0 $rawOutside.Count
$sessionPost = @($rawCalls | Where-Object { $_.Extent.Text -match 'Invoke-WebRequest' })
Assert-Equal 'the one Invoke-WebRequest is the session sign-in' 1 $sessionPost.Count
$writeHost = @($commands | Where-Object { $_.GetCommandName() -eq 'Write-Host' })
Assert-Equal 'no Write-Host (house rule)' 0 $writeHost.Count

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
