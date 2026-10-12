<#
.SYNOPSIS
    Reports VMs that live on the wrong PROD, SIT or DEV datastore, per vSphere cluster, with a GUI
    and CSV export.

.DESCRIPTION
    Signs in to vCenter with a domain account, discovers one cluster (or all of them) and works out,
    for every VM, which environment it belongs to and which environment its datastores belong to.
    Only VMs that are NOT where they should be are reported. A VM in the right place is not shown.

    READ-ONLY. Nothing in vCenter is changed - no VM, datastore or setting. The only thing written
    is the CSV you choose to export.

    Which environment a VM belongs to, in order:

      1. DNS name (the guest's DNS name, from VMware Tools). Matched label by label, so 'dpe' does
         not match inside 'dpesit':
           dpe, protected          -> PROD
           dpesit, protectedsit    -> SIT
           dpedev, protecteddev    -> DEV
      2. When there is no DNS name, or it carries none of those labels, the VM name - then the
         guest's short hostname - against the naming standard siepdXXxxL:
           siepd + 2-digit site number + 2 letters + environment letter L
           p -> PROD, t -> SIT, d -> DEV
         e.g. siepd85csp1000 is PROD.

    Which environment a datastore belongs to: its name contains PROD, SIT or DEV as a word of its
    own - delimited by anything that is not a letter - so NFS_PROD_01 and SIEPD85PROD01 are PROD,
    but SITE2_DS is not SIT. The Datastores tab shows how every datastore was classified.

    What 'lives on' means: the VM's home folder (.vmx) and every virtual disk. A mounted ISO and
    the swap file do not count.

    What is reported:
      Wrong datastore            The VM uses a PROD/SIT/DEV datastore that is not its own.
      Unmapped hostname letter   The name matches the standard but its letter is not mapped -
                                 e.g. 'b'. Add the letter to the right environment in the rules
                                 grid and click Re-apply rules (or Discover).
      Environment undetermined   No usable DNS name and the name does not match the standard.
                                 Hidden with -HideUndetermined or the matching GUI checkbox.
      Ambiguous datastore name   A datastore name matches more than one environment.

    VMs that use no PROD/SIT/DEV datastore at all are out of scope and not reported, unless
    -FlagUnclassifiedDatastores is set. Templates, vCLS/agent VMs (managed by ESX Agent Manager)
    and SRM placeholder VMs are skipped and counted in the summary.

    The letters, DNS labels and datastore keywords are all editable in the GUI's rules grid, and
    as parameters for -NoGui runs.

    Requirements: VMware PowerCLI (VMware.VimAutomation.Core). The GUI needs Windows and an STA
    console - powershell.exe or pwsh launched normally. VS Code's integrated console can run MTA;
    use -NoGui there, or a normal console window.

    Single file by design: it does not depend on the Richo.Common module, so it can be copied to a
    jump host on its own. When Richo.Common is already loaded, logging goes through Write-RichoLog.

.PARAMETER Server
    vCenter FQDN. Pre-fills the GUI. Required with -NoGui.

.PARAMETER Credential
    Domain account for vCenter (DOMAIN\user or user@domain). The GUI uses it when its password box
    is left empty. With -NoGui you are prompted when it is not given.

.PARAMETER Cluster
    -NoGui only. Cluster names to discover; wildcards allowed. All clusters when omitted.

.PARAMETER NoGui
    Run headless: discover, write the CSV, and output the reported rows to the pipeline.

.PARAMETER OutputPath
    -NoGui only. CSV path. Defaults to VMDatastorePlacement_<vCenter>_<timestamp>.csv in your
    Documents folder.

.PARAMETER ProdLetters
    Hostname environment letters that mean PROD. Default p.

.PARAMETER SitLetters
    Hostname environment letters that mean SIT. Default t.

.PARAMETER DevLetters
    Hostname environment letters that mean DEV. Default d.

.PARAMETER ProdDnsLabels
    DNS labels that mean PROD. Default dpe, protected.

.PARAMETER SitDnsLabels
    DNS labels that mean SIT. Default dpesit, protectedsit.

.PARAMETER DevDnsLabels
    DNS labels that mean DEV. Default dpedev, protecteddev.

.PARAMETER ProdDatastoreKeywords
    Words in a datastore name that mean PROD. Default PROD.

.PARAMETER SitDatastoreKeywords
    Words in a datastore name that mean SIT. Default SIT.

.PARAMETER DevDatastoreKeywords
    Words in a datastore name that mean DEV. Default DEV.

.PARAMETER HostnamePattern
    Regular expression for the naming standard, matched case-insensitively against the VM name. It
    must capture the environment letter in a group named 'env'. Default:
    ^siepd(?<site>\d{2})(?<role>[a-z]{2})(?<env>[a-z])

.PARAMETER NfsOnly
    Only NFS datastores count as PROD/SIT/DEV; VMFS, vSAN and vVol datastores are ignored.

.PARAMETER FlagUnclassifiedDatastores
    Also report a VM that uses a datastore with no PROD/SIT/DEV keyword, including a VM that uses
    no PROD/SIT/DEV datastore at all.

.PARAMETER HideUndetermined
    Do not report VMs whose environment cannot be worked out from DNS name or hostname.

.EXAMPLE
    .\Test-VMDatastorePlacement.ps1 -Server vcenter01.dpe.protected.mil.au

    Opens the GUI. Sign in with your domain account, pick a cluster, Discover, Export CSV.

.EXAMPLE
    .\Test-VMDatastorePlacement.ps1 -Server vcenter01.dpe.protected.mil.au -DevLetters d, b

    GUI, with 'b' already counted as DEV.

.EXAMPLE
    .\Test-VMDatastorePlacement.ps1 -NoGui -Server vcenter01.dpe.protected.mil.au -Cluster 'CL-PROD-*' -OutputPath C:\Temp\placement.csv

    Headless. Prompts for the domain account, writes the CSV, and outputs the reported rows.

.NOTES
    Version is in $ScriptVersion below and is stamped onto every CSV row.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Server,

    [pscredential]$Credential,

    [string[]]$Cluster,

    [switch]$NoGui,

    [string]$OutputPath,

    [string[]]$ProdLetters = @('p'),
    [string[]]$SitLetters = @('t'),
    [string[]]$DevLetters = @('d'),

    [string[]]$ProdDnsLabels = @('dpe', 'protected'),
    [string[]]$SitDnsLabels = @('dpesit', 'protectedsit'),
    [string[]]$DevDnsLabels = @('dpedev', 'protecteddev'),

    [string[]]$ProdDatastoreKeywords = @('PROD'),
    [string[]]$SitDatastoreKeywords = @('SIT'),
    [string[]]$DevDatastoreKeywords = @('DEV'),

    [string]$HostnamePattern = '^siepd(?<site>\d{2})(?<role>[a-z]{2})(?<env>[a-z])',

    [switch]$NfsOnly,

    [switch]$FlagUnclassifiedDatastores,

    [switch]$HideUndetermined
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'

$script:GuiLogSink = $null
$script:Gui = $null
$script:GuiState = $null

# =============================================================================================
# Logging
# =============================================================================================

function Write-PlacementLog {
    <#
    .SYNOPSIS
        Logs a timestamped, levelled line - through Write-RichoLog when Richo.Common is loaded.

    .DESCRIPTION
        This script is deliberately a single file, so it cannot assume Richo.Common is present.
        When it is, Write-RichoLog is used so the line also lands in $env:RICHO_LOG_FILE; when it
        is not, the same format is written to the same streams. Either way, while the GUI is open
        the line is also appended to its Log tab.

        ERROR is written non-terminating. A log line must never be what stops the run.

    .PARAMETER Message
        The text to log.

    .PARAMETER Level
        DEBUG, INFO, WARN or ERROR. Defaults to INFO.

    .EXAMPLE
        Write-PlacementLog "Discovering cluster CL01." -Level INFO
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
    $line = '{0} [{1,-5}] {2}' -f $stamp, $Level, $Message

    if (Get-Command -Name 'Write-RichoLog' -CommandType Function -ErrorAction SilentlyContinue) {
        Write-RichoLog -Message $Message -Level $Level -ErrorAction Continue
    }
    else {
        switch ($Level) {
            'DEBUG' { Write-Verbose $line }
            'INFO' { Write-Information $line -InformationAction Continue }
            'WARN' { Write-Warning $line }
            'ERROR' { Write-Error $line -ErrorAction Continue }
        }
    }

    $sink = Get-Variable -Name 'GuiLogSink' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $sink -and $Level -ne 'DEBUG') {
        try {
            & $sink $line
        }
        catch {
            Write-Verbose "GUI log sink failed: $($_.Exception.Message)"
        }
    }
}

# =============================================================================================
# Placement rules and classification - pure functions, no vCenter
# =============================================================================================

function Split-RuleValue {
    <#
    .SYNOPSIS
        Splits a rules-grid cell such as "d, b" into its individual values.

    .DESCRIPTION
        Commas, semicolons and whitespace all separate values, so "d,b", "d; b" and "d b" are the
        same. Blank input gives nothing.

    .PARAMETER Value
        The cell text.

    .EXAMPLE
        @(Split-RuleValue 'dpe, protected')
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    foreach ($part in ($Value -split '[,;\s]+')) {
        if ($part.Trim() -ne '') { $part.Trim() }
    }
}

function ConvertTo-PlacementRuleSet {
    <#
    .SYNOPSIS
        Validates the per-environment rules and compiles them into the matchers the evaluation uses.

    .DESCRIPTION
        Each definition carries the environment name plus three comma-separated strings: hostname
        letters, DNS labels and datastore keywords - exactly what the GUI rules grid holds.

        Throws, listing every problem at once, when:
          - a hostname letter is not a single letter, or is mapped to two environments
          - a DNS label is not a single dot-free label, or is mapped to two environments
          - a datastore keyword is used by two environments
          - an environment has no datastore keyword (nothing could ever be classified as it)
          - the hostname pattern is not a valid regex, or has no group named 'env'

        Ambiguous rules are refused rather than resolved, because any tie-break would silently
        decide where a VM belongs.

    .PARAMETER Definition
        Objects with Environment, Letters, DnsLabels and DatastoreKeywords properties.

    .PARAMETER HostnamePattern
        Regex for the naming standard; must contain (?<env>...).

    .EXAMPLE
        ConvertTo-PlacementRuleSet -Definition $rows -HostnamePattern '^siepd(?<site>\d{2})(?<role>[a-z]{2})(?<env>[a-z])'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Definition,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$HostnamePattern
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $rules = New-Object System.Collections.Generic.List[object]
    $letterMap = @{}
    $labelMap = @{}
    $keywordMap = @{}
    $environmentNames = New-Object System.Collections.Generic.List[string]
    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'

    if ($Definition.Count -eq 0) { $problems.Add('No environments are defined.') }

    foreach ($item in $Definition) {
        $environment = ([string]$item.Environment).Trim().ToUpperInvariant()
        if ($environment -eq '') {
            $problems.Add('An environment row has no name.')
            continue
        }
        if ($environmentNames.Contains($environment)) {
            $problems.Add("Environment $environment is defined twice.")
            continue
        }
        $environmentNames.Add($environment)

        $letters = New-Object System.Collections.Generic.List[string]
        foreach ($letter in @(Split-RuleValue ([string]$item.Letters))) {
            $letter = $letter.ToLowerInvariant()
            if ($letter -notmatch '^[a-z]$') {
                $problems.Add("$environment hostname letter '$letter' is not a single letter.")
            }
            elseif ($letterMap.ContainsKey($letter) -and $letterMap[$letter] -ne $environment) {
                $problems.Add("Hostname letter '$letter' is mapped to both $($letterMap[$letter]) and $environment.")
            }
            elseif (-not $letters.Contains($letter)) {
                $letterMap[$letter] = $environment
                $letters.Add($letter)
            }
        }

        $labels = New-Object System.Collections.Generic.List[string]
        foreach ($label in @(Split-RuleValue ([string]$item.DnsLabels))) {
            $label = $label.Trim('.').ToLowerInvariant()
            if ($label -notmatch '^[a-z0-9-]+$') {
                $problems.Add("$environment DNS label '$label' must be a single label without dots - enter dpe.protected as two labels, dpe and protected.")
            }
            elseif ($labelMap.ContainsKey($label) -and $labelMap[$label] -ne $environment) {
                $problems.Add("DNS label '$label' is mapped to both $($labelMap[$label]) and $environment.")
            }
            elseif (-not $labels.Contains($label)) {
                $labelMap[$label] = $environment
                $labels.Add($label)
            }
        }

        $keywords = New-Object System.Collections.Generic.List[string]
        foreach ($keyword in @(Split-RuleValue ([string]$item.DatastoreKeywords))) {
            $key = $keyword.ToUpperInvariant()
            if ($keywordMap.ContainsKey($key) -and $keywordMap[$key] -ne $environment) {
                $problems.Add("Datastore keyword '$keyword' is mapped to both $($keywordMap[$key]) and $environment.")
            }
            elseif (-not $keywords.Contains($key)) {
                $keywordMap[$key] = $environment
                $keywords.Add($key)
            }
        }
        if ($keywords.Count -eq 0) {
            $problems.Add("$environment has no datastore keyword, so no datastore could ever be classified as $environment.")
        }

        $datastoreRegex = $null
        if ($keywords.Count -gt 0) {
            # A keyword only counts as a word of its own: anything but a letter either side. That
            # keeps SIT from matching inside SITE, while NFS_PROD_01 and SIEPD85PROD01 still match.
            $alternation = (@($keywords.ToArray() | ForEach-Object { [regex]::Escape($_) }) -join '|')
            $datastoreRegex = [regex]::new("(?<![A-Za-z])(?:$alternation)(?![A-Za-z])", $ignoreCase)
        }

        $rules.Add([pscustomobject]@{
                Environment = $environment
                Letters = $letters.ToArray()
                DnsLabels = $labels.ToArray()
                DatastoreKeywords = $keywords.ToArray()
                DatastoreRegex = $datastoreRegex
            })
    }

    $hostnameRegex = $null
    if ([string]::IsNullOrWhiteSpace($HostnamePattern)) {
        $problems.Add('The hostname pattern is empty.')
    }
    else {
        try {
            $hostnameRegex = [regex]::new($HostnamePattern, $ignoreCase)
        }
        catch {
            $cause = $_.Exception
            if ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
            $problems.Add("The hostname pattern is not a valid regular expression: $($cause.Message)")
        }
        if ($null -ne $hostnameRegex -and @($hostnameRegex.GetGroupNames()) -notcontains 'env') {
            $problems.Add("The hostname pattern must capture the environment letter in a group named 'env', e.g. (?<env>[a-z]).")
        }
    }

    if ($problems.Count -gt 0) {
        throw ("Placement rules are not valid:`n  - " + ($problems.ToArray() -join "`n  - "))
    }

    [pscustomobject]@{
        Rules = $rules.ToArray()
        EnvironmentNames = $environmentNames.ToArray()
        LetterMap = $letterMap
        LabelMap = $labelMap
        HostnameRegex = $hostnameRegex
        HostnamePattern = $HostnamePattern
    }
}

function Get-DatastoreEnvironment {
    <#
    .SYNOPSIS
        Classifies one datastore as one environment, AMBIGUOUS, or nothing.

    .DESCRIPTION
        Environment is '' when the name carries no keyword, or when -NfsOnly is set and the
        datastore is not NFS. Label is the human-readable reason, used in the report and the
        Datastores tab.

    .PARAMETER Name
        Datastore name.

    .PARAMETER Type
        Datastore type as vCenter reports it: NFS, NFS41, VMFS, vsan, VVOL.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .PARAMETER NfsOnly
        Treat anything that is not NFS as out of scope.

    .EXAMPLE
        Get-DatastoreEnvironment -Name 'NFS_PROD_01' -Type 'NFS' -RuleSet $ruleSet
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Type = '',

        [Parameter(Mandatory)]
        [object]$RuleSet,

        [switch]$NfsOnly
    )

    if ($NfsOnly -and @('NFS', 'NFS41') -notcontains $Type.ToUpperInvariant()) {
        $shownType = if ($Type) { $Type } else { 'unknown type' }
        return [pscustomobject]@{ Environment = ''; Label = "excluded - $shownType, not NFS" }
    }

    $hits = @(foreach ($rule in $RuleSet.Rules) {
            if ($null -ne $rule.DatastoreRegex -and $rule.DatastoreRegex.IsMatch($Name)) { $rule.Environment }
        })

    if ($hits.Count -eq 1) {
        return [pscustomobject]@{ Environment = $hits[0]; Label = $hits[0] }
    }
    if ($hits.Count -gt 1) {
        return [pscustomobject]@{ Environment = 'AMBIGUOUS'; Label = "ambiguous - matches $($hits -join ' and ')" }
    }
    [pscustomobject]@{ Environment = ''; Label = "no $($RuleSet.EnvironmentNames -join '/') keyword" }
}

function Get-DnsEnvironment {
    <#
    .SYNOPSIS
        Works out the environment from a DNS name's domain labels.

    .DESCRIPTION
        The first label is the host itself and is ignored; every label after it is compared, whole,
        against the DNS labels in the rules. Whole-label matching is the point: 'dpe' must not match
        inside 'dpesit'. A short name with no domain has nothing to compare and gives ''.

    .PARAMETER DnsName
        The guest DNS name, e.g. siepd85csp1000.dpe.protected.mil.au.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .EXAMPLE
        Get-DnsEnvironment -DnsName 'host.dpesit.protectedsit.mil.au' -RuleSet $ruleSet
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$DnsName,

        [Parameter(Mandatory)]
        [object]$RuleSet
    )

    $clean = $DnsName.Trim().TrimEnd('.').ToLowerInvariant()
    if ($clean -eq '' -or $clean -notmatch '\.') {
        return [pscustomobject]@{ Environment = ''; HasDomain = $false; Matched = @() }
    }

    $domainLabels = @($clean.Split('.') | Select-Object -Skip 1)
    $hits = @($domainLabels |
            Where-Object { $RuleSet.LabelMap.ContainsKey($_) } |
            ForEach-Object { $RuleSet.LabelMap[$_] } |
            Select-Object -Unique)

    $environment = ''
    if ($hits.Count -eq 1) { $environment = $hits[0] }
    elseif ($hits.Count -gt 1) { $environment = 'AMBIGUOUS' }

    [pscustomobject]@{ Environment = $environment; HasDomain = $true; Matched = $hits }
}

function Get-HostnameEnvironment {
    <#
    .SYNOPSIS
        Works out the environment from a name that follows the siepdXXxxL naming standard.

    .DESCRIPTION
        Only the first label is used, so a VM named with its FQDN works too. Matched says whether
        the name follows the standard at all; Environment is '' when it does but its letter is not
        mapped to any environment - that case is reported, so the letter can be added.

    .PARAMETER Name
        VM name or guest hostname.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .EXAMPLE
        Get-HostnameEnvironment -Name 'siepd85csp1000' -RuleSet $ruleSet
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory)]
        [object]$RuleSet
    )

    $short = ($Name.Trim() -split '\.')[0]
    if ($short -eq '') {
        return [pscustomobject]@{ Matched = $false; Letter = ''; Environment = '' }
    }

    $match = $RuleSet.HostnameRegex.Match($short)
    if (-not $match.Success -or -not $match.Groups['env'].Success) {
        return [pscustomobject]@{ Matched = $false; Letter = ''; Environment = '' }
    }

    $letter = $match.Groups['env'].Value.ToLowerInvariant()
    $environment = ''
    if ($RuleSet.LetterMap.ContainsKey($letter)) { $environment = $RuleSet.LetterMap[$letter] }

    [pscustomobject]@{ Matched = $true; Letter = $letter; Environment = $environment }
}

function Resolve-VMExpectedEnvironment {
    <#
    .SYNOPSIS
        Decides which environment a VM belongs to: DNS name first, then VM name, then guest hostname.

    .DESCRIPTION
        Returns Environment ('' when it cannot be decided), DeterminedBy, Letter, Status and Detail.
        Status is '' when an environment was found, otherwise 'Unmapped hostname letter' or
        'Environment undetermined', with Detail saying why in a sentence for the report.

        The DNS name wins when it carries a known label. A conflicting hostname letter does not
        override it.

    .PARAMETER VmName
        VM name in the vCenter inventory.

    .PARAMETER DnsName
        Guest DNS name from VMware Tools. Empty when Tools is not running.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .EXAMPLE
        Resolve-VMExpectedEnvironment -VmName 'siepd85csd01' -DnsName '' -RuleSet $ruleSet
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$VmName,

        [AllowEmptyString()]
        [string]$DnsName = '',

        [Parameter(Mandatory)]
        [object]$RuleSet
    )

    $dns = Get-DnsEnvironment -DnsName $DnsName -RuleSet $RuleSet
    if ($dns.Environment -eq 'AMBIGUOUS') {
        return [pscustomobject]@{
            Environment = ''
            DeterminedBy = 'DNS name'
            Letter = ''
            Status = 'Environment undetermined'
            Detail = "DNS name '$DnsName' carries labels for more than one environment ($($dns.Matched -join ', '))."
        }
    }
    if ($dns.Environment -ne '') {
        return [pscustomobject]@{
            Environment = $dns.Environment
            DeterminedBy = 'DNS name'
            Letter = ''
            Status = ''
            Detail = "DNS name '$DnsName' says $($dns.Environment)"
        }
    }

    $candidates = @(
        [pscustomobject]@{ Source = 'VM name'; Value = $VmName }
        [pscustomobject]@{ Source = 'Guest hostname'; Value = $DnsName }
    )
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.Value)) { continue }
        $byName = Get-HostnameEnvironment -Name $candidate.Value -RuleSet $RuleSet
        if (-not $byName.Matched) { continue }

        if ($byName.Environment -ne '') {
            return [pscustomobject]@{
                Environment = $byName.Environment
                DeterminedBy = $candidate.Source
                Letter = $byName.Letter
                Status = ''
                Detail = "$($candidate.Source) '$($candidate.Value)' (letter '$($byName.Letter)') says $($byName.Environment)"
            }
        }
        return [pscustomobject]@{
            Environment = ''
            DeterminedBy = $candidate.Source
            Letter = $byName.Letter
            Status = 'Unmapped hostname letter'
            Detail = "$($candidate.Source) '$($candidate.Value)' has environment letter '$($byName.Letter)', which is not mapped to $($RuleSet.EnvironmentNames -join ', '). Add it to the hostname letters of the right environment and re-apply."
        }
    }

    $why = if ([string]::IsNullOrWhiteSpace($DnsName)) {
        'No DNS name (VMware Tools not running, or the VM is powered off)'
    }
    elseif ($dns.HasDomain) {
        "DNS name '$DnsName' carries no $($RuleSet.EnvironmentNames -join '/') label"
    }
    else {
        "DNS name '$DnsName' has no domain"
    }
    [pscustomobject]@{
        Environment = ''
        DeterminedBy = ''
        Letter = ''
        Status = 'Environment undetermined'
        Detail = "$why, and the name does not match the hostname pattern $($RuleSet.HostnamePattern)."
    }
}

function Get-PlacementReportColumn {
    <#
    .SYNOPSIS
        The report columns, in order - shared by the GUI grid and the CSV so they cannot drift.

    .EXAMPLE
        Get-PlacementReportColumn
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    'Status', 'Cluster', 'VMName', 'DnsName', 'ExpectedEnvironment', 'DeterminedBy', 'HostnameLetter',
    'DatastoreEnvironment', 'WrongDatastores', 'AllDatastores', 'Reason', 'PowerState', 'ToolsStatus',
    'EsxiHost', 'vCenter', 'DiscoveredAt', 'ScriptVersion'
}

function Test-VMPlacement {
    <#
    .SYNOPSIS
        Evaluates one VM and returns its outcome, with a report row when it is to be reported.

    .DESCRIPTION
        Outcome is one of:
          Correct     every PROD/SIT/DEV datastore the VM uses is its own environment
          Reported    Finding holds the report row
          OutOfScope  the VM uses no PROD/SIT/DEV datastore (and -FlagUnclassifiedDatastores is off)
          Hidden      environment undetermined and -HideUndetermined is set

        An unmapped hostname letter is always reported - it is the signal to add the letter.

    .PARAMETER Record
        One VM from Get-ClusterPlacementInventory: Cluster, VMName, DnsName, PowerState,
        ToolsStatus, EsxiHost, vCenter, DiscoveredAt, and Datastores (Name, Type).

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .PARAMETER NfsOnly
        Only NFS datastores count.

    .PARAMETER FlagUnclassifiedDatastores
        A datastore with no keyword counts as wrong, rather than being ignored.

    .PARAMETER HideUndetermined
        Do not report a VM whose environment cannot be decided.

    .PARAMETER ScriptVersion
        Stamped onto the report row.

    .EXAMPLE
        Test-VMPlacement -Record $vm -RuleSet $ruleSet
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Record,

        [Parameter(Mandatory)]
        [object]$RuleSet,

        [switch]$NfsOnly,

        [switch]$FlagUnclassifiedDatastores,

        [switch]$HideUndetermined,

        [string]$ScriptVersion = ''
    )

    $classified = @(foreach ($datastore in @($Record.Datastores)) {
            if ($null -eq $datastore) { continue }
            $class = Get-DatastoreEnvironment -Name ([string]$datastore.Name) -Type ([string]$datastore.Type) -RuleSet $RuleSet -NfsOnly:$NfsOnly
            [pscustomobject]@{ Name = [string]$datastore.Name; Environment = $class.Environment; Label = $class.Label }
        })
    $scoped = @($classified | Where-Object { $_.Environment -ne '' })

    if ($classified.Count -eq 0 -or ($scoped.Count -eq 0 -and -not $FlagUnclassifiedDatastores)) {
        return [pscustomobject]@{ Outcome = 'OutOfScope'; Finding = $null }
    }

    $expected = Resolve-VMExpectedEnvironment -VmName ([string]$Record.VMName) -DnsName ([string]$Record.DnsName) -RuleSet $RuleSet
    $nameLetter = (Get-HostnameEnvironment -Name ([string]$Record.VMName) -RuleSet $RuleSet).Letter
    $wrong = @()

    if ($expected.Environment -eq '') {
        if ($expected.Status -ne 'Unmapped hostname letter' -and $HideUndetermined) {
            return [pscustomobject]@{ Outcome = 'Hidden'; Finding = $null }
        }
        $status = $expected.Status
        $reason = $expected.Detail
    }
    else {
        $wrong = @($classified | Where-Object {
                if ($_.Environment -eq '') { [bool]$FlagUnclassifiedDatastores }
                else { $_.Environment -ne $expected.Environment }
            })
        if ($wrong.Count -eq 0) {
            return [pscustomobject]@{ Outcome = 'Correct'; Finding = $null }
        }

        $mismatched = @($wrong | Where-Object { $_.Environment -ne '' -and $_.Environment -ne 'AMBIGUOUS' })
        $ambiguous = @($wrong | Where-Object { $_.Environment -eq 'AMBIGUOUS' })
        if ($mismatched.Count -gt 0) { $status = 'Wrong datastore' }
        elseif ($ambiguous.Count -gt 0) { $status = 'Ambiguous datastore name' }
        else { $status = "Not on a $($RuleSet.EnvironmentNames -join '/') datastore" }

        $wrongText = @($wrong | ForEach-Object { "$($_.Name) ($($_.Label))" }) -join ', '
        $reason = "$($expected.Detail), but the VM uses $wrongText."
    }

    $finding = [pscustomobject]@{
        Status = $status
        Cluster = [string]$Record.Cluster
        VMName = [string]$Record.VMName
        DnsName = [string]$Record.DnsName
        ExpectedEnvironment = $expected.Environment
        DeterminedBy = $expected.DeterminedBy
        HostnameLetter = $nameLetter
        DatastoreEnvironment = (@($scoped | ForEach-Object { $_.Environment } | Select-Object -Unique) -join ', ')
        WrongDatastores = (@($wrong | ForEach-Object { "$($_.Name) ($($_.Label))" }) -join '; ')
        AllDatastores = (@($classified | ForEach-Object { "$($_.Name) ($($_.Label))" }) -join '; ')
        Reason = $reason
        PowerState = [string]$Record.PowerState
        ToolsStatus = [string]$Record.ToolsStatus
        EsxiHost = [string]$Record.EsxiHost
        vCenter = [string]$Record.vCenter
        DiscoveredAt = ([datetime]$Record.DiscoveredAt).ToString('yyyy-MM-dd HH:mm:ss')
        ScriptVersion = $ScriptVersion
    }
    [pscustomobject]@{ Outcome = 'Reported'; Finding = $finding }
}

function Invoke-PlacementEvaluation {
    <#
    .SYNOPSIS
        Applies the rules to discovered clusters: report rows, datastore classification, summary.

    .DESCRIPTION
        Works on inventory already read from vCenter, so changing a rule and re-applying is
        instant - vCenter is only read again by Discover.

    .PARAMETER Inventory
        One object per cluster from Get-ClusterPlacementInventory.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .PARAMETER NfsOnly
        Only NFS datastores count.

    .PARAMETER FlagUnclassifiedDatastores
        A datastore with no keyword counts as wrong.

    .PARAMETER HideUndetermined
        Do not report VMs whose environment cannot be decided.

    .PARAMETER ScriptVersion
        Stamped onto every report row.

    .EXAMPLE
        Invoke-PlacementEvaluation -Inventory $inventory -RuleSet $ruleSet -ScriptVersion $ScriptVersion
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Inventory,

        [Parameter(Mandatory)]
        [object]$RuleSet,

        [switch]$NfsOnly,

        [switch]$FlagUnclassifiedDatastores,

        [switch]$HideUndetermined,

        [string]$ScriptVersion = ''
    )

    $findings = New-Object System.Collections.Generic.List[object]
    $datastoreRows = New-Object System.Collections.Generic.List[object]
    $clusters = 0; $vmCount = 0; $correct = 0; $outOfScope = 0; $hidden = 0
    $skippedTemplates = 0; $skippedAgents = 0; $skippedPlaceholders = 0

    foreach ($cluster in $Inventory) {
        $clusters++
        $skippedTemplates += [int]$cluster.SkippedTemplates
        $skippedAgents += [int]$cluster.SkippedAgents
        $skippedPlaceholders += [int]$cluster.SkippedPlaceholders
        $vmsPerDatastore = @{}

        foreach ($vm in @($cluster.VMs)) {
            if ($null -eq $vm) { continue }
            $vmCount++
            foreach ($datastore in @($vm.Datastores)) {
                if ($null -eq $datastore) { continue }
                $vmsPerDatastore[[string]$datastore.Name] = 1 + [int]$vmsPerDatastore[[string]$datastore.Name]
            }

            $outcome = Test-VMPlacement -Record $vm -RuleSet $RuleSet -NfsOnly:$NfsOnly -FlagUnclassifiedDatastores:$FlagUnclassifiedDatastores -HideUndetermined:$HideUndetermined -ScriptVersion $ScriptVersion
            switch ($outcome.Outcome) {
                'Correct' { $correct++ }
                'OutOfScope' { $outOfScope++ }
                'Hidden' { $hidden++ }
                'Reported' { $findings.Add($outcome.Finding) }
            }
        }

        foreach ($datastore in @($cluster.Datastores)) {
            if ($null -eq $datastore) { continue }
            $class = Get-DatastoreEnvironment -Name ([string]$datastore.Name) -Type ([string]$datastore.Type) -RuleSet $RuleSet -NfsOnly:$NfsOnly
            $datastoreRows.Add([pscustomobject]@{
                    Cluster = [string]$cluster.Cluster
                    Datastore = [string]$datastore.Name
                    Type = [string]$datastore.Type
                    Environment = $class.Label
                    VMs = [int]$vmsPerDatastore[[string]$datastore.Name]
                })
        }
    }

    $byStatus = @{}
    foreach ($finding in $findings) { $byStatus[$finding.Status] = 1 + [int]$byStatus[$finding.Status] }

    [pscustomobject]@{
        Findings = $findings.ToArray()
        Datastores = $datastoreRows.ToArray()
        Summary = [pscustomobject]@{
            Clusters = $clusters
            VMs = $vmCount
            Correct = $correct
            Reported = $findings.Count
            ReportedByStatus = $byStatus
            OutOfScope = $outOfScope
            HiddenUndetermined = $hidden
            SkippedTemplates = $skippedTemplates
            SkippedAgents = $skippedAgents
            SkippedPlaceholders = $skippedPlaceholders
        }
    }
}

function Format-PlacementSummary {
    <#
    .SYNOPSIS
        One line describing an evaluation, for the log and the GUI status bar.

    .PARAMETER Summary
        The Summary property of Invoke-PlacementEvaluation's result.

    .EXAMPLE
        Format-PlacementSummary -Summary $result.Summary
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Summary
    )

    $statusParts = @($Summary.ReportedByStatus.Keys | Sort-Object | ForEach-Object { "$($Summary.ReportedByStatus[$_]) $_" })
    $reported = "$($Summary.Reported) reported"
    if ($statusParts.Count -gt 0) { $reported += " ($($statusParts -join ', '))" }

    $text = "$($Summary.Clusters) cluster(s), $($Summary.VMs) VMs: $($Summary.Correct) correct, $reported, $($Summary.OutOfScope) not on a PROD/SIT/DEV datastore"
    if ($Summary.HiddenUndetermined -gt 0) { $text += ", $($Summary.HiddenUndetermined) undetermined hidden" }
    $text + ". Skipped $($Summary.SkippedTemplates) template(s), $($Summary.SkippedAgents) vCLS/agent VM(s), $($Summary.SkippedPlaceholders) SRM placeholder(s)."
}

function Export-PlacementReport {
    <#
    .SYNOPSIS
        Writes the report rows to CSV, in the fixed column order.

    .DESCRIPTION
        With nothing to report the file still gets its header row, so an empty result is a
        deliberate "nothing misplaced" rather than a missing file.

    .PARAMETER Finding
        Report rows from Invoke-PlacementEvaluation.

    .PARAMETER Path
        CSV path. The folder is created when it does not exist.

    .EXAMPLE
        Export-PlacementReport -Finding $result.Findings -Path C:\Temp\placement.csv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Finding,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $columns = @(Get-PlacementReportColumn)
    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -Path $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }

    if ($Finding.Count -eq 0) {
        $header = @($columns | ForEach-Object { '"' + $_ + '"' }) -join ','
        Set-Content -Path $Path -Value $header -Encoding UTF8
    }
    else {
        $Finding | Select-Object -Property $columns | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    }
    Write-PlacementLog "Report written: $Path ($($Finding.Count) row(s))." -Level INFO
}

# =============================================================================================
# vCenter
# =============================================================================================

function Get-ViewProperty {
    <#
    .SYNOPSIS
        Reads a dotted property path from a vSphere view, returning $null at the first gap.

    .DESCRIPTION
        Get-View -Property fills only what was asked for, and an inaccessible or orphaned VM can
        have no Config at all. Walking the path here keeps one missing level from throwing under
        StrictMode halfway through a cluster.

    .PARAMETER InputObject
        The view, or any object.

    .PARAMETER Path
        e.g. 'Config.Files.VmPathName'.

    .EXAMPLE
        Get-ViewProperty -InputObject $vmView -Path 'Guest.HostName'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Path
    )

    $current = $InputObject
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    # Deliberately unrolled: callers collect arrays with @() and scalars with a cast.
    $current
}

function Get-DatastoreNameFromPath {
    <#
    .SYNOPSIS
        Extracts the datastore name from a vSphere file path such as "[NFS_PROD_01] vm/vm.vmx".

    .PARAMETER Path
        The bracketed datastore path.

    .EXAMPLE
        Get-DatastoreNameFromPath '[NFS_PROD_01] siepd85csp1000/siepd85csp1000.vmx'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ($Path -match '^\s*\[(?<ds>[^\]]+)\]') { return $Matches['ds'] }
    ''
}

function ConvertTo-PlacementVMRecord {
    <#
    .SYNOPSIS
        Turns one VirtualMachine view into the plain record the evaluation works on, or a skip reason.

    .DESCRIPTION
        Skip is one of:
          Template     a VM template
          Placeholder  an SRM placeholder VM (managed by com.vmware.vcDr) - the real VM is at the
                       protected site and is evaluated there
          Agent        a vCLS or other ESX Agent Manager VM (managed by com.vmware.vim.eam, or named
                       vCLS*) - placed by vSphere, not by us

        Datastores are the home (.vmx) datastore and each virtual disk's datastore, home first,
        without duplicates. CD-ROM ISOs and swap are deliberately not counted. When neither can be
        read - an inaccessible VM - the VM's own datastore list is used instead.

    .PARAMETER View
        VirtualMachine view from Get-View.

    .PARAMETER DatastoreByRef
        MoRef value -> @{ Name; Type } for the cluster's datastores.

    .PARAMETER DatastoreByName
        Datastore name -> @{ Name; Type }.

    .PARAMETER HostByRef
        MoRef value -> ESXi host name.

    .PARAMETER Cluster
        Cluster name, carried onto the record.

    .PARAMETER VCenter
        vCenter name, carried onto the record.

    .PARAMETER DiscoveredAt
        When the cluster was read.

    .EXAMPLE
        ConvertTo-PlacementVMRecord -View $vmView -DatastoreByRef $byRef -DatastoreByName $byName -Cluster 'CL01'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$View,

        [hashtable]$DatastoreByRef = @{},

        [hashtable]$DatastoreByName = @{},

        [hashtable]$HostByRef = @{},

        [string]$Cluster = '',

        [string]$VCenter = '',

        [datetime]$DiscoveredAt = (Get-Date)
    )

    $name = [string](Get-ViewProperty $View 'Name')

    if ([bool](Get-ViewProperty $View 'Config.Template')) {
        return [pscustomobject]@{ Skip = 'Template'; Record = $null }
    }
    $managedBy = [string](Get-ViewProperty $View 'Config.ManagedBy.ExtensionKey')
    if ($managedBy -eq 'com.vmware.vcDr') {
        return [pscustomobject]@{ Skip = 'Placeholder'; Record = $null }
    }
    if ($managedBy -eq 'com.vmware.vim.eam' -or $name -match '^vCLS') {
        return [pscustomobject]@{ Skip = 'Agent'; Record = $null }
    }

    $datastores = New-Object System.Collections.Specialized.OrderedDictionary
    $paths = New-Object System.Collections.Generic.List[object]
    $paths.Add([pscustomobject]@{ Ref = ''; FileName = [string](Get-ViewProperty $View 'Config.Files.VmPathName') })
    foreach ($device in @(Get-ViewProperty $View 'Config.Hardware.Device')) {
        if ($null -eq $device) { continue }
        if (@($device.PSObject.TypeNames) -notcontains 'VMware.Vim.VirtualDisk') { continue }
        $backing = Get-ViewProperty $device 'Backing'
        $paths.Add([pscustomobject]@{
                Ref = [string](Get-ViewProperty $backing 'Datastore.Value')
                FileName = [string](Get-ViewProperty $backing 'FileName')
            })
    }

    foreach ($path in $paths) {
        $info = $null
        if ($path.Ref -and $DatastoreByRef.ContainsKey($path.Ref)) {
            $info = $DatastoreByRef[$path.Ref]
        }
        else {
            $datastoreName = Get-DatastoreNameFromPath $path.FileName
            if ($datastoreName) {
                $info = $DatastoreByName[$datastoreName]
                if ($null -eq $info) { $info = [pscustomobject]@{ Name = $datastoreName; Type = 'Unknown' } }
            }
        }
        if ($null -ne $info -and -not $datastores.Contains($info.Name)) { $datastores[$info.Name] = $info }
    }

    if ($datastores.Count -eq 0) {
        foreach ($ref in @(Get-ViewProperty $View 'Datastore')) {
            if ($null -eq $ref) { continue }
            $key = [string]$ref.Value
            if ($DatastoreByRef.ContainsKey($key) -and -not $datastores.Contains($DatastoreByRef[$key].Name)) {
                $datastores[$DatastoreByRef[$key].Name] = $DatastoreByRef[$key]
            }
        }
    }

    $hostRef = [string](Get-ViewProperty $View 'Runtime.Host.Value')
    $esxiHost = ''
    if ($hostRef -and $HostByRef.ContainsKey($hostRef)) { $esxiHost = [string]$HostByRef[$hostRef] }

    $record = [pscustomobject]@{
        Cluster = $Cluster
        VMName = $name
        DnsName = [string](Get-ViewProperty $View 'Guest.HostName')
        PowerState = [string](Get-ViewProperty $View 'Runtime.PowerState')
        ToolsStatus = [string](Get-ViewProperty $View 'Guest.ToolsRunningStatus')
        EsxiHost = $esxiHost
        vCenter = $VCenter
        DiscoveredAt = $DiscoveredAt
        Datastores = @($datastores.Values)
    }
    [pscustomobject]@{ Skip = ''; Record = $record }
}

function Assert-PowerCliAvailable {
    <#
    .SYNOPSIS
        Fails early, with the install command, when PowerCLI is not on this machine.

    .DESCRIPTION
        PowerShell auto-loads VMware.VimAutomation.Core on the first Connect-VIServer; this only
        checks that the command can be found, so the failure is a clear message instead of
        "the term is not recognized" after the GUI is already up.

    .EXAMPLE
        Assert-PowerCliAvailable
    #>
    [CmdletBinding()]
    param()

    if ($null -eq (Get-Command -Name 'Connect-VIServer' -ErrorAction SilentlyContinue)) {
        throw 'VMware PowerCLI was not found - Connect-VIServer is not available in this session. Install it with: Install-Module VMware.PowerCLI -Scope CurrentUser'
    }
}

function Connect-PlacementVCenter {
    <#
    .SYNOPSIS
        Signs in to vCenter and returns the connection.

    .DESCRIPTION
        With a credential, signs in as that account. Without one, PowerCLI signs in as the current
        Windows session (SSPI) where vCenter allows it. Common failures are turned into a message
        that says what to do.

    .PARAMETER Server
        vCenter FQDN.

    .PARAMETER Credential
        Domain account. Optional.

    .EXAMPLE
        $vc = Connect-PlacementVCenter -Server vcenter01.example.com -Credential (Get-Credential)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [pscredential]$Credential
    )

    $who = if ($null -ne $Credential) { $Credential.UserName } else { 'the current Windows session' }
    Write-PlacementLog "Connecting to vCenter $Server as $who." -Level INFO

    try {
        if ($null -ne $Credential) {
            $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
        }
        else {
            $connection = Connect-VIServer -Server $Server -ErrorAction Stop
        }
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match '(?i)certificate') {
            throw "Could not connect to $Server - its certificate is not trusted by this machine. Trust the vCenter root CA on this host, or review PowerCLI's InvalidCertificateAction setting. Detail: $detail"
        }
        if ($detail -match '(?i)incorrect user name or password|cannot complete login|InvalidLogin') {
            throw "vCenter $Server rejected the sign-in for $who. Use DOMAIN\user or user@domain, and check the account is not locked. Detail: $detail"
        }
        throw "Could not connect to vCenter $Server. Detail: $detail"
    }

    Write-PlacementLog "Connected to $($connection.Name) (vCenter $($connection.Version) build $($connection.Build)) as $($connection.User)." -Level INFO
    $connection
}

function Disconnect-PlacementVCenter {
    <#
    .SYNOPSIS
        Closes a connection this script opened. Never throws.

    .PARAMETER Connection
        The object Connect-PlacementVCenter returned.

    .EXAMPLE
        Disconnect-PlacementVCenter -Connection $vc
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Connection
    )

    if ($null -eq $Connection) { return }
    try {
        Disconnect-VIServer -Server $Connection -Confirm:$false -ErrorAction Stop
        Write-PlacementLog "Disconnected from $($Connection.Name)." -Level INFO
    }
    catch {
        Write-PlacementLog "Disconnect from $($Connection.Name) failed: $($_.Exception.Message)" -Level WARN
    }
}

function Get-PlacementClusterList {
    <#
    .SYNOPSIS
        Lists the clusters in the connected vCenter, by name.

    .PARAMETER Server
        Connection from Connect-PlacementVCenter.

    .EXAMPLE
        Get-PlacementClusterList -Server $vc
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Server
    )

    @(Get-View -Server $Server -ViewType ClusterComputeResource -Property 'Name') | Sort-Object -Property Name
}

function Get-ClusterPlacementInventory {
    <#
    .SYNOPSIS
        Reads one cluster from vCenter: its datastores and, for each VM, its DNS name and datastores.

    .DESCRIPTION
        Four property-collector calls per cluster - cluster, datastores, hosts, VMs - each asking
        only for the properties used, rather than a round trip per VM. Read-only.

    .PARAMETER Server
        Connection from Connect-PlacementVCenter.

    .PARAMETER ClusterView
        ClusterComputeResource view from Get-PlacementClusterList.

    .EXAMPLE
        Get-ClusterPlacementInventory -Server $vc -ClusterView $clusterView
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter(Mandatory)]
        [object]$ClusterView
    )

    $discoveredAt = Get-Date
    $clusterInfo = Get-View -Server $Server -Id $ClusterView.MoRef -Property 'Name', 'Datastore', 'Host'
    Write-PlacementLog "Reading cluster $($clusterInfo.Name)..." -Level INFO

    $datastoreByRef = @{}
    $datastoreByName = @{}
    $datastoreRefs = @($clusterInfo.Datastore | Where-Object { $null -ne $_ })
    if ($datastoreRefs.Count -gt 0) {
        foreach ($view in @(Get-View -Server $Server -Id $datastoreRefs -Property 'Name', 'Summary.Type')) {
            $info = [pscustomobject]@{ Name = [string]$view.Name; Type = [string](Get-ViewProperty $view 'Summary.Type') }
            $datastoreByRef[[string]$view.MoRef.Value] = $info
            $datastoreByName[$info.Name] = $info
        }
    }

    $hostByRef = @{}
    $hostRefs = @($clusterInfo.Host | Where-Object { $null -ne $_ })
    if ($hostRefs.Count -gt 0) {
        foreach ($view in @(Get-View -Server $Server -Id $hostRefs -Property 'Name')) {
            $hostByRef[[string]$view.MoRef.Value] = [string]$view.Name
        }
    }

    $vmProperties = @(
        'Name', 'Config.Template', 'Config.ManagedBy', 'Config.Files.VmPathName', 'Config.Hardware.Device',
        'Guest.HostName', 'Guest.ToolsRunningStatus', 'Runtime.PowerState', 'Runtime.Host', 'Datastore'
    )
    $vmViews = @(Get-View -Server $Server -ViewType VirtualMachine -SearchRoot $clusterInfo.MoRef -Property $vmProperties)

    $records = New-Object System.Collections.Generic.List[object]
    $skipped = @{ Template = 0; Agent = 0; Placeholder = 0 }
    $seen = @{}
    foreach ($view in $vmViews) {
        $id = [string]$view.MoRef.Value
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true

        $converted = ConvertTo-PlacementVMRecord -View $view -DatastoreByRef $datastoreByRef -DatastoreByName $datastoreByName -HostByRef $hostByRef -Cluster $clusterInfo.Name -VCenter ([string]$Server.Name) -DiscoveredAt $discoveredAt
        if ($converted.Skip) {
            $skipped[$converted.Skip] = $skipped[$converted.Skip] + 1
            continue
        }
        $records.Add($converted.Record)
    }

    Write-PlacementLog ("Cluster {0}: {1} VMs, {2} datastores; skipped {3} template(s), {4} vCLS/agent VM(s), {5} SRM placeholder(s)." -f $clusterInfo.Name, $records.Count, $datastoreByName.Count, $skipped.Template, $skipped.Agent, $skipped.Placeholder) -Level INFO

    [pscustomobject]@{
        Cluster = [string]$clusterInfo.Name
        vCenter = [string]$Server.Name
        DiscoveredAt = $discoveredAt
        Datastores = @($datastoreByName.Values | Sort-Object -Property Name)
        VMs = $records.ToArray()
        SkippedTemplates = $skipped.Template
        SkippedAgents = $skipped.Agent
        SkippedPlaceholders = $skipped.Placeholder
    }
}

# =============================================================================================
# GUI
# =============================================================================================

function ConvertTo-PlacementDataTable {
    <#
    .SYNOPSIS
        Builds a DataTable for a grid, so the columns sort on a header click.

    .PARAMETER Row
        Objects to show.

    .PARAMETER Column
        Property names, in display order.

    .EXAMPLE
        $grid.DataSource = ConvertTo-PlacementDataTable -Row $findings -Column (Get-PlacementReportColumn)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Row,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Column
    )

    $table = New-Object System.Data.DataTable
    foreach ($name in $Column) {
        $type = [string]
        if ($name -eq 'VMs') { $type = [int] }
        [void]$table.Columns.Add($name, $type)
    }
    foreach ($item in $Row) {
        $dataRow = $table.NewRow()
        foreach ($name in $Column) {
            $value = $item.$name
            if ($null -eq $value) { $value = [DBNull]::Value }
            $dataRow[$name] = $value
        }
        [void]$table.Rows.Add($dataRow)
    }
    , $table
}

function Show-GuiMessage {
    <#
    .SYNOPSIS
        Shows a message box over the main window.

    .PARAMETER Text
        Message.

    .PARAMETER Icon
        Information, Warning or Error.

    .EXAMPLE
        Show-GuiMessage -Text 'Done.' -Icon Information
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Icon = 'Information'
    )

    [void][System.Windows.Forms.MessageBox]::Show($script:Gui.Form, $Text, $script:Gui.Form.Text, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::$Icon)
}

function Invoke-GuiAction {
    <#
    .SYNOPSIS
        Runs a button's work, turning any failure into a message box instead of a crashed window.

    .PARAMETER Action
        The work.

    .EXAMPLE
        $button.Add_Click({ Invoke-GuiAction { Invoke-GuiDiscovery } })
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [scriptblock]$Action
    )

    # The log pane pumps the message loop so it updates during discovery, which means a click can
    # arrive mid-run. Buttons are disabled then, but Enter in the password box is not - so refuse
    # here rather than start a second run inside the first.
    if ($script:GuiState.Busy) { return }

    try {
        & $Action
    }
    catch {
        $message = $_.Exception.Message
        Write-PlacementLog $message -Level WARN
        $script:Gui.Status.Text = 'Failed - see the Log tab.'
        Show-GuiMessage -Text $message -Icon Error
    }
    finally {
        Exit-GuiBusyState
    }
}

function Enter-GuiBusyState {
    <#
    .SYNOPSIS
        Disables the buttons and shows a wait cursor while vCenter is being read.

    .PARAMETER Text
        Status bar text while busy.

    .EXAMPLE
        Enter-GuiBusyState -Text 'Discovering...'
    #>
    [CmdletBinding()]
    param(
        [string]$Text = 'Working...'
    )

    $script:GuiState.Busy = $true
    foreach ($control in @($script:Gui.Connect, $script:Gui.Disconnect, $script:Gui.Discover, $script:Gui.Reapply, $script:Gui.Export, $script:Gui.ClusterList)) {
        $control.Enabled = $false
    }
    $script:Gui.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $script:Gui.Status.Text = $Text
    [System.Windows.Forms.Application]::DoEvents()
}

function Exit-GuiBusyState {
    <#
    .SYNOPSIS
        Re-enables whatever the current state allows.

    .EXAMPLE
        Exit-GuiBusyState
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:Gui -or $null -eq $script:GuiState) { return }
    $script:GuiState.Busy = $false
    $connected = $null -ne $script:GuiState.Connection
    $discovered = $null -ne $script:GuiState.Inventory
    $script:Gui.Connect.Enabled = $true
    $script:Gui.Disconnect.Enabled = $connected
    $script:Gui.Discover.Enabled = $connected
    $script:Gui.ClusterList.Enabled = $connected
    $script:Gui.Reapply.Enabled = $discovered
    $script:Gui.Export.Enabled = $null -ne $script:GuiState.Result
    $script:Gui.Form.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Get-GuiRuleDefinition {
    <#
    .SYNOPSIS
        Reads the rules grid into the definitions ConvertTo-PlacementRuleSet takes.

    .EXAMPLE
        $definition = @(Get-GuiRuleDefinition)
    #>
    [CmdletBinding()]
    param()

    [void]$script:Gui.RulesGrid.EndEdit()
    foreach ($gridRow in $script:Gui.RulesGrid.Rows) {
        if ($gridRow.IsNewRow) { continue }
        [pscustomobject]@{
            Environment = [string]$gridRow.Cells['Environment'].Value
            Letters = [string]$gridRow.Cells['Letters'].Value
            DnsLabels = [string]$gridRow.Cells['DnsLabels'].Value
            DatastoreKeywords = [string]$gridRow.Cells['DatastoreKeywords'].Value
        }
    }
}

function Invoke-GuiConnect {
    <#
    .SYNOPSIS
        Signs in with the username and password typed into the GUI, then lists the clusters.

    .DESCRIPTION
        An empty password uses the -Credential the script was started with, if any, or else the
        current Windows session. The password box is cleared once used.

    .EXAMPLE
        Invoke-GuiConnect
    #>
    [CmdletBinding()]
    param()

    $server = $script:Gui.Server.Text.Trim()
    if ($server -eq '') { throw 'Enter the vCenter server name.' }

    $credential = $null
    if ($script:Gui.Password.TextLength -gt 0) {
        $user = $script:Gui.User.Text.Trim()
        if ($user -eq '') { throw 'Enter your domain username - DOMAIN\user or user@domain.' }
        $secure = New-Object System.Security.SecureString
        foreach ($character in $script:Gui.Password.Text.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()
        $credential = New-Object System.Management.Automation.PSCredential($user, $secure)
    }
    elseif ($null -ne $script:GuiState.SuppliedCredential) {
        $credential = $script:GuiState.SuppliedCredential
    }
    $script:Gui.Password.Clear()

    Enter-GuiBusyState -Text "Connecting to $server..."
    if ($null -ne $script:GuiState.Connection) {
        Disconnect-PlacementVCenter -Connection $script:GuiState.Connection
        $script:GuiState.Connection = $null
    }
    $script:Gui.ConnectionLabel.Text = 'Not connected'
    $script:GuiState.Inventory = $null
    $script:GuiState.Result = $null
    $script:GuiState.ClusterViews = @{}
    $script:Gui.ClusterList.Items.Clear()

    $script:GuiState.Connection = Connect-PlacementVCenter -Server $server -Credential $credential
    $clusterViews = @(Get-PlacementClusterList -Server $script:GuiState.Connection)
    [void]$script:Gui.ClusterList.Items.Add('(All clusters)')
    foreach ($view in $clusterViews) {
        $script:GuiState.ClusterViews[[string]$view.Name] = $view
        [void]$script:Gui.ClusterList.Items.Add([string]$view.Name)
    }
    if ($clusterViews.Count -gt 0) { $script:Gui.ClusterList.SelectedIndex = 1 }
    else { $script:Gui.ClusterList.SelectedIndex = 0 }

    $script:Gui.ConnectionLabel.Text = "Connected to $($script:GuiState.Connection.Name) as $($script:GuiState.Connection.User) - $($clusterViews.Count) cluster(s)"
    $script:Gui.Status.Text = 'Pick a cluster and click Discover.'
    Write-PlacementLog "$($clusterViews.Count) cluster(s) found." -Level INFO
}

function Invoke-GuiDisconnect {
    <#
    .SYNOPSIS
        Signs out of vCenter and clears the cluster list.

    .EXAMPLE
        Invoke-GuiDisconnect
    #>
    [CmdletBinding()]
    param()

    Enter-GuiBusyState -Text 'Disconnecting...'
    Disconnect-PlacementVCenter -Connection $script:GuiState.Connection
    $script:GuiState.Connection = $null
    $script:GuiState.ClusterViews = @{}
    $script:Gui.ClusterList.Items.Clear()
    $script:Gui.ConnectionLabel.Text = 'Not connected'
    $script:Gui.Status.Text = 'Disconnected. Results stay on screen and can still be exported.'
}

function Invoke-GuiDiscovery {
    <#
    .SYNOPSIS
        Reads the selected cluster (or every cluster) from vCenter, then applies the rules.

    .EXAMPLE
        Invoke-GuiDiscovery
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:GuiState.Connection) { throw 'Connect to vCenter first.' }
    $selected = [string]$script:Gui.ClusterList.SelectedItem
    if ($selected -eq '') { throw 'Pick a cluster.' }

    # Rules are validated before vCenter is read, so a typo costs nothing.
    [void](ConvertTo-PlacementRuleSet -Definition @(Get-GuiRuleDefinition) -HostnamePattern $script:Gui.Pattern.Text.Trim())

    $targets = if ($selected -eq '(All clusters)') {
        @($script:GuiState.ClusterViews.Keys | Sort-Object | ForEach-Object { $script:GuiState.ClusterViews[$_] })
    }
    else {
        @($script:GuiState.ClusterViews[$selected])
    }

    $inventory = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($clusterView in $targets) {
        $index++
        Enter-GuiBusyState -Text "Discovering $($clusterView.Name) ($index of $($targets.Count))..."
        $inventory.Add((Get-ClusterPlacementInventory -Server $script:GuiState.Connection -ClusterView $clusterView))
    }

    $script:GuiState.Inventory = $inventory.ToArray()
    $script:GuiState.Scope = $selected
    Invoke-GuiEvaluation
}

function Invoke-GuiEvaluation {
    <#
    .SYNOPSIS
        Applies the current rules and options to the last discovery and refreshes the grids.

    .EXAMPLE
        Invoke-GuiEvaluation
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:GuiState.Inventory) { throw 'Nothing discovered yet - click Discover first.' }
    Enter-GuiBusyState -Text 'Applying rules...'

    $ruleSet = ConvertTo-PlacementRuleSet -Definition @(Get-GuiRuleDefinition) -HostnamePattern $script:Gui.Pattern.Text.Trim()
    $result = Invoke-PlacementEvaluation -Inventory $script:GuiState.Inventory -RuleSet $ruleSet `
        -NfsOnly:($script:Gui.NfsOnly.Checked) `
        -FlagUnclassifiedDatastores:($script:Gui.FlagUnclassified.Checked) `
        -HideUndetermined:(-not $script:Gui.ShowUndetermined.Checked) `
        -ScriptVersion $script:GuiState.ScriptVersion
    $script:GuiState.Result = $result

    $script:Gui.ResultsGrid.DataSource = ConvertTo-PlacementDataTable -Row $result.Findings -Column @(Get-PlacementReportColumn)
    $script:Gui.DatastoreGrid.DataSource = ConvertTo-PlacementDataTable -Row $result.Datastores -Column @('Cluster', 'Datastore', 'Type', 'Environment', 'VMs')
    $script:Gui.ResultsTab.Text = "Misplaced VMs ($($result.Findings.Count))"
    $script:Gui.DatastoreTab.Text = "Datastores ($($result.Datastores.Count))"

    $summary = Format-PlacementSummary -Summary $result.Summary
    $script:Gui.Status.Text = "$($script:GuiState.Scope): $summary"
    Write-PlacementLog $summary -Level INFO
}

function Invoke-GuiExport {
    <#
    .SYNOPSIS
        Saves what the Misplaced VMs tab shows to a CSV the user picks.

    .EXAMPLE
        Invoke-GuiExport
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:GuiState.Result) { throw 'Nothing to export yet - click Discover first.' }

    $scope = ([string]$script:GuiState.Scope) -replace '^\(All clusters\)$', 'AllClusters' -replace '[^A-Za-z0-9._-]', '_'
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $dialog.Title = 'Export misplaced VMs'
        $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
        $dialog.FileName = 'VMDatastorePlacement_{0}_{1}.csv' -f $scope, (Get-Date -Format 'yyyyMMdd-HHmm')
        $documents = [Environment]::GetFolderPath('MyDocuments')
        if ($documents) { $dialog.InitialDirectory = $documents }
        if ($dialog.ShowDialog($script:Gui.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

        Export-PlacementReport -Finding $script:GuiState.Result.Findings -Path $dialog.FileName
        $note = if ($script:GuiState.Result.Findings.Count -eq 0) { 'No misplaced VMs - the file has the header row only.' } else { "$($script:GuiState.Result.Findings.Count) row(s) exported." }
        Show-GuiMessage -Text "$note`n`n$($dialog.FileName)" -Icon Information
    }
    finally {
        $dialog.Dispose()
    }
}

function Show-PlacementGui {
    <#
    .SYNOPSIS
        Opens the placement window: sign in, pick a cluster, discover, adjust rules, export.

    .PARAMETER InitialServer
        Pre-fills the vCenter box.

    .PARAMETER Credential
        Used when the password box is left empty.

    .PARAMETER RuleDefinition
        Initial rules grid rows.

    .PARAMETER HostnamePattern
        Initial hostname pattern.

    .PARAMETER NfsOnly
        Initial state of the NFS-only checkbox.

    .PARAMETER FlagUnclassifiedDatastores
        Initial state of the flag-unclassified checkbox.

    .PARAMETER HideUndetermined
        Initial state (inverted) of the report-undetermined checkbox.

    .PARAMETER ScriptVersion
        Shown in the title and stamped onto report rows.

    .EXAMPLE
        Show-PlacementGui -RuleDefinition $definition -HostnamePattern $HostnamePattern -ScriptVersion $ScriptVersion
    #>
    [CmdletBinding()]
    param(
        [string]$InitialServer = '',

        [pscredential]$Credential,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$RuleDefinition,

        [Parameter(Mandatory)]
        [string]$HostnamePattern,

        [switch]$NfsOnly,

        [switch]$FlagUnclassifiedDatastores,

        [switch]$HideUndetermined,

        [Parameter(Mandatory)]
        [string]$ScriptVersion
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:GuiState = @{
        Connection = $null
        Inventory = $null
        Result = $null
        Scope = ''
        Busy = $false
        ClusterViews = @{}
        SuppliedCredential = $Credential
        ScriptVersion = $ScriptVersion
    }
    $script:Gui = @{}

    $font = New-Object System.Drawing.Font('Segoe UI', 9)
    $labelMargin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
    $tips = New-Object System.Windows.Forms.ToolTip

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "VM Datastore Placement $ScriptVersion"
    $form.Font = $font
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Size = New-Object System.Drawing.Size(1320, 860)
    $form.MinimumSize = New-Object System.Drawing.Size(1000, 600)
    $script:Gui.Form = $form

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    $layout.Padding = New-Object System.Windows.Forms.Padding(6)
    [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $newRow = {
        $flow = New-Object System.Windows.Forms.FlowLayoutPanel
        $flow.AutoSize = $true
        $flow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $flow.WrapContents = $false
        $flow.Dock = [System.Windows.Forms.DockStyle]::Fill
        $flow.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
        $flow
    }
    $newLabel = {
        param([string]$Text)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.AutoSize = $true
        $label.Margin = $labelMargin
        $label
    }
    $newButton = {
        param([string]$Text)
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.AutoSize = $true
        $button.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
        $button
    }
    $newTextBox = {
        param([int]$Width, [string]$Text)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Width = $Width
        $box.Text = $Text
        $box
    }

    # ---- Row 0: sign in --------------------------------------------------------------------
    $row0 = & $newRow
    $script:Gui.Server = & $newTextBox 240 $InitialServer
    $defaultUser = ''
    if ($null -ne $Credential) { $defaultUser = $Credential.UserName }
    elseif ($env:USERDOMAIN -and $env:USERNAME) { $defaultUser = "$env:USERDOMAIN\$env:USERNAME" }
    $script:Gui.User = & $newTextBox 220 $defaultUser
    $script:Gui.Password = & $newTextBox 170 ''
    $script:Gui.Password.UseSystemPasswordChar = $true
    $script:Gui.Connect = & $newButton 'Connect'
    $script:Gui.Disconnect = & $newButton 'Disconnect'
    $script:Gui.ConnectionLabel = & $newLabel 'Not connected'
    $script:Gui.ConnectionLabel.ForeColor = [System.Drawing.Color]::DimGray
    $row0.Controls.AddRange(@(
            (& $newLabel 'vCenter'), $script:Gui.Server,
            (& $newLabel 'Domain user'), $script:Gui.User,
            (& $newLabel 'Password'), $script:Gui.Password,
            $script:Gui.Connect, $script:Gui.Disconnect))
    $tips.SetToolTip($script:Gui.User, 'DOMAIN\user or user@domain')
    $tips.SetToolTip($script:Gui.Password, 'Leave empty to sign in as your current Windows session (or with the -Credential the script was started with).')

    # ---- Row 1: discover -------------------------------------------------------------------
    $row1 = & $newRow
    $script:Gui.ClusterList = New-Object System.Windows.Forms.ComboBox
    $script:Gui.ClusterList.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:Gui.ClusterList.Width = 300
    $script:Gui.Discover = & $newButton 'Discover'
    $script:Gui.Reapply = & $newButton 'Re-apply rules'
    $script:Gui.Export = & $newButton 'Export CSV...'
    $row1.Controls.AddRange(@((& $newLabel 'Cluster'), $script:Gui.ClusterList, $script:Gui.Discover, $script:Gui.Reapply, $script:Gui.Export, $script:Gui.ConnectionLabel))
    $tips.SetToolTip($script:Gui.Discover, 'Read the cluster from vCenter again, then apply the rules.')
    $tips.SetToolTip($script:Gui.Reapply, 'Apply the rules below to the last discovery, without reading vCenter again.')

    # ---- Row 2: options --------------------------------------------------------------------
    $row2 = & $newRow
    $script:Gui.NfsOnly = New-Object System.Windows.Forms.CheckBox
    $script:Gui.NfsOnly.Text = 'NFS datastores only'
    $script:Gui.NfsOnly.AutoSize = $true
    $script:Gui.NfsOnly.Checked = [bool]$NfsOnly
    $script:Gui.ShowUndetermined = New-Object System.Windows.Forms.CheckBox
    $script:Gui.ShowUndetermined.Text = 'Report VMs whose environment cannot be determined'
    $script:Gui.ShowUndetermined.AutoSize = $true
    $script:Gui.ShowUndetermined.Checked = -not $HideUndetermined
    $script:Gui.FlagUnclassified = New-Object System.Windows.Forms.CheckBox
    $script:Gui.FlagUnclassified.Text = 'Flag datastores with no PROD/SIT/DEV keyword'
    $script:Gui.FlagUnclassified.AutoSize = $true
    $script:Gui.FlagUnclassified.Checked = [bool]$FlagUnclassifiedDatastores
    $script:Gui.Pattern = & $newTextBox 330 $HostnamePattern
    $row2.Controls.AddRange(@($script:Gui.NfsOnly, $script:Gui.ShowUndetermined, $script:Gui.FlagUnclassified, (& $newLabel 'Hostname pattern'), $script:Gui.Pattern))
    $tips.SetToolTip($script:Gui.FlagUnclassified, 'Off: only PROD/SIT/DEV datastores are checked and any other datastore is ignored. On: a VM using any other datastore is reported too.')
    $tips.SetToolTip($script:Gui.Pattern, "Regex matched against the VM name. The environment letter must be captured as (?<env>...).")

    # ---- Row 3/4: rules --------------------------------------------------------------------
    $rulesLabel = & $newLabel 'Placement rules - comma-separate values. Example: if VMs with letter b belong on DEV, add b to DEV''s hostname letters and click Re-apply rules.'
    $rulesLabel.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)

    $rulesGrid = New-Object System.Windows.Forms.DataGridView
    $rulesGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rulesGrid.AllowUserToAddRows = $false
    $rulesGrid.AllowUserToDeleteRows = $false
    $rulesGrid.AllowUserToResizeRows = $false
    $rulesGrid.RowHeadersVisible = $false
    $rulesGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::CellSelect
    $rulesGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $rulesGrid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing
    $rowHeight = [Math]::Max(22, $font.Height + 9)
    $rulesGrid.ColumnHeadersHeight = $rowHeight
    $rulesGrid.RowTemplate.Height = $rowHeight
    foreach ($spec in @(
            @('Environment', 'Environment', 15, $true),
            @('Letters', 'Hostname letters (p / t / d)', 20, $false),
            @('DnsLabels', 'DNS labels', 35, $false),
            @('DatastoreKeywords', 'Datastore keywords', 30, $false))) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.Name = $spec[0]
        $column.HeaderText = $spec[1]
        $column.FillWeight = $spec[2]
        $column.ReadOnly = $spec[3]
        $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
        [void]$rulesGrid.Columns.Add($column)
    }
    $rulesGrid.Columns['Environment'].DefaultCellStyle.BackColor = [System.Drawing.SystemColors]::Control
    foreach ($definition in $RuleDefinition) {
        [void]$rulesGrid.Rows.Add([string]$definition.Environment, [string]$definition.Letters, [string]$definition.DnsLabels, [string]$definition.DatastoreKeywords)
    }
    $rulesHeight = $rowHeight * ([Math]::Max(1, $RuleDefinition.Count) + 1) + 4
    $script:Gui.RulesGrid = $rulesGrid

    # ---- Row 5: results tabs ---------------------------------------------------------------
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill

    $newGrid = {
        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
        $grid.ReadOnly = $true
        $grid.AllowUserToAddRows = $false
        $grid.AllowUserToDeleteRows = $false
        $grid.RowHeadersVisible = $false
        $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
        $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells
        $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
        $grid
    }

    $script:Gui.ResultsTab = New-Object System.Windows.Forms.TabPage
    $script:Gui.ResultsTab.Text = 'Misplaced VMs'
    $script:Gui.ResultsGrid = & $newGrid
    $script:Gui.ResultsTab.Controls.Add($script:Gui.ResultsGrid)
    $script:Gui.ResultsGrid.Add_DataBindingComplete({
            foreach ($gridRow in $this.Rows) {
                $colour = switch ([string]$gridRow.Cells['Status'].Value) {
                    'Wrong datastore' { [System.Drawing.Color]::MistyRose }
                    'Unmapped hostname letter' { [System.Drawing.Color]::LightYellow }
                    'Environment undetermined' { [System.Drawing.Color]::Gainsboro }
                    default { [System.Drawing.Color]::Lavender }
                }
                $gridRow.DefaultCellStyle.BackColor = $colour
            }
        })

    $script:Gui.DatastoreTab = New-Object System.Windows.Forms.TabPage
    $script:Gui.DatastoreTab.Text = 'Datastores'
    $script:Gui.DatastoreGrid = & $newGrid
    $script:Gui.DatastoreTab.Controls.Add($script:Gui.DatastoreGrid)

    $logTab = New-Object System.Windows.Forms.TabPage
    $logTab.Text = 'Log'
    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true
    $logBox.ReadOnly = $true
    $logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $logBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $logBox.BackColor = [System.Drawing.SystemColors]::Window
    $logTab.Controls.Add($logBox)
    $script:Gui.LogBox = $logBox

    $tabs.TabPages.AddRange(@($script:Gui.ResultsTab, $script:Gui.DatastoreTab, $logTab))

    # ---- Assemble --------------------------------------------------------------------------
    $layout.RowCount = 6
    foreach ($style in @('AutoSize', 'AutoSize', 'AutoSize', 'AutoSize')) {
        [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::$style)))
    }
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $rulesHeight)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $layout.Controls.Add($row0, 0, 0)
    $layout.Controls.Add($row1, 0, 1)
    $layout.Controls.Add($row2, 0, 2)
    $layout.Controls.Add($rulesLabel, 0, 3)
    $layout.Controls.Add($rulesGrid, 0, 4)
    $layout.Controls.Add($tabs, 0, 5)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $script:Gui.Status = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:Gui.Status.Spring = $true
    $script:Gui.Status.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $script:Gui.Status.Text = 'Sign in to vCenter with your domain account.'
    [void]$statusStrip.Items.Add($script:Gui.Status)

    # Docking runs from the back of the z-order: the strip takes the bottom edge first and the
    # table, brought to the front, fills what is left.
    $form.Controls.Add($layout)
    $form.Controls.Add($statusStrip)
    $layout.BringToFront()

    # ---- Events ----------------------------------------------------------------------------
    $script:Gui.Connect.Add_Click({ Invoke-GuiAction { Invoke-GuiConnect } })
    $script:Gui.Disconnect.Add_Click({ Invoke-GuiAction { Invoke-GuiDisconnect } })
    $script:Gui.Discover.Add_Click({ Invoke-GuiAction { Invoke-GuiDiscovery } })
    $script:Gui.Reapply.Add_Click({ Invoke-GuiAction { Invoke-GuiEvaluation } })
    $script:Gui.Export.Add_Click({ Invoke-GuiAction { Invoke-GuiExport } })
    $script:Gui.Password.Add_KeyDown({
            if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                $_.SuppressKeyPress = $true
                Invoke-GuiAction { Invoke-GuiConnect }
            }
        })
    foreach ($checkbox in @($script:Gui.NfsOnly, $script:Gui.ShowUndetermined, $script:Gui.FlagUnclassified)) {
        $checkbox.Add_CheckedChanged({
                if ($null -ne $script:GuiState.Inventory -and -not $script:GuiState.Busy) {
                    Invoke-GuiAction { Invoke-GuiEvaluation }
                }
            })
    }
    $form.Add_FormClosing({
            if ($script:GuiState.Busy) { $_.Cancel = $true }
        })

    $script:GuiLogSink = {
        param([string]$Line)
        $script:Gui.LogBox.AppendText($Line + [Environment]::NewLine)
        [System.Windows.Forms.Application]::DoEvents()
    }

    Exit-GuiBusyState
    try {
        Write-PlacementLog "VM datastore placement $ScriptVersion - GUI started. Read-only: nothing in vCenter is changed." -Level INFO
        [void]$form.ShowDialog()
    }
    finally {
        $script:GuiLogSink = $null
        Disconnect-PlacementVCenter -Connection $script:GuiState.Connection
        $script:GuiState.Connection = $null
        $form.Dispose()
    }
}

# =============================================================================================
# Main
# =============================================================================================

try {
    $ruleDefinition = @(
        [pscustomobject]@{ Environment = 'PROD'; Letters = ($ProdLetters -join ', '); DnsLabels = ($ProdDnsLabels -join ', '); DatastoreKeywords = ($ProdDatastoreKeywords -join ', ') }
        [pscustomobject]@{ Environment = 'SIT'; Letters = ($SitLetters -join ', '); DnsLabels = ($SitDnsLabels -join ', '); DatastoreKeywords = ($SitDatastoreKeywords -join ', ') }
        [pscustomobject]@{ Environment = 'DEV'; Letters = ($DevLetters -join ', '); DnsLabels = ($DevDnsLabels -join ', '); DatastoreKeywords = ($DevDatastoreKeywords -join ', ') }
    )

    # Validated before anything else, so a bad -DevLetters fails before a sign-in prompt.
    $ruleSet = ConvertTo-PlacementRuleSet -Definition $ruleDefinition -HostnamePattern $HostnamePattern

    if ($NoGui) {
        if ([string]::IsNullOrWhiteSpace($Server)) { throw '-Server is required with -NoGui.' }
        Assert-PowerCliAvailable
        Write-PlacementLog "VM datastore placement $ScriptVersion - read-only, nothing in vCenter is changed." -Level INFO

        if ($null -eq $Credential) {
            $Credential = Get-Credential -Message "Domain account for vCenter $Server (DOMAIN\user)"
        }
        $connection = Connect-PlacementVCenter -Server $Server -Credential $Credential
        try {
            $clusterViews = @(Get-PlacementClusterList -Server $connection)
            if ($Cluster) {
                $wanted = $Cluster
                $clusterViews = @($clusterViews | Where-Object { $name = [string]$_.Name; @($wanted | Where-Object { $name -like $_ }).Count -gt 0 })
                if ($clusterViews.Count -eq 0) {
                    $known = @(Get-PlacementClusterList -Server $connection | ForEach-Object { $_.Name }) -join ', '
                    throw "No cluster matches '$($Cluster -join "', '")'. Clusters in $($connection.Name): $known"
                }
            }

            $inventory = New-Object System.Collections.Generic.List[object]
            foreach ($clusterView in $clusterViews) {
                $inventory.Add((Get-ClusterPlacementInventory -Server $connection -ClusterView $clusterView))
            }

            $result = Invoke-PlacementEvaluation -Inventory $inventory.ToArray() -RuleSet $ruleSet -NfsOnly:$NfsOnly -FlagUnclassifiedDatastores:$FlagUnclassifiedDatastores -HideUndetermined:$HideUndetermined -ScriptVersion $ScriptVersion
            Write-PlacementLog (Format-PlacementSummary -Summary $result.Summary) -Level INFO

            if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                $folder = [Environment]::GetFolderPath('MyDocuments')
                if (-not $folder) { $folder = (Get-Location).Path }
                $vcName = ([string]$connection.Name) -replace '[^A-Za-z0-9._-]', '_'
                $OutputPath = Join-Path $folder ('VMDatastorePlacement_{0}_{1}.csv' -f $vcName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            }
            Export-PlacementReport -Finding $result.Findings -Path $OutputPath
            $result.Findings
        }
        finally {
            Disconnect-PlacementVCenter -Connection $connection
        }
    }
    else {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            throw 'The GUI needs Windows. Use -NoGui on this platform.'
        }
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
            throw 'The GUI needs an STA thread and this console is MTA - VS Code''s integrated console can be. Run the script from a normal powershell.exe or pwsh window, or use -NoGui.'
        }
        Assert-PowerCliAvailable
        Show-PlacementGui -InitialServer $Server -Credential $Credential -RuleDefinition $ruleDefinition -HostnamePattern $HostnamePattern `
            -NfsOnly:$NfsOnly -FlagUnclassifiedDatastores:$FlagUnclassifiedDatastores -HideUndetermined:$HideUndetermined -ScriptVersion $ScriptVersion
    }
}
catch {
    Write-PlacementLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
