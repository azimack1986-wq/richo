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
    A VM is skipped - with the reason on the Migrations tab - when its environment is unknown, no target was picked for it, the
    target is not mounted on its host, it is already there, or the move would leave the target with
    less than -MinFreeSpacePercent free. Up to -MaxConcurrentMigrations run at once (default 2, at
    most 4). Stop finishes the running ones and starts nothing new. Moved clusters are re-discovered.

    A VM protected by SRM with array-based replication leaves its replicated datastore when it is
    moved. Check its protection group afterwards.

    WHERE YOU ARE. A banner across the top of the window names the tool and shows the vCenter you
    are signed in to, the datacenter and cluster selected, the site (read from a siepdXX name of the
    vCenter or cluster) and the account - and which cluster the results on screen came from, warning
    when that is not the one selected. It turns amber when the script was started with -WhatIf.
    The migration confirmation names the vCenter too. The Re-align Tool picture sits in the banner's
    spare space on the right - its one place in the tool - and opens full size when clicked. It is
    embedded in this file, so the script stays a single download.

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

$ScriptVersion = '1.6.0'

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
            $why = 'its environment is not known'
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

        Skipped:
          - environment not known (fix the rules first - there is nowhere correct to move it)
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

        [hashtable]$Suggestion = @{},

        [ValidateRange(0, 50)]
        [int]$MinFreeSpacePercent = 10
    )

    $planned = @{}
    $seen = @{}
    foreach ($item in $Finding) {
        $environment = [string]$item.ExpectedEnvironment
        $choice = $null
        if ($environment -and $TargetByEnvironment.ContainsKey($environment)) { $choice = $TargetByEnvironment[$environment] }
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
        $isFallback = $null -ne $target -and [bool](Get-ViewProperty $target 'Fallback')

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
        if ($environment -eq '') {
            $row.Reason = "Environment not known ($($item.Status)) - there is nowhere correct to move it. Fix the rules, re-apply, then migrate."
        }
        elseif ($null -eq $target -and $noSuggestion) {
            $row.Reason = "No suggested destination: $noSuggestion."
        }
        elseif ($null -eq $target) {
            $row.Reason = "No $environment target was picked."
        }
        elseif (-not $isFallback -and $target.Environment -ne $environment) {
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
                if ($isFallback) {
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
            $marker = ''
            if ($_.Fallback) { $marker = " (NOT a $($_.ExpectedEnvironment) datastore)" }
            "$($_.ExpectedEnvironment) -> $($_.TargetKind.ToLowerInvariant()) $($_.Target)$marker"
        } | ForEach-Object { "  $($_.Name): $($_.Count) VM(s)" })
    $skipped = @($Plan | Where-Object { $_.Action -ne 'Migrate' }).Count
    $fallbackMoves = @($moves | Where-Object { $_.Fallback }).Count
    $text = "Storage vMotion $($moves.Count) VM(s) now, on vCenter $($VCenter)?`n`n$($lines -join "`n")`n`n"
    if ($fallbackMoves -gt 0) { $text += "$fallbackMoves VM(s) go to a datastore not named for their environment - none is available - so they will still be listed afterwards.`n" }
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
        MaxConcurrent and MinFreeSpacePercent - or $null when cancelled.

        Per environment: when it has eligible targets, "Suggested destination for each VM" is
        preselected (if any VM has one), followed by the eligible targets. When it has none, every
        available NFS datastore (Fallback) is listed with its own classification and nothing is
        preselected - with a note that none is named for the environment.

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

        [hashtable]$Suggested = @{},

        [hashtable]$Fallback = @{},

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
            'and single NFS datastores named for it - mounted on the clusters involved. Where a VM has a suggested destination, that is preselected; you can pick one target for all instead.') ([System.Drawing.SystemColors]::ControlText)
        & $addNote 'A VM protected by SRM with array-based replication leaves its replicated datastore - check its protection group afterwards.' ([System.Drawing.Color]::DarkGoldenrod)
        if ($Unknown -gt 0) { & $addNote "$Unknown chosen VM(s) have no known environment and will be skipped." ([System.Drawing.Color]::DimGray) }
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
        Free space and datastore clusters are read fresh from vCenter first, and the suggested
        destinations worked out again from them. When an environment has no eligible target, every
        available NFS datastore on the clusters is offered instead. A Preview runs the same plan
        with -WhatIf. After a live run, the clusters whose VMs moved are discovered again, so
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
    $unknown = @($chosen | Where-Object { -not $_.ExpectedEnvironment }).Count
    Exit-GuiBusyState

    $selection = Show-MigrationDialog -Environment $environments -Choice $choices -Count $counts -Suggested $suggested -Fallback $fallbacks -Unknown $unknown -MaxConcurrent $script:GuiState.MaxConcurrent -MinFreeSpacePercent $script:GuiState.MinFreePercent -WhatIfOnly $script:WhatIfRun
    if ($null -eq $selection) { return }
    $script:GuiState.MaxConcurrent = $selection.MaxConcurrent
    $script:GuiState.MinFreePercent = $selection.MinFreeSpacePercent

    $plan = @(Get-PlacementMigrationPlan -Finding $chosen -TargetByEnvironment $selection.Targets -Suggestion $suggestions -MinFreeSpacePercent $selection.MinFreeSpacePercent)
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

function Get-PlacementBannerImage {
    <#
    .SYNOPSIS
        The banner picture, decoded from the copy embedded at the end of this script.

    .DESCRIPTION
        Returns a Bitmap, or $null when it cannot be read - the banner is then shown without it.
        The decoded image is copied into a Bitmap so its stream can be closed straight away.

    .EXAMPLE
        $picture.Image = Get-PlacementBannerImage
    #>
    [CmdletBinding()]
    param()

    $data = Get-Variable -Name 'BannerImageBase64' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($data)) { return $null }
    try {
        $bytes = [Convert]::FromBase64String($data)
        $stream = New-Object System.IO.MemoryStream(, $bytes)
        try {
            $decoded = [System.Drawing.Image]::FromStream($stream)
            try {
                return (New-Object System.Drawing.Bitmap($decoded))
            }
            finally {
                $decoded.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        Write-PlacementLog "The banner picture could not be shown: $($_.Exception.Message)" -Level DEBUG
        return $null
    }
}

function Show-GuiBannerImage {
    <#
    .SYNOPSIS
        Shows the banner picture full size, in a window that closes on a click.

    .EXAMPLE
        Show-GuiBannerImage
    #>
    [CmdletBinding()]
    param()

    $image = $script:Gui.BannerImage
    if ($null -eq $image) { return }
    $viewer = New-Object System.Windows.Forms.Form
    $box = New-Object System.Windows.Forms.PictureBox
    try {
        $viewer.Text = 'Re-align Tool'
        $viewer.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $viewer.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $viewer.MinimizeBox = $false
        $viewer.MaximizeBox = $false
        $viewer.ShowInTaskbar = $false
        $viewer.ClientSize = New-Object System.Drawing.Size($image.Width, $image.Height)
        $box.Dock = [System.Windows.Forms.DockStyle]::Fill
        $box.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $box.Image = $image
        $box.Add_Click({ $this.FindForm().Close() })
        $viewer.Controls.Add($box)
        [void]$viewer.ShowDialog($script:Gui.Form)
    }
    finally {
        # The picture belongs to the banner; only the viewer is disposed.
        $box.Image = $null
        $viewer.Dispose()
    }
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

    # The Re-align Tool picture fills the banner's spare space on the right - the one place it
    # appears in the tool. Click it for full size.
    $bannerHost = New-Object System.Windows.Forms.TableLayoutPanel
    $bannerHost.ColumnCount = 2
    $bannerHost.RowCount = 1
    [void]$bannerHost.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$bannerHost.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $bannerHost.AutoSize = $true
    $bannerHost.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $bannerHost.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bannerHost.Margin = $banner.Margin
    $bannerHost.BackColor = $banner.BackColor
    $banner.Margin = New-Object System.Windows.Forms.Padding(0)
    $bannerHost.Controls.Add($banner, 0, 0)
    $script:Gui.BannerImage = Get-PlacementBannerImage
    if ($null -ne $script:Gui.BannerImage) {
        $picture = New-Object System.Windows.Forms.PictureBox
        $picture.Image = $script:Gui.BannerImage
        $picture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $picture.Size = New-Object System.Drawing.Size(150, 100)
        $picture.Margin = New-Object System.Windows.Forms.Padding(6, 4, 8, 4)
        $picture.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Right'
        $picture.Cursor = [System.Windows.Forms.Cursors]::Hand
        $picture.Add_Click({ Invoke-GuiAction { Show-GuiBannerImage } })
        $tips.SetToolTip($picture, 'Re-align Tool - click to see it full size.')
        $bannerHost.Controls.Add($picture, 1, 0)
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
    $layout.Controls.Add($bannerHost, 0, 0)
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
        if ($null -ne $script:Gui.BannerImage) { $script:Gui.BannerImage.Dispose() }
    }
}

# =============================================================================================
# Embedded picture - the Re-align Tool, shown once, in the banner. JPEG, 768 x 512, base64.
# Kept in the file so the script stays a single download.
# =============================================================================================

$script:BannerImageBase64 = @'
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
'@

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
                foreach ($key in @($MigrateTo.Keys)) {
                    $environment = ([string]$key).ToUpperInvariant()
                    $wantedName = [string]$MigrateTo[$key]
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
                $plan = @(Get-PlacementMigrationPlan -Finding $candidates -TargetByEnvironment $targetByEnvironment -Suggestion $suggestions -MinFreeSpacePercent $MinFreeSpacePercent)
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
