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
         guest's short hostname - by either of two name rules:
           - the naming standard siepdXXxxL: siepd + 2-digit site number + 2 letters +
             environment letter L, where p -> PROD, t -> SIT, d -> DEV
             e.g. siepd85csp1000 is PROD
           - a name suffix: a name ending -P or -S is PROD, e.g. SQLCLUSTER01-P
         When both apply and disagree, the VM is reported as undetermined rather than guessed.

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

    FULL VMs ONLY. Not shown, and counted in the summary:
      - templates, and vCLS/agent VMs (managed by ESX Agent Manager)
      - SRM placeholder VMs: marked by SRM (managedBy com.vmware.vcDr*, or type placeholderVm)
        AND with no virtual disks - placeholders never have disks
      - any other VM with no virtual disks
    A VM that carries the SRM placeholder mark but HAS disks is a real VM - vCenter can leave the
    mark behind after a failback (Broadcom KB 412345) - so it is shown, its Reason says so, and the
    log lists it.

    SUGGESTED DESTINATION. Every VM on either list whose environment is known gets one, in the
    SuggestedDestination column and CSV: of the targets for its environment mounted on the host it
    runs on, a datastore cluster first, then the one with most free space - that still keeps
    -MinFreeSpacePercent free after taking the VM, counting the VMs suggested to it before. Where
    there is none, the column says why.

    MIGRATION. From either VM tab, Migrate selected or Migrate all in tab. For each environment among
    the chosen VMs the dialog offers, preselected, each VM's own suggested destination - or one
    target for all of them:
      - a datastore cluster, when every datastore in it is that environment (Storage DRS then picks
        the member), or
      - a single NFS datastore named for that environment, not part of a datastore cluster.
    When NO such target is mounted where the chosen VMs run, every available NFS datastore on their
    cluster is offered instead, labelled with its own classification and not preselected. None of
    them is named for the VMs' environment, so a VM moved there is still listed afterwards; the
    confirmation says so. Only targets mounted on the host the VM runs on are offered or used.
    A VM whose environment is not known has no correct place, so nothing is suggested for it: the
    dialog lists every datastore cluster and available NFS datastore on the clusters for those VMs,
    nothing preselected, and they go only where you pick. They stay listed afterwards, until the
    rules can work out their environment. A VM is skipped - with the reason on the Migrations tab -
    when no target was picked for it, the target is not mounted on its host, it is already there,
    or the move would leave the target with less than -MinFreeSpacePercent free. Up to
    -MaxConcurrentMigrations run at once (default 2, at most 4). Stop finishes the running ones
    and starts nothing new. Moved clusters are re-discovered.

    A VM protected by SRM with array-based replication leaves its replicated datastore when it is
    moved. Check its protection group afterwards.

    WHERE YOU ARE. A banner across the top of the window names the tool and shows the vCenter you
    are signed in to, the datacenter and cluster selected, the site (read from a siepdXX name of the
    vCenter or cluster) and the account - and which cluster the results on screen came from, warning
    when that is not the one selected. It turns amber when the script was started with -WhatIf.
    The migration confirmation names the vCenter too.

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

.PARAMETER ProdNameSuffixes
    Name endings that mean PROD. Default -P, -S.

.PARAMETER SitNameSuffixes
    Name endings that mean SIT. Default none.

.PARAMETER DevNameSuffixes
    Name endings that mean DEV. Default none.

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
    -NoGui only. Environment -> target, e.g. @{ PROD = 'Suggested'; DEV = 'NFS_DEV_02' }.
    'Suggested' moves each VM to its own suggested destination. A name must be an eligible datastore
    cluster or NFS datastore for that environment - or, when the clusters have no eligible target for
    it at all, any available NFS datastore on them. The error lists what is allowed. VMs from both
    VM lists whose environment has a target are migrated. Prompts per VM unless -Confirm:$false; -WhatIf previews.
    UNKNOWN = '<name>' moves the VMs whose environment is not known to that datastore cluster or NFS
    datastore - any on the clusters, by name ('Suggested' is not allowed). Narrow it with -MigrateVM.

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

.EXAMPLE
    .\Test-VMDatastorePlacement.ps1 -NoGui -Server vcenter01.dpe.protected.mil.au -MigrateTo @{ PROD = 'Suggested'; DEV = 'Suggested' } -WhatIf

    Preview moving every misplaced VM to its own suggested destination.

.EXAMPLE
    .\Test-VMDatastorePlacement.ps1 -NoGui -Server vcenter01.dpe.protected.mil.au -MigrateTo @{ UNKNOWN = 'NFS_MISC_01' } -MigrateVM 'appserver*' -WhatIf

    Preview moving the matching VMs whose environment is not known to NFS_MISC_01.

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

    [string[]]$ProdNameSuffixes = @('-P', '-S'),
    [string[]]$SitNameSuffixes = @(),
    [string[]]$DevNameSuffixes = @(),

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

$ScriptVersion = '1.7.0'

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
        Each definition carries the environment name plus comma-separated strings: hostname
        letters, name suffixes, DNS labels and datastore keywords - exactly what the GUI rules
        grid holds. Name suffixes are optional on a definition.

        Throws, listing every problem at once, when:
          - a hostname letter is not a single letter, or is mapped to two environments
          - a name suffix has a space or symbol in it, or is mapped to two environments
          - a DNS label is not a single dot-free label, or is mapped to two environments
          - a datastore keyword is used by two environments
          - an environment has no datastore keyword (nothing could ever be classified as it)
          - the hostname pattern is not a valid regex, or has no group named 'env'

        Ambiguous rules are refused rather than resolved, because any tie-break would silently
        decide where a VM belongs.

    .PARAMETER Definition
        Objects with Environment, Letters, DnsLabels and DatastoreKeywords properties, and
        optionally NameSuffixes.

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
    $suffixMap = @{}
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

        $suffixes = New-Object System.Collections.Generic.List[string]
        $suffixText = ''
        $suffixProperty = $item.PSObject.Properties['NameSuffixes']
        if ($null -ne $suffixProperty) { $suffixText = [string]$suffixProperty.Value }
        foreach ($suffix in @(Split-RuleValue $suffixText)) {
            $suffix = $suffix.ToLowerInvariant()
            if ($suffix -notmatch '^[a-z0-9._-]+$') {
                $problems.Add("$environment name suffix '$suffix' may only contain letters, digits, '.', '_' and '-'.")
            }
            elseif ($suffixMap.ContainsKey($suffix) -and $suffixMap[$suffix] -ne $environment) {
                $problems.Add("Name suffix '$suffix' is mapped to both $($suffixMap[$suffix]) and $environment.")
            }
            elseif (-not $suffixes.Contains($suffix)) {
                $suffixMap[$suffix] = $environment
                $suffixes.Add($suffix)
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
                NameSuffixes = $suffixes.ToArray()
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

    # Longest first, so when one suffix ends another the more specific one decides.
    $suffixList = @($suffixMap.Keys | Sort-Object -Property @{ Expression = { $_.Length }; Descending = $true }, @{ Expression = { $_ } } |
            ForEach-Object { [pscustomobject]@{ Suffix = $_; Environment = $suffixMap[$_] } })

    [pscustomobject]@{
        Rules = $rules.ToArray()
        EnvironmentNames = $environmentNames.ToArray()
        LetterMap = $letterMap
        SuffixList = $suffixList
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
        Works out the environment from a name: the siepdXXxxL naming standard, or a name suffix
        such as -P.

    .DESCRIPTION
        Only the first label is used, so a VM named with its FQDN works too. Both rules are
        checked:
          - the hostname pattern, whose 'env' group is the environment letter
          - the name suffixes, case-insensitive, longest first
        Matched says whether either applies. Environment is '' when the pattern matched but its
        letter is not mapped and no suffix applies - that is reported so the letter can be added -
        or when the letter and the suffix name different environments (Conflict), which is
        reported rather than guessed.

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
    $letter = ''
    $letterEnvironment = ''
    $patternMatched = $false
    $suffix = ''
    $suffixEnvironment = ''

    if ($short -ne '') {
        $match = $RuleSet.HostnameRegex.Match($short)
        if ($match.Success -and $match.Groups['env'].Success) {
            $patternMatched = $true
            $letter = $match.Groups['env'].Value.ToLowerInvariant()
            if ($RuleSet.LetterMap.ContainsKey($letter)) { $letterEnvironment = $RuleSet.LetterMap[$letter] }
        }
        $lowered = $short.ToLowerInvariant()
        foreach ($entry in @($RuleSet.SuffixList)) {
            # Ordinal: a culture-aware EndsWith treats '-' specially on Windows PowerShell 5.1.
            if ($null -ne $entry -and $lowered.EndsWith([string]$entry.Suffix, [System.StringComparison]::Ordinal)) {
                $suffix = $entry.Suffix
                $suffixEnvironment = $entry.Environment
                break
            }
        }
    }

    $environment = $letterEnvironment
    if (-not $environment) { $environment = $suffixEnvironment }
    $conflict = [bool]($letterEnvironment -and $suffixEnvironment -and $letterEnvironment -ne $suffixEnvironment)
    if ($conflict) { $environment = '' }

    [pscustomobject]@{
        Matched = ($patternMatched -or [bool]$suffixEnvironment)
        Letter = $letter
        Suffix = $suffix
        Environment = $environment
        LetterEnvironment = $letterEnvironment
        SuffixEnvironment = $suffixEnvironment
        Conflict = $conflict
    }
}

function Resolve-VMExpectedEnvironment {
    <#
    .SYNOPSIS
        Decides which environment a VM belongs to: DNS name first, then VM name, then guest hostname.

    .DESCRIPTION
        Returns Environment ('' when it cannot be decided), DeterminedBy, Letter, Status and Detail.
        Status is '' when an environment was found, otherwise 'Unmapped hostname letter' or
        'Environment undetermined', with Detail saying why in a sentence for the report.

        The DNS name wins when it carries a known label. A conflicting hostname letter or suffix
        does not override it.

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

        if ($byName.Conflict) {
            return [pscustomobject]@{
                Environment = ''
                DeterminedBy = $candidate.Source
                Letter = $byName.Letter
                Status = 'Environment undetermined'
                Detail = "$($candidate.Source) '$($candidate.Value)' says $($byName.LetterEnvironment) by its letter '$($byName.Letter)' but $($byName.SuffixEnvironment) by its suffix '$($byName.Suffix)'."
            }
        }
        if ($byName.Environment -ne '') {
            $how = "letter '$($byName.Letter)'"
            if (-not $byName.LetterEnvironment) { $how = "suffix '$($byName.Suffix)'" }
            return [pscustomobject]@{
                Environment = $byName.Environment
                DeterminedBy = $candidate.Source
                Letter = $byName.Letter
                Status = ''
                Detail = "$($candidate.Source) '$($candidate.Value)' ($how) says $($byName.Environment)"
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
    $knownSuffixes = @(@($RuleSet.SuffixList) | Where-Object { $null -ne $_ } | ForEach-Object { $_.Suffix })
    $nameText = "the name does not match the hostname pattern $($RuleSet.HostnamePattern)"
    if ($knownSuffixes.Count -gt 0) {
        $nameText = "the name matches neither the hostname pattern $($RuleSet.HostnamePattern) nor a name suffix ($($knownSuffixes -join ', '))"
    }
    [pscustomobject]@{
        Environment = ''
        DeterminedBy = ''
        Letter = ''
        Status = 'Environment undetermined'
        Detail = "$why, and $nameText."
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
    'DatastoreEnvironment', 'WrongDatastores', 'SuggestedDestination', 'AllDatastores', 'SizeGB', 'Reason', 'PowerState',
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

        The row also carries, for migration and not for the CSV: VMId, VMRef, CommittedBytes,
        DatastoreNames and SuggestedTarget. SuggestedDestination and SuggestedTarget are filled in by
        Invoke-PlacementEvaluation, which sees the cluster's storage.

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

    if ([bool](Get-ViewProperty $Record 'SrmPlaceholderFlag')) {
        $reason += ' vCenter also marks this VM as an SRM placeholder although it has disks - most likely a mark left behind by a failback (Broadcom KB 412345), which can make operations on it fail until cleared.'
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
        SuggestedDestination = ''
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
        SuggestedTarget = $null
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

    .PARAMETER MinFreeSpacePercent
        Free space a suggested destination must keep after taking the VM.

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

        [ValidateRange(0, 50)]
        [int]$MinFreeSpacePercent = 10,

        [string]$ScriptVersion = ''
    )

    $findings = New-Object System.Collections.Generic.List[object]
    $unscoped = New-Object System.Collections.Generic.List[object]
    $datastoreRows = New-Object System.Collections.Generic.List[object]
    $excludedTypes = New-Object System.Collections.Generic.List[string]
    $clusters = 0; $vmCount = 0; $correct = 0; $hidden = 0
    $skippedTemplates = 0; $skippedAgents = 0; $skippedPlaceholders = 0; $skippedNoDisks = 0; $skippedExcluded = 0

    foreach ($cluster in $Inventory) {
        $clusters++
        $skippedTemplates += [int]$cluster.SkippedTemplates
        $skippedAgents += [int]$cluster.SkippedAgents
        $skippedPlaceholders += [int]$cluster.SkippedPlaceholders
        $skippedNoDisks += [int]$cluster.SkippedNoDisks
        $skippedExcluded += [int]$cluster.SkippedExcluded
        foreach ($type in @($cluster.ExcludedTypes)) {
            if ($type -and -not $excludedTypes.Contains([string]$type)) { $excludedTypes.Add([string]$type) }
        }
        $vmsPerDatastore = @{}
        $clusterRows = New-Object System.Collections.Generic.List[object]

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
                'Unscoped' { $unscoped.Add($outcome.Finding); $clusterRows.Add($outcome.Finding) }
                'Reported' { $findings.Add($outcome.Finding); $clusterRows.Add($outcome.Finding) }
            }
        }

        # Suggestions need the cluster's storage: free space, datastore clusters, host mounts.
        $storage = Get-ViewProperty $cluster 'Storage'
        if ($null -ne $storage -and $clusterRows.Count -gt 0) {
            $suggestions = Get-PlacementSuggestion -Finding $clusterRows.ToArray() -StorageInfo @($storage) -RuleSet $RuleSet -MinFreeSpacePercent $MinFreeSpacePercent
            foreach ($row in $clusterRows) {
                $key = [string]$row.VMId
                if (-not $key) { $key = "name:$($row.VMName)" }
                if (-not $suggestions.ContainsKey($key)) { continue }
                $row.SuggestedDestination = $suggestions[$key].Text
                $row.SuggestedTarget = $suggestions[$key].Target
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
            SkippedNoDisks = $skippedNoDisks
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

    $text = "$($Summary.Clusters) cluster(s), $($Summary.VMs) full VMs: $($Summary.Correct) correct, $reported, $($Summary.NotOnScoped) not on a PROD/SIT/DEV datastore"
    if ($Summary.HiddenUndetermined -gt 0) { $text += ", $($Summary.HiddenUndetermined) undetermined hidden" }
    $excluded = @($Summary.ExcludedTypes) -join '/'
    if (-not $excluded) { $excluded = 'excluded' }
    $text + ". Not shown: $($Summary.SkippedTemplates) template(s), $($Summary.SkippedAgents) vCLS/agent VM(s), $($Summary.SkippedPlaceholders) SRM placeholder(s), $($Summary.SkippedNoDisks) with no disks, $($Summary.SkippedExcluded) only on $excluded datastores."
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

    $line = '{0}  {1}  -  {2} free of {3}  -  {4}' -f $Target.Kind, $Target.Name, (Format-PlacementSize $Target.FreeBytes), (Format-PlacementSize $Target.CapacityBytes), (@($Target.Clusters) -join ', ')
    if ([bool](Get-ViewProperty $Target 'Fallback')) {
        $line = '{0}  {1}  [{2}]  -  {3} free of {4}  -  {5}' -f $Target.Kind, $Target.Name, $Target.Label, (Format-PlacementSize $Target.FreeBytes), (Format-PlacementSize $Target.CapacityBytes), (@($Target.Clusters) -join ', ')
        if ($Target.Pod) { $line += "  (in datastore cluster $($Target.Pod))" }
    }
    $line
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

function Get-PlacementSuggestion {
    <#
    .SYNOPSIS
        Picks a destination for each VM: the best target for its environment mounted where it runs.

    .DESCRIPTION
        Never for a VM whose environment is not known - the migration dialog lets you pick any
        target for those yourself.

        For each VM with a known environment, of the targets Get-PlacementTargetChoice offers for it
        that are mounted on its host (on its cluster, when the host is not known) and that it is not
        already wholly on:
          1. only those that keep MinFreeSpacePercent free after taking it, counting the VMs
             suggested to the same target before it (VMs are taken in name order)
          2. a datastore cluster before a single datastore - Storage DRS balances inside it
          3. then the most free space left
        Returns a hashtable keyed by VMId (or "name:<VMName>" when there is none) of
        { Target; Text; Why }. Target is $null when there is no suggestion, and Why says why.

        Pure: reads nothing from vCenter.

    .PARAMETER Finding
        Rows from either VM list.

    .PARAMETER StorageInfo
        Output of Get-PlacementStorageInfo for the VMs' clusters.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .PARAMETER MinFreeSpacePercent
        Free space, as a percentage of capacity, a target must keep.

    .EXAMPLE
        $suggestions = Get-PlacementSuggestion -Finding $findings -StorageInfo $storage -RuleSet $ruleSet
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Finding,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$StorageInfo,

        [Parameter(Mandatory)]
        [object]$RuleSet,

        [ValidateRange(0, 50)]
        [int]$MinFreeSpacePercent = 10
    )

    $choices = @{}
    $planned = @{}
    $result = @{}
    foreach ($item in @($Finding | Sort-Object -Property VMName)) {
        $key = [string]$item.VMId
        if (-not $key) { $key = "name:$($item.VMName)" }
        $environment = [string]$item.ExpectedEnvironment
        $esxi = [string]$item.EsxiHost
        $where = "on $esxi"
        if (-not $esxi) { $where = "on cluster $($item.Cluster)" }

        $why = ''
        $best = $null
        if (-not $environment) {
            $why = 'its environment is not known. Migrate it to pick any datastore cluster or NFS datastore yourself'
        }
        else {
            if (-not $choices.ContainsKey($environment)) {
                $choices[$environment] = @(Get-PlacementTargetChoice -StorageInfo $StorageInfo -RuleSet $RuleSet -Environment $environment)
            }
            $currentNames = @($item.DatastoreNames)
            $usable = @($choices[$environment] | Where-Object {
                    $candidate = $_
                    if ($esxi) { $visible = @($candidate.Hosts) -contains $esxi }
                    else { $visible = @($candidate.Clusters) -contains [string]$item.Cluster }
                    $alreadyThere = $candidate.Kind -eq 'Datastore' -and $currentNames.Count -gt 0 -and @($currentNames | Where-Object { $_ -ne $candidate.Name }).Count -eq 0
                    $visible -and -not $alreadyThere
                })
            if ($usable.Count -eq 0) {
                $why = "no $environment datastore cluster or NFS datastore is mounted $where. Migrate it on its own to choose from every NFS datastore there"
            }
            else {
                $size = [double]$item.CommittedBytes
                $ranked = @($usable | ForEach-Object {
                        $target = $_
                        $targetKey = "$($target.Kind)|$($target.RefValue)"
                        $floor = [double]$target.CapacityBytes * $MinFreeSpacePercent / 100
                        $left = [double]$target.FreeBytes - [double]$planned[$targetKey] - $size
                        [pscustomobject]@{ Target = $target; Key = $targetKey; Spare = $left - $floor; IsPod = ($target.Kind -eq 'Datastore cluster') }
                    } | Where-Object { $_.Spare -ge 0 } |
                    Sort-Object -Property @{ Expression = { $_.IsPod }; Descending = $true }, @{ Expression = { $_.Spare }; Descending = $true }, @{ Expression = { $_.Target.Name } })
                if ($ranked.Count -eq 0) {
                    $why = "no $environment target mounted $where has room for it while keeping $MinFreeSpacePercent% free"
                }
                else {
                    $best = $ranked[0].Target
                    $planned[$ranked[0].Key] = [double]$planned[$ranked[0].Key] + $size
                }
            }
        }

        if ($null -ne $best) {
            $result[$key] = [pscustomobject]@{ Target = $best; Text = "$($best.Name) ($($best.Kind.ToLowerInvariant()))"; Why = '' }
        }
        else {
            $result[$key] = [pscustomobject]@{ Target = $null; Text = "None - $why."; Why = $why }
        }
    }
    $result
}

function Get-PlacementFallbackChoice {
    <#
    .SYNOPSIS
        Every available NFS datastore on the clusters - offered only when an environment has no
        eligible target at all.

    .DESCRIPTION
        NFS or NFS 4.1, accessible, not in maintenance mode, mounted on at least one of the
        cluster's hosts - whatever its name says, members of datastore clusters included. Each
        carries Fallback = $true, its own classification (Environment, Label) and its datastore
        cluster (Pod), so the dialog, the plan and the confirmation can all say plainly that it is
        not named for the VMs' environment. Datastores with no keyword come first, then by name.

        Pure: reads nothing from vCenter.

    .PARAMETER StorageInfo
        Output of Get-PlacementStorageInfo.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .EXAMPLE
        Get-PlacementFallbackChoice -StorageInfo $storage -RuleSet $ruleSet
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$StorageInfo,

        [Parameter(Mandatory)]
        [object]$RuleSet
    )

    $targets = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($info in $StorageInfo) {
        # A datastore's own parent says which datastore cluster it is in.
        $podName = @{}
        foreach ($pod in @($info.Pods)) { $podName[[string]$pod.RefValue] = [string]$pod.Name }
        foreach ($datastore in @($info.Datastores)) {
            if (@('NFS', 'NFS41') -notcontains ([string]$datastore.Type).ToUpperInvariant()) { continue }
            if (-not $datastore.Accessible -or @('', 'normal') -notcontains [string]$datastore.MaintenanceMode) { continue }
            $hosts = @(Get-PlacementHostSeeing -HostDatastores $info.HostDatastores -RefValue @([string]$datastore.RefValue))
            if ($hosts.Count -eq 0) { continue }
            $key = [string]$datastore.RefValue
            if ($targets.Contains($key)) {
                $existing = $targets[$key]
                $existing.Clusters = @($existing.Clusters) + [string]$info.Cluster
                $existing.Hosts = @($existing.Hosts) + $hosts
                continue
            }
            $class = Get-DatastoreEnvironment -Name $datastore.Name -RuleSet $RuleSet
            $pod = ''
            if ($datastore.PodRefValue -and $podName.ContainsKey([string]$datastore.PodRefValue)) { $pod = $podName[[string]$datastore.PodRefValue] }
            $targets[$key] = [pscustomobject]@{
                Kind = 'Datastore'
                Name = [string]$datastore.Name
                Ref = $datastore.Ref
                RefValue = $key
                Environment = $class.Environment
                Label = $class.Label
                FreeBytes = [double]$datastore.FreeBytes
                CapacityBytes = [double]$datastore.CapacityBytes
                Clusters = @([string]$info.Cluster)
                Hosts = $hosts
                Pod = $pod
                Fallback = $true
            }
        }
    }

    @($targets.Values) | Sort-Object -Property @{ Expression = { if ($_.Environment) { 1 } else { 0 } } }, Name
}

function Get-PlacementAnyChoice {
    <#
    .SYNOPSIS
        Every datastore cluster and every available NFS datastore on the clusters - for VMs whose
        environment is not known, where you pick the destination yourself.

    .DESCRIPTION
        Datastore clusters first: every member discovered (one of an excluded type, such as VMFS,
        rules the datastore cluster out), all of them mounted on at least one of the cluster's
        hosts, and at least one accessible and not in maintenance mode - whatever the members are
        named. Then every datastore Get-PlacementFallbackChoice offers.

        Each carries Fallback = $true and a Label saying what its name classifies it as ('mixed -'
        for a datastore cluster whose members differ), so the dialog, the plan and the confirmation
        can show it. None of them is a suggestion, and the dialog preselects none.

        Pure: reads nothing from vCenter.

    .PARAMETER StorageInfo
        Output of Get-PlacementStorageInfo.

    .PARAMETER RuleSet
        Output of ConvertTo-PlacementRuleSet.

    .EXAMPLE
        Get-PlacementAnyChoice -StorageInfo $storage -RuleSet $ruleSet
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$StorageInfo,

        [Parameter(Mandatory)]
        [object]$RuleSet
    )

    $pods = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($info in $StorageInfo) {
        $byRef = @{}
        foreach ($datastore in @($info.Datastores)) { $byRef[[string]$datastore.RefValue] = $datastore }
        foreach ($pod in @($info.Pods)) {
            $members = @($pod.MemberRefValues)
            if ($members.Count -eq 0) { continue }
            $complete = $true
            $usable = 0
            $names = New-Object System.Collections.Generic.List[string]
            $classes = New-Object System.Collections.Generic.List[object]
            foreach ($member in $members) {
                if (-not $byRef.ContainsKey([string]$member)) { $complete = $false; break }
                $datastore = $byRef[[string]$member]
                if ($datastore.Accessible -and @('', 'normal') -contains [string]$datastore.MaintenanceMode) { $usable++ }
                $names.Add([string]$datastore.Name)
                $classes.Add((Get-DatastoreEnvironment -Name $datastore.Name -RuleSet $RuleSet))
            }
            if (-not $complete -or $usable -eq 0) { continue }
            $hosts = @(Get-PlacementHostSeeing -HostDatastores $info.HostDatastores -RefValue @($members | ForEach-Object { [string]$_ }))
            if ($hosts.Count -eq 0) { continue }

            $key = [string]$pod.RefValue
            if ($pods.Contains($key)) {
                $existing = $pods[$key]
                $existing.Clusters = @($existing.Clusters) + [string]$info.Cluster
                $existing.Hosts = @($existing.Hosts) + $hosts
                continue
            }
            $labels = @($classes | ForEach-Object { $_.Label } | Select-Object -Unique)
            $environments = @($classes | ForEach-Object { $_.Environment } | Select-Object -Unique)
            $label = $labels[0]
            if ($labels.Count -gt 1) { $label = "mixed - $($labels -join ', ')" }
            $environment = ''
            if ($environments.Count -eq 1) { $environment = [string]$environments[0] }
            $pods[$key] = [pscustomobject]@{
                Kind = 'Datastore cluster'
                Name = [string]$pod.Name
                Ref = $pod.Ref
                RefValue = $key
                Environment = $environment
                Label = $label
                FreeBytes = [double]$pod.FreeBytes
                CapacityBytes = [double]$pod.CapacityBytes
                Members = $names.ToArray()
                Clusters = @([string]$info.Cluster)
                Hosts = $hosts
                Pod = ''
                Fallback = $true
            }
        }
    }

    @($pods.Values) | Sort-Object -Property Name
    Get-PlacementFallbackChoice -StorageInfo $StorageInfo -RuleSet $RuleSet
}

function Get-PlacementMigrationPlan {
    <#
    .SYNOPSIS
        Decides, per VM, whether it will be moved and where - or why not.

    .DESCRIPTION
        Every VM given gets one row: Action 'Migrate' or 'Skip', with Reason in a sentence.

        A target per environment is either one target for all of its VMs, or 'Suggested': each VM
        to its own entry in Suggestion. A fallback target (Fallback = $true - an NFS datastore not
        named for the environment, offered only when it has no eligible target) is allowed through
        the environment check, and its Reason says the VM will still be listed afterwards.

        A VM whose environment is not known goes to UnknownEnvironmentTarget - whatever you picked
        for it, there being no environment to check against - and its Reason says it will still be
        listed afterwards. With none picked it is skipped.

        Skipped:
          - environment not known and no target picked for it
          - no target picked for its environment, or no suggested destination for it
          - target is a different environment and not a fallback (defence in depth - the dialog
            only offers matches)
          - target not mounted on the host the VM runs on
          - already wholly on the target datastore
          - the move would leave the target with less than MinFreeSpacePercent free, counting the
            moves planned before it to the same target
          - listed twice

        Pure: reads nothing from vCenter.

    .PARAMETER Finding
        Rows from either VM list.

    .PARAMETER TargetByEnvironment
        Environment -> a target from Get-PlacementTargetChoice or Get-PlacementFallbackChoice, or
        the string 'Suggested'.

    .PARAMETER Suggestion
        Output of Get-PlacementSuggestion, used for environments set to 'Suggested'.

    .PARAMETER UnknownEnvironmentTarget
        A target from Get-PlacementAnyChoice for the VMs whose environment is not known. $null
        skips them.

    .PARAMETER MinFreeSpacePercent
        Free space, as a percentage of capacity, each target must keep.

    .EXAMPLE
        Get-PlacementMigrationPlan -Finding $chosen -TargetByEnvironment @{ PROD = $target }

    .EXAMPLE
        Get-PlacementMigrationPlan -Finding $chosen -UnknownEnvironmentTarget $anyTarget
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Finding,

        [hashtable]$TargetByEnvironment = @{},

        [hashtable]$Suggestion = @{},

        [object]$UnknownEnvironmentTarget,

        [ValidateRange(0, 50)]
        [int]$MinFreeSpacePercent = 10
    )

    $planned = @{}
    $seen = @{}
    foreach ($item in $Finding) {
        $environment = [string]$item.ExpectedEnvironment
        $choice = $null
        if ($environment -and $TargetByEnvironment.ContainsKey($environment)) { $choice = $TargetByEnvironment[$environment] }
        elseif (-not $environment) { $choice = $UnknownEnvironmentTarget }
        $target = $choice
        $noSuggestion = ''
        if ($choice -is [string]) {
            $target = $null
            if ($choice -eq 'Suggested') {
                $suggestionKey = [string]$item.VMId
                if (-not $suggestionKey) { $suggestionKey = "name:$($item.VMName)" }
                $suggested = $null
                if ($Suggestion.ContainsKey($suggestionKey)) { $suggested = $Suggestion[$suggestionKey] }
                if ($null -ne $suggested -and $null -ne $suggested.Target) { $target = $suggested.Target }
                elseif ($null -ne $suggested) { $noSuggestion = [string]$suggested.Why }
                else { $noSuggestion = 'none was worked out for it' }
            }
        }
        # Nothing is named for an unknown environment, so wherever such a VM goes counts as a fallback.
        $isFallback = $null -ne $target -and (-not $environment -or [bool](Get-ViewProperty $target 'Fallback'))

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
            Fallback = $isFallback
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
        if ($environment -eq '' -and $null -eq $target -and -not $noSuggestion) {
            $row.Reason = "Environment not known ($($item.Status)) and no datastore was picked for it."
        }
        elseif ($null -eq $target -and $noSuggestion) {
            $row.Reason = "No suggested destination: $noSuggestion."
        }
        elseif ($null -eq $target) {
            $row.Reason = "No $environment target was picked."
        }
        elseif ($environment -and -not $isFallback -and $target.Environment -ne $environment) {
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
                if (-not $environment) {
                    $label = [string](Get-ViewProperty $target 'Label')
                    if (-not $label) { $label = [string](Get-ViewProperty $target 'Environment') }
                    if ($label) { $label = " ($label)" }
                    $row.Reason += " Its environment is not known, so it goes where you picked$label - and will still be listed afterwards, until the rules can work out its environment."
                }
                elseif ($isFallback) {
                    $row.Reason += " It is NOT a $environment datastore ($($target.Label)) - none is available here - so the VM will still be listed afterwards."
                }
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

function Format-PlacementNameList {
    <#
    .SYNOPSIS
        "a, b, c (+12 more)" - a name list short enough for one log line.

    .PARAMETER Name
        The names.

    .PARAMETER Max
        How many to spell out.

    .EXAMPLE
        Format-PlacementNameList -Name $names -Max 10
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Name,

        [int]$Max = 10
    )

    $sorted = @($Name | Sort-Object)
    $text = @($sorted | Select-Object -First $Max) -join ', '
    if ($sorted.Count -gt $Max) { $text += " (+$($sorted.Count - $Max) more)" }
    $text
}

function ConvertTo-PlacementVMRecord {
    <#
    .SYNOPSIS
        Turns one VirtualMachine view into the plain record the evaluation works on, or a skip reason.

    .DESCRIPTION
        Only full VMs come through. Skip is one of:
          Template     a VM template
          Agent        a vCLS or other ESX Agent Manager VM (managed by com.vmware.vim.eam, or named
                       vCLS*) - placed by vSphere, not by us
          Placeholder  an SRM placeholder: marked by SRM (managedBy extension com.vmware.vcDr*, any
                       case, or type placeholderVm) AND no virtual disks. The real VM is at the
                       protected site and is evaluated there.
          NoDisks      no virtual disks and no SRM mark - not a full VM either
          Excluded     every datastore the VM uses is an excluded type (VMFS by default)

        The SRM mark alone is not enough. vCenter can leave it on real VMs after a failback
        (Broadcom KB 412345), and a placeholder never has disks - so a marked VM WITH disks is a
        full VM, returned with SrmPlaceholderFlag set so the report can say so.

        A VM whose configuration cannot be read (inaccessible) cannot be judged on disks; it is
        kept and evaluated on its datastore list.

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
    $managedType = [string](Get-ViewProperty $View 'Config.ManagedBy.Type')
    if ($managedBy -eq 'com.vmware.vim.eam' -or $name -match '^vCLS') {
        return [pscustomobject]@{ Skip = 'Agent'; Record = $null }
    }

    $srmMarked = ($managedBy -like 'com.vmware.vcDr*') -or ($managedType -eq 'placeholderVm')
    $config = Get-ViewProperty $View 'Config'
    $devices = @(Get-ViewProperty $View 'Config.Hardware.Device' | Where-Object { $null -ne $_ })
    $disks = @($devices | Where-Object { @($_.PSObject.TypeNames) -contains 'VMware.Vim.VirtualDisk' })
    if ($null -ne $config -and $disks.Count -eq 0) {
        if ($srmMarked) { return [pscustomobject]@{ Skip = 'Placeholder'; Record = $null } }
        return [pscustomobject]@{ Skip = 'NoDisks'; Record = $null }
    }

    $datastores = New-Object System.Collections.Specialized.OrderedDictionary
    $excludedHits = 0
    $paths = New-Object System.Collections.Generic.List[object]
    $paths.Add([pscustomobject]@{ Ref = ''; FileName = [string](Get-ViewProperty $View 'Config.Files.VmPathName') })
    foreach ($device in $disks) {
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
        SrmPlaceholderFlag = [bool]$srmMarked
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
        Lists the clusters in the connected vCenter, by name, each with the datacenter it is in.

    .DESCRIPTION
        One call for the datacenters, then one per datacenter for the clusters under it - so
        clusters in nested host folders are found too. Returns Name, MoRef and Datacenter.

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

    $clusters = New-Object System.Collections.Generic.List[object]
    foreach ($datacenter in @(Get-View -Server $Server -ViewType Datacenter -Property 'Name')) {
        foreach ($cluster in @(Get-View -Server $Server -ViewType ClusterComputeResource -SearchRoot $datacenter.MoRef -Property 'Name')) {
            $clusters.Add([pscustomobject]@{ Name = [string]$cluster.Name; MoRef = $cluster.MoRef; Datacenter = [string]$datacenter.Name })
        }
    }
    $clusters.ToArray() | Sort-Object -Property Name
}

function Get-ClusterPlacementInventory {
    <#
    .SYNOPSIS
        Reads one cluster from vCenter: its datastores and, for each VM, its DNS name and datastores.

    .DESCRIPTION
        A handful of property-collector calls per cluster - cluster, datastores, hosts, datastore
        clusters, VMs - each asking only for the properties used, rather than a round trip per VM.
        Read-only. The storage read is kept on the result (Storage) for the suggested
        destinations.

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
    Write-PlacementLog "Reading cluster $($ClusterView.Name)..." -Level INFO

    # One storage read serves both the placement check and the suggested destinations.
    $storage = @(Get-PlacementStorageInfo -Server $Server -ClusterView @($ClusterView) -ExcludeDatastoreType $ExcludeDatastoreType)[0]
    $datastoreByRef = @{}
    $datastoreByName = @{}
    foreach ($datastore in @($storage.Datastores)) {
        $info = [pscustomobject]@{ Name = [string]$datastore.Name; Type = [string]$datastore.Type }
        $datastoreByRef[[string]$datastore.RefValue] = $info
        $datastoreByName[$info.Name] = $info
    }
    $excludedByRef = @{}
    $excludedByName = @{}
    foreach ($datastore in @($storage.Excluded)) {
        $excludedByRef[[string]$datastore.RefValue] = [string]$datastore.Name
        $excludedByName[[string]$datastore.Name] = [string]$datastore.Type
    }
    $hostByRef = $storage.HostNameByRef

    $vmProperties = @(
        'Name', 'Config.Template', 'Config.ManagedBy', 'Config.Files.VmPathName', 'Config.Hardware.Device',
        'Guest.HostName', 'Guest.ToolsRunningStatus', 'Runtime.PowerState', 'Runtime.Host', 'Datastore',
        'Summary.Storage.Committed'
    )
    $vmViews = @(Get-View -Server $Server -ViewType VirtualMachine -SearchRoot $ClusterView.MoRef -Property $vmProperties)

    $records = New-Object System.Collections.Generic.List[object]
    $skipped = @{ Template = 0; Agent = 0; Placeholder = 0; NoDisks = 0; Excluded = 0 }
    $placeholderNames = New-Object System.Collections.Generic.List[string]
    $noDiskNames = New-Object System.Collections.Generic.List[string]
    $flaggedNames = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($view in $vmViews) {
        $id = [string]$view.MoRef.Value
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true

        $converted = ConvertTo-PlacementVMRecord -View $view -DatastoreByRef $datastoreByRef -DatastoreByName $datastoreByName -ExcludedByRef $excludedByRef -ExcludedByName $excludedByName -HostByRef $hostByRef -Cluster $storage.Cluster -VCenter ([string]$Server.Name) -DiscoveredAt $discoveredAt
        if ($converted.Skip) {
            $skipped[$converted.Skip] = $skipped[$converted.Skip] + 1
            if ($converted.Skip -eq 'Placeholder') { $placeholderNames.Add([string]$view.Name) }
            if ($converted.Skip -eq 'NoDisks') { $noDiskNames.Add([string]$view.Name) }
            continue
        }
        if ($converted.Record.SrmPlaceholderFlag) { $flaggedNames.Add($converted.Record.VMName) }
        $records.Add($converted.Record)
    }

    Write-PlacementLog ("Cluster {0}: {1} full VMs, {2} datastores ({3} {4} not discovered); not shown: {5} template(s), {6} vCLS/agent VM(s), {7} SRM placeholder(s), {8} VM(s) with no disks, {9} VM(s) only on {4}." -f $storage.Cluster, $records.Count, $datastoreByName.Count, $excludedByName.Count, ($excludedTypes -join '/'), $skipped.Template, $skipped.Agent, $skipped.Placeholder, $skipped.NoDisks, $skipped.Excluded) -Level INFO
    if ($placeholderNames.Count -gt 0) {
        Write-PlacementLog "Cluster $($storage.Cluster): SRM placeholders not shown: $(Format-PlacementNameList -Name $placeholderNames.ToArray())" -Level INFO
    }
    if ($noDiskNames.Count -gt 0) {
        Write-PlacementLog "Cluster $($storage.Cluster): VMs with no disks not shown: $(Format-PlacementNameList -Name $noDiskNames.ToArray())" -Level INFO
    }
    if ($flaggedNames.Count -gt 0) {
        Write-PlacementLog "Cluster $($storage.Cluster): $($flaggedNames.Count) VM(s) carry the SRM placeholder mark but have disks, so are shown as full VMs - most likely a mark left by a failback (Broadcom KB 412345): $(Format-PlacementNameList -Name $flaggedNames.ToArray())" -Level WARN
    }

    [pscustomobject]@{
        Cluster = [string]$storage.Cluster
        vCenter = [string]$Server.Name
        DiscoveredAt = $discoveredAt
        Datastores = @($datastoreByName.Values | Sort-Object -Property Name)
        VMs = $records.ToArray()
        ExcludedTypes = $excludedTypes
        SkippedTemplates = $skipped.Template
        SkippedAgents = $skipped.Agent
        SkippedPlaceholders = $skipped.Placeholder
        SkippedNoDisks = $skipped.NoDisks
        SkippedExcluded = $skipped.Excluded
        Storage = $storage
    }
}

function Get-PlacementStorageInfo {
    <#
    .SYNOPSIS
        Reads what migration needs about each cluster's storage, fresh: free space, datastore
        clusters, and which host mounts which datastore. Read-only.

    .DESCRIPTION
        Read at discovery, for the suggested destinations, and again when the migration dialog
        opens, so the free space the plan checks is current. Excluded datastore types are listed
        apart (Excluded), which also makes any datastore cluster with such a member ineligible.

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
        $excluded = New-Object System.Collections.Generic.List[object]
        $podRefs = @{}
        $datastoreRefs = @($clusterInfo.Datastore | Where-Object { $null -ne $_ })
        if ($datastoreRefs.Count -gt 0) {
            foreach ($datastore in @(Get-View -Server $Server -Id $datastoreRefs -Property 'Name', 'Parent', 'Summary.Type', 'Summary.FreeSpace', 'Summary.Capacity', 'Summary.Accessible', 'Summary.MaintenanceMode')) {
                $type = [string](Get-ViewProperty $datastore 'Summary.Type')
                if ($excludedTypes -contains $type.ToUpperInvariant()) {
                    $excluded.Add([pscustomobject]@{ RefValue = [string]$datastore.MoRef.Value; Name = [string]$datastore.Name; Type = $type })
                    continue
                }
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
        $hostNameByRef = @{}
        $hostRefs = @($clusterInfo.Host | Where-Object { $null -ne $_ })
        if ($hostRefs.Count -gt 0) {
            foreach ($hostView in @(Get-View -Server $Server -Id $hostRefs -Property 'Name', 'Datastore')) {
                $hostDatastores[[string]$hostView.Name] = @($hostView.Datastore | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Value })
                $hostNameByRef[[string]$hostView.MoRef.Value] = [string]$hostView.Name
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
            HostNameByRef = $hostNameByRef
            Excluded = $excluded.ToArray()
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

    # PowerCLI's State and the vSphere API's Info.State (queued, running, success, error) should
    # agree. The API's is the documented one, so a finished API state wins - a move must never be
    # left polled as Running forever because the two name a state differently.
    $state = [string]$task.State
    $apiState = [string](Get-ViewProperty $task 'ExtensionData.Info.State')
    if (@('success', 'error') -contains $apiState -and @('success', 'error') -notcontains $state) { $state = $apiState }

    [pscustomobject]@{
        State = $state
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
                # A move to a datastore not named for the VM's environment keeps saying so.
                if (-not [bool](Get-ViewProperty $item 'Fallback')) { $row.Detail = '' }
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

function Get-PlacementSite {
    <#
    .SYNOPSIS
        The site number from the first name that follows the siepdXX naming standard.

    .PARAMETER Name
        Names to try, in order - e.g. the vCenter, then the cluster.

    .EXAMPLE
        Get-PlacementSite -Name 'siepd85vcs01.dpe.protected.mil.au', 'CL-PROD-01'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Name
    )

    foreach ($candidate in $Name) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $short = ($candidate.Trim() -split '\.')[0]
        if ($short -match '(?i)^siepd(?<site>\d{2})') { return $Matches['site'] }
    }
    ''
}

function Format-PlacementLocation {
    <#
    .SYNOPSIS
        The "where am I" line for the banner: vCenter, datacenter, cluster, site, account.

    .PARAMETER VCenter
        vCenter signed in to; empty when not connected.

    .PARAMETER User
        Account signed in as.

    .PARAMETER Datacenter
        Every datacenter in the vCenter.

    .PARAMETER Cluster
        Cluster selected, or '(All clusters)'.

    .PARAMETER ClusterDatacenter
        Datacenter of the selected cluster.

    .PARAMETER ClusterCount
        Clusters in the vCenter.

    .PARAMETER Site
        Site number, when known.

    .EXAMPLE
        Format-PlacementLocation -VCenter vc01 -User 'DPE\me' -Cluster CL01 -ClusterDatacenter DC-85
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$VCenter = '',

        [AllowEmptyString()]
        [string]$User = '',

        [AllowEmptyCollection()]
        [string[]]$Datacenter = @(),

        [AllowEmptyString()]
        [string]$Cluster = '',

        [AllowEmptyString()]
        [string]$ClusterDatacenter = '',

        [int]$ClusterCount = 0,

        [AllowEmptyString()]
        [string]$Site = ''
    )

    if (-not $VCenter) {
        return 'Not connected - sign in below. This line then shows the vCenter, datacenter, cluster and site you are working on.'
    }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("vCenter: $VCenter")
    $datacenters = @($Datacenter | Where-Object { $_ })
    if ($Cluster -eq '(All clusters)') {
        if ($datacenters.Count -gt 0) { $parts.Add("Datacenter: $($datacenters -join ', ')") }
        $parts.Add("Cluster: all $ClusterCount")
    }
    elseif ($Cluster) {
        if ($ClusterDatacenter) { $parts.Add("Datacenter: $ClusterDatacenter") }
        $parts.Add("Cluster: $Cluster")
    }
    elseif ($datacenters.Count -gt 0) {
        $parts.Add("Datacenter: $($datacenters -join ', ')")
    }
    if ($Site) { $parts.Add("Site: $Site") }
    if ($User) { $parts.Add("Signed in as: $User") }
    $parts.ToArray() -join '   |   '
}

function Show-GuiLocation {
    <#
    .SYNOPSIS
        Refreshes the banner: where you are, and which cluster the results on screen came from.

    .DESCRIPTION
        Never throws - it runs from the cluster list's selection change as well as after connect,
        disconnect and discovery, and a banner must not be what breaks the window.

    .EXAMPLE
        Show-GuiLocation
    #>
    [CmdletBinding()]
    param()

    try {
        $connection = $script:GuiState.Connection
        $vCenter = ''
        $user = ''
        if ($null -ne $connection) {
            $vCenter = [string]$connection.Name
            $user = [string]$connection.User
        }
        $selected = [string]$script:Gui.ClusterList.SelectedItem
        $views = @($script:GuiState.ClusterViews.Values)
        $datacenters = @($views | ForEach-Object { [string]$_.Datacenter } | Where-Object { $_ } | Sort-Object -Unique)
        $clusterDatacenter = ''
        if ($selected -and $script:GuiState.ClusterViews.ContainsKey($selected)) { $clusterDatacenter = [string]$script:GuiState.ClusterViews[$selected].Datacenter }
        $site = ''
        if ($null -ne $connection) { $site = Get-PlacementSite -Name @($vCenter, $selected) }
        $script:Gui.Location.Text = Format-PlacementLocation -VCenter $vCenter -User $user -Datacenter $datacenters -Cluster $selected -ClusterDatacenter $clusterDatacenter -ClusterCount $views.Count -Site $site

        $inventory = @($script:GuiState.Inventory | Where-Object { $null -ne $_ })
        if ($inventory.Count -eq 0) {
            $script:Gui.OnScreen.Text = 'No results on screen yet - pick a cluster and click Discover.'
        }
        else {
            $scope = [string]$script:GuiState.Scope
            $when = @($inventory | ForEach-Object { [datetime]$_.DiscoveredAt } | Sort-Object)[-1].ToString('HH:mm:ss')
            $text = "Results on screen: $scope, discovered $when"
            if ($selected -and $selected -ne $scope) { $text += "  -  NOT the cluster selected below. Click Discover to read $selected." }
            $script:Gui.OnScreen.Text = $text
        }
    }
    catch {
        Write-Verbose "Banner not refreshed: $($_.Exception.Message)"
    }
}

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
    # UseWaitCursor rather than Form.Cursor: every child control follows it, and it is undone
    # cleanly. See Exit-GuiBusyState for why the grids are also reset by name.
    $script:Gui.Form.UseWaitCursor = $true
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

    # The spinning cursor must not outlive the work. A DataGridView keeps the cursor it had when
    # the pointer crossed a column divider and puts it back afterwards, so a wait cursor picked up
    # mid-discovery could stay on a grid once the form was back to normal. Each grid's own cursor
    # is cleared, and Cursor.Current is set so the pointer changes now, not on the next move.
    $script:Gui.Form.UseWaitCursor = $false
    foreach ($name in @('ResultsGrid', 'UnscopedGrid', 'DatastoreGrid', 'MigrationGrid', 'RulesGrid', 'Tabs')) {
        if ($script:Gui.ContainsKey($name) -and $null -ne $script:Gui[$name]) { $script:Gui[$name].ResetCursor() }
    }
    $script:Gui.Form.ResetCursor()
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
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
            NameSuffixes = [string]$gridRow.Cells['NameSuffixes'].Value
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
    $datacenterNames = @($clusterViews | ForEach-Object { $_.Datacenter } | Where-Object { $_ } | Sort-Object -Unique)
    Write-PlacementLog "$($clusterViews.Count) cluster(s) found in datacenter(s) $($datacenterNames -join ', ')." -Level INFO
    Show-GuiLocation
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
    Show-GuiLocation
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
        -MinFreeSpacePercent $script:GuiState.MinFreePercent `
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
    Show-GuiLocation
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

    .PARAMETER VCenter
        The vCenter the moves will run on, named in the question.

    .EXAMPLE
        if (Confirm-GuiMigration -Plan $plan -MaxConcurrent 2) { ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Plan,

        [int]$MaxConcurrent = 2,

        [string]$VCenter = ''
    )

    $moves = @($Plan | Where-Object { $_.Action -eq 'Migrate' })
    $lines = @($moves | Group-Object -Property {
            $from = [string]$_.ExpectedEnvironment
            $marker = ''
            if (-not $from) { $from = '(environment not known)' }
            elseif ($_.Fallback) { $marker = " (NOT a $from datastore)" }
            "$from -> $($_.TargetKind.ToLowerInvariant()) $($_.Target)$marker"
        } | ForEach-Object { "  $($_.Name): $($_.Count) VM(s)" })
    $skipped = @($Plan | Where-Object { $_.Action -ne 'Migrate' }).Count
    $fallbackMoves = @($moves | Where-Object { $_.Fallback -and $_.ExpectedEnvironment }).Count
    $unknownMoves = @($moves | Where-Object { -not $_.ExpectedEnvironment }).Count
    $text = "Storage vMotion $($moves.Count) VM(s) now, on vCenter $($VCenter)?`n`n$($lines -join "`n")`n`n"
    if ($fallbackMoves -gt 0) { $text += "$fallbackMoves VM(s) go to a datastore not named for their environment - none is available - so they will still be listed afterwards.`n" }
    if ($unknownMoves -gt 0) { $text += "$unknownMoves VM(s) have no known environment and go where you picked - they will still be listed afterwards.`n" }
    if ($skipped -gt 0) { $text += "$skipped VM(s) will be skipped - the Migrations tab will say why.`n" }
    $text += "Up to $MaxConcurrent run at once. Powered-on VMs stay running. This changes vCenter."
    $answer = [System.Windows.Forms.MessageBox]::Show($script:Gui.Form, $text, "Confirm storage vMotion - $VCenter", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

function Show-MigrationDialog {
    <#
    .SYNOPSIS
        Asks where each environment's VMs should go, how many at once, and how much space to keep.

    .DESCRIPTION
        Returns Mode ('Preview' or 'Migrate'), Targets (environment -> target, or 'Suggested'),
        UnknownTarget (the target picked for VMs with no known environment, or $null),
        MaxConcurrent and MinFreeSpacePercent - or $null when cancelled.

        Per environment: when it has eligible targets, "Suggested destination for each VM" is
        preselected (if any VM has one), followed by the eligible targets. When it has none, every
        available NFS datastore (Fallback) is listed with its own classification and nothing is
        preselected - with a note that none is named for the environment.

        When chosen VMs have no known environment, one more row lists every datastore cluster and
        available NFS datastore (UnknownChoice), each with its own classification. Nothing is
        preselected there either: those VMs move only to a datastore you pick.

    .PARAMETER Environment
        The environments of the chosen VMs, in rule order.

    .PARAMETER Choice
        Environment -> targets from Get-PlacementTargetChoice.

    .PARAMETER Count
        Environment -> number of chosen VMs.

    .PARAMETER Suggested
        Environment -> summary of the VMs' suggested destinations, '' when none has one.

    .PARAMETER Fallback
        Environment -> targets from Get-PlacementFallbackChoice, for environments with no eligible
        target.

    .PARAMETER Unknown
        Chosen VMs with no known environment.

    .PARAMETER UnknownChoice
        Targets from Get-PlacementAnyChoice, for the VMs with no known environment.

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

        [hashtable]$Suggested = @{},

        [hashtable]$Fallback = @{},

        [int]$Unknown = 0,

        [AllowEmptyCollection()]
        [object[]]$UnknownChoice = @(),

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
            'and single NFS datastores named for it - mounted on the clusters involved. Where a VM has a suggested destination, that is preselected; you can pick one target for all instead.') ([System.Drawing.SystemColors]::ControlText)
        & $addNote 'A VM protected by SRM with array-based replication leaves its replicated datastore - check its protection group afterwards.' ([System.Drawing.Color]::DarkGoldenrod)
        if ($Unknown -gt 0) {
            & $addNote ("$Unknown chosen VM(s) have no known environment, so nothing can be suggested for them. Pick any datastore cluster or NFS datastore for them in the last row - " +
                'nothing is preselected, and they stay listed afterwards until the rules can work out their environment. Leave it at "(do not migrate)" to skip them.') ([System.Drawing.Color]::Firebrick)
        }
        if ($WhatIfOnly) { & $addNote 'The script was started with -WhatIf, so this can only preview.' ([System.Drawing.Color]::Firebrick) }

        $combos = @{}
        $optionsByName = @{}
        foreach ($name in $Environment) {
            $eligible = @($Choice[$name])
            $fallbackTargets = @()
            if ($eligible.Count -eq 0 -and $Fallback.ContainsKey($name)) { $fallbackTargets = @($Fallback[$name]) }
            if ($eligible.Count -eq 0 -and $fallbackTargets.Count -gt 0) {
                & $addNote ("No $name datastore cluster or NFS datastore is mounted where these VMs run, so every available NFS datastore on their cluster is listed instead. " +
                    "None is named for $name - a VM moved there will still be listed afterwards. Nothing is preselected.") ([System.Drawing.Color]::Firebrick)
            }

            $label = New-Object System.Windows.Forms.Label
            $label.Text = "$name - $($Count[$name]) VM(s)"
            $label.AutoSize = $true
            $label.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
            $combo = New-Object System.Windows.Forms.ComboBox
            $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
            $combo.Width = 620
            $options = New-Object System.Collections.Generic.List[object]
            $preselect = 0
            if ($eligible.Count -gt 0) {
                [void]$combo.Items.Add('(do not migrate)')
                $summary = ''
                if ($Suggested.ContainsKey($name)) { $summary = [string]$Suggested[$name] }
                if ($summary) {
                    [void]$combo.Items.Add("Suggested destination for each VM:  $summary")
                    $options.Add('Suggested')
                    $preselect = 1
                }
                foreach ($target in $eligible) {
                    [void]$combo.Items.Add((Format-PlacementTarget -Target $target))
                    $options.Add($target)
                }
            }
            elseif ($fallbackTargets.Count -gt 0) {
                [void]$combo.Items.Add('(do not migrate)')
                foreach ($target in $fallbackTargets) {
                    [void]$combo.Items.Add((Format-PlacementTarget -Target $target))
                    $options.Add($target)
                }
            }
            else {
                [void]$combo.Items.Add("(no $name target and no NFS datastore available - these VMs will be skipped)")
            }
            $combo.SelectedIndex = $preselect
            $layout.Controls.Add($label)
            $layout.Controls.Add($combo)
            $combos[$name] = $combo
            $optionsByName[$name] = $options.ToArray()
        }

        $unknownCombo = $null
        $unknownOptions = @($UnknownChoice)
        if ($Unknown -gt 0) {
            $label = New-Object System.Windows.Forms.Label
            $label.Text = "Environment not known - $Unknown VM(s)"
            $label.AutoSize = $true
            $label.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
            $unknownCombo = New-Object System.Windows.Forms.ComboBox
            $unknownCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
            $unknownCombo.Width = 620
            if ($unknownOptions.Count -gt 0) {
                [void]$unknownCombo.Items.Add('(do not migrate)')
                foreach ($target in $unknownOptions) { [void]$unknownCombo.Items.Add((Format-PlacementTarget -Target $target)) }
            }
            else {
                [void]$unknownCombo.Items.Add('(no datastore cluster or NFS datastore available - these VMs will be skipped)')
            }
            $unknownCombo.SelectedIndex = 0
            $layout.Controls.Add($label)
            $layout.Controls.Add($unknownCombo)
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
            $options = @($optionsByName[$name])
            $index = $combos[$name].SelectedIndex
            if ($index -gt 0 -and $index -le $options.Count) { $targets[$name] = $options[$index - 1] }
        }
        $unknownTarget = $null
        if ($null -ne $unknownCombo) {
            $index = $unknownCombo.SelectedIndex
            if ($index -gt 0 -and $index -le $unknownOptions.Count) { $unknownTarget = $unknownOptions[$index - 1] }
        }
        [pscustomobject]@{
            Mode = [string]$dialog.Tag
            Targets = $targets
            UnknownTarget = $unknownTarget
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
        Free space and datastore clusters are read fresh from vCenter first, and the suggested
        destinations worked out again from them. When an environment has no eligible target, every
        available NFS datastore on the clusters is offered instead. VMs whose environment is not
        known can go to any datastore cluster or NFS datastore you pick for them - never to one
        picked for you. A Preview runs the same plan with -WhatIf. After a live run, the clusters
        whose VMs moved are discovered again, so the VM tabs show where things are now.

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
    $unknown = @($chosen | Where-Object { -not $_.ExpectedEnvironment }).Count

    Enter-GuiBusyState -Text 'Reading datastore and datastore cluster free space...'
    $clusterNames = @($chosen | ForEach-Object { $_.Cluster } | Select-Object -Unique)
    $clusterViews = @($clusterNames | Where-Object { $script:GuiState.ClusterViews.ContainsKey($_) } | ForEach-Object { $script:GuiState.ClusterViews[$_] })
    $storage = @(Get-PlacementStorageInfo -Server $script:GuiState.Connection -ClusterView $clusterViews -ExcludeDatastoreType $script:GuiState.ExcludeTypes)
    $suggestions = Get-PlacementSuggestion -Finding $chosen -StorageInfo $storage -RuleSet $ruleSet -MinFreeSpacePercent $script:GuiState.MinFreePercent
    $choices = @{}
    $counts = @{}
    $suggested = @{}
    $fallbacks = @{}
    $allFallback = $null
    foreach ($name in $environments) {
        $choices[$name] = @(Get-PlacementTargetChoice -StorageInfo $storage -RuleSet $ruleSet -Environment $name)
        $ofEnvironment = @($chosen | Where-Object { $_.ExpectedEnvironment -eq $name })
        $counts[$name] = $ofEnvironment.Count

        $targetNames = @($ofEnvironment | ForEach-Object {
                $key = [string]$_.VMId
                if (-not $key) { $key = "name:$($_.VMName)" }
                if ($suggestions.ContainsKey($key) -and $null -ne $suggestions[$key].Target) { $suggestions[$key].Target.Name }
            })
        $parts = @($targetNames | Group-Object | Sort-Object -Property Name | ForEach-Object { "$($_.Name) for $($_.Count)" })
        $summary = ''
        if ($parts.Count -gt 0) {
            $summary = $parts -join ', '
            $without = $ofEnvironment.Count - $targetNames.Count
            if ($without -gt 0) { $summary += "; $without with none (skipped)" }
        }
        $suggested[$name] = $summary

        if ($choices[$name].Count -eq 0) {
            if ($null -eq $allFallback) { $allFallback = @(Get-PlacementFallbackChoice -StorageInfo $storage -RuleSet $ruleSet) }
            $fallbacks[$name] = $allFallback
        }
    }
    $anyChoice = @()
    if ($unknown -gt 0) { $anyChoice = @(Get-PlacementAnyChoice -StorageInfo $storage -RuleSet $ruleSet) }
    Exit-GuiBusyState

    $selection = Show-MigrationDialog -Environment $environments -Choice $choices -Count $counts -Suggested $suggested -Fallback $fallbacks -Unknown $unknown -UnknownChoice $anyChoice -MaxConcurrent $script:GuiState.MaxConcurrent -MinFreeSpacePercent $script:GuiState.MinFreePercent -WhatIfOnly $script:WhatIfRun
    if ($null -eq $selection) { return }
    $script:GuiState.MaxConcurrent = $selection.MaxConcurrent
    $script:GuiState.MinFreePercent = $selection.MinFreeSpacePercent

    $plan = @(Get-PlacementMigrationPlan -Finding $chosen -TargetByEnvironment $selection.Targets -Suggestion $suggestions -UnknownEnvironmentTarget $selection.UnknownTarget -MinFreeSpacePercent $selection.MinFreeSpacePercent)
    $moves = @($plan | Where-Object { $_.Action -eq 'Migrate' })
    $preview = ($selection.Mode -ne 'Migrate') -or $script:WhatIfRun
    if (-not $preview -and $moves.Count -gt 0 -and -not (Confirm-GuiMigration -Plan $plan -MaxConcurrent $selection.MaxConcurrent -VCenter ([string]$script:GuiState.Connection.Name))) {
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

    # ---- Banner: what this is, and where you are ---------------------------------------------
    $banner = New-Object System.Windows.Forms.FlowLayoutPanel
    $banner.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $banner.WrapContents = $false
    $banner.AutoSize = $true
    $banner.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $banner.Dock = [System.Windows.Forms.DockStyle]::Fill
    $banner.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $banner.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 6)
    $banner.BackColor = [System.Drawing.Color]::FromArgb(28, 52, 92)
    $subtitleText = "Finds VMs on the wrong PROD / SIT / DEV datastore, and moves them  -  version $ScriptVersion"
    if ($script:WhatIfRun) {
        $banner.BackColor = [System.Drawing.Color]::FromArgb(150, 90, 0)
        $subtitleText += '  -  PREVIEW ONLY (-WhatIf): nothing in vCenter can be changed'
    }
    $newBannerLabel = {
        param([string]$Text, [System.Drawing.Font]$Font, [System.Drawing.Color]$Colour)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Font = $Font
        $label.ForeColor = $Colour
        $label.AutoSize = $true
        $label.Margin = New-Object System.Windows.Forms.Padding(0, 1, 0, 1)
        $label
    }
    $bannerTitle = & $newBannerLabel 'VM Datastore Placement' (New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)) ([System.Drawing.Color]::White)
    $bannerSubtitle = & $newBannerLabel $subtitleText $font ([System.Drawing.Color]::Gainsboro)
    $script:Gui.Location = & $newBannerLabel '' (New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)) ([System.Drawing.Color]::White)
    $script:Gui.OnScreen = & $newBannerLabel '' $font ([System.Drawing.Color]::Gainsboro)
    $banner.Controls.AddRange(@($bannerTitle, $bannerSubtitle, $script:Gui.Location, $script:Gui.OnScreen))
    $tips.SetToolTip($script:Gui.Location, 'Where you are. Site is read from a siepdXX vCenter or cluster name.')

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
    $rulesLabel = & $newLabel 'Placement rules - comma-separate values, then click Re-apply rules. E.g. VMs with letter b belong on DEV: add b to DEV''s hostname letters. Names ending -Q are SIT: add -Q to SIT''s name suffixes.'
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
            @('Environment', 'Environment', 11, $true),
            @('Letters', 'Hostname letters (p / t / d)', 17, $false),
            @('NameSuffixes', 'Name suffixes (e.g. -P, -S)', 17, $false),
            @('DnsLabels', 'DNS labels', 30, $false),
            @('DatastoreKeywords', 'Datastore keywords', 25, $false))) {
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
        [void]$rulesGrid.Rows.Add([string]$definition.Environment, [string]$definition.Letters, [string]$definition.NameSuffixes, [string]$definition.DnsLabels, [string]$definition.DatastoreKeywords)
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
    $layout.RowCount = 7
    foreach ($style in @('AutoSize', 'AutoSize', 'AutoSize', 'AutoSize', 'AutoSize')) {
        [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::$style)))
    }
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $rulesHeight)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $layout.Controls.Add($banner, 0, 0)
    $layout.Controls.Add($row0, 0, 1)
    $layout.Controls.Add($row1, 0, 2)
    $layout.Controls.Add($row2, 0, 3)
    $layout.Controls.Add($rulesLabel, 0, 4)
    $layout.Controls.Add($rulesGrid, 0, 5)
    $layout.Controls.Add($tabs, 0, 6)

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
    # Picking another cluster changes where you are; the banner says so before anything is read.
    $script:Gui.ClusterList.Add_SelectedIndexChanged({ Show-GuiLocation })
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
    Show-GuiLocation
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
        [pscustomobject]@{ Environment = 'PROD'; Letters = ($ProdLetters -join ', '); NameSuffixes = ($ProdNameSuffixes -join ', '); DnsLabels = ($ProdDnsLabels -join ', '); DatastoreKeywords = ($ProdDatastoreKeywords -join ', ') }
        [pscustomobject]@{ Environment = 'SIT'; Letters = ($SitLetters -join ', '); NameSuffixes = ($SitNameSuffixes -join ', '); DnsLabels = ($SitDnsLabels -join ', '); DatastoreKeywords = ($SitDatastoreKeywords -join ', ') }
        [pscustomobject]@{ Environment = 'DEV'; Letters = ($DevLetters -join ', '); NameSuffixes = ($DevNameSuffixes -join ', '); DnsLabels = ($DevDnsLabels -join ', '); DatastoreKeywords = ($DevDatastoreKeywords -join ', ') }
    )

    # Validated before anything else, so a bad -DevLetters fails before a sign-in prompt.
    $ruleSet = ConvertTo-PlacementRuleSet -Definition $ruleDefinition -HostnamePattern $HostnamePattern

    if ($null -ne $MigrateTo) {
        $unknownKeys = @($MigrateTo.Keys | Where-Object { $upper = ([string]$_).ToUpperInvariant(); $upper -ne 'UNKNOWN' -and $ruleSet.EnvironmentNames -notcontains $upper })
        if ($unknownKeys.Count -gt 0) {
            throw "-MigrateTo has $($unknownKeys -join ', '), which is not an environment. Use $($ruleSet.EnvironmentNames -join ', '), or UNKNOWN for VMs whose environment is not known."
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
            Write-PlacementLog "Location: vCenter $($connection.Name), datacenter(s) $(@($clusterViews | ForEach-Object { $_.Datacenter } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')." -Level INFO
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

            $result = Invoke-PlacementEvaluation -Inventory $inventory.ToArray() -RuleSet $ruleSet -FlagUnclassifiedDatastores:$FlagUnclassifiedDatastores -HideUndetermined:$HideUndetermined -MinFreeSpacePercent $MinFreeSpacePercent -ScriptVersion $ScriptVersion
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
                $unknownTarget = $null
                foreach ($key in @($MigrateTo.Keys)) {
                    $environment = ([string]$key).ToUpperInvariant()
                    $wantedName = [string]$MigrateTo[$key]
                    if ($environment -eq 'UNKNOWN') {
                        # No environment to check against, so the name must be given - never 'Suggested'.
                        $any = @(Get-PlacementAnyChoice -StorageInfo $storage -RuleSet $ruleSet)
                        $match = @($any | Where-Object { $_.Name -eq $wantedName })
                        if ($match.Count -eq 0) {
                            $names = @($any | ForEach-Object { "$($_.Name) ($($_.Kind.ToLowerInvariant()), $($_.Label))" }) -join ', '
                            if (-not $names) { $names = 'none' }
                            throw "UNKNOWN needs the name of a datastore cluster or NFS datastore on these clusters - there is no suggestion for a VM whose environment is not known. '$wantedName' is not one of them: $names."
                        }
                        if ($match.Count -gt 1) {
                            throw "'$wantedName' names both a datastore cluster and a datastore. Rename one, or migrate from the GUI."
                        }
                        $unknownTarget = $match[0]
                        Write-PlacementLog "Environment not known: $(Format-PlacementTarget -Target $match[0]) - VMs moved there will still be listed afterwards." -Level WARN
                        continue
                    }
                    if ($wantedName -eq 'Suggested') {
                        $targetByEnvironment[$environment] = 'Suggested'
                        Write-PlacementLog "$environment target: each VM's suggested destination." -Level INFO
                        continue
                    }
                    $eligible = @(Get-PlacementTargetChoice -StorageInfo $storage -RuleSet $ruleSet -Environment $environment)
                    $match = @($eligible | Where-Object { $_.Name -eq $wantedName })
                    if ($match.Count -eq 0 -and $eligible.Count -eq 0) {
                        # Nothing eligible at all: any available NFS datastore may be named instead.
                        $fallback = @(Get-PlacementFallbackChoice -StorageInfo $storage -RuleSet $ruleSet)
                        $match = @($fallback | Where-Object { $_.Name -eq $wantedName })
                        if ($match.Count -eq 0) {
                            $names = @($fallback | ForEach-Object { "$($_.Name) ($($_.Label))" }) -join ', '
                            if (-not $names) { $names = 'none' }
                            throw "No $environment target is available on these clusters, and '$wantedName' is not one of their available NFS datastores either: $names."
                        }
                        Write-PlacementLog "'$wantedName' is not a $environment datastore ($($match[0].Label)) - none is available on these clusters - so VMs moved there will still be listed afterwards." -Level WARN
                    }
                    elseif ($match.Count -eq 0) {
                        $names = @($eligible | ForEach-Object { "$($_.Name) ($($_.Kind.ToLowerInvariant()))" }) -join ', '
                        throw "'$wantedName' is not an eligible $environment target. Eligible: $names, or 'Suggested'."
                    }
                    if ($match.Count -gt 1) {
                        throw "'$wantedName' names both a datastore cluster and a datastore. Rename one, or migrate from the GUI."
                    }
                    $targetByEnvironment[$environment] = $match[0]
                    Write-PlacementLog "$environment target: $(Format-PlacementTarget -Target $match[0])" -Level INFO
                }

                $patterns = $MigrateVM
                $candidates = @(@($result.Findings) + @($result.Unscoped) | Where-Object { $vmName = $_.VMName; @($patterns | Where-Object { $vmName -like $_ }).Count -gt 0 })
                $suggestions = Get-PlacementSuggestion -Finding $candidates -StorageInfo $storage -RuleSet $ruleSet -MinFreeSpacePercent $MinFreeSpacePercent
                $plan = @(Get-PlacementMigrationPlan -Finding $candidates -TargetByEnvironment $targetByEnvironment -Suggestion $suggestions -UnknownEnvironmentTarget $unknownTarget -MinFreeSpacePercent $MinFreeSpacePercent)
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
