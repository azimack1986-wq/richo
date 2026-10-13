<#
.SYNOPSIS
    Finds VMs on the wrong PROD, SIT or DEV datastore, per vSphere cluster, and can Storage vMotion
    them to the right datastore cluster or NFS datastore. GUI or headless, with CSV export.

.DESCRIPTION
    Signs in to vCenter with a domain account, discovers one cluster (or all of them) and works out,
    for every VM, which environment it belongs to and which environment its datastores belong to.
    A VM in the right place is not shown.

    WHAT IT CHANGES. Discovery and reporting are read-only. Migration is the only thing that changes
    vCenter: it Storage vMotions the VMs you pick - home folder and every disk - to the target you
    pick, and only after a Yes to a final confirmation (GUI) or to ShouldProcess (headless). -WhatIf
    makes every migration a preview and changes nothing in vCenter. The CSVs you export are the only
    files written.

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

    Which environment a datastore belongs to: a keyword in its name, as a word of its own -
    delimited by anything that is not a letter:
           SHARED -> PROD,  SIT -> SIT,  DEV -> DEV
    so NFS_SHARED_01 and SIEPD85SHARED01 are PROD, but SITE2_DS is not SIT. The Datastores tab shows
    how every datastore was classified.

    VMFS DATASTORES ARE NOT DISCOVERED (-ExcludeDatastoreType, default VMFS). They are not
    classified, not listed and not counted for any VM, and are never offered as a migration target.
    A VM that lives only on excluded datastores is skipped and counted in the summary.

    What 'lives on' means: the VM's home folder (.vmx) and every virtual disk. A mounted ISO and
    the swap file do not count.

    Misplaced VMs tab:
      Wrong datastore            The VM uses a PROD/SIT/DEV datastore that is not its own.
      Unmapped hostname letter   The name matches the standard but its letter is not mapped -
                                 e.g. 'b'. Add the letter to the right environment in the rules
                                 grid and click Re-apply rules (or Discover).
      Environment undetermined   No usable DNS name and the name does not match the standard.
                                 Hidden with -HideUndetermined or the matching GUI checkbox.
      Ambiguous datastore name   A datastore name matches more than one environment.
      Partly outside PROD/SIT/DEV  Only with -FlagUnclassifiedDatastores: the VM also uses a
                                 datastore with no keyword.

    Not on PROD/SIT/DEV tab: VMs none of whose (non-excluded) datastores carries a keyword.

    Templates, vCLS/agent VMs (managed by ESX Agent Manager) and SRM placeholder VMs are skipped and
    counted in the summary.

    MIGRATION. From either VM tab, Migrate selected or Migrate all in tab. For each environment among
    the chosen VMs you pick one target:
      - a datastore cluster, when every datastore in it is that environment (Storage DRS then picks
        the member), or
      - a single NFS datastore named for that environment, not part of a datastore cluster.
    Only targets mounted on the host the VM runs on are offered or used. A VM is skipped - with the
    reason on the Migrations tab - when its environment is unknown, no target was picked for it, the
    target is not mounted on its host, it is already there, or the move would leave the target with
    less than -MinFreeSpacePercent free. Up to -MaxConcurrentMigrations run at once (default 2, at
    most 4). Stop finishes the running ones and starts nothing new. Moved clusters are re-discovered.

    A VM protected by SRM with array-based replication leaves its replicated datastore when it is
    moved. Check its protection group afterwards.

    Requirements: VMware PowerCLI (VMware.VimAutomation.Core). Migration needs the vCenter privileges
    to relocate VMs. The GUI needs Windows and an STA console - powershell.exe or pwsh launched
    normally. VS Code's integrated console can run MTA; use -NoGui there, or a normal console window.

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
    Run headless: discover, write the CSVs, and output the misplaced rows (or, with -MigrateTo, the
    migration results) to the pipeline.

.PARAMETER OutputPath
    -NoGui only. CSV path for the misplaced VMs. The Not on PROD/SIT/DEV list and any migration
    results are written beside it with _NotOnProdSitDev and _Migration added to the name. Defaults
    to VMDatastorePlacement_<vCenter>_<timestamp>.csv in your Documents folder.

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
    Words in a datastore name that mean PROD. Default SHARED.

.PARAMETER SitDatastoreKeywords
    Words in a datastore name that mean SIT. Default SIT.

.PARAMETER DevDatastoreKeywords
    Words in a datastore name that mean DEV. Default DEV.

.PARAMETER HostnamePattern
    Regular expression for the naming standard, matched case-insensitively against the VM name. It
    must capture the environment letter in a group named 'env'. Default:
    ^siepd(?<site>\d{2})(?<role>[a-z]{2})(?<env>[a-z])

.PARAMETER ExcludeDatastoreType
    Datastore types that are not discovered at all. Default VMFS.

.PARAMETER FlagUnclassifiedDatastores
    Also report, on the Misplaced tab, a VM that uses a PROD/SIT/DEV datastore and also a datastore
    with no keyword.

.PARAMETER HideUndetermined
    Do not report VMs whose environment cannot be worked out from DNS name or hostname.

.PARAMETER MigrateTo
    -NoGui only. Environment -> target name, e.g. @{ PROD = 'DSC_SHARED_01'; DEV = 'NFS_DEV_02' }.
    Each name must be an eligible datastore cluster or NFS datastore for that environment; the error
    lists the eligible ones when it is not. VMs from both VM lists whose environment has a target are
    migrated. Prompts per VM unless -Confirm:$false; -WhatIf previews.

.PARAMETER MigrateVM
    -NoGui only, with -MigrateTo. VM names to migrate; wildcards allowed. Default all.

.PARAMETER MaxConcurrentMigrations
    Storage vMotions running at once, 1 to 4. Default 2.

.PARAMETER MinFreeSpacePercent
    Free space, as a percentage of the target's capacity, that a migration must leave. Default 10.

.EXAMPLE
    .\Test-VMDatastorePlacement.ps1 -Server vcenter01.dpe.protected.mil.au

    Opens the GUI. Sign in with your domain account, pick a cluster, Discover, Export CSV, Migrate.

.EXAMPLE
    .\Test-VMDatastorePlacement.ps1 -Server vcenter01.dpe.protected.mil.au -WhatIf

    GUI in which every migration is a preview. Nothing in vCenter can be changed.

.EXAMPLE
    .\Test-VMDatastorePlacement.ps1 -NoGui -Server vcenter01.dpe.protected.mil.au -Cluster 'CL-PROD-*' -OutputPath C:\Temp\placement.csv

    Headless report. Prompts for the domain account, writes the CSVs, outputs the misplaced rows.

.EXAMPLE
    .\Test-VMDatastorePlacement.ps1 -NoGui -Server vcenter01.dpe.protected.mil.au -Cluster CL-PROD-01 -MigrateTo @{ PROD = 'DSC_SHARED_01' } -WhatIf

    Headless migration preview: what would move where, and what would be skipped and why. Run again
    without -WhatIf to migrate, confirming each VM (or -Confirm:$false for none).

.NOTES
    Version is in $ScriptVersion below and is stamped onto every CSV row.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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

    [string[]]$ProdDatastoreKeywords = @('SHARED'),
    [string[]]$SitDatastoreKeywords = @('SIT'),
    [string[]]$DevDatastoreKeywords = @('DEV'),

    [string]$HostnamePattern = '^siepd(?<site>\d{2})(?<role>[a-z]{2})(?<env>[a-z])',

    [string[]]$ExcludeDatastoreType = @('VMFS'),

    [switch]$FlagUnclassifiedDatastores,

    [switch]$HideUndetermined,

    [hashtable]$MigrateTo,

    [string[]]$MigrateVM = @('*'),

    [ValidateRange(1, 4)]
    [int]$MaxConcurrentMigrations = 2,

    [ValidateRange(0, 50)]
    [int]$MinFreeSpacePercent = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.2.0'

$script:GuiLogSink = $null
$script:Gui = $null
$script:GuiState = $null
# Captured once: a run started with -WhatIf can only ever preview, including from the GUI.
$script:WhatIfRun = [bool]$WhatIfPreference

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
        Environment is '' when the name carries no keyword. Label is the human-readable reason, used
        in the report and the Datastores tab. Datastore types excluded from discovery never get
        this far.

    .PARAMETER Name
        Datastore or datastore cluster name.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .EXAMPLE
        Get-DatastoreEnvironment -Name 'NFS_SHARED_01' -RuleSet $ruleSet
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory)]
        [object]$RuleSet
    )

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
        The VM report columns, in order - shared by both VM tabs and their CSVs so they cannot drift.

    .EXAMPLE
        Get-PlacementReportColumn
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    'Status', 'Cluster', 'VMName', 'DnsName', 'ExpectedEnvironment', 'DeterminedBy', 'HostnameLetter',
    'DatastoreEnvironment', 'WrongDatastores', 'AllDatastores', 'SizeGB', 'Reason', 'PowerState',
    'ToolsStatus', 'EsxiHost', 'vCenter', 'DiscoveredAt', 'ScriptVersion'
}

function Get-PlacementMigrationColumn {
    <#
    .SYNOPSIS
        The migration result columns, in order - shared by the Migrations tab and its CSV.

    .EXAMPLE
        Get-PlacementMigrationColumn
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    'Result', 'VMName', 'Cluster', 'ExpectedEnvironment', 'From', 'To', 'SizeGB', 'Progress', 'Started',
    'Finished', 'Detail', 'vCenter', 'ScriptVersion'
}

function Format-PlacementSize {
    <#
    .SYNOPSIS
        Bytes as "512.0 GB" or "12.3 TB".

    .PARAMETER Bytes
        Size in bytes.

    .EXAMPLE
        Format-PlacementSize -Bytes 13194139533312
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [double]$Bytes
    )

    if ([Math]::Abs($Bytes) -ge 1TB) { return '{0:N1} TB' -f ($Bytes / 1TB) }
    '{0:N1} GB' -f ($Bytes / 1GB)
}

function Test-VMPlacement {
    <#
    .SYNOPSIS
        Evaluates one VM and returns its outcome, with a report row when it is to be listed.

    .DESCRIPTION
        Outcome is one of:
          Correct    every PROD/SIT/DEV datastore the VM uses is its own environment
          Reported   Finding is a row for the Misplaced VMs tab
          Unscoped   Finding is a row for the Not on PROD/SIT/DEV tab: none of the VM's datastores
                     carries a keyword
          Hidden     environment undetermined and -HideUndetermined is set

        An unmapped hostname letter is always reported - it is the signal to add the letter.

        The row also carries, for migration and not for the CSV: VMId, VMRef, CommittedBytes and
        DatastoreNames.

    .PARAMETER Record
        One VM from Get-ClusterPlacementInventory.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .PARAMETER FlagUnclassifiedDatastores
        A datastore with no keyword, used alongside a PROD/SIT/DEV one, counts as wrong.

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

        [switch]$FlagUnclassifiedDatastores,

        [switch]$HideUndetermined,

        [string]$ScriptVersion = ''
    )

    $environments = $RuleSet.EnvironmentNames -join '/'
    $classified = @(foreach ($datastore in @($Record.Datastores)) {
            if ($null -eq $datastore) { continue }
            $class = Get-DatastoreEnvironment -Name ([string]$datastore.Name) -RuleSet $RuleSet
            [pscustomobject]@{ Name = [string]$datastore.Name; Environment = $class.Environment; Label = $class.Label }
        })
    $scoped = @($classified | Where-Object { $_.Environment -ne '' })

    $expected = Resolve-VMExpectedEnvironment -VmName ([string]$Record.VMName) -DnsName ([string]$Record.DnsName) -RuleSet $RuleSet
    $nameLetter = (Get-HostnameEnvironment -Name ([string]$Record.VMName) -RuleSet $RuleSet).Letter
    $wrong = @()

    if ($scoped.Count -eq 0) {
        $outcome = 'Unscoped'
        $status = "Not on a $environments datastore"
        $wrong = $classified
        $usesText = @($classified | ForEach-Object { "$($_.Name) ($($_.Label))" }) -join ', '
        if ($classified.Count -eq 0) { $reason = 'No datastore could be read for this VM.' }
        elseif ($expected.Environment -ne '') { $reason = "$($expected.Detail), but the VM uses only $usesText." }
        else { $reason = "$($expected.Detail) The VM uses only $usesText." }
    }
    elseif ($expected.Environment -eq '') {
        if ($expected.Status -ne 'Unmapped hostname letter' -and $HideUndetermined) {
            return [pscustomobject]@{ Outcome = 'Hidden'; Finding = $null }
        }
        $outcome = 'Reported'
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

        $outcome = 'Reported'
        $mismatched = @($wrong | Where-Object { $_.Environment -ne '' -and $_.Environment -ne 'AMBIGUOUS' })
        $ambiguous = @($wrong | Where-Object { $_.Environment -eq 'AMBIGUOUS' })
        if ($mismatched.Count -gt 0) { $status = 'Wrong datastore' }
        elseif ($ambiguous.Count -gt 0) { $status = 'Ambiguous datastore name' }
        else { $status = "Partly outside $environments" }

        $wrongText = @($wrong | ForEach-Object { "$($_.Name) ($($_.Label))" }) -join ', '
        $reason = "$($expected.Detail), but the VM uses $wrongText."
    }

    $committed = [long]$Record.CommittedBytes
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
        SizeGB = [Math]::Round($committed / 1GB, 1)
        Reason = $reason
        PowerState = [string]$Record.PowerState
        ToolsStatus = [string]$Record.ToolsStatus
        EsxiHost = [string]$Record.EsxiHost
        vCenter = [string]$Record.vCenter
        DiscoveredAt = ([datetime]$Record.DiscoveredAt).ToString('yyyy-MM-dd HH:mm:ss')
        ScriptVersion = $ScriptVersion
        VMId = [string]$Record.VMId
        VMRef = $Record.VMRef
        CommittedBytes = $committed
        DatastoreNames = @($classified | ForEach-Object { $_.Name })
    }
    [pscustomobject]@{ Outcome = $outcome; Finding = $finding }
}

function Invoke-PlacementEvaluation {
    <#
    .SYNOPSIS
        Applies the rules to discovered clusters: both VM lists, datastore classification, summary.

    .DESCRIPTION
        Works on inventory already read from vCenter, so changing a rule and re-applying is
        instant - vCenter is only read again by Discover.

    .PARAMETER Inventory
        One object per cluster from Get-ClusterPlacementInventory.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .PARAMETER FlagUnclassifiedDatastores
        A datastore with no keyword, used alongside a PROD/SIT/DEV one, counts as wrong.

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

        [switch]$FlagUnclassifiedDatastores,

        [switch]$HideUndetermined,

        [string]$ScriptVersion = ''
    )

    $findings = New-Object System.Collections.Generic.List[object]
    $unscoped = New-Object System.Collections.Generic.List[object]
    $datastoreRows = New-Object System.Collections.Generic.List[object]
    $excludedTypes = New-Object System.Collections.Generic.List[string]
    $clusters = 0; $vmCount = 0; $correct = 0; $hidden = 0
    $skippedTemplates = 0; $skippedAgents = 0; $skippedPlaceholders = 0; $skippedExcluded = 0

    foreach ($cluster in $Inventory) {
        $clusters++
        $skippedTemplates += [int]$cluster.SkippedTemplates
        $skippedAgents += [int]$cluster.SkippedAgents
        $skippedPlaceholders += [int]$cluster.SkippedPlaceholders
        $skippedExcluded += [int]$cluster.SkippedExcluded
        foreach ($type in @($cluster.ExcludedTypes)) {
            if ($type -and -not $excludedTypes.Contains([string]$type)) { $excludedTypes.Add([string]$type) }
        }
        $vmsPerDatastore = @{}

        foreach ($vm in @($cluster.VMs)) {
            if ($null -eq $vm) { continue }
            $vmCount++
            foreach ($datastore in @($vm.Datastores)) {
                if ($null -eq $datastore) { continue }
                $vmsPerDatastore[[string]$datastore.Name] = 1 + [int]$vmsPerDatastore[[string]$datastore.Name]
            }

            $outcome = Test-VMPlacement -Record $vm -RuleSet $RuleSet -FlagUnclassifiedDatastores:$FlagUnclassifiedDatastores -HideUndetermined:$HideUndetermined -ScriptVersion $ScriptVersion
            switch ($outcome.Outcome) {
                'Correct' { $correct++ }
                'Hidden' { $hidden++ }
                'Unscoped' { $unscoped.Add($outcome.Finding) }
                'Reported' { $findings.Add($outcome.Finding) }
            }
        }

        foreach ($datastore in @($cluster.Datastores)) {
            if ($null -eq $datastore) { continue }
            $class = Get-DatastoreEnvironment -Name ([string]$datastore.Name) -RuleSet $RuleSet
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
        Unscoped = $unscoped.ToArray()
        Datastores = $datastoreRows.ToArray()
        Summary = [pscustomobject]@{
            Clusters = $clusters
            VMs = $vmCount
            Correct = $correct
            Reported = $findings.Count
            ReportedByStatus = $byStatus
            NotOnScoped = $unscoped.Count
            HiddenUndetermined = $hidden
            SkippedTemplates = $skippedTemplates
            SkippedAgents = $skippedAgents
            SkippedPlaceholders = $skippedPlaceholders
            SkippedExcluded = $skippedExcluded
            ExcludedTypes = $excludedTypes.ToArray()
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
    $reported = "$($Summary.Reported) misplaced"
    if ($statusParts.Count -gt 0) { $reported += " ($($statusParts -join ', '))" }

    $text = "$($Summary.Clusters) cluster(s), $($Summary.VMs) VMs: $($Summary.Correct) correct, $reported, $($Summary.NotOnScoped) not on a PROD/SIT/DEV datastore"
    if ($Summary.HiddenUndetermined -gt 0) { $text += ", $($Summary.HiddenUndetermined) undetermined hidden" }
    $excluded = @($Summary.ExcludedTypes) -join '/'
    if (-not $excluded) { $excluded = 'excluded' }
    $text + ". Skipped $($Summary.SkippedTemplates) template(s), $($Summary.SkippedAgents) vCLS/agent VM(s), $($Summary.SkippedPlaceholders) SRM placeholder(s), $($Summary.SkippedExcluded) only on $excluded datastores."
}

function Get-PlacementSiblingPath {
    <#
    .SYNOPSIS
        "C:\x\report.csv" + "Migration" -> "C:\x\report_Migration.csv".

    .PARAMETER Path
        The main CSV path.

    .PARAMETER Suffix
        Added to the file name before the extension.

    .EXAMPLE
        Get-PlacementSiblingPath -Path C:\Temp\placement.csv -Suffix NotOnProdSitDev
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Suffix
    )

    $extension = [IO.Path]::GetExtension($Path)
    if (-not $extension) { $extension = '.csv' }
    $stem = $Path.Substring(0, $Path.Length - [IO.Path]::GetExtension($Path).Length)
    "${stem}_$Suffix$extension"
}

function Export-PlacementReport {
    <#
    .SYNOPSIS
        Writes rows to CSV in a fixed column order.

    .DESCRIPTION
        With nothing to write the file still gets its header row, so an empty result is a deliberate
        "nothing found" rather than a missing file.

        The report is the output of a run, -WhatIf included, so it is written even under -WhatIf -
        that covers only changes to vCenter.

    .PARAMETER Finding
        Rows to write.

    .PARAMETER Path
        CSV path. The folder is created when it does not exist.

    .PARAMETER Column
        Columns, in order. Defaults to the VM report columns.

    .EXAMPLE
        Export-PlacementReport -Finding $result.Findings -Path C:\Temp\placement.csv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Finding,

        [Parameter(Mandatory)]
        [string]$Path,

        [string[]]$Column
    )

    if ($null -eq $Column -or $Column.Count -eq 0) {
        $columns = @(Get-PlacementReportColumn)
    }
    else {
        $columns = @($Column)
    }
    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -Path $folder)) {
        New-Item -Path $folder -ItemType Directory -Force -WhatIf:$false -Confirm:$false | Out-Null
    }

    if ($Finding.Count -eq 0) {
        $header = @($columns | ForEach-Object { '"' + $_ + '"' }) -join ','
        Set-Content -Path $Path -Value $header -Encoding UTF8 -WhatIf:$false -Confirm:$false
    }
    else {
        $Finding | Select-Object -Property $columns | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false
    }
    Write-PlacementLog "Written: $Path ($($Finding.Count) row(s))." -Level INFO
}

# =============================================================================================
# Migration planning - pure functions, no vCenter
# =============================================================================================

function Get-PlacementHostSeeing {
    <#
    .SYNOPSIS
        The hosts that have every one of the given datastores mounted.

    .PARAMETER HostDatastores
        Host name -> datastore MoRef values mounted on it.

    .PARAMETER RefValue
        Datastore MoRef values that must all be mounted.

    .EXAMPLE
        Get-PlacementHostSeeing -HostDatastores $info.HostDatastores -RefValue 'datastore-12'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [hashtable]$HostDatastores = @{},

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$RefValue
    )

    foreach ($hostName in @($HostDatastores.Keys | Sort-Object)) {
        $mounted = @($HostDatastores[$hostName])
        if (@($RefValue | Where-Object { $mounted -notcontains $_ }).Count -eq 0) { $hostName }
    }
}

function Format-PlacementTarget {
    <#
    .SYNOPSIS
        One line describing a migration target, for the dialog's drop-down and the log.

    .PARAMETER Target
        A target from Get-PlacementTargetChoice.

    .EXAMPLE
        Format-PlacementTarget -Target $target
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Target
    )

    '{0}  {1}  -  {2} free of {3}  -  {4}' -f $Target.Kind, $Target.Name, (Format-PlacementSize $Target.FreeBytes), (Format-PlacementSize $Target.CapacityBytes), (@($Target.Clusters) -join ', ')
}

function Get-PlacementTargetChoice {
    <#
    .SYNOPSIS
        The datastore clusters and NFS datastores a VM of one environment may be moved to.

    .DESCRIPTION
        Offered, per environment:
          Datastore cluster   every member datastore is that environment and is mounted on at least
                              one of the cluster's hosts, at least one member is accessible and not
                              in maintenance mode. Storage DRS picks the member.
          Datastore           NFS, named for that environment, not a member of a datastore cluster,
                              accessible and not in maintenance mode.

        Excluded datastore types never reach here, so a datastore cluster with a VMFS member is
        not offered. Each target lists the clusters and hosts it is usable from, which the plan
        checks per VM.

    .PARAMETER StorageInfo
        Output of Get-PlacementStorageInfo, one object per cluster.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .PARAMETER Environment
        PROD, SIT or DEV.

    .EXAMPLE
        Get-PlacementTargetChoice -StorageInfo $storage -RuleSet $ruleSet -Environment PROD
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$StorageInfo,

        [Parameter(Mandatory)]
        [object]$RuleSet,

        [Parameter(Mandatory)]
        [string]$Environment
    )

    $targets = New-Object System.Collections.Specialized.OrderedDictionary

    foreach ($info in $StorageInfo) {
        $byRef = @{}
        foreach ($datastore in @($info.Datastores)) { $byRef[[string]$datastore.RefValue] = $datastore }

        $candidates = New-Object System.Collections.Generic.List[object]
        foreach ($datastore in @($info.Datastores)) {
            if ($datastore.PodRefValue) { continue }
            if (@('NFS', 'NFS41') -notcontains ([string]$datastore.Type).ToUpperInvariant()) { continue }
            if (-not $datastore.Accessible -or @('', 'normal') -notcontains [string]$datastore.MaintenanceMode) { continue }
            if ((Get-DatastoreEnvironment -Name $datastore.Name -RuleSet $RuleSet).Environment -ne $Environment) { continue }
            $candidates.Add([pscustomobject]@{
                    Kind = 'Datastore'; Name = $datastore.Name; Ref = $datastore.Ref; RefValue = [string]$datastore.RefValue
                    FreeBytes = [double]$datastore.FreeBytes; CapacityBytes = [double]$datastore.CapacityBytes
                    Members = @($datastore.Name); MemberRefValues = @([string]$datastore.RefValue)
                })
        }

        foreach ($pod in @($info.Pods)) {
            $members = @($pod.MemberRefValues)
            if ($members.Count -eq 0) { continue }
            $eligible = $true
            $usable = 0
            $names = New-Object System.Collections.Generic.List[string]
            foreach ($member in $members) {
                if (-not $byRef.ContainsKey([string]$member)) { $eligible = $false; break }
                $datastore = $byRef[[string]$member]
                if ((Get-DatastoreEnvironment -Name $datastore.Name -RuleSet $RuleSet).Environment -ne $Environment) { $eligible = $false; break }
                if ($datastore.Accessible -and @('', 'normal') -contains [string]$datastore.MaintenanceMode) { $usable++ }
                $names.Add([string]$datastore.Name)
            }
            if (-not $eligible -or $usable -eq 0) { continue }
            $candidates.Add([pscustomobject]@{
                    Kind = 'Datastore cluster'; Name = $pod.Name; Ref = $pod.Ref; RefValue = [string]$pod.RefValue
                    FreeBytes = [double]$pod.FreeBytes; CapacityBytes = [double]$pod.CapacityBytes
                    Members = $names.ToArray(); MemberRefValues = $members
                })
        }

        foreach ($candidate in $candidates) {
            $hosts = @(Get-PlacementHostSeeing -HostDatastores $info.HostDatastores -RefValue $candidate.MemberRefValues)
            if ($hosts.Count -eq 0) { continue }
            $key = "$($candidate.Kind)|$($candidate.RefValue)"
            if ($targets.Contains($key)) {
                $existing = $targets[$key]
                $existing.Clusters = @($existing.Clusters) + [string]$info.Cluster
                $existing.Hosts = @($existing.Hosts) + $hosts
            }
            else {
                $targets[$key] = [pscustomobject]@{
                    Kind = $candidate.Kind
                    Name = [string]$candidate.Name
                    Ref = $candidate.Ref
                    RefValue = $candidate.RefValue
                    Environment = $Environment
                    FreeBytes = $candidate.FreeBytes
                    CapacityBytes = $candidate.CapacityBytes
                    Members = $candidate.Members
                    Clusters = @([string]$info.Cluster)
                    Hosts = $hosts
                }
            }
        }
    }

    @($targets.Values) | Sort-Object -Property @{ Expression = { if ($_.Kind -eq 'Datastore cluster') { 0 } else { 1 } } }, Name
}

function Get-PlacementMigrationPlan {
    <#
    .SYNOPSIS
        Decides, per VM, whether it will be moved and where - or why not.

    .DESCRIPTION
        Every VM given gets one row: Action 'Migrate' or 'Skip', with Reason in a sentence. Skipped:
          - environment not known (fix the rules first - there is nowhere correct to move it)
          - no target picked for its environment
          - target is a different environment (defence in depth - the dialog only offers matches)
          - target not mounted on the host the VM runs on
          - already wholly on the target datastore
          - the move would leave the target with less than MinFreeSpacePercent free, counting the
            moves planned before it to the same target
          - listed twice

        Pure: reads nothing from vCenter.

    .PARAMETER Finding
        Rows from either VM list.

    .PARAMETER TargetByEnvironment
        Environment -> target from Get-PlacementTargetChoice.

    .PARAMETER MinFreeSpacePercent
        Free space, as a percentage of capacity, each target must keep.

    .EXAMPLE
        Get-PlacementMigrationPlan -Finding $chosen -TargetByEnvironment @{ PROD = $target }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Finding,

        [hashtable]$TargetByEnvironment = @{},

        [ValidateRange(0, 50)]
        [int]$MinFreeSpacePercent = 10
    )

    $planned = @{}
    $seen = @{}
    foreach ($item in $Finding) {
        $environment = [string]$item.ExpectedEnvironment
        $target = $null
        if ($environment -and $TargetByEnvironment.ContainsKey($environment)) { $target = $TargetByEnvironment[$environment] }

        $row = [pscustomobject]@{
            Action = 'Skip'
            Reason = ''
            VMName = [string]$item.VMName
            VMId = [string]$item.VMId
            VMRef = $item.VMRef
            Cluster = [string]$item.Cluster
            EsxiHost = [string]$item.EsxiHost
            ExpectedEnvironment = $environment
            From = (@($item.DatastoreNames) -join '; ')
            SizeGB = $item.SizeGB
            SizeBytes = [double]$item.CommittedBytes
            Target = ''
            TargetKind = ''
            TargetRef = $null
        }
        if ($null -ne $target) {
            $row.Target = [string]$target.Name
            $row.TargetKind = [string]$target.Kind
            $row.TargetRef = $target.Ref
        }

        if ($row.VMId -and $seen.ContainsKey($row.VMId)) {
            $row.Reason = 'Listed twice - planned once.'
            $row
            continue
        }
        if ($row.VMId) { $seen[$row.VMId] = $true }

        $currentNames = @($item.DatastoreNames)
        if ($environment -eq '') {
            $row.Reason = "Environment not known ($($item.Status)) - there is nowhere correct to move it. Fix the rules, re-apply, then migrate."
        }
        elseif ($null -eq $target) {
            $row.Reason = "No $environment target was picked."
        }
        elseif ($target.Environment -ne $environment) {
            $row.Reason = "Target $($target.Name) is $($target.Environment); the VM belongs on $environment."
        }
        elseif ($row.EsxiHost -and @($target.Hosts) -notcontains $row.EsxiHost) {
            $row.Reason = "$($target.Name) is not mounted on $($row.EsxiHost), where the VM runs."
        }
        elseif (-not $row.EsxiHost -and @($target.Clusters) -notcontains $row.Cluster) {
            $row.Reason = "$($target.Name) is not usable from cluster $($row.Cluster)."
        }
        elseif ($target.Kind -eq 'Datastore' -and $currentNames.Count -gt 0 -and @($currentNames | Where-Object { $_ -ne $target.Name }).Count -eq 0) {
            $row.Reason = "Already on $($target.Name)."
        }
        else {
            $key = "$($target.Kind)|$($target.RefValue)"
            $freeBefore = [double]$target.FreeBytes - [double]$planned[$key]
            $floor = [double]$target.CapacityBytes * $MinFreeSpacePercent / 100
            if ($freeBefore - $row.SizeBytes -lt $floor) {
                $row.Reason = "Not enough space on $($target.Name): the VM needs $(Format-PlacementSize $row.SizeBytes), $(Format-PlacementSize $freeBefore) is free after the moves planned before it, and $MinFreeSpacePercent% ($(Format-PlacementSize $floor)) is kept free."
            }
            else {
                $planned[$key] = [double]$planned[$key] + $row.SizeBytes
                $row.Action = 'Migrate'
                $row.Reason = "Move $(Format-PlacementSize $row.SizeBytes) to $($target.Kind.ToLowerInvariant()) $($target.Name)."
            }
        }
        $row
    }
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
          Excluded     every datastore the VM uses is an excluded type (VMFS by default)

        Datastores are the home (.vmx) datastore and each virtual disk's datastore, home first,
        without duplicates, leaving out excluded types. CD-ROM ISOs and swap are deliberately not
        counted. When neither can be read - an inaccessible VM - the VM's own datastore list is used.

    .PARAMETER View
        VirtualMachine view from Get-View.

    .PARAMETER DatastoreByRef
        MoRef value -> @{ Name; Type } for the cluster's discovered datastores.

    .PARAMETER DatastoreByName
        Datastore name -> @{ Name; Type }.

    .PARAMETER ExcludedByRef
        MoRef value -> name, for datastores of excluded types.

    .PARAMETER ExcludedByName
        Name -> type, for datastores of excluded types.

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

        [hashtable]$ExcludedByRef = @{},

        [hashtable]$ExcludedByName = @{},

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
    $excludedHits = 0
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
        elseif ($path.Ref -and $ExcludedByRef.ContainsKey($path.Ref)) {
            $excludedHits++
        }
        else {
            $datastoreName = Get-DatastoreNameFromPath $path.FileName
            if ($datastoreName -and $ExcludedByName.ContainsKey($datastoreName)) {
                $excludedHits++
            }
            elseif ($datastoreName) {
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
            if ($DatastoreByRef.ContainsKey($key)) {
                if (-not $datastores.Contains($DatastoreByRef[$key].Name)) { $datastores[$DatastoreByRef[$key].Name] = $DatastoreByRef[$key] }
            }
            elseif ($ExcludedByRef.ContainsKey($key)) {
                $excludedHits++
            }
        }
    }

    if ($datastores.Count -eq 0 -and $excludedHits -gt 0) {
        return [pscustomobject]@{ Skip = 'Excluded'; Record = $null }
    }

    $hostRef = [string](Get-ViewProperty $View 'Runtime.Host.Value')
    $esxiHost = ''
    if ($hostRef -and $HostByRef.ContainsKey($hostRef)) { $esxiHost = [string]$HostByRef[$hostRef] }

    $record = [pscustomobject]@{
        Cluster = $Cluster
        VMName = $name
        VMId = [string](Get-ViewProperty $View 'MoRef.Value')
        VMRef = Get-ViewProperty $View 'MoRef'
        DnsName = [string](Get-ViewProperty $View 'Guest.HostName')
        PowerState = [string](Get-ViewProperty $View 'Runtime.PowerState')
        ToolsStatus = [string](Get-ViewProperty $View 'Guest.ToolsRunningStatus')
        EsxiHost = $esxiHost
        vCenter = $VCenter
        DiscoveredAt = $DiscoveredAt
        CommittedBytes = [long](Get-ViewProperty $View 'Summary.Storage.Committed')
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

    .DESCRIPTION
        Runs even under -WhatIf: closing our own session is not a change to vCenter.

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
        Disconnect-VIServer -Server $Connection -Confirm:$false -WhatIf:$false -ErrorAction Stop
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

        Datastores of an excluded type (VMFS by default) are dropped here: not listed, not counted
        for any VM.

    .PARAMETER Server
        Connection from Connect-PlacementVCenter.

    .PARAMETER ClusterView
        ClusterComputeResource view from Get-PlacementClusterList.

    .PARAMETER ExcludeDatastoreType
        Datastore types not to discover. Default VMFS.

    .EXAMPLE
        Get-ClusterPlacementInventory -Server $vc -ClusterView $clusterView
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter(Mandatory)]
        [object]$ClusterView,

        [string[]]$ExcludeDatastoreType = @('VMFS')
    )

    $discoveredAt = Get-Date
    $excludedTypes = @($ExcludeDatastoreType | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
    $clusterInfo = Get-View -Server $Server -Id $ClusterView.MoRef -Property 'Name', 'Datastore', 'Host'
    Write-PlacementLog "Reading cluster $($clusterInfo.Name)..." -Level INFO

    $datastoreByRef = @{}
    $datastoreByName = @{}
    $excludedByRef = @{}
    $excludedByName = @{}
    $datastoreRefs = @($clusterInfo.Datastore | Where-Object { $null -ne $_ })
    if ($datastoreRefs.Count -gt 0) {
        foreach ($view in @(Get-View -Server $Server -Id $datastoreRefs -Property 'Name', 'Summary.Type')) {
            $info = [pscustomobject]@{ Name = [string]$view.Name; Type = [string](Get-ViewProperty $view 'Summary.Type') }
            if ($excludedTypes -contains $info.Type.ToUpperInvariant()) {
                $excludedByRef[[string]$view.MoRef.Value] = $info.Name
                $excludedByName[$info.Name] = $info.Type
                continue
            }
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
        'Guest.HostName', 'Guest.ToolsRunningStatus', 'Runtime.PowerState', 'Runtime.Host', 'Datastore',
        'Summary.Storage.Committed'
    )
    $vmViews = @(Get-View -Server $Server -ViewType VirtualMachine -SearchRoot $clusterInfo.MoRef -Property $vmProperties)

    $records = New-Object System.Collections.Generic.List[object]
    $skipped = @{ Template = 0; Agent = 0; Placeholder = 0; Excluded = 0 }
    $seen = @{}
    foreach ($view in $vmViews) {
        $id = [string]$view.MoRef.Value
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true

        $converted = ConvertTo-PlacementVMRecord -View $view -DatastoreByRef $datastoreByRef -DatastoreByName $datastoreByName -ExcludedByRef $excludedByRef -ExcludedByName $excludedByName -HostByRef $hostByRef -Cluster $clusterInfo.Name -VCenter ([string]$Server.Name) -DiscoveredAt $discoveredAt
        if ($converted.Skip) {
            $skipped[$converted.Skip] = $skipped[$converted.Skip] + 1
            continue
        }
        $records.Add($converted.Record)
    }

    Write-PlacementLog ("Cluster {0}: {1} VMs, {2} datastores ({3} {4} not discovered); skipped {5} template(s), {6} vCLS/agent VM(s), {7} SRM placeholder(s), {8} VM(s) only on {4}." -f $clusterInfo.Name, $records.Count, $datastoreByName.Count, $excludedByName.Count, ($excludedTypes -join '/'), $skipped.Template, $skipped.Agent, $skipped.Placeholder, $skipped.Excluded) -Level INFO

    [pscustomobject]@{
        Cluster = [string]$clusterInfo.Name
        vCenter = [string]$Server.Name
        DiscoveredAt = $discoveredAt
        Datastores = @($datastoreByName.Values | Sort-Object -Property Name)
        VMs = $records.ToArray()
        ExcludedTypes = $excludedTypes
        SkippedTemplates = $skipped.Template
        SkippedAgents = $skipped.Agent
        SkippedPlaceholders = $skipped.Placeholder
        SkippedExcluded = $skipped.Excluded
    }
}

function Get-PlacementStorageInfo {
    <#
    .SYNOPSIS
        Reads what migration needs about each cluster's storage, fresh: free space, datastore
        clusters, and which host mounts which datastore. Read-only.

    .DESCRIPTION
        Read when the migration dialog opens, not at discovery, so the free space the plan checks
        is current. Excluded datastore types are dropped, which also makes any datastore cluster
        with such a member ineligible.

    .PARAMETER Server
        Connection from Connect-PlacementVCenter.

    .PARAMETER ClusterView
        ClusterComputeResource views of the clusters whose VMs may be moved.

    .PARAMETER ExcludeDatastoreType
        Datastore types not to consider. Default VMFS.

    .EXAMPLE
        Get-PlacementStorageInfo -Server $vc -ClusterView $clusterViews
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$ClusterView,

        [string[]]$ExcludeDatastoreType = @('VMFS')
    )

    $excludedTypes = @($ExcludeDatastoreType | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
    foreach ($view in $ClusterView) {
        if ($null -eq $view) { continue }
        $clusterInfo = Get-View -Server $Server -Id $view.MoRef -Property 'Name', 'Datastore', 'Host'

        $datastores = New-Object System.Collections.Generic.List[object]
        $podRefs = @{}
        $datastoreRefs = @($clusterInfo.Datastore | Where-Object { $null -ne $_ })
        if ($datastoreRefs.Count -gt 0) {
            foreach ($datastore in @(Get-View -Server $Server -Id $datastoreRefs -Property 'Name', 'Parent', 'Summary.Type', 'Summary.FreeSpace', 'Summary.Capacity', 'Summary.Accessible', 'Summary.MaintenanceMode')) {
                $type = [string](Get-ViewProperty $datastore 'Summary.Type')
                if ($excludedTypes -contains $type.ToUpperInvariant()) { continue }
                $podRef = ''
                if ([string](Get-ViewProperty $datastore 'Parent.Type') -eq 'StoragePod') {
                    $podRef = [string](Get-ViewProperty $datastore 'Parent.Value')
                    $podRefs[$podRef] = $datastore.Parent
                }
                $datastores.Add([pscustomobject]@{
                        Ref = $datastore.MoRef
                        RefValue = [string]$datastore.MoRef.Value
                        Name = [string]$datastore.Name
                        Type = $type
                        FreeBytes = [double](Get-ViewProperty $datastore 'Summary.FreeSpace')
                        CapacityBytes = [double](Get-ViewProperty $datastore 'Summary.Capacity')
                        Accessible = [bool](Get-ViewProperty $datastore 'Summary.Accessible')
                        MaintenanceMode = [string](Get-ViewProperty $datastore 'Summary.MaintenanceMode')
                        PodRefValue = $podRef
                    })
            }
        }

        $hostDatastores = @{}
        $hostRefs = @($clusterInfo.Host | Where-Object { $null -ne $_ })
        if ($hostRefs.Count -gt 0) {
            foreach ($hostView in @(Get-View -Server $Server -Id $hostRefs -Property 'Name', 'Datastore')) {
                $hostDatastores[[string]$hostView.Name] = @($hostView.Datastore | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Value })
            }
        }

        $pods = New-Object System.Collections.Generic.List[object]
        if ($podRefs.Count -gt 0) {
            foreach ($pod in @(Get-View -Server $Server -Id @($podRefs.Values) -Property 'Name', 'ChildEntity', 'Summary.FreeSpace', 'Summary.Capacity')) {
                $pods.Add([pscustomobject]@{
                        Ref = $pod.MoRef
                        RefValue = [string]$pod.MoRef.Value
                        Name = [string]$pod.Name
                        FreeBytes = [double](Get-ViewProperty $pod 'Summary.FreeSpace')
                        CapacityBytes = [double](Get-ViewProperty $pod 'Summary.Capacity')
                        MemberRefValues = @($pod.ChildEntity | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Value })
                    })
            }
        }

        [pscustomobject]@{
            Cluster = [string]$clusterInfo.Name
            Datastores = $datastores.ToArray()
            Pods = $pods.ToArray()
            HostDatastores = $hostDatastores
        }
    }
}

function Get-PlacementTaskState {
    <#
    .SYNOPSIS
        Reads one vCenter task: its state, progress and any error message.

    .PARAMETER Server
        Connection from Connect-PlacementVCenter.

    .PARAMETER TaskId
        The Id of the task Move-VM -RunAsync returned.

    .EXAMPLE
        Get-PlacementTaskState -Server $vc -TaskId $task.Id
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter(Mandatory)]
        [string]$TaskId
    )

    $task = Get-Task -Server $Server -Id $TaskId -ErrorAction Stop
    $message = [string](Get-ViewProperty $task 'ExtensionData.Info.Error.LocalizedMessage')
    if (-not $message) { $message = [string](Get-ViewProperty $task 'Description') }
    [pscustomobject]@{
        State = [string]$task.State
        Progress = [int](Get-ViewProperty $task 'PercentComplete')
        Error = $message
    }
}

function Invoke-PlacementMigration {
    <#
    .SYNOPSIS
        Storage vMotions the VMs a plan says to move, a few at a time, and reports each outcome.

    .DESCRIPTION
        THIS CHANGES vCENTER. Each move is Move-VM -Datastore <target> -RunAsync: the VM's home
        folder and every disk go to the target datastore, or to the member Storage DRS picks in a
        datastore cluster. Powered-on VMs stay running.

        Every move goes through ShouldProcess, so -WhatIf previews without calling Move-VM and
        -Confirm (or ConfirmImpact High) asks per VM. Up to MaxConcurrent run at once; when one
        finishes the next starts. ShouldStop is asked before each start - once it says stop,
        nothing new starts and the running moves are left to finish.

        Every plan row comes back as one result row: Migrated, Failed, WhatIf, Declined, Skipped,
        Not started, or Unknown (the task could no longer be read - check it in vCenter).

    .PARAMETER Server
        Connection from Connect-PlacementVCenter.

    .PARAMETER Plan
        Rows from Get-PlacementMigrationPlan.

    .PARAMETER MaxConcurrent
        Moves running at once, 1 to 4.

    .PARAMETER ScriptVersion
        Stamped onto every result row.

    .PARAMETER OnProgress
        Called with the result rows whenever they change.

    .PARAMETER ShouldStop
        Returns $true to stop starting new moves.

    .PARAMETER Wait
        Called between task polls. Defaults to five seconds' sleep.

    .EXAMPLE
        Invoke-PlacementMigration -Server $vc -Plan $plan -MaxConcurrent 2 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Plan,

        [ValidateRange(1, 4)]
        [int]$MaxConcurrent = 2,

        [string]$ScriptVersion = '',

        [scriptblock]$OnProgress,

        [scriptblock]$ShouldStop,

        [scriptblock]$Wait = { Start-Sleep -Seconds 5 }
    )

    $stamp = { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    $results = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($item in $Plan) {
        $to = ''
        if ($item.Target) { $to = "$($item.TargetKind) $($item.Target)" }
        $row = [pscustomobject]@{
            Result = 'Skipped'
            VMName = [string]$item.VMName
            Cluster = [string]$item.Cluster
            ExpectedEnvironment = [string]$item.ExpectedEnvironment
            From = [string]$item.From
            To = $to
            SizeGB = $item.SizeGB
            Progress = 0
            Started = ''
            Finished = ''
            Detail = [string]$item.Reason
            vCenter = [string]$Server.Name
            ScriptVersion = $ScriptVersion
        }
        $results.Add($row)
        if ($item.Action -eq 'Migrate') {
            $row.Result = 'Queued'
            $queue.Enqueue([pscustomobject]@{ Plan = $item; Row = $row })
        }
    }

    $running = @{}
    $stopped = $false
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $MaxConcurrent) {
            if ($null -ne $ShouldStop -and (& $ShouldStop)) {
                $stopped = $true
                break
            }
            $next = $queue.Dequeue()
            $item = $next.Plan
            $row = $next.Row
            $what = "VM '$($item.VMName)' in cluster '$($item.Cluster)'"
            $action = "Storage vMotion to $($item.TargetKind.ToLowerInvariant()) '$($item.Target)' (home folder and every disk)"
            if (-not $PSCmdlet.ShouldProcess($what, $action)) {
                if ($WhatIfPreference) {
                    $row.Result = 'WhatIf'
                    $row.Detail = "Would move $($item.VMName) to $($item.TargetKind.ToLowerInvariant()) $($item.Target)."
                }
                else {
                    $row.Result = 'Declined'
                    $row.Detail = 'Declined at the confirmation prompt.'
                }
                continue
            }

            try {
                $vm = Get-VIObjectByVIView -Server $Server -MORef $item.VMRef -ErrorAction Stop
                $target = Get-VIObjectByVIView -Server $Server -MORef $item.TargetRef -ErrorAction Stop
                $task = Move-VM -VM $vm -Datastore $target -RunAsync -Confirm:$false -ErrorAction Stop
                $row.Result = 'Running'
                $row.Started = & $stamp
                $row.Detail = ''
                $running[[string]$task.Id] = [pscustomobject]@{ Row = $row; Misses = 0 }
                Write-PlacementLog "Storage vMotion started: $($item.VMName) -> $($item.TargetKind.ToLowerInvariant()) $($item.Target) (task $($task.Id))." -Level INFO
            }
            catch {
                $row.Result = 'Failed'
                $row.Finished = & $stamp
                $row.Detail = $_.Exception.Message
                Write-PlacementLog "Storage vMotion of $($item.VMName) could not start: $($_.Exception.Message)" -Level WARN
            }
        }

        if ($stopped -and $queue.Count -gt 0) {
            foreach ($left in $queue.ToArray()) {
                $left.Row.Result = 'Not started'
                $left.Row.Detail = 'Stopped before it started.'
            }
            Write-PlacementLog "Stopped: $($queue.Count) queued migration(s) not started; $($running.Count) running will finish." -Level WARN
            $queue.Clear()
        }
        if ($null -ne $OnProgress) { & $OnProgress $results.ToArray() }
        if ($running.Count -eq 0) { continue }

        & $Wait

        foreach ($taskId in @($running.Keys)) {
            $entry = $running[$taskId]
            $row = $entry.Row
            try {
                $state = Get-PlacementTaskState -Server $Server -TaskId $taskId
                $entry.Misses = 0
            }
            catch {
                $entry.Misses = $entry.Misses + 1
                if ($entry.Misses -ge 3) {
                    $row.Result = 'Unknown'
                    $row.Finished = & $stamp
                    $row.Detail = "Lost track of task $taskId - check it in vCenter. $($_.Exception.Message)"
                    $running.Remove($taskId)
                    Write-PlacementLog "$($row.VMName): $($row.Detail)" -Level WARN
                }
                continue
            }

            if ($state.State -eq 'Success') {
                $row.Result = 'Migrated'
                $row.Progress = 100
                $row.Finished = & $stamp
                $running.Remove($taskId)
                Write-PlacementLog "Storage vMotion finished: $($row.VMName) -> $($row.To)." -Level INFO
            }
            elseif ($state.State -eq 'Error' -or $state.State -match '^Cancel') {
                $row.Result = 'Failed'
                $row.Finished = & $stamp
                $row.Detail = $state.Error
                $running.Remove($taskId)
                Write-PlacementLog "Storage vMotion failed: $($row.VMName) - $($state.Error)" -Level WARN
            }
            else {
                $row.Progress = $state.Progress
            }
        }
        if ($null -ne $OnProgress) { & $OnProgress $results.ToArray() }
    }

    $results.ToArray()
}

# =============================================================================================
# GUI
# =============================================================================================

function ConvertTo-PlacementDataTable {
    <#
    .SYNOPSIS
        Builds a DataTable for a grid, so the columns sort on a header click.

    .DESCRIPTION
        VMs and Progress are whole numbers and SizeGB a decimal, so they sort as numbers; everything
        else is text.

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

    $numeric = @{ VMs = [int]; Progress = [int]; SizeGB = [double] }
    $table = New-Object System.Data.DataTable
    foreach ($name in $Column) {
        $type = [string]
        if ($numeric.ContainsKey($name)) { $type = $numeric[$name] }
        [void]$table.Columns.Add($name, $type)
    }
    foreach ($item in $Row) {
        $dataRow = $table.NewRow()
        foreach ($name in $Column) {
            $value = $item.$name
            if ($null -eq $value -or ($numeric.ContainsKey($name) -and [string]$value -eq '')) { $value = [DBNull]::Value }
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
        Disables the buttons and shows a wait cursor while vCenter is being read or changed.

    .DESCRIPTION
        Stop is the exception: it stays enabled while migrations run, so they can be stopped.

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
    foreach ($control in @($script:Gui.Connect, $script:Gui.Disconnect, $script:Gui.Discover, $script:Gui.Reapply, $script:Gui.Export, $script:Gui.MigrateSelected, $script:Gui.MigrateAll, $script:Gui.ClusterList)) {
        $control.Enabled = $false
    }
    $script:Gui.Stop.Enabled = [bool]$script:GuiState.Migrating -and -not $script:GuiState.StopRequested
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
    $evaluated = $null -ne $script:GuiState.Result
    $script:Gui.Connect.Enabled = $true
    $script:Gui.Disconnect.Enabled = $connected
    $script:Gui.Discover.Enabled = $connected
    $script:Gui.ClusterList.Enabled = $connected
    $script:Gui.Reapply.Enabled = $discovered
    $script:Gui.Export.Enabled = $evaluated -or ($null -ne $script:GuiState.Migrations)
    $script:Gui.MigrateSelected.Enabled = $connected -and $evaluated
    $script:Gui.MigrateAll.Enabled = $connected -and $evaluated
    $script:Gui.Stop.Enabled = $false
    $script:Gui.Form.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Wait-GuiInterval {
    <#
    .SYNOPSIS
        Waits between task polls while keeping the window responsive - Stop included.

    .PARAMETER Seconds
        How long to wait.

    .EXAMPLE
        Wait-GuiInterval -Seconds 5
    #>
    [CmdletBinding()]
    param(
        [int]$Seconds = 5
    )

    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        Start-Sleep -Milliseconds 100
        [System.Windows.Forms.Application]::DoEvents()
    }
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

    # Assigned inside each branch, not as "$targets = if ...": assigning an if statement unrolls
    # its output, so one selected cluster arrived as a bare object and Windows PowerShell 5.1
    # under StrictMode threw "The property 'Count' cannot be found on this object".
    if ($selected -eq '(All clusters)') {
        $targets = @($script:GuiState.ClusterViews.Keys | Sort-Object | ForEach-Object { $script:GuiState.ClusterViews[$_] })
    }
    else {
        $targets = @($script:GuiState.ClusterViews[$selected])
    }

    $inventory = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($clusterView in $targets) {
        $index++
        Enter-GuiBusyState -Text "Discovering $($clusterView.Name) ($index of $($targets.Count))..."
        $inventory.Add((Get-ClusterPlacementInventory -Server $script:GuiState.Connection -ClusterView $clusterView -ExcludeDatastoreType $script:GuiState.ExcludeTypes))
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
        -FlagUnclassifiedDatastores:($script:Gui.FlagUnclassified.Checked) `
        -HideUndetermined:(-not $script:Gui.ShowUndetermined.Checked) `
        -ScriptVersion $script:GuiState.ScriptVersion
    $script:GuiState.Result = $result

    $byId = @{}
    foreach ($finding in @($result.Findings) + @($result.Unscoped)) {
        if ($finding.VMId) { $byId[$finding.VMId] = $finding }
    }
    $script:GuiState.FindingById = $byId

    # VMId rides along hidden, so a selected row can be traced back to its VM for migration.
    $gridColumns = @(Get-PlacementReportColumn) + 'VMId'
    $script:Gui.ResultsGrid.DataSource = ConvertTo-PlacementDataTable -Row $result.Findings -Column $gridColumns
    $script:Gui.UnscopedGrid.DataSource = ConvertTo-PlacementDataTable -Row $result.Unscoped -Column $gridColumns
    $script:Gui.DatastoreGrid.DataSource = ConvertTo-PlacementDataTable -Row $result.Datastores -Column @('Cluster', 'Datastore', 'Type', 'Environment', 'VMs')
    $script:Gui.ResultsTab.Text = "Misplaced VMs ($($result.Findings.Count))"
    $script:Gui.UnscopedTab.Text = "Not on PROD/SIT/DEV ($($result.Unscoped.Count))"
    $script:Gui.DatastoreTab.Text = "Datastores ($($result.Datastores.Count))"

    $summary = Format-PlacementSummary -Summary $result.Summary
    $script:Gui.Status.Text = "$($script:GuiState.Scope): $summary"
    Write-PlacementLog $summary -Level INFO
}

function Get-GuiActiveTable {
    <#
    .SYNOPSIS
        The rows and columns of the tab on show, for export.

    .EXAMPLE
        Get-GuiActiveTable
    #>
    [CmdletBinding()]
    param()

    $tab = $script:Gui.Tabs.SelectedTab
    $result = $script:GuiState.Result
    if ([object]::ReferenceEquals($tab, $script:Gui.ResultsTab) -and $null -ne $result) {
        return [pscustomobject]@{ Name = 'Misplaced'; Row = $result.Findings; Column = @(Get-PlacementReportColumn) }
    }
    if ([object]::ReferenceEquals($tab, $script:Gui.UnscopedTab) -and $null -ne $result) {
        return [pscustomobject]@{ Name = 'NotOnProdSitDev'; Row = $result.Unscoped; Column = @(Get-PlacementReportColumn) }
    }
    if ([object]::ReferenceEquals($tab, $script:Gui.DatastoreTab) -and $null -ne $result) {
        return [pscustomobject]@{ Name = 'Datastores'; Row = $result.Datastores; Column = @('Cluster', 'Datastore', 'Type', 'Environment', 'VMs') }
    }
    if ([object]::ReferenceEquals($tab, $script:Gui.MigrationTab) -and $null -ne $script:GuiState.Migrations) {
        return [pscustomobject]@{ Name = 'Migrations'; Row = $script:GuiState.Migrations; Column = @(Get-PlacementMigrationColumn) }
    }
    throw 'Open the tab to export - Misplaced VMs, Not on PROD/SIT/DEV, Datastores or Migrations - once it has something in it.'
}

function Invoke-GuiExport {
    <#
    .SYNOPSIS
        Saves the tab on show to a CSV the user picks.

    .EXAMPLE
        Invoke-GuiExport
    #>
    [CmdletBinding()]
    param()

    $active = Get-GuiActiveTable
    $scope = ([string]$script:GuiState.Scope) -replace '^\(All clusters\)$', 'AllClusters' -replace '[^A-Za-z0-9._-]', '_'
    if (-not $scope) { $scope = 'vCenter' }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $dialog.Title = "Export $($active.Name)"
        $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
        $dialog.FileName = 'VMDatastorePlacement_{0}_{1}_{2}.csv' -f $scope, $active.Name, (Get-Date -Format 'yyyyMMdd-HHmm')
        $documents = [Environment]::GetFolderPath('MyDocuments')
        if ($documents) { $dialog.InitialDirectory = $documents }
        if ($dialog.ShowDialog($script:Gui.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

        $rows = @($active.Row)
        Export-PlacementReport -Finding $rows -Path $dialog.FileName -Column $active.Column
        $note = if ($rows.Count -eq 0) { 'Nothing to list - the file has the header row only.' } else { "$($rows.Count) row(s) exported." }
        Show-GuiMessage -Text "$note`n`n$($dialog.FileName)" -Icon Information
    }
    finally {
        $dialog.Dispose()
    }
}

function Show-GuiMigrationProgress {
    <#
    .SYNOPSIS
        Refreshes the Migrations tab and the status bar from the migration result rows.

    .PARAMETER Row
        Result rows from Invoke-PlacementMigration.

    .EXAMPLE
        Show-GuiMigrationProgress -Row $results
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Row
    )

    $script:GuiState.Migrations = $Row
    $script:Gui.MigrationGrid.DataSource = ConvertTo-PlacementDataTable -Row $Row -Column @(Get-PlacementMigrationColumn)
    $script:Gui.MigrationTab.Text = "Migrations ($($Row.Count))"
    $counts = @($Row | Group-Object -Property Result | Sort-Object -Property Name | ForEach-Object { "$($_.Count) $($_.Name.ToLowerInvariant())" })
    $script:Gui.Status.Text = "Migrations: $($counts -join ', ')"
}

function Confirm-GuiMigration {
    <#
    .SYNOPSIS
        The last question before anything in vCenter changes. Defaults to No.

    .PARAMETER Plan
        Rows from Get-PlacementMigrationPlan.

    .PARAMETER MaxConcurrent
        Moves running at once, shown in the question.

    .EXAMPLE
        if (Confirm-GuiMigration -Plan $plan -MaxConcurrent 2) { ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Plan,

        [int]$MaxConcurrent = 2
    )

    $moves = @($Plan | Where-Object { $_.Action -eq 'Migrate' })
    $lines = @($moves | Group-Object -Property { "$($_.ExpectedEnvironment) -> $($_.TargetKind.ToLowerInvariant()) $($_.Target)" } | ForEach-Object { "  $($_.Name): $($_.Count) VM(s)" })
    $skipped = @($Plan | Where-Object { $_.Action -ne 'Migrate' }).Count
    $text = "Storage vMotion $($moves.Count) VM(s) now?`n`n$($lines -join "`n")`n`n"
    if ($skipped -gt 0) { $text += "$skipped VM(s) will be skipped - the Migrations tab will say why.`n" }
    $text += "Up to $MaxConcurrent run at once. Powered-on VMs stay running. This changes vCenter."
    $answer = [System.Windows.Forms.MessageBox]::Show($script:Gui.Form, $text, 'Confirm storage vMotion', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

function Show-MigrationDialog {
    <#
    .SYNOPSIS
        Asks where each environment's VMs should go, how many at once, and how much space to keep.

    .DESCRIPTION
        Returns Mode ('Preview' or 'Migrate'), Targets (environment -> target), MaxConcurrent and
        MinFreeSpacePercent - or $null when cancelled. Nothing is preselected: every target is an
        explicit choice.

    .PARAMETER Environment
        The environments of the chosen VMs, in rule order.

    .PARAMETER Choice
        Environment -> targets from Get-PlacementTargetChoice.

    .PARAMETER Count
        Environment -> number of chosen VMs.

    .PARAMETER Unknown
        Chosen VMs with no known environment (they will be skipped).

    .PARAMETER MaxConcurrent
        Initial moves at once.

    .PARAMETER MinFreeSpacePercent
        Initial free space to keep.

    .PARAMETER WhatIfOnly
        The script was started with -WhatIf: offer Preview only.

    .EXAMPLE
        Show-MigrationDialog -Environment PROD -Choice $choices -Count @{ PROD = 3 }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Environment,

        [Parameter(Mandatory)]
        [hashtable]$Choice,

        [Parameter(Mandatory)]
        [hashtable]$Count,

        [int]$Unknown = 0,

        [int]$MaxConcurrent = 2,

        [int]$MinFreeSpacePercent = 10,

        [bool]$WhatIfOnly = $false
    )

    $dialog = New-Object System.Windows.Forms.Form
    try {
        $dialog.Text = 'Storage vMotion'
        $dialog.Font = $script:Gui.Form.Font
        $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $dialog.MinimizeBox = $false
        $dialog.MaximizeBox = $false
        $dialog.ShowInTaskbar = $false
        $dialog.AutoSize = $true
        $dialog.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink

        $layout = New-Object System.Windows.Forms.TableLayoutPanel
        $layout.ColumnCount = 2
        $layout.AutoSize = $true
        $layout.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $layout.Padding = New-Object System.Windows.Forms.Padding(10)
        $dialog.Controls.Add($layout)

        $addNote = {
            param([string]$Text, [System.Drawing.Color]$Colour)
            $label = New-Object System.Windows.Forms.Label
            $label.Text = $Text
            $label.AutoSize = $true
            $label.MaximumSize = New-Object System.Drawing.Size(720, 0)
            $label.ForeColor = $Colour
            $label.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 8)
            $layout.Controls.Add($label)
            $layout.SetColumnSpan($label, 2)
        }
        & $addNote ("Moves each VM's home folder and every disk to the target you pick. Powered-on VMs stay running. " +
            'Offered per environment: datastore clusters whose every datastore is that environment (Storage DRS picks the member), ' +
            'and single NFS datastores named for it - mounted on the clusters involved. Nothing is preselected.') ([System.Drawing.SystemColors]::ControlText)
        & $addNote 'A VM protected by SRM with array-based replication leaves its replicated datastore - check its protection group afterwards.' ([System.Drawing.Color]::DarkGoldenrod)
        if ($Unknown -gt 0) { & $addNote "$Unknown chosen VM(s) have no known environment and will be skipped." ([System.Drawing.Color]::DimGray) }
        if ($WhatIfOnly) { & $addNote 'The script was started with -WhatIf, so this can only preview.' ([System.Drawing.Color]::Firebrick) }

        $combos = @{}
        foreach ($name in $Environment) {
            $label = New-Object System.Windows.Forms.Label
            $label.Text = "$name - $($Count[$name]) VM(s)"
            $label.AutoSize = $true
            $label.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
            $combo = New-Object System.Windows.Forms.ComboBox
            $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
            $combo.Width = 620
            $options = @($Choice[$name])
            if ($options.Count -eq 0) { [void]$combo.Items.Add("(no eligible $name target on these clusters - these VMs will be skipped)") }
            else { [void]$combo.Items.Add('(do not migrate)') }
            foreach ($target in $options) { [void]$combo.Items.Add((Format-PlacementTarget -Target $target)) }
            $combo.SelectedIndex = 0
            $layout.Controls.Add($label)
            $layout.Controls.Add($combo)
            $combos[$name] = $combo
        }

        $concurrency = New-Object System.Windows.Forms.NumericUpDown
        $concurrency.Minimum = 1
        $concurrency.Maximum = 4
        $concurrency.Value = [Math]::Min(4, [Math]::Max(1, $MaxConcurrent))
        $concurrency.Width = 60
        $headroom = New-Object System.Windows.Forms.NumericUpDown
        $headroom.Minimum = 0
        $headroom.Maximum = 50
        $headroom.Value = [Math]::Min(50, [Math]::Max(0, $MinFreeSpacePercent))
        $headroom.Width = 60
        foreach ($pair in @(@('Migrations at once', $concurrency), @('Keep free on target (%)', $headroom))) {
            $label = New-Object System.Windows.Forms.Label
            $label.Text = $pair[0]
            $label.AutoSize = $true
            $label.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
            $layout.Controls.Add($label)
            $layout.Controls.Add($pair[1])
        }

        $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
        $buttons.AutoSize = $true
        $buttons.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
        $buttons.Dock = [System.Windows.Forms.DockStyle]::Fill
        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = 'Cancel'
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $migrate = New-Object System.Windows.Forms.Button
        $migrate.Text = 'Migrate...'
        $migrate.AutoSize = $true
        $migrate.Enabled = -not $WhatIfOnly
        $migrate.Add_Click({
                $form = $this.FindForm()
                $form.Tag = 'Migrate'
                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            })
        $preview = New-Object System.Windows.Forms.Button
        $preview.Text = 'Preview (WhatIf)'
        $preview.AutoSize = $true
        $preview.Add_Click({
                $form = $this.FindForm()
                $form.Tag = 'Preview'
                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            })
        $buttons.Controls.AddRange(@($cancel, $migrate, $preview))
        $layout.Controls.Add($buttons)
        $layout.SetColumnSpan($buttons, 2)
        $dialog.CancelButton = $cancel

        if ($dialog.ShowDialog($script:Gui.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

        $targets = @{}
        foreach ($name in $Environment) {
            $options = @($Choice[$name])
            $index = $combos[$name].SelectedIndex
            if ($options.Count -gt 0 -and $index -gt 0) { $targets[$name] = $options[$index - 1] }
        }
        [pscustomobject]@{
            Mode = [string]$dialog.Tag
            Targets = $targets
            MaxConcurrent = [int]$concurrency.Value
            MinFreeSpacePercent = [int]$headroom.Value
        }
    }
    finally {
        $dialog.Dispose()
    }
}

function Invoke-GuiMigration {
    <#
    .SYNOPSIS
        Migrates the selected VMs - or every VM - on the tab on show, after a target dialog and a
        final confirmation.

    .DESCRIPTION
        Free space and datastore clusters are read fresh from vCenter first. A Preview runs the same
        plan with -WhatIf. After a live run, the clusters whose VMs moved are discovered again, so
        the VM tabs show where things are now.

    .PARAMETER All
        Every VM on the tab, not just the selected rows.

    .EXAMPLE
        Invoke-GuiMigration -All
    #>
    [CmdletBinding()]
    param(
        [switch]$All
    )

    if ($null -eq $script:GuiState.Connection) { throw 'Connect to vCenter first - migration needs a live connection.' }
    if ($null -eq $script:GuiState.Result) { throw 'Nothing discovered yet - click Discover first.' }

    $tab = $script:Gui.Tabs.SelectedTab
    if ([object]::ReferenceEquals($tab, $script:Gui.ResultsTab)) {
        $grid = $script:Gui.ResultsGrid
        $pool = @($script:GuiState.Result.Findings)
    }
    elseif ([object]::ReferenceEquals($tab, $script:Gui.UnscopedTab)) {
        $grid = $script:Gui.UnscopedGrid
        $pool = @($script:GuiState.Result.Unscoped)
    }
    else {
        throw 'Open the Misplaced VMs or Not on PROD/SIT/DEV tab, then pick the VMs to migrate.'
    }

    if ($All) {
        $chosen = $pool
    }
    else {
        $ids = @(foreach ($gridRow in $grid.SelectedRows) { [string]$gridRow.Cells['VMId'].Value })
        $chosen = @($ids | Where-Object { $script:GuiState.FindingById.ContainsKey($_) } | ForEach-Object { $script:GuiState.FindingById[$_] })
    }
    if ($chosen.Count -eq 0) { throw 'Select one or more VMs first (Ctrl-click or Shift-click for several), or use Migrate all in tab.' }

    $ruleSet = ConvertTo-PlacementRuleSet -Definition @(Get-GuiRuleDefinition) -HostnamePattern $script:Gui.Pattern.Text.Trim()
    $present = @($chosen | Where-Object { $_.ExpectedEnvironment } | ForEach-Object { $_.ExpectedEnvironment } | Select-Object -Unique)
    $environments = @($ruleSet.EnvironmentNames | Where-Object { $present -contains $_ })
    if ($environments.Count -eq 0) {
        throw 'None of the chosen VMs has a known environment, so there is nowhere correct to move them. Fix the rules and re-apply first.'
    }

    Enter-GuiBusyState -Text 'Reading datastore and datastore cluster free space...'
    $clusterNames = @($chosen | ForEach-Object { $_.Cluster } | Select-Object -Unique)
    $clusterViews = @($clusterNames | Where-Object { $script:GuiState.ClusterViews.ContainsKey($_) } | ForEach-Object { $script:GuiState.ClusterViews[$_] })
    $storage = @(Get-PlacementStorageInfo -Server $script:GuiState.Connection -ClusterView $clusterViews -ExcludeDatastoreType $script:GuiState.ExcludeTypes)
    $choices = @{}
    $counts = @{}
    foreach ($name in $environments) {
        $choices[$name] = @(Get-PlacementTargetChoice -StorageInfo $storage -RuleSet $ruleSet -Environment $name)
        $counts[$name] = @($chosen | Where-Object { $_.ExpectedEnvironment -eq $name }).Count
    }
    $unknown = @($chosen | Where-Object { -not $_.ExpectedEnvironment }).Count
    Exit-GuiBusyState

    $selection = Show-MigrationDialog -Environment $environments -Choice $choices -Count $counts -Unknown $unknown -MaxConcurrent $script:GuiState.MaxConcurrent -MinFreeSpacePercent $script:GuiState.MinFreePercent -WhatIfOnly $script:WhatIfRun
    if ($null -eq $selection) { return }
    $script:GuiState.MaxConcurrent = $selection.MaxConcurrent
    $script:GuiState.MinFreePercent = $selection.MinFreeSpacePercent

    $plan = @(Get-PlacementMigrationPlan -Finding $chosen -TargetByEnvironment $selection.Targets -MinFreeSpacePercent $selection.MinFreeSpacePercent)
    $moves = @($plan | Where-Object { $_.Action -eq 'Migrate' })
    $preview = ($selection.Mode -ne 'Migrate') -or $script:WhatIfRun
    if (-not $preview -and $moves.Count -gt 0 -and -not (Confirm-GuiMigration -Plan $plan -MaxConcurrent $selection.MaxConcurrent)) {
        Write-PlacementLog 'Migration cancelled at the confirmation.' -Level INFO
        return
    }

    $mode = if ($preview) { 'Preview' } else { 'Migration' }
    Write-PlacementLog "$mode of $($plan.Count) VM(s): $($moves.Count) to move, $($plan.Count - $moves.Count) skipped." -Level INFO
    $script:GuiState.Migrating = -not $preview
    $script:GuiState.StopRequested = $false
    $script:Gui.Tabs.SelectedTab = $script:Gui.MigrationTab
    Enter-GuiBusyState -Text "$mode running..."
    try {
        $results = @(Invoke-PlacementMigration -Server $script:GuiState.Connection -Plan $plan -MaxConcurrent $selection.MaxConcurrent -ScriptVersion $script:GuiState.ScriptVersion `
                -WhatIf:$preview -Confirm:$false `
                -OnProgress { param($Rows) Show-GuiMigrationProgress -Row $Rows } `
                -ShouldStop { [bool]$script:GuiState.StopRequested } `
                -Wait { Wait-GuiInterval -Seconds 5 })
    }
    finally {
        $script:GuiState.Migrating = $false
    }
    Show-GuiMigrationProgress -Row $results

    $migrated = @($results | Where-Object { $_.Result -eq 'Migrated' })
    $failed = @($results | Where-Object { @('Failed', 'Unknown') -contains $_.Result })
    if ($migrated.Count -gt 0) {
        $moved = @($migrated | ForEach-Object { $_.Cluster } | Select-Object -Unique)
        $refreshed = New-Object System.Collections.Generic.List[object]
        foreach ($clusterInventory in @($script:GuiState.Inventory)) {
            if ($moved -contains $clusterInventory.Cluster -and $script:GuiState.ClusterViews.ContainsKey($clusterInventory.Cluster)) {
                Enter-GuiBusyState -Text "Re-discovering $($clusterInventory.Cluster)..."
                $refreshed.Add((Get-ClusterPlacementInventory -Server $script:GuiState.Connection -ClusterView $script:GuiState.ClusterViews[$clusterInventory.Cluster] -ExcludeDatastoreType $script:GuiState.ExcludeTypes))
            }
            else {
                $refreshed.Add($clusterInventory)
            }
        }
        $script:GuiState.Inventory = $refreshed.ToArray()
        Invoke-GuiEvaluation
        Show-GuiMigrationProgress -Row $results
    }

    $text = if ($preview) {
        "Preview only - nothing was changed.`n`n$($moves.Count) VM(s) would move; $($plan.Count - $moves.Count) would be skipped. The Migrations tab has each one and why."
    }
    else {
        "$($migrated.Count) VM(s) migrated, $($failed.Count) failed, $(@($results | Where-Object { $_.Result -eq 'Not started' }).Count) not started, $(@($results | Where-Object { $_.Result -eq 'Skipped' }).Count) skipped. The Migrations tab has each one."
    }
    Write-PlacementLog ($text -replace "`n+", ' ') -Level INFO
    Show-GuiMessage -Text $text -Icon $(if ($failed.Count -gt 0) { 'Warning' } else { 'Information' })
}

function Show-PlacementGui {
    <#
    .SYNOPSIS
        Opens the placement window: sign in, pick a cluster, discover, adjust rules, export, migrate.

    .PARAMETER InitialServer
        Pre-fills the vCenter box.

    .PARAMETER Credential
        Used when the password box is left empty.

    .PARAMETER RuleDefinition
        Initial rules grid rows.

    .PARAMETER HostnamePattern
        Initial hostname pattern.

    .PARAMETER ExcludeDatastoreType
        Datastore types not discovered.

    .PARAMETER FlagUnclassifiedDatastores
        Initial state of the flag-unclassified checkbox.

    .PARAMETER HideUndetermined
        Initial state (inverted) of the report-undetermined checkbox.

    .PARAMETER MaxConcurrentMigrations
        Initial moves at once in the migration dialog.

    .PARAMETER MinFreeSpacePercent
        Initial free space to keep in the migration dialog.

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

        [string[]]$ExcludeDatastoreType = @('VMFS'),

        [switch]$FlagUnclassifiedDatastores,

        [switch]$HideUndetermined,

        [int]$MaxConcurrentMigrations = 2,

        [int]$MinFreeSpacePercent = 10,

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
        Migrations = $null
        FindingById = @{}
        Scope = ''
        Busy = $false
        Migrating = $false
        StopRequested = $false
        ClusterViews = @{}
        SuppliedCredential = $Credential
        ScriptVersion = $ScriptVersion
        ExcludeTypes = $ExcludeDatastoreType
        MaxConcurrent = $MaxConcurrentMigrations
        MinFreePercent = $MinFreeSpacePercent
    }
    $script:Gui = @{}

    $font = New-Object System.Drawing.Font('Segoe UI', 9)
    $labelMargin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
    $tips = New-Object System.Windows.Forms.ToolTip

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "VM Datastore Placement $ScriptVersion"
    if ($script:WhatIfRun) { $form.Text += ' - WHATIF: migrations are previews only' }
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
    $row0.Controls.AddRange(@(
            (& $newLabel 'vCenter'), $script:Gui.Server,
            (& $newLabel 'Domain user'), $script:Gui.User,
            (& $newLabel 'Password'), $script:Gui.Password,
            $script:Gui.Connect, $script:Gui.Disconnect))
    $tips.SetToolTip($script:Gui.User, 'DOMAIN\user or user@domain')
    $tips.SetToolTip($script:Gui.Password, 'Leave empty to sign in as your current Windows session (or with the -Credential the script was started with).')

    # ---- Row 1: discover, export, migrate ----------------------------------------------------
    $row1 = & $newRow
    $script:Gui.ClusterList = New-Object System.Windows.Forms.ComboBox
    $script:Gui.ClusterList.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:Gui.ClusterList.Width = 260
    $script:Gui.Discover = & $newButton 'Discover'
    $script:Gui.Reapply = & $newButton 'Re-apply rules'
    $script:Gui.Export = & $newButton 'Export CSV...'
    $script:Gui.MigrateSelected = & $newButton 'Migrate selected...'
    $script:Gui.MigrateAll = & $newButton 'Migrate all in tab...'
    $script:Gui.Stop = & $newButton 'Stop migrations'
    $row1.Controls.AddRange(@((& $newLabel 'Cluster'), $script:Gui.ClusterList, $script:Gui.Discover, $script:Gui.Reapply, $script:Gui.Export, $script:Gui.MigrateSelected, $script:Gui.MigrateAll, $script:Gui.Stop))
    $tips.SetToolTip($script:Gui.Discover, 'Read the cluster from vCenter again, then apply the rules.')
    $tips.SetToolTip($script:Gui.Reapply, 'Apply the rules below to the last discovery, without reading vCenter again.')
    $tips.SetToolTip($script:Gui.Export, 'Save the tab on show to CSV.')
    $tips.SetToolTip($script:Gui.MigrateSelected, 'Storage vMotion the selected rows of the Misplaced VMs or Not on PROD/SIT/DEV tab. You pick the target and confirm first.')
    $tips.SetToolTip($script:Gui.MigrateAll, 'Storage vMotion every VM on the Misplaced VMs or Not on PROD/SIT/DEV tab. You pick the target and confirm first.')
    $tips.SetToolTip($script:Gui.Stop, 'Start no more migrations. The ones running finish.')

    # ---- Row 2: options --------------------------------------------------------------------
    $row2 = & $newRow
    $script:Gui.ShowUndetermined = New-Object System.Windows.Forms.CheckBox
    $script:Gui.ShowUndetermined.Text = 'Report VMs with an undetermined environment'
    $script:Gui.ShowUndetermined.AutoSize = $true
    $script:Gui.ShowUndetermined.Checked = -not $HideUndetermined
    $script:Gui.FlagUnclassified = New-Object System.Windows.Forms.CheckBox
    $script:Gui.FlagUnclassified.Text = 'Flag VMs also on other datastores'
    $script:Gui.FlagUnclassified.AutoSize = $true
    $script:Gui.FlagUnclassified.Checked = [bool]$FlagUnclassifiedDatastores
    $script:Gui.Pattern = & $newTextBox 330 $HostnamePattern
    $excludedLabel = & $newLabel "Not discovered: $(@($ExcludeDatastoreType) -join ', ') datastores"
    $excludedLabel.ForeColor = [System.Drawing.Color]::DimGray
    $row2.Controls.AddRange(@($script:Gui.ShowUndetermined, $script:Gui.FlagUnclassified, (& $newLabel 'Hostname pattern'), $script:Gui.Pattern, $excludedLabel))
    $tips.SetToolTip($script:Gui.FlagUnclassified, 'Off: a VM on a PROD/SIT/DEV datastore is judged on those alone. On: it is also reported if it uses any datastore with no keyword.')
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

    # ---- Row 5: tabs -----------------------------------------------------------------------
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:Gui.Tabs = $tabs

    $newGrid = {
        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
        $grid.ReadOnly = $true
        $grid.AllowUserToAddRows = $false
        $grid.AllowUserToDeleteRows = $false
        $grid.RowHeadersVisible = $false
        $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
        $grid.MultiSelect = $true
        $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells
        $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
        $grid
    }
    $newTab = {
        param([string]$Text, $Grid)
        $page = New-Object System.Windows.Forms.TabPage
        $page.Text = $Text
        $page.Controls.Add($Grid)
        $page
    }
    $vmGridColours = {
        foreach ($gridRow in $this.Rows) {
            $colour = switch -Wildcard ([string]$gridRow.Cells['Status'].Value) {
                'Wrong datastore' { [System.Drawing.Color]::MistyRose }
                'Unmapped hostname letter' { [System.Drawing.Color]::LightYellow }
                'Environment undetermined' { [System.Drawing.Color]::Gainsboro }
                'Not on a *' { [System.Drawing.Color]::AliceBlue }
                default { [System.Drawing.Color]::Lavender }
            }
            $gridRow.DefaultCellStyle.BackColor = $colour
        }
        if ($this.Columns.Contains('VMId')) { $this.Columns['VMId'].Visible = $false }
    }

    $script:Gui.ResultsGrid = & $newGrid
    $script:Gui.ResultsGrid.Add_DataBindingComplete($vmGridColours)
    $script:Gui.ResultsTab = & $newTab 'Misplaced VMs' $script:Gui.ResultsGrid

    $script:Gui.UnscopedGrid = & $newGrid
    $script:Gui.UnscopedGrid.Add_DataBindingComplete($vmGridColours)
    $script:Gui.UnscopedTab = & $newTab 'Not on PROD/SIT/DEV' $script:Gui.UnscopedGrid

    $script:Gui.DatastoreGrid = & $newGrid
    $script:Gui.DatastoreTab = & $newTab 'Datastores' $script:Gui.DatastoreGrid

    $script:Gui.MigrationGrid = & $newGrid
    $script:Gui.MigrationGrid.Add_DataBindingComplete({
            foreach ($gridRow in $this.Rows) {
                $colour = switch ([string]$gridRow.Cells['Result'].Value) {
                    'Migrated' { [System.Drawing.Color]::Honeydew }
                    'Running' { [System.Drawing.Color]::LightCyan }
                    'Queued' { [System.Drawing.Color]::White }
                    'WhatIf' { [System.Drawing.Color]::Lavender }
                    'Failed' { [System.Drawing.Color]::MistyRose }
                    'Unknown' { [System.Drawing.Color]::MistyRose }
                    default { [System.Drawing.Color]::Gainsboro }
                }
                $gridRow.DefaultCellStyle.BackColor = $colour
            }
        })
    $script:Gui.MigrationTab = & $newTab 'Migrations' $script:Gui.MigrationGrid

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true
    $logBox.ReadOnly = $true
    $logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $logBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $logBox.BackColor = [System.Drawing.SystemColors]::Window
    $logTab = & $newTab 'Log' $logBox
    $script:Gui.LogBox = $logBox

    $tabs.TabPages.AddRange(@($script:Gui.ResultsTab, $script:Gui.UnscopedTab, $script:Gui.DatastoreTab, $script:Gui.MigrationTab, $logTab))

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
    $script:Gui.ConnectionLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:Gui.ConnectionLabel.Text = 'Not connected'
    $script:Gui.ConnectionLabel.ForeColor = [System.Drawing.Color]::DimGray
    [void]$statusStrip.Items.Add($script:Gui.Status)
    [void]$statusStrip.Items.Add($script:Gui.ConnectionLabel)

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
    $script:Gui.MigrateSelected.Add_Click({ Invoke-GuiAction { Invoke-GuiMigration } })
    $script:Gui.MigrateAll.Add_Click({ Invoke-GuiAction { Invoke-GuiMigration -All } })
    # Not through Invoke-GuiAction: that refuses to run while busy, and busy is exactly when Stop
    # is needed.
    $script:Gui.Stop.Add_Click({
            $script:GuiState.StopRequested = $true
            $script:Gui.Stop.Enabled = $false
            Write-PlacementLog 'Stop requested - running migrations will finish, nothing new will start.' -Level WARN
        })
    $script:Gui.Password.Add_KeyDown({
            if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                $_.SuppressKeyPress = $true
                Invoke-GuiAction { Invoke-GuiConnect }
            }
        })
    foreach ($checkbox in @($script:Gui.ShowUndetermined, $script:Gui.FlagUnclassified)) {
        $checkbox.Add_CheckedChanged({
                if ($null -ne $script:GuiState.Inventory -and -not $script:GuiState.Busy) {
                    Invoke-GuiAction { Invoke-GuiEvaluation }
                }
            })
    }
    $form.Add_FormClosing({
            if ($script:GuiState.Busy) {
                $_.Cancel = $true
                if ($script:GuiState.Migrating) {
                    Show-GuiMessage -Text 'Migrations are running. Click Stop migrations, wait for the running ones to finish, then close.' -Icon Warning
                }
            }
        })

    $script:GuiLogSink = {
        param([string]$Line)
        $script:Gui.LogBox.AppendText($Line + [Environment]::NewLine)
        [System.Windows.Forms.Application]::DoEvents()
    }

    Exit-GuiBusyState
    try {
        $whatIfNote = ''
        if ($script:WhatIfRun) { $whatIfNote = ' Started with -WhatIf: migrations are previews only.' }
        Write-PlacementLog "VM datastore placement $ScriptVersion - GUI started. Discovery is read-only; vCenter changes only when you migrate and confirm.$whatIfNote" -Level INFO
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

    if ($null -ne $MigrateTo) {
        $unknownKeys = @($MigrateTo.Keys | Where-Object { $ruleSet.EnvironmentNames -notcontains ([string]$_).ToUpperInvariant() })
        if ($unknownKeys.Count -gt 0) {
            throw "-MigrateTo has $($unknownKeys -join ', '), which is not an environment. Use $($ruleSet.EnvironmentNames -join ', ')."
        }
    }

    if ($NoGui) {
        if ([string]::IsNullOrWhiteSpace($Server)) { throw '-Server is required with -NoGui.' }
        Assert-PowerCliAvailable
        $modeNote = 'read-only'
        if ($null -ne $MigrateTo) { $modeNote = 'MIGRATION REQUESTED' }
        if ($script:WhatIfRun) { $modeNote += ', -WhatIf: nothing in vCenter is changed' }
        Write-PlacementLog "VM datastore placement $ScriptVersion - $modeNote." -Level INFO

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
                $inventory.Add((Get-ClusterPlacementInventory -Server $connection -ClusterView $clusterView -ExcludeDatastoreType $ExcludeDatastoreType))
            }

            $result = Invoke-PlacementEvaluation -Inventory $inventory.ToArray() -RuleSet $ruleSet -FlagUnclassifiedDatastores:$FlagUnclassifiedDatastores -HideUndetermined:$HideUndetermined -ScriptVersion $ScriptVersion
            Write-PlacementLog (Format-PlacementSummary -Summary $result.Summary) -Level INFO

            if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                $folder = [Environment]::GetFolderPath('MyDocuments')
                if (-not $folder) { $folder = (Get-Location).Path }
                $vcName = ([string]$connection.Name) -replace '[^A-Za-z0-9._-]', '_'
                $OutputPath = Join-Path $folder ('VMDatastorePlacement_{0}_{1}.csv' -f $vcName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            }
            Export-PlacementReport -Finding $result.Findings -Path $OutputPath
            Export-PlacementReport -Finding $result.Unscoped -Path (Get-PlacementSiblingPath -Path $OutputPath -Suffix 'NotOnProdSitDev')

            if ($null -eq $MigrateTo) {
                $result.Findings
            }
            else {
                $storage = @(Get-PlacementStorageInfo -Server $connection -ClusterView $clusterViews -ExcludeDatastoreType $ExcludeDatastoreType)
                $targetByEnvironment = @{}
                foreach ($key in @($MigrateTo.Keys)) {
                    $environment = ([string]$key).ToUpperInvariant()
                    $wantedName = [string]$MigrateTo[$key]
                    $eligible = @(Get-PlacementTargetChoice -StorageInfo $storage -RuleSet $ruleSet -Environment $environment)
                    $match = @($eligible | Where-Object { $_.Name -eq $wantedName })
                    if ($match.Count -eq 0) {
                        $names = @($eligible | ForEach-Object { "$($_.Name) ($($_.Kind.ToLowerInvariant()))" }) -join ', '
                        if (-not $names) { $names = 'none on these clusters' }
                        throw "'$wantedName' is not an eligible $environment target. Eligible: $names."
                    }
                    if ($match.Count -gt 1) {
                        throw "'$wantedName' names both a datastore cluster and a datastore. Rename one, or migrate from the GUI."
                    }
                    $targetByEnvironment[$environment] = $match[0]
                    Write-PlacementLog "$environment target: $(Format-PlacementTarget -Target $match[0])" -Level INFO
                }

                $patterns = $MigrateVM
                $candidates = @(@($result.Findings) + @($result.Unscoped) | Where-Object { $vmName = $_.VMName; @($patterns | Where-Object { $vmName -like $_ }).Count -gt 0 })
                $plan = @(Get-PlacementMigrationPlan -Finding $candidates -TargetByEnvironment $targetByEnvironment -MinFreeSpacePercent $MinFreeSpacePercent)
                $moves = @($plan | Where-Object { $_.Action -eq 'Migrate' })
                Write-PlacementLog "Migration plan: $($plan.Count) VM(s), $($moves.Count) to move, $($plan.Count - $moves.Count) skipped." -Level INFO
                foreach ($row in $plan) {
                    Write-PlacementLog "  $($row.Action.PadRight(7)) $($row.VMName) - $($row.Reason)" -Level INFO
                }

                $migration = @(Invoke-PlacementMigration -Server $connection -Plan $plan -MaxConcurrent $MaxConcurrentMigrations -ScriptVersion $ScriptVersion)
                Export-PlacementReport -Finding $migration -Path (Get-PlacementSiblingPath -Path $OutputPath -Suffix 'Migration') -Column @(Get-PlacementMigrationColumn)
                $tally = @($migration | Group-Object -Property Result | Sort-Object -Property Name | ForEach-Object { "$($_.Count) $($_.Name.ToLowerInvariant())" }) -join ', '
                Write-PlacementLog "Migration finished: $tally." -Level INFO
                $migration
            }
        }
        finally {
            Disconnect-PlacementVCenter -Connection $connection
        }
    }
    else {
        if ($null -ne $MigrateTo) {
            Write-PlacementLog '-MigrateTo applies to -NoGui runs and is ignored here; pick targets in the migration dialog.' -Level WARN
        }
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            throw 'The GUI needs Windows. Use -NoGui on this platform.'
        }
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
            throw 'The GUI needs an STA thread and this console is MTA - VS Code''s integrated console can be. Run the script from a normal powershell.exe or pwsh window, or use -NoGui.'
        }
        Assert-PowerCliAvailable
        Show-PlacementGui -InitialServer $Server -Credential $Credential -RuleDefinition $ruleDefinition -HostnamePattern $HostnamePattern `
            -ExcludeDatastoreType $ExcludeDatastoreType -FlagUnclassifiedDatastores:$FlagUnclassifiedDatastores -HideUndetermined:$HideUndetermined `
            -MaxConcurrentMigrations $MaxConcurrentMigrations -MinFreeSpacePercent $MinFreeSpacePercent -ScriptVersion $ScriptVersion
    }
}
catch {
    Write-PlacementLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
