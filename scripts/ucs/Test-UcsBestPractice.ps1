<#
.SYNOPSIS
    Audits every readable configuration setting on a UCS 6400-family domain against Cisco's
    published recommendations and writes the result to CSV.

.DESCRIPTION
    Read-only. One UCS Manager domain per run: the script prompts for the fabric address and for
    a username and password, connects, walks the configuration, and emits one CSV row per setting
    checked.

    Every row carries the value found, the value Cisco recommends, and a verdict:

        Meets           the setting matches the recommendation
        Does Not Meet   it does not - RecommendedValue holds what it should be set to
        Review          the correct value depends on the site's design, so the row reports the
                        current value and what to confirm rather than passing judgement
        Not Applicable  the check does not apply to this domain (wrong FI family, feature unused)
        Unknown         the object or property could not be read from this UCSM/PowerTool version

    The Basis column says where the recommendation comes from, because these are not all the same
    weight of advice:

        Best Practice   Cisco recommends it explicitly (see Reference on the row)
        Cisco Default   Cisco ships this value; a deviation is not automatically wrong, but it was
                        changed by someone and should be intentional
        Site Policy     the value is a local design decision; the row reports it for confirmation

    UCS CENTRAL. These domains are registered with UCS Central, so a setting shown here may be
    owned centrally rather than locally. Every row carries the object's PolicyOwner in the Owner
    column, and where that owner is UCS Central the remediation says so - changing it in UCS
    Manager would either be rejected or be overwritten at the next policy push. The UCS Central
    section additionally reports each Policy Resolution Control (global or local), which is what
    decides that ownership.

    NOTHING IS CHANGED. There is no write, acknowledgement, or reconnect anywhere in this script;
    the only thing it creates is the CSV. -WhatIf therefore still performs the full audit and
    skips only that file write.

.PARAMETER Fabric
    UCS Manager cluster VIP or hostname. Prompted for if not supplied. Use the cluster VIP, not an
    individual fabric interconnect - a subordinate FI serves a read-only view and some objects are
    not resolvable from it.

.PARAMETER Credential
    UCS Manager credential. If not supplied, and -CredentialName is not used, the script prompts
    for a username and password.

.PARAMETER CredentialName
    Resolve the credential through Get-RichoCredential (SecretManagement, then RICHO_* environment
    variables, then a prompt) instead of prompting directly. Use this for scheduled runs.

.PARAMETER OutputPath
    CSV to write. Defaults to output/UcsBestPractice-<fabric>-<utc timestamp>.csv at the repo root.

.PARAMETER MaxDetailRowsPerCheck
    Cap on the number of per-object rows a single check may emit for non-compliant objects, so one
    badly configured domain cannot produce a ten thousand row CSV. Defaults to 50. When a check is
    capped it says so in its aggregate row - the truncation is never silent.

.PARAMETER IgnoreCertificateError
    Tell UCS PowerTool to accept the fabric interconnect's certificate without validating it.

    UCS Manager normally presents a self-signed certificate, and PowerTool refuses it by default -
    which is the most common reason a first run gets no further than Connect-Ucs. Off by default,
    because a script that silently stops validating certificates is worse than one that fails
    clearly; the connection failure names this switch when the error looks certificate-shaped.

.PARAMETER Transcript
    Start a PowerShell transcript in logs/ for the run.

.EXAMPLE
    .\Test-UcsBestPractice.ps1

    Prompts for the fabric address, then for a username and password, and writes the CSV to
    output/.

.EXAMPLE
    .\Test-UcsBestPractice.ps1 -Fabric ucsm-prod-01.example.com -OutputPath C:\audit\prod01.csv

.EXAMPLE
    .\Test-UcsBestPractice.ps1 -Fabric ucsm-lab-01 -CredentialName ucsm-lab -Transcript

.EXAMPLE
    $rows = .\Test-UcsBestPractice.ps1 -Fabric ucsm-prod-01
    $rows | Where-Object { $_.Result -eq 'Does Not Meet' -and $_.Severity -eq 'Critical' }

    The rows are returned on the pipeline as well as written to CSV.

.NOTES
    REQUIREMENTS

      - Cisco UCS PowerTool Suite - the Cisco.UCSManager module, which brings Cisco.UCS.Core with
        it. That is the only Cisco module needed; there is no Intersight or UCS Central module
        involved, because a registered domain still answers for its own configuration.

            Install-Module -Name Cisco.UCSManager -Scope CurrentUser

        Nothing is imported explicitly - PowerShell auto-loads it on the first Connect-Ucs. The
        older CiscoUcsPS PowerTool works too if that is what the jump host already carries. If
        neither is present the run stops before connecting and says so, rather than failing later
        on "term not recognized".

      - A UCS Manager account. Read-only is enough: every call this script makes is a read.

      - PowerShell 5.1 or later.

    REFERENCES - the guidance the recommendations in this script are taken from:
      Cisco UCS Manager Infrastructure Management Guide (equipment policies, chassis/FEX discovery)
        https://www.cisco.com/c/en/us/td/docs/unified_computing/ucs/ucs-manager/GUI-User-Guides/Infrastructure-Mgmt/4-3/b_UCSM_GUI_Infrastructure_Management_Guide_4_3/b_UCSM_GUI_Infrastructure_Management_Guide_chapter_011.html
      Cisco UCS Manager Network Management Guide (QoS, LAN connectivity, network control policies)
        https://www.cisco.com/c/en/us/td/docs/unified_computing/ucs/ucs-manager/GUI-User-Guides/Network-Mgmt/4-3/b_UCSM_Network_Mgmt_Guide_4_3/b_UCSM_Network_Mgmt_Guide_chapter_01000.html
      Cisco UCS Manager Administration Management Guide (deferred deployments, backup, passwords)
        https://www.cisco.com/c/en/us/td/docs/unified_computing/ucs/ucs-manager/GUI-User-Guides/Admin-Management/4-3/b_cisco_ucs_admin_mgmt_guide_4-3/m_gui_deferred_deployments_of_service_profile_updates.html
      Cisco UCS Manager Server Management Guide (registering domains with UCS Central)
        https://www.cisco.com/c/en/us/td/docs/unified_computing/ucs/ucs-manager/GUI-User-Guides/Server-Mgmt/4-2/b_Cisco_UCS_Manager_Server_Mgmt_Guide_4_2/chapter_0100.html
      Cisco UCS Central Operations Guide (policy differences, policy resolution control)
        https://www.cisco.com/c/en/us/td/docs/unified_computing/ucs/ucs-central/GUI-User-Guides/Operations/b_UCSC_Ops_Guide/b_UCSC_Ops_Guide_chapter_0111.html
      Cisco Compute UCS Manager Hardening Guide (telnet, HTTPS redirect, SNMPv3, passwords)
        https://www.cisco.com/c/en/us/products/collateral/servers-unified-computing/compute-ucs-manager-hardening-guide.html
      Cisco UCS Ethernet Switching Modes white paper (end-host mode)
        https://www.cisco.com/c/en/us/solutions/collateral/data-center-virtualization/unified-computing/whitepaper_c11-701962.html
      Cisco UCS 6400 Series FI Hardware Installation Guide (unified port rules, ports 1-16)
        https://www.cisco.com/c/en/us/td/docs/unified_computing/ucs/hw/6454-install-guide/6454/6454_chapter_0111.html
      Configure UCS with VMware ESXi End-to-End Jumbo MTU (MTU 9216 end to end)
        https://www.cisco.com/c/en/us/support/docs/servers-unified-computing/ucs-b-series-blade-servers/117601-configure-UCS-00.html

    A recommendation is only as current as the release it was written for. Where a check compares
    against a Cisco default rather than an explicit recommendation the Basis column says so, and
    a "Does Not Meet" there means "someone changed this" - not "this is wrong".
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string]$Fabric,

    [pscredential]$Credential,

    [string]$CredentialName,

    [string]$OutputPath,

    [ValidateRange(1, 100000)]
    [int]$MaxDetailRowsPerCheck = 50,

    [switch]$IgnoreCertificateError,

    [switch]$Transcript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\modules\Richo.Common\Richo.Common.psd1') -Force

$ScriptVersion = '1.1.0'

# ---------------------------------------------------------------------------------------------
# Run state
# ---------------------------------------------------------------------------------------------

# Every row the audit produces, in the order the checks ran.
$script:Rows = New-Object System.Collections.Generic.List[object]

# ClassId -> the error text from the read that failed. A check whose class is in here reports
# Unknown rather than concluding "not configured" from an empty result, which is the difference
# between "there is no syslog destination" and "we could not tell".
$script:ReadFailures = @{}

# ClassId -> the managed objects returned, so a class read by several checks is fetched once.
$script:MoCache = @{}

$script:UcsHandle = $null
$script:FabricName = ''
$script:RunTimestampUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# Set once the fabric interconnect models are known. Checks that only apply to the 6400 family
# read this rather than re-deriving it.
$script:FabricFamily = 'Unknown'

# ---------------------------------------------------------------------------------------------
# Reading UCSM
# ---------------------------------------------------------------------------------------------

function Get-UcsBpProperty {
    <#
    .SYNOPSIS
        Reads a property from a managed object, returning a default when it is absent.

    .DESCRIPTION
        Two reasons this exists rather than a bare $mo.Prop.

        Set-StrictMode -Version Latest turns a missing property into a terminating error, and the
        property set of a UCSM managed object varies by UCSM release and by PowerTool version. A
        check that reaches for a property added in 4.2 must degrade to "Unknown" on a 4.0 domain,
        not take the whole run down.

    .PARAMETER InputObject
        The managed object.

    .PARAMETER Name
        Property name.

    .PARAMETER Default
        Returned when the object is null, the property is absent, or its value is null.

    .EXAMPLE
        $mode = Get-UcsBpProperty -InputObject $lanCloud -Name 'Mode' -Default '(not reported)'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name,

        [Parameter(Position = 2)]
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    if ($null -eq $property.Value) { return $Default }

    return $property.Value
}

function Test-UcsBpPropertyPresent {
    <#
    .SYNOPSIS
        True when a managed object actually carries the named property.

    .DESCRIPTION
        Distinguishes "the property is not in this schema version" from "the property is empty".
        The first is Unknown, the second is usually Does Not Meet, and conflating them produces
        confident findings about settings that were never read.

    .PARAMETER InputObject
        The managed object.

    .PARAMETER Name
        Property name.

    .EXAMPLE
        if (Test-UcsBpPropertyPresent -InputObject $fi -Name 'AdminEvacState') { ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
    )

    if ($null -eq $InputObject) { return $false }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Get-UcsBpMo {
    <#
    .SYNOPSIS
        Reads every managed object of one class from the connected domain, once per run.

    .DESCRIPTION
        Get-UcsManagedObject -ClassId is used in preference to the sixty-odd class-specific
        cmdlets. The class IDs are the XML API's own and are stable across PowerTool releases,
        whereas the cmdlet surface is not - a class-specific cmdlet that was renamed or that does
        not exist in the installed PowerTool would take out an otherwise good audit.

        A failed read is recorded in $script:ReadFailures and returns an empty array, so the
        caller can tell "nothing configured" apart from "could not read", and one unreadable class
        costs one section rather than the run.

        Results are cached because several checks read the same class.

    .PARAMETER ClassId
        UCSM XML API class ID, for example commNtpProvider.

    .EXAMPLE
        $ntp = Get-UcsBpMo -ClassId 'commNtpProvider'
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ClassId
    )

    if ($script:MoCache.ContainsKey($ClassId)) { return $script:MoCache[$ClassId] }

    $result = @()
    try {
        $result = @(Get-UcsManagedObject -Ucs $script:UcsHandle -ClassId $ClassId -ErrorAction Stop)
        Write-RichoLog "Read $($result.Count) object(s) of class '$ClassId'." -Level DEBUG
    }
    catch {
        $script:ReadFailures[$ClassId] = $_.Exception.Message
        Write-RichoLog "Could not read class '$ClassId': $($_.Exception.Message)" -Level DEBUG
        $result = @()
    }

    $script:MoCache[$ClassId] = $result
    return $result
}

function Test-UcsBpClassReadable {
    <#
    .SYNOPSIS
        True unless the read of this class failed.

    .PARAMETER ClassId
        UCSM XML API class ID.

    .EXAMPLE
        if (-not (Test-UcsBpClassReadable -ClassId 'commSnmp')) { ... report Unknown ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$ClassId
    )

    return (-not $script:ReadFailures.ContainsKey($ClassId))
}

function Get-UcsBpReadFailure {
    <#
    .SYNOPSIS
        The error text from a failed class read, or an empty string.

    .PARAMETER ClassId
        UCSM XML API class ID.

    .EXAMPLE
        $why = Get-UcsBpReadFailure -ClassId 'commSnmp'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$ClassId
    )

    if ($script:ReadFailures.ContainsKey($ClassId)) { return [string]$script:ReadFailures[$ClassId] }
    return ''
}

# ---------------------------------------------------------------------------------------------
# Producing rows
# ---------------------------------------------------------------------------------------------

function Test-UcsBpOwnerIsGlobal {
    <#
    .SYNOPSIS
        True when a managed object's PolicyOwner says UCS Central owns it, not this domain.

    .DESCRIPTION
        UCSM reports PolicyOwner as 'local' for a locally defined object, and as 'policy',
        'ucs-central' or 'pending-policy' for one resolved from UCS Central. The distinction
        decides where a finding has to be fixed: editing a globally owned object in UCS Manager is
        either refused outright or silently reverted at the next policy push, so a remediation
        that names the wrong console is a remediation that does not happen.

    .PARAMETER Owner
        The PolicyOwner value read from the object.

    .EXAMPLE
        if (Test-UcsBpOwnerIsGlobal -Owner $mo.PolicyOwner) { ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Owner
    )

    if ([string]::IsNullOrWhiteSpace($Owner)) { return $false }
    return ($Owner.Trim().ToLowerInvariant() -in @('policy', 'ucs-central', 'ucscentral', 'pending-policy'))
}

function ConvertTo-UcsBpDisplayValue {
    <#
    .SYNOPSIS
        Renders a property value as a single CSV-safe string.

    .DESCRIPTION
        Values arriving here are strings, numbers, arrays and the odd null. A CSV cell holding
        "System.Object[]" tells the reader nothing, and an empty cell is ambiguous between "empty
        string" and "not set", so both are made explicit.

    .PARAMETER Value
        The value to render.

    .EXAMPLE
        ConvertTo-UcsBpDisplayValue -Value $mo.AdminState
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) { return '(not set)' }

    if ($Value -is [array]) {
        $parts = @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($parts.Count -eq 0) { return '(none)' }
        return ($parts -join '; ')
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return '(not set)' }
    return $text.Trim()
}

function Add-UcsBpRow {
    <#
    .SYNOPSIS
        Records one audited setting.

    .DESCRIPTION
        The single place a result row is built, so every row in the CSV has the same shape and the
        same rules applied to it. Two of those rules matter:

          - Where the object is owned by UCS Central the remediation is prefixed to say so. The
            check does not have to remember; it cannot get it wrong by forgetting.
          - RecommendedValue is mandatory on a Does Not Meet row. The whole point of the CSV is
            that a failing row states what the value should be, and a blank there is a row that
            tells the operator nothing.

    .PARAMETER Category
        Audit section, e.g. 'LAN', 'Security', 'UCS Central'.

    .PARAMETER CheckId
        Stable identifier for the check, e.g. 'UCS-LAN-020'. Stable across runs so results can be
        diffed between audits and tracked to closure.

    .PARAMETER Setting
        Human-readable name of the setting, matching what the UCSM GUI calls it.

    .PARAMETER ObjectDn
        Distinguished name of the object the row is about, so a finding can be navigated to.

    .PARAMETER Owner
        The object's PolicyOwner, where it has one.

    .PARAMETER CurrentValue
        The value found.

    .PARAMETER RecommendedValue
        The value Cisco recommends, or the value that should be set.

    .PARAMETER Basis
        Where the recommendation comes from: Best Practice, Cisco Default, or Site Policy.

    .PARAMETER Result
        Meets, Does Not Meet, Review, Not Applicable, or Unknown.

    .PARAMETER Severity
        Critical, High, Medium, Low, or Info.

    .PARAMETER Remediation
        What to do about it, in the console where it can actually be done.

    .PARAMETER Reference
        The Cisco document the recommendation is taken from.

    .PARAMETER Detail
        Supporting evidence - counts, the objects involved, or why a value could not be read.

    .EXAMPLE
        Add-UcsBpRow -Category 'LAN' -CheckId 'UCS-LAN-001' -Setting 'Ethernet switching mode' `
            -CurrentValue 'switch' -RecommendedValue 'end-host' -Basis 'Best Practice' `
            -Result 'Does Not Meet' -Severity 'High'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Category,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CheckId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Setting,

        [AllowEmptyString()]
        [string]$ObjectDn = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Owner = '',

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        $CurrentValue,

        [AllowEmptyString()]
        [string]$RecommendedValue = '',

        [ValidateSet('Best Practice', 'Cisco Default', 'Site Policy')]
        [string]$Basis = 'Best Practice',

        [Parameter(Mandatory)]
        [ValidateSet('Meets', 'Does Not Meet', 'Review', 'Not Applicable', 'Unknown')]
        [string]$Result,

        [ValidateSet('Critical', 'High', 'Medium', 'Low', 'Info')]
        [string]$Severity = 'Medium',

        [AllowEmptyString()]
        [string]$Remediation = '',

        [AllowEmptyString()]
        [string]$Reference = '',

        [AllowEmptyString()]
        [string]$Detail = ''
    )

    if ($Result -eq 'Does Not Meet' -and [string]::IsNullOrWhiteSpace($RecommendedValue)) {
        throw "Check '$CheckId' reported Does Not Meet without a RecommendedValue. A failing row must state the value to set."
    }

    $ownerText = ''
    if (-not [string]::IsNullOrWhiteSpace($Owner)) { $ownerText = $Owner.Trim() }

    $remediationText = $Remediation
    if (Test-UcsBpOwnerIsGlobal -Owner $ownerText) {
        $prefix = 'Owned by UCS Central (PolicyOwner=' + $ownerText + ') - change it in UCS Central, not in UCS Manager.'
        if ([string]::IsNullOrWhiteSpace($remediationText)) { $remediationText = $prefix }
        else { $remediationText = $prefix + ' ' + $remediationText }
    }

    $row = [pscustomobject]@{
        Fabric           = $script:FabricName
        RunTimestampUtc  = $script:RunTimestampUtc
        ScriptVersion    = $ScriptVersion
        Category         = $Category
        CheckId          = $CheckId
        Setting          = $Setting
        ObjectDn         = $ObjectDn
        Owner            = if ($ownerText) { $ownerText } else { 'n/a' }
        CurrentValue     = ConvertTo-UcsBpDisplayValue -Value $CurrentValue
        RecommendedValue = $RecommendedValue
        Basis            = $Basis
        Result           = $Result
        Severity         = $Severity
        Remediation      = $remediationText
        Reference        = $Reference
        Detail           = $Detail
    }

    $script:Rows.Add($row)
}

function Add-UcsBpPropertyCheck {
    <#
    .SYNOPSIS
        Audits one property of one managed object against a set of acceptable values.

    .DESCRIPTION
        The workhorse behind most of the catalogue. It reads the property through
        Get-UcsBpProperty, and:

          - reports Unknown when the property is not in this schema version, naming it, rather
            than reporting a confident verdict on a value it never saw;
          - compares case-insensitively, because UCSM returns 'end-host' where the GUI shows
            'End Host' and the comparison should not depend on which one the check was written
            against;
          - takes the object's PolicyOwner automatically, so the UCS Central prefix lands on the
            remediation without every caller remembering.

    .PARAMETER Mo
        The managed object to read.

    .PARAMETER Property
        Property name on that object.

    .PARAMETER Expected
        Acceptable values. A match against any one of them is a pass.

    .PARAMETER Category
        Audit section.

    .PARAMETER CheckId
        Stable check identifier.

    .PARAMETER Setting
        Human-readable setting name.

    .PARAMETER RecommendedValue
        Text for the RecommendedValue column. Defaults to the acceptable values joined by ' or '.

    .PARAMETER Basis
        Where the recommendation comes from.

    .PARAMETER Severity
        Severity of a failure.

    .PARAMETER Remediation
        What to do about a failure.

    .PARAMETER Reference
        Cisco document the recommendation is taken from.

    .PARAMETER Detail
        Supporting evidence.

    .PARAMETER ObjectDn
        Override for the object's Dn. Defaults to the object's own Dn property.

    .EXAMPLE
        Add-UcsBpPropertyCheck -Mo $lanCloud -Property 'Mode' -Expected @('end-host') `
            -Category 'LAN' -CheckId 'UCS-LAN-001' -Setting 'Ethernet switching mode' `
            -Severity 'High'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        $Mo,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Property,

        [Parameter(Mandatory, Position = 2)]
        [AllowEmptyCollection()]
        [string[]]$Expected,

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$CheckId,

        [Parameter(Mandatory)]
        [string]$Setting,

        [string]$RecommendedValue = '',

        [ValidateSet('Best Practice', 'Cisco Default', 'Site Policy')]
        [string]$Basis = 'Best Practice',

        [ValidateSet('Critical', 'High', 'Medium', 'Low', 'Info')]
        [string]$Severity = 'Medium',

        [string]$Remediation = '',

        [string]$Reference = '',

        [string]$Detail = '',

        [string]$ObjectDn = ''
    )

    $recommendedText = $RecommendedValue
    if ([string]::IsNullOrWhiteSpace($recommendedText)) { $recommendedText = ($Expected -join ' or ') }

    $dn = $ObjectDn
    if ([string]::IsNullOrWhiteSpace($dn)) { $dn = [string](Get-UcsBpProperty -InputObject $Mo -Name 'Dn' -Default '') }

    $owner = [string](Get-UcsBpProperty -InputObject $Mo -Name 'PolicyOwner' -Default '')

    if ($null -eq $Mo) {
        Add-UcsBpRow -Category $Category -CheckId $CheckId -Setting $Setting -ObjectDn $dn -Owner $owner `
            -CurrentValue '(object not found)' -RecommendedValue $recommendedText -Basis $Basis `
            -Result 'Unknown' -Severity $Severity -Remediation $Remediation -Reference $Reference `
            -Detail 'The object this setting lives on was not returned by UCS Manager.'
        return
    }

    if (-not (Test-UcsBpPropertyPresent -InputObject $Mo -Name $Property)) {
        Add-UcsBpRow -Category $Category -CheckId $CheckId -Setting $Setting -ObjectDn $dn -Owner $owner `
            -CurrentValue '(property not reported)' -RecommendedValue $recommendedText -Basis $Basis `
            -Result 'Unknown' -Severity $Severity -Remediation $Remediation -Reference $Reference `
            -Detail "Property '$Property' is not present on this object in the connected UCSM/PowerTool version, so the setting could not be read."
        return
    }

    $actual = Get-UcsBpProperty -InputObject $Mo -Name $Property -Default ''
    $actualText = ConvertTo-UcsBpDisplayValue -Value $actual

    $matched = $false
    foreach ($candidate in $Expected) {
        if ([string]$actual -ieq $candidate) { $matched = $true; break }
    }

    $result = if ($matched) { 'Meets' } else { 'Does Not Meet' }

    Add-UcsBpRow -Category $Category -CheckId $CheckId -Setting $Setting -ObjectDn $dn -Owner $owner `
        -CurrentValue $actualText -RecommendedValue $recommendedText -Basis $Basis `
        -Result $result -Severity $Severity -Remediation $Remediation -Reference $Reference -Detail $Detail
}

function Add-UcsBpUnreadableClassRow {
    <#
    .SYNOPSIS
        Records that a class could not be read, so the settings it holds are reported as Unknown
        rather than passed over.

    .DESCRIPTION
        A check whose class failed to read has nothing to say about the setting. Saying nothing is
        the dangerous option: an absent row reads as "not applicable" to whoever reviews the CSV.
        This makes the gap explicit and carries the reason.

    .PARAMETER Category
        Audit section.

    .PARAMETER CheckId
        Stable check identifier.

    .PARAMETER Setting
        Human-readable setting name.

    .PARAMETER ClassId
        The class that could not be read.

    .PARAMETER RecommendedValue
        What the setting should be, for the operator checking it by hand.

    .PARAMETER Severity
        Severity the check would have carried.

    .PARAMETER Reference
        Cisco document the recommendation is taken from.

    .EXAMPLE
        Add-UcsBpUnreadableClassRow -Category 'Monitoring' -CheckId 'UCS-MON-020' `
            -Setting 'SNMP' -ClassId 'commSnmp' -RecommendedValue 'enabled'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$Setting,
        [Parameter(Mandatory)][string]$ClassId,
        [string]$RecommendedValue = '',
        [ValidateSet('Critical', 'High', 'Medium', 'Low', 'Info')][string]$Severity = 'Medium',
        [string]$Reference = ''
    )

    Add-UcsBpRow -Category $Category -CheckId $CheckId -Setting $Setting `
        -CurrentValue '(could not read)' -RecommendedValue $RecommendedValue -Basis 'Best Practice' `
        -Result 'Unknown' -Severity $Severity -Reference $Reference `
        -Remediation "Check this setting by hand in UCS Manager." `
        -Detail "Read of class '$ClassId' failed: $(Get-UcsBpReadFailure -ClassId $ClassId)"
}

function Add-UcsBpOffenderRows {
    <#
    .SYNOPSIS
        Emits one row per non-compliant object, capped, and says so when it caps.

    .DESCRIPTION
        A domain with two thousand service profiles all missing a host firmware package should not
        produce two thousand rows; but a CSV that quietly shows the first fifty reads as though
        there were only fifty. Every truncation is stated in the returned count and in the caller's
        aggregate row.

    .PARAMETER Offender
        The non-compliant objects.

    .PARAMETER Category
        Audit section.

    .PARAMETER CheckId
        Stable check identifier.

    .PARAMETER Setting
        Human-readable setting name.

    .PARAMETER CurrentValueScript
        Script block returning the CurrentValue text for one offender. Receives the object, and
        -CurrentValueArgument if one was supplied.

        Deliberately NOT a closure. GetNewClosure() rebinds a script block into a new dynamic
        module scope, and the functions this script defines - Get-UcsBpProperty among them - are
        not visible from there, so the block fails at call time with "term is not recognized" and
        takes its whole section with it. Anything the block needs from the caller's loop is passed
        in through -CurrentValueArgument instead.

    .PARAMETER CurrentValueArgument
        Optional second argument passed to -CurrentValueScript, for the loop variable a closure
        would otherwise have captured.

    .PARAMETER RecommendedValue
        What the value should be.

    .PARAMETER Basis
        Where the recommendation comes from.

    .PARAMETER Severity
        Severity of the failure.

    .PARAMETER Remediation
        What to do about it.

    .PARAMETER Reference
        Cisco document the recommendation is taken from.

    .EXAMPLE
        Add-UcsBpOffenderRows -Offender $bad -Category 'Server Policies' -CheckId 'UCS-SRV-011' `
            -Setting 'Service profile host firmware package' -RecommendedValue 'a host firmware package' `
            -CurrentValueScript { param($mo) 'none' }
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Offender,

        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$Setting,
        [Parameter(Mandatory)][scriptblock]$CurrentValueScript,
        [Parameter(Mandatory)][string]$RecommendedValue,

        [AllowNull()]
        $CurrentValueArgument = $null,

        [ValidateSet('Best Practice', 'Cisco Default', 'Site Policy')][string]$Basis = 'Best Practice',
        [ValidateSet('Critical', 'High', 'Medium', 'Low', 'Info')][string]$Severity = 'Medium',
        [string]$Remediation = '',
        [string]$Reference = ''
    )

    $emitted = 0
    foreach ($mo in $Offender) {
        if ($emitted -ge $MaxDetailRowsPerCheck) { break }

        Add-UcsBpRow -Category $Category -CheckId ($CheckId + '-D') -Setting $Setting `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $mo -Name 'Dn' -Default '')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $mo -Name 'PolicyOwner' -Default '')) `
            -CurrentValue (& $CurrentValueScript $mo $CurrentValueArgument) -RecommendedValue $RecommendedValue -Basis $Basis `
            -Result 'Does Not Meet' -Severity $Severity -Remediation $Remediation -Reference $Reference `
            -Detail 'Per-object detail for the aggregate check of the same number.'
        $emitted++
    }

    return $emitted
}

# ---------------------------------------------------------------------------------------------
# Checks - system, hardware, firmware
# ---------------------------------------------------------------------------------------------

function Get-UcsBpFabricFamily {
    <#
    .SYNOPSIS
        Derives the fabric interconnect family from the models reported by the domain.

    .DESCRIPTION
        Models look like UCS-FI-6332, UCS-FI-6454 or UCS-FI-64108. The first two digits of the
        model number give the family - 6200, 6300, 6400, 6500 - and that decides which of the
        hardware-specific checks apply. Both fabric interconnects are read; if they disagree the
        family is Mixed and the hardware-specific checks are reported Not Applicable rather than
        guessed at.

    .PARAMETER NetworkElement
        The networkElement objects for the domain.

    .EXAMPLE
        $family = (Get-UcsBpFabricFamily -NetworkElement $fis).Family
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyCollection()]
        [array]$NetworkElement
    )

    $models = @($NetworkElement | ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Model' -Default '') } | Where-Object { $_ })

    if ($models.Count -eq 0) {
        return [pscustomobject]@{ Family = 'Unknown'; Models = @(); Detail = 'No fabric interconnect model was reported.' }
    }

    $families = @(
        $models | ForEach-Object {
            if ($_ -match '(?i)FI-?(\d{2})\d') { "$($Matches[1])00" } else { $null }
        } | Where-Object { $_ } | Select-Object -Unique
    )

    if ($families.Count -eq 0) {
        return [pscustomobject]@{ Family = 'Unknown'; Models = $models; Detail = "No family could be derived from model(s): $($models -join ', ')" }
    }
    if ($families.Count -gt 1) {
        return [pscustomobject]@{ Family = 'Mixed'; Models = $models; Detail = "Fabric interconnects report different families: $($models -join ', ')" }
    }

    return [pscustomobject]@{ Family = $families[0]; Models = $models; Detail = "Model(s): $($models -join ', ')" }
}

function Test-UcsBpSystem {
    <#
    .SYNOPSIS
        Audits the domain identity, cluster high availability, and the fabric interconnects.

    .DESCRIPTION
        These are the rows that decide how much the rest of the audit is worth. A domain running
        on one fabric interconnect, or with high availability not ready, has a configuration
        problem that outranks any policy setting below it - and the FI family read here is what
        gates the 6400-specific checks.

    .EXAMPLE
        Test-UcsBpSystem
    #>
    [CmdletBinding()]
    param()

    $category = 'System'
    $reference = 'Cisco UCS Manager Getting Started Guide / Infrastructure Management Guide'

    $topSystem = @(Get-UcsBpMo -ClassId 'topSystem') | Select-Object -First 1
    $fis = @(Get-UcsBpMo -ClassId 'networkElement')

    # --- Cluster mode -------------------------------------------------------------------------
    # A production domain is a two-FI cluster. 'stand-alone' means either a single FI or a broken
    # cluster, and both are an availability finding before they are a configuration one.
    Add-UcsBpPropertyCheck -Mo $topSystem -Property 'Mode' -Expected @('cluster') `
        -Category $category -CheckId 'UCS-SYS-001' -Setting 'System mode (fabric interconnect clustering)' `
        -RecommendedValue 'cluster' -Basis 'Best Practice' -Severity 'Critical' -Reference $reference `
        -Remediation 'A production domain runs two clustered fabric interconnects. Investigate why the cluster is not formed before acting on any other finding.'

    # --- Domain name --------------------------------------------------------------------------
    $systemName = [string](Get-UcsBpProperty -InputObject $topSystem -Name 'Name' -Default '')
    $nameIsDefault = ([string]::IsNullOrWhiteSpace($systemName) -or $systemName -ieq 'ucs')
    Add-UcsBpRow -Category $category -CheckId 'UCS-SYS-002' -Setting 'System name' `
        -ObjectDn ([string](Get-UcsBpProperty -InputObject $topSystem -Name 'Dn' -Default 'sys')) `
        -CurrentValue $systemName -RecommendedValue 'A site-specific name identifying this domain, not the shipped default "ucs"' `
        -Basis 'Best Practice' -Result $(if ($nameIsDefault) { 'Does Not Meet' } else { 'Meets' }) `
        -Severity 'Low' -Reference $reference `
        -Remediation 'Admin > All > Rename UCS Domain. With UCS Central registered, a distinct name per domain is what keeps faults and inventory attributable.'

    # --- Fabric interconnect count ------------------------------------------------------------
    Add-UcsBpRow -Category $category -CheckId 'UCS-SYS-003' -Setting 'Fabric interconnect count' `
        -CurrentValue $fis.Count -RecommendedValue '2 (a redundant pair)' -Basis 'Best Practice' `
        -Result $(if ($fis.Count -eq 2) { 'Meets' } else { 'Does Not Meet' }) -Severity 'Critical' -Reference $reference `
        -Remediation 'A single fabric interconnect is a single point of failure for the whole domain.' `
        -Detail "Models: $(@($fis | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Model' -Default '?' }) -join ', ')"

    # --- Fabric interconnect family -----------------------------------------------------------
    $familyInfo = Get-UcsBpFabricFamily -NetworkElement $fis
    $script:FabricFamily = $familyInfo.Family
    Add-UcsBpRow -Category $category -CheckId 'UCS-SYS-004' -Setting 'Fabric interconnect family' `
        -CurrentValue $familyInfo.Family -RecommendedValue '6400 (this audit targets the 6400 family)' -Basis 'Site Policy' `
        -Result $(if ($familyInfo.Family -eq '6400') { 'Meets' } else { 'Review' }) -Severity 'Info' -Reference $reference `
        -Remediation 'The generic checks below apply to any UCS Manager domain. The 6400-specific ones are reported Not Applicable on other families.' `
        -Detail $familyInfo.Detail

    # --- Per fabric interconnect --------------------------------------------------------------
    foreach ($fi in $fis) {
        $fiDn = [string](Get-UcsBpProperty -InputObject $fi -Name 'Dn' -Default '')
        $fiId = [string](Get-UcsBpProperty -InputObject $fi -Name 'Id' -Default $fiDn)

        Add-UcsBpPropertyCheck -Mo $fi -Property 'Operability' -Expected @('operable') `
            -Category $category -CheckId "UCS-SYS-005" -Setting "Fabric interconnect $fiId operability" `
            -RecommendedValue 'operable' -Basis 'Best Practice' -Severity 'Critical' -Reference $reference `
            -Remediation 'Resolve the hardware fault on this fabric interconnect before making configuration changes.'

        # Fabric evacuation left on after a maintenance window is a live outage that looks like a
        # configuration setting, which is exactly why it belongs in a configuration audit.
        if (Test-UcsBpPropertyPresent -InputObject $fi -Name 'AdminEvacState') {
            Add-UcsBpPropertyCheck -Mo $fi -Property 'AdminEvacState' -Expected @('stopped', 'disabled', 'off') `
                -Category $category -CheckId 'UCS-SYS-006' -Setting "Fabric interconnect $fiId traffic evacuation" `
                -RecommendedValue 'stopped (evacuation is a maintenance state, not a running one)' -Basis 'Best Practice' `
                -Severity 'Critical' -Reference $reference `
                -Remediation 'Equipment > Fabric Interconnects > FI > Configure Evacuation. Evacuation left enabled blackholes all server traffic on this fabric.'
        }
        else {
            Add-UcsBpRow -Category $category -CheckId 'UCS-SYS-006' -Setting "Fabric interconnect $fiId traffic evacuation" `
                -ObjectDn $fiDn -CurrentValue '(property not reported)' -RecommendedValue 'stopped' -Basis 'Best Practice' `
                -Result 'Unknown' -Severity 'High' -Reference $reference `
                -Remediation 'Check Equipment > Fabric Interconnects > FI > Configure Evacuation by hand.' `
                -Detail 'AdminEvacState is not present on networkElement in this UCSM/PowerTool version.'
        }
    }

    # --- High availability --------------------------------------------------------------------
    $mgmtEntities = @(Get-UcsBpMo -ClassId 'mgmtEntity')
    if ($mgmtEntities.Count -eq 0) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-SYS-007' -Setting 'Cluster HA readiness' `
            -ClassId 'mgmtEntity' -RecommendedValue 'ready' -Severity 'Critical' -Reference $reference
    }
    foreach ($entity in $mgmtEntities) {
        $entityId = [string](Get-UcsBpProperty -InputObject $entity -Name 'Id' -Default '?')

        Add-UcsBpPropertyCheck -Mo $entity -Property 'HaReadiness' -Expected @('ready') `
            -Category $category -CheckId 'UCS-SYS-007' -Setting "Cluster HA readiness (fabric interconnect $entityId)" `
            -RecommendedValue 'ready' -Basis 'Best Practice' -Severity 'Critical' -Reference $reference `
            -Remediation 'HA not ready means a fabric interconnect failure would not fail over. Investigate before any change window.'

        $haReason = [string](Get-UcsBpProperty -InputObject $entity -Name 'HaFailureReason' -Default '')
        if ($haReason -and $haReason -inotmatch '^(none|)$') {
            Add-UcsBpRow -Category $category -CheckId 'UCS-SYS-008' -Setting "Cluster HA failure reason (fabric interconnect $entityId)" `
                -ObjectDn ([string](Get-UcsBpProperty -InputObject $entity -Name 'Dn' -Default '')) `
                -CurrentValue $haReason -RecommendedValue 'none' -Basis 'Best Practice' -Result 'Does Not Meet' `
                -Severity 'Critical' -Reference $reference -Remediation 'Resolve the reported HA failure reason.'
        }
    }

    # --- Outstanding faults -------------------------------------------------------------------
    # Not a setting, but an audit that reports a domain as compliant while it is sitting on
    # critical faults has answered the wrong question.
    $faults = @(Get-UcsBpMo -ClassId 'faultInst')
    if (Test-UcsBpClassReadable -ClassId 'faultInst') {
        foreach ($severityPair in @(
                @{ Name = 'critical'; CheckId = 'UCS-SYS-010'; RowSeverity = 'Critical' },
                @{ Name = 'major';    CheckId = 'UCS-SYS-011'; RowSeverity = 'High' })) {

            $matching = @($faults | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Severity' -Default '') -ieq $severityPair.Name })
            Add-UcsBpRow -Category $category -CheckId $severityPair.CheckId -Setting "Outstanding $($severityPair.Name) faults" `
                -CurrentValue $matching.Count -RecommendedValue '0' -Basis 'Best Practice' `
                -Result $(if ($matching.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) `
                -Severity $severityPair.RowSeverity -Reference 'Cisco UCS Manager System Monitoring Guide' `
                -Remediation 'Clear or explain outstanding faults before treating the domain as compliant.' `
                -Detail (@($matching | Select-Object -First 5 | ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Descr' -Default '') }) -join ' | ')
        }
    }
    else {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-SYS-010' -Setting 'Outstanding faults' `
            -ClassId 'faultInst' -RecommendedValue '0 critical, 0 major' -Severity 'High'
    }
}

function Test-UcsBpFirmware {
    <#
    .SYNOPSIS
        Audits firmware version consistency, the auto-sync policy, and host firmware packages.

    .DESCRIPTION
        Two fabric interconnects on different releases is the finding that matters here: it is
        both a supportability problem and a sign that an infrastructure upgrade did not finish.
        The host firmware package check is the other half - a service profile with no package
        takes whatever firmware the blade shipped with, which is how a domain ends up with servers
        no two of which are on the same version.

    .EXAMPLE
        Test-UcsBpFirmware
    #>
    [CmdletBinding()]
    param()

    $category = 'Firmware'
    $reference = 'Cisco UCS Manager Firmware Management Guide'

    # --- Running versions ---------------------------------------------------------------------
    $running = @(Get-UcsBpMo -ClassId 'firmwareRunning')
    if (-not (Test-UcsBpClassReadable -ClassId 'firmwareRunning')) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-FW-001' -Setting 'UCS Manager version consistency' `
            -ClassId 'firmwareRunning' -RecommendedValue 'both fabric interconnects on the same release' -Severity 'High' -Reference $reference
    }
    else {
        $systemVersions = @(
            $running |
                Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Type' -Default '') -ieq 'system' } |
                ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Version' -Default '') } |
                Where-Object { $_ } | Select-Object -Unique
        )

        if ($systemVersions.Count -eq 0) {
            Add-UcsBpRow -Category $category -CheckId 'UCS-FW-001' -Setting 'UCS Manager version consistency' `
                -CurrentValue '(no system firmware reported)' -RecommendedValue 'both fabric interconnects on the same release' `
                -Basis 'Best Practice' -Result 'Unknown' -Severity 'High' -Reference $reference `
                -Detail 'firmwareRunning returned no objects of type "system".'
        }
        else {
            Add-UcsBpRow -Category $category -CheckId 'UCS-FW-001' -Setting 'UCS Manager version consistency' `
                -CurrentValue ($systemVersions -join ', ') -RecommendedValue 'a single release across both fabric interconnects' `
                -Basis 'Best Practice' -Result $(if ($systemVersions.Count -eq 1) { 'Meets' } else { 'Does Not Meet' }) `
                -Severity 'High' -Reference $reference `
                -Remediation 'Mixed infrastructure firmware means an upgrade did not complete. Finish it before relying on the rest of this audit.'

            Add-UcsBpRow -Category $category -CheckId 'UCS-FW-002' -Setting 'Running UCS Manager release' `
                -CurrentValue ($systemVersions -join ', ') `
                -RecommendedValue 'A release that is current on the Cisco UCS 6400 Series suggested release list and not past end of support' `
                -Basis 'Site Policy' -Result 'Review' -Severity 'Medium' `
                -Reference 'https://www.cisco.com/c/en/us/support/servers-unified-computing/ucs-6400-series-fabric-interconnects/series.html' `
                -Remediation 'Compare against the Cisco recommended release for the 6400 series and the interoperability matrix for the attached storage and adapters. This script does not have network access to Cisco to check it for you.'
        }
    }

    # --- Firmware auto sync -------------------------------------------------------------------
    $autoSync = @(Get-UcsBpMo -ClassId 'firmwareAutoSyncPolicy') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $autoSync -Property 'SyncState' -Expected @('user-acknowledge') `
        -Category $category -CheckId 'UCS-FW-003' -Setting 'Firmware auto sync policy (newly discovered servers)' `
        -RecommendedValue 'User Acknowledge - so a newly discovered server does not upgrade itself unattended' `
        -Basis 'Best Practice' -Severity 'Medium' -Reference $reference `
        -Remediation 'Equipment > Policies > Global Policies > Firmware Auto Sync Server Policy.'

    # --- Host firmware packages ---------------------------------------------------------------
    $hostPacks = @(Get-UcsBpMo -ClassId 'firmwareComputeHostPack')
    Add-UcsBpRow -Category $category -CheckId 'UCS-FW-004' -Setting 'Host firmware packages defined' `
        -CurrentValue $hostPacks.Count -RecommendedValue 'At least one host firmware package, referenced by every service profile' `
        -Basis 'Best Practice' -Result $(if ($hostPacks.Count -ge 1) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'High' -Reference $reference `
        -Remediation 'Servers > Policies > Host Firmware Packages. Without one, blade firmware is whatever each server happened to ship with.' `
        -Detail (@($hostPacks | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')
}

# ---------------------------------------------------------------------------------------------
# Checks - time, name services, monitoring, logging
# ---------------------------------------------------------------------------------------------

function Test-UcsBpTimeAndNameServices {
    <#
    .SYNOPSIS
        Audits NTP, time zone, and DNS.

    .DESCRIPTION
        These carry more weight on a UCS Central-registered domain than they would standalone.
        Cisco's registration prerequisite is explicit: configure an NTP server and the correct time
        zone in both UCS Manager and UCS Central, because a domain whose clock has drifted fails
        registration and, once registered, produces faults and log correlation nobody can trust.

    .EXAMPLE
        Test-UcsBpTimeAndNameServices
    #>
    [CmdletBinding()]
    param()

    $category = 'Time and Name Services'
    $reference = 'Cisco UCS Manager Server Management Guide - Registering Cisco UCS Domains with Cisco UCS Central'

    # --- NTP --------------------------------------------------------------------------------
    $ntp = @(Get-UcsBpMo -ClassId 'commNtpProvider')
    if (-not (Test-UcsBpClassReadable -ClassId 'commNtpProvider')) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-TIME-001' -Setting 'NTP servers' `
            -ClassId 'commNtpProvider' -RecommendedValue 'at least 2' -Severity 'High' -Reference $reference
    }
    else {
        $ntpNames = @($ntp | ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '') } | Where-Object { $_ })
        $ntpResult = if ($ntpNames.Count -ge 2) { 'Meets' } elseif ($ntpNames.Count -eq 1) { 'Does Not Meet' } else { 'Does Not Meet' }

        Add-UcsBpRow -Category $category -CheckId 'UCS-TIME-001' -Setting 'NTP servers configured' `
            -ObjectDn 'sys/svc-ext/datetime-svc' `
            -CurrentValue $ntpNames.Count -RecommendedValue 'At least 2 NTP servers (3 preferred, so a single bad source can be outvoted)' `
            -Basis 'Best Practice' -Result $ntpResult -Severity 'High' -Reference $reference `
            -Remediation 'Admin > Time Zone Management > NTP Servers. Required for UCS Central registration and for any log correlation across domains.' `
            -Detail "Configured: $($ntpNames -join ', ')"
    }

    # --- Time zone ----------------------------------------------------------------------------
    $dateTime = @(Get-UcsBpMo -ClassId 'commDateTime') | Select-Object -First 1
    $timezone = [string](Get-UcsBpProperty -InputObject $dateTime -Name 'Timezone' -Default '')
    Add-UcsBpRow -Category $category -CheckId 'UCS-TIME-002' -Setting 'Time zone' `
        -ObjectDn ([string](Get-UcsBpProperty -InputObject $dateTime -Name 'Dn' -Default 'sys/svc-ext/datetime-svc')) `
        -Owner ([string](Get-UcsBpProperty -InputObject $dateTime -Name 'PolicyOwner' -Default '')) `
        -CurrentValue $timezone -RecommendedValue 'The site time zone, set and matching UCS Central' `
        -Basis 'Best Practice' -Result $(if ([string]::IsNullOrWhiteSpace($timezone)) { 'Does Not Meet' } else { 'Meets' }) `
        -Severity 'High' -Reference $reference `
        -Remediation 'Admin > Time Zone Management. An unset or mismatched time zone is a documented cause of UCS Central registration failure.'

    # --- DNS ----------------------------------------------------------------------------------
    $dns = @(Get-UcsBpMo -ClassId 'commDnsProvider')
    if (-not (Test-UcsBpClassReadable -ClassId 'commDnsProvider')) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-TIME-003' -Setting 'DNS servers' `
            -ClassId 'commDnsProvider' -RecommendedValue 'at least 2' -Severity 'Medium' -Reference $reference
    }
    else {
        $dnsNames = @($dns | ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '') } | Where-Object { $_ })
        Add-UcsBpRow -Category $category -CheckId 'UCS-TIME-003' -Setting 'DNS servers configured' `
            -ObjectDn 'sys/svc-ext/dns-svc' `
            -CurrentValue $dnsNames.Count -RecommendedValue 'At least 2 DNS servers' -Basis 'Best Practice' `
            -Result $(if ($dnsNames.Count -ge 2) { 'Meets' } else { 'Does Not Meet' }) -Severity 'Medium' -Reference $reference `
            -Remediation 'Admin > Communication Management > DNS Management. Call Home, syslog by name, and LDAP all depend on it.' `
            -Detail "Configured: $($dnsNames -join ', ')"
    }
}

function Test-UcsBpMonitoring {
    <#
    .SYNOPSIS
        Audits syslog, SNMP, Call Home, the SEL policy, core file export, fault policy, and the
        management interfaces monitoring policy.

    .DESCRIPTION
        This is the section Cisco's own field guidance calls out as the one most often left
        unconfigured: Call Home turned off, no SNMP traps going anywhere, SEL logs never collected,
        and no remote syslog. Each of those is silent until the day it is needed.

    .EXAMPLE
        Test-UcsBpMonitoring
    #>
    [CmdletBinding()]
    param()

    $category = 'Monitoring'
    $reference = 'Cisco UCS Manager System Monitoring Guide; Cisco UCS best practices and common recommendations for configuration'

    # --- Remote syslog ------------------------------------------------------------------------
    $syslogClients = @(Get-UcsBpMo -ClassId 'commSyslogClient')
    if (-not (Test-UcsBpClassReadable -ClassId 'commSyslogClient')) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-MON-001' -Setting 'Remote syslog destinations' `
            -ClassId 'commSyslogClient' -RecommendedValue 'at least 1 enabled, 2 preferred' -Severity 'High' -Reference $reference
    }
    else {
        $enabledClients = @(
            $syslogClients | Where-Object {
                ([string](Get-UcsBpProperty -InputObject $_ -Name 'AdminState' -Default '') -ieq 'enabled') -and
                (-not [string]::IsNullOrWhiteSpace([string](Get-UcsBpProperty -InputObject $_ -Name 'Hostname' -Default '')))
            }
        )

        Add-UcsBpRow -Category $category -CheckId 'UCS-MON-001' -Setting 'Remote syslog destinations enabled' `
            -ObjectDn 'sys/svc-ext/syslog' `
            -CurrentValue $enabledClients.Count -RecommendedValue 'At least 1 enabled remote destination with a hostname; 2 preferred' `
            -Basis 'Best Practice' -Result $(if ($enabledClients.Count -ge 1) { 'Meets' } else { 'Does Not Meet' }) `
            -Severity 'High' -Reference $reference `
            -Remediation 'Admin > Faults, Events and Audit Log > Syslog > Remote Destinations. System audit log output should go to a remote collector - the FI keeps very little locally.' `
            -Detail (@($syslogClients | ForEach-Object {
                        "$(Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?')=$(Get-UcsBpProperty -InputObject $_ -Name 'Hostname' -Default '(none)')/$(Get-UcsBpProperty -InputObject $_ -Name 'AdminState' -Default '?')"
                    }) -join ', ')

        foreach ($client in $enabledClients) {
            Add-UcsBpPropertyCheck -Mo $client -Property 'Severity' -Expected @('information', 'informational', 'notifications', 'debugging') `
                -Category $category -CheckId 'UCS-MON-002' `
                -Setting "Syslog destination '$(Get-UcsBpProperty -InputObject $client -Name 'Name' -Default '?')' severity" `
                -RecommendedValue 'information or more verbose, so faults and audit entries are actually forwarded' `
                -Basis 'Best Practice' -Severity 'Low' -Reference $reference `
                -Remediation 'A destination set to emergencies or critical forwards almost nothing and gives false confidence that logging is in place.'
        }
    }

    # --- SNMP ---------------------------------------------------------------------------------
    $snmp = @(Get-UcsBpMo -ClassId 'commSnmp') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $snmp -Property 'AdminState' -Expected @('enabled') `
        -Category $category -CheckId 'UCS-MON-010' -Setting 'SNMP service' `
        -RecommendedValue 'enabled, with traps to a monitoring station' -Basis 'Best Practice' -Severity 'High' -Reference $reference `
        -Remediation 'Admin > Communication Management > Communication Services > SNMP. Cisco field guidance lists absent SNMP as one of the most common gaps in a UCS build.'

    # The community string is only meaningful while v1/v2c is in use, but a default community is
    # worth reporting either way - it is readable by anyone who can reach the management network.
    $community = [string](Get-UcsBpProperty -InputObject $snmp -Name 'Community' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($community)) {
        $weakCommunity = ($community -ieq 'public' -or $community -ieq 'private')
        Add-UcsBpRow -Category $category -CheckId 'UCS-MON-011' -Setting 'SNMP community string' `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $snmp -Name 'Dn' -Default 'sys/svc-ext/snmp-svc')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $snmp -Name 'PolicyOwner' -Default '')) `
            -CurrentValue $(if ($weakCommunity) { $community } else { '(set, not a default value)' }) `
            -RecommendedValue 'Not "public" or "private"; prefer SNMPv3 and no v1/v2c community at all' `
            -Basis 'Best Practice' -Result $(if ($weakCommunity) { 'Does Not Meet' } else { 'Meets' }) `
            -Severity 'High' -Reference 'Cisco Compute UCS Manager Hardening Guide' `
            -Remediation 'Replace the default community, or move to SNMPv3 and remove the v1/v2c community entirely.'
    }

    $snmpUsers = @(Get-UcsBpMo -ClassId 'commSnmpUser')
    Add-UcsBpRow -Category $category -CheckId 'UCS-MON-012' -Setting 'SNMPv3 users' `
        -ObjectDn 'sys/svc-ext/snmp-svc' `
        -CurrentValue $snmpUsers.Count -RecommendedValue 'At least 1 SNMPv3 user using authPriv (authentication and encryption)' `
        -Basis 'Best Practice' -Result $(if ($snmpUsers.Count -ge 1) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'Medium' -Reference 'Cisco Compute UCS Manager Hardening Guide' `
        -Remediation 'Cisco recommends SNMPv3 with the authPriv method - v1 and v2c send the community string in clear text.' `
        -Detail (@($snmpUsers | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')

    foreach ($snmpUser in $snmpUsers) {
        Add-UcsBpPropertyCheck -Mo $snmpUser -Property 'UsePrivacyPassword' -Expected @('yes', 'true') `
            -Category $category -CheckId 'UCS-MON-013' `
            -Setting "SNMPv3 user '$(Get-UcsBpProperty -InputObject $snmpUser -Name 'Name' -Default '?')' privacy (encryption)" `
            -RecommendedValue 'yes - authPriv, not authNoPriv' -Basis 'Best Practice' -Severity 'Medium' `
            -Reference 'Cisco Compute UCS Manager Hardening Guide' `
            -Remediation 'Admin > Communication Management > Communication Services > SNMP Users.'
    }

    $snmpTraps = @(Get-UcsBpMo -ClassId 'commSnmpTrap')
    Add-UcsBpRow -Category $category -CheckId 'UCS-MON-014' -Setting 'SNMP trap destinations' `
        -ObjectDn 'sys/svc-ext/snmp-svc' `
        -CurrentValue $snmpTraps.Count -RecommendedValue 'At least 1 trap destination pointing at the monitoring station' `
        -Basis 'Best Practice' -Result $(if ($snmpTraps.Count -ge 1) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'Medium' -Reference $reference `
        -Remediation 'SNMP enabled with nowhere to send traps monitors nothing.' `
        -Detail (@($snmpTraps | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Hostname' -Default '?')/v$(Get-UcsBpProperty -InputObject $_ -Name 'Version' -Default '?')" }) -join ', ')

    # --- Call Home ----------------------------------------------------------------------------
    $callhome = @(Get-UcsBpMo -ClassId 'callhomeEp') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $callhome -Property 'AdminState' -Expected @('on', 'enabled') `
        -Category $category -CheckId 'UCS-MON-020' -Setting 'Call Home' `
        -RecommendedValue 'on - proactive email alerts, and the prerequisite for Smart Call Home and automatic TAC case creation' `
        -Basis 'Best Practice' -Severity 'High' -Reference $reference `
        -Remediation 'Admin > Communication Management > Call Home.'

    $callhomeSource = @(Get-UcsBpMo -ClassId 'callhomeSource') | Select-Object -First 1
    foreach ($field in @(
            @{ Property = 'Contact';    CheckId = 'UCS-MON-021'; Label = 'contact name' },
            @{ Property = 'Email';      CheckId = 'UCS-MON-022'; Label = 'contact email' },
            @{ Property = 'Phone';      CheckId = 'UCS-MON-023'; Label = 'contact phone' },
            @{ Property = 'Addr';       CheckId = 'UCS-MON-024'; Label = 'street address' },
            @{ Property = 'CustomerId'; CheckId = 'UCS-MON-025'; Label = 'customer ID' },
            @{ Property = 'ContractId'; CheckId = 'UCS-MON-026'; Label = 'contract ID' },
            @{ Property = 'SiteId';     CheckId = 'UCS-MON-027'; Label = 'site ID' })) {

        $value = [string](Get-UcsBpProperty -InputObject $callhomeSource -Name $field.Property -Default '')
        $present = -not [string]::IsNullOrWhiteSpace($value)
        Add-UcsBpRow -Category $category -CheckId $field.CheckId -Setting "Call Home $($field.Label)" `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $callhomeSource -Name 'Dn' -Default 'call-home')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $callhomeSource -Name 'PolicyOwner' -Default '')) `
            -CurrentValue $value -RecommendedValue 'Populated - Smart Call Home cannot raise a TAC case without it' `
            -Basis 'Best Practice' -Result $(if ($present) { 'Meets' } else { 'Does Not Meet' }) `
            -Severity 'Medium' -Reference $reference `
            -Remediation 'Admin > Communication Management > Call Home > General.'
    }

    $callhomeSmtp = @(Get-UcsBpMo -ClassId 'callhomeSmtp') | Select-Object -First 1
    $smtpHost = [string](Get-UcsBpProperty -InputObject $callhomeSmtp -Name 'Host' -Default '')
    Add-UcsBpRow -Category $category -CheckId 'UCS-MON-028' -Setting 'Call Home SMTP server' `
        -ObjectDn ([string](Get-UcsBpProperty -InputObject $callhomeSmtp -Name 'Dn' -Default 'call-home/smtp')) `
        -CurrentValue $smtpHost -RecommendedValue 'A reachable SMTP relay' -Basis 'Best Practice' `
        -Result $(if ([string]::IsNullOrWhiteSpace($smtpHost)) { 'Does Not Meet' } else { 'Meets' }) `
        -Severity 'Medium' -Reference $reference `
        -Remediation 'Call Home enabled with no SMTP server sends nothing.'

    $callhomeProfiles = @(Get-UcsBpMo -ClassId 'callhomeProfile')
    Add-UcsBpRow -Category $category -CheckId 'UCS-MON-029' -Setting 'Call Home profiles' `
        -ObjectDn 'call-home' `
        -CurrentValue $callhomeProfiles.Count -RecommendedValue 'At least one profile with recipients; a Smart Call Home (CiscoTAC-1) profile where entitled' `
        -Basis 'Best Practice' -Result $(if ($callhomeProfiles.Count -ge 1) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'Medium' -Reference $reference `
        -Remediation 'Admin > Communication Management > Call Home > Profiles.' `
        -Detail (@($callhomeProfiles | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?')/$(Get-UcsBpProperty -InputObject $_ -Name 'Level' -Default '?')" }) -join ', ')

    $inventory = @(Get-UcsBpMo -ClassId 'callhomePeriodicSystemInventory') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $inventory -Property 'AdminState' -Expected @('on', 'enabled') `
        -Category $category -CheckId 'UCS-MON-030' -Setting 'Call Home periodic system inventory' `
        -RecommendedValue 'on - keeps the Cisco-side inventory current for entitlement and TAC' -Basis 'Best Practice' `
        -Severity 'Low' -Reference $reference `
        -Remediation 'Admin > Communication Management > Call Home > System Inventory.'

    # --- SEL policy ---------------------------------------------------------------------------
    $selPolicies = @(Get-UcsBpMo -ClassId 'sysdebugMEpLogPolicy')
    if ($selPolicies.Count -eq 0) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-MON-040' -Setting 'SEL (system event log) backup policy' `
            -ClassId 'sysdebugMEpLogPolicy' -RecommendedValue 'backup configured to a remote host' -Severity 'Medium' -Reference $reference
    }
    foreach ($sel in $selPolicies) {
        $backupHost = [string](Get-UcsBpProperty -InputObject $sel -Name 'BackupHostname' -Default '')
        Add-UcsBpRow -Category $category -CheckId 'UCS-MON-040' `
            -Setting "SEL backup destination ($(Get-UcsBpProperty -InputObject $sel -Name 'Name' -Default 'default'))" `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $sel -Name 'Dn' -Default '')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $sel -Name 'PolicyOwner' -Default '')) `
            -CurrentValue $backupHost -RecommendedValue 'A remote host, so blade SEL logs are captured and stored centrally' `
            -Basis 'Best Practice' -Result $(if ([string]::IsNullOrWhiteSpace($backupHost)) { 'Does Not Meet' } else { 'Meets' }) `
            -Severity 'Medium' -Reference $reference `
            -Remediation 'Servers > Policies > root > SEL Policy. The SEL is what a hardware post-mortem is written from, and it is lost when the blade is reseated.'
    }

    # --- Core file export ----------------------------------------------------------------------
    $coreExport = @(Get-UcsBpMo -ClassId 'sysdebugAutoCoreFileExportTarget') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $coreExport -Property 'AdminState' -Expected @('enabled') `
        -Category $category -CheckId 'UCS-MON-041' -Setting 'Automatic core file export' `
        -RecommendedValue 'enabled, to a TFTP target - a core file that was never exported cannot be given to TAC' `
        -Basis 'Best Practice' -Severity 'Low' -Reference $reference `
        -Remediation 'Admin > Faults, Events and Audit Log > Settings > TFTP Core Exporter.'

    # --- Global fault policy --------------------------------------------------------------------
    $faultPolicy = @(Get-UcsBpMo -ClassId 'faultPolicy') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $faultPolicy -Property 'ClearAction' -Expected @('retain') `
        -Category $category -CheckId 'UCS-MON-050' -Setting 'Global fault policy - action on cleared fault' `
        -RecommendedValue 'retain (Cisco default) - a cleared fault stays visible for its retention interval' `
        -Basis 'Cisco Default' -Severity 'Low' -Reference $reference `
        -Remediation 'Admin > Faults, Events and Audit Log > Settings > Global Fault Policy. Set to delete, faults vanish the moment they clear and intermittent problems become invisible.'

    $retention = [string](Get-UcsBpProperty -InputObject $faultPolicy -Name 'RetentionInterval' -Default '')
    Add-UcsBpRow -Category $category -CheckId 'UCS-MON-051' -Setting 'Global fault policy - retention interval' `
        -ObjectDn ([string](Get-UcsBpProperty -InputObject $faultPolicy -Name 'Dn' -Default 'fault/policy')) `
        -Owner ([string](Get-UcsBpProperty -InputObject $faultPolicy -Name 'PolicyOwner' -Default '')) `
        -CurrentValue $retention -RecommendedValue 'Long enough to cover the gap between monitoring polls and a working day' `
        -Basis 'Site Policy' -Result 'Review' -Severity 'Info' -Reference $reference `
        -Remediation 'Confirm the retention interval matches how often the monitoring system actually collects faults.'

    # --- Management interfaces monitoring policy ------------------------------------------------
    $ifMon = @(Get-UcsBpMo -ClassId 'mgmtIfMonPolicy') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $ifMon -Property 'AdminState' -Expected @('enabled') `
        -Category $category -CheckId 'UCS-MON-060' -Setting 'Management interfaces monitoring policy' `
        -RecommendedValue 'enabled - detects loss of the fabric interconnect management port and can fail the cluster over' `
        -Basis 'Best Practice' -Severity 'Medium' -Reference $reference `
        -Remediation 'Admin > Communication Management > Management Interfaces > Management Interfaces Monitoring Policy. Disabled, a dead management port on the primary is not noticed until someone tries to log in.'
}

# ---------------------------------------------------------------------------------------------
# Checks - communication services, authentication, backup
# ---------------------------------------------------------------------------------------------

function Test-UcsBpSecurity {
    <#
    .SYNOPSIS
        Audits the management protocols exposed by the fabric interconnects.

    .DESCRIPTION
        Cisco's hardening guidance for UCS is short and specific: unsecured protocols are disabled
        by default, HTTP redirects to HTTPS, and the shipped self-signed keyring should be replaced.
        Every one of those defaults can be turned off by an operator working around a browser
        warning, which is exactly the change this section is looking for.

    .EXAMPLE
        Test-UcsBpSecurity
    #>
    [CmdletBinding()]
    param()

    $category = 'Security'
    $reference = 'Cisco Compute UCS Manager Hardening Guide'

    # --- Telnet -------------------------------------------------------------------------------
    $telnet = @(Get-UcsBpMo -ClassId 'commTelnet') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $telnet -Property 'AdminState' -Expected @('disabled') `
        -Category $category -CheckId 'UCS-SEC-001' -Setting 'Telnet' `
        -RecommendedValue 'disabled (Cisco default) - telnet carries credentials in clear text' `
        -Basis 'Best Practice' -Severity 'High' -Reference $reference `
        -Remediation 'Admin > Communication Management > Communication Services > Telnet.'

    # --- HTTP redirect ------------------------------------------------------------------------
    $http = @(Get-UcsBpMo -ClassId 'commHttp') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $http -Property 'RedirectState' -Expected @('enabled') `
        -Category $category -CheckId 'UCS-SEC-002' -Setting 'HTTP to HTTPS redirect' `
        -RecommendedValue 'enabled (Cisco default) - HTTP requests are redirected to HTTPS' `
        -Basis 'Best Practice' -Severity 'High' -Reference $reference `
        -Remediation 'Admin > Communication Management > Communication Services > HTTP.'

    # --- HTTPS --------------------------------------------------------------------------------
    $https = @(Get-UcsBpMo -ClassId 'commHttps') | Select-Object -First 1

    Add-UcsBpPropertyCheck -Mo $https -Property 'AdminState' -Expected @('enabled') `
        -Category $category -CheckId 'UCS-SEC-003' -Setting 'HTTPS' `
        -RecommendedValue 'enabled' -Basis 'Best Practice' -Severity 'Critical' -Reference $reference `
        -Remediation 'HTTPS disabled leaves the GUI and XML API reachable only over HTTP, in clear text.'

    if (Test-UcsBpPropertyPresent -InputObject $https -Name 'CipherSuiteMode') {
        Add-UcsBpPropertyCheck -Mo $https -Property 'CipherSuiteMode' -Expected @('high-strength') `
            -Category $category -CheckId 'UCS-SEC-004' -Setting 'HTTPS cipher suite mode' `
            -RecommendedValue 'high-strength' -Basis 'Best Practice' -Severity 'Medium' -Reference $reference `
            -Remediation 'Admin > Communication Management > Communication Services > HTTPS > Cipher Suite Mode.'
    }

    $keyRing = [string](Get-UcsBpProperty -InputObject $https -Name 'KeyRing' -Default '')
    $keyRingIsDefault = ($keyRing -ieq 'default' -or [string]::IsNullOrWhiteSpace($keyRing))
    Add-UcsBpRow -Category $category -CheckId 'UCS-SEC-005' -Setting 'HTTPS key ring (certificate)' `
        -ObjectDn ([string](Get-UcsBpProperty -InputObject $https -Name 'Dn' -Default 'sys/svc-ext/https-svc')) `
        -Owner ([string](Get-UcsBpProperty -InputObject $https -Name 'PolicyOwner' -Default '')) `
        -CurrentValue $keyRing -RecommendedValue 'A key ring holding a certificate signed by the site CA, not the shipped self-signed "default"' `
        -Basis 'Best Practice' -Result $(if ($keyRingIsDefault) { 'Does Not Meet' } else { 'Meets' }) `
        -Severity 'Medium' -Reference $reference `
        -Remediation 'Admin > Key Management > Key Ring, then select it under Communication Services > HTTPS. The self-signed default trains operators to click through certificate warnings.'

    # --- Session limits -------------------------------------------------------------------------
    $webLimits = @(Get-UcsBpMo -ClassId 'commWebSvcLimits') | Select-Object -First 1
    if ($null -ne $webLimits) {
        Add-UcsBpRow -Category $category -CheckId 'UCS-SEC-006' -Setting 'Web session limits' `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $webLimits -Name 'Dn' -Default '')) `
            -CurrentValue "per user: $(Get-UcsBpProperty -InputObject $webLimits -Name 'SessionsPerUser' -Default '?'), total: $(Get-UcsBpProperty -InputObject $webLimits -Name 'TotalSessions' -Default '?')" `
            -RecommendedValue 'Bounded to what the operations team actually needs' -Basis 'Site Policy' -Result 'Review' `
            -Severity 'Info' -Reference $reference `
            -Remediation 'Admin > Communication Management > Communication Services > Web Session Limits.'
    }

    # --- CIMC web service -----------------------------------------------------------------------
    $cimcWeb = @(Get-UcsBpMo -ClassId 'commCimcWebService') | Select-Object -First 1
    if ($null -ne $cimcWeb) {
        Add-UcsBpPropertyCheck -Mo $cimcWeb -Property 'AdminState' -Expected @('enabled') `
            -Category $category -CheckId 'UCS-SEC-007' -Setting 'CIMC web service' `
            -RecommendedValue 'enabled (Cisco default) - required for KVM and vMedia' -Basis 'Cisco Default' `
            -Severity 'Low' -Reference $reference `
            -Remediation 'Admin > Communication Management > Communication Services > CIMC Web Service.'
    }
}

function Test-UcsBpAuthentication {
    <#
    .SYNOPSIS
        Audits password policy, authentication realms, and remote authentication providers.

    .DESCRIPTION
        The one check here worth more than the rest is the console realm. Cisco's guidance is to
        leave console authentication local so that a domain stays reachable when the LDAP or RADIUS
        servers are not - a domain with both the default and the console realm pointed at a remote
        provider locks its own administrators out the moment that provider is unreachable.

    .EXAMPLE
        Test-UcsBpAuthentication
    #>
    [CmdletBinding()]
    param()

    $category = 'Authentication'
    $reference = 'Cisco UCS Manager Administration Management Guide - Password Management; Cisco Compute UCS Manager Hardening Guide'

    # --- Password strength ---------------------------------------------------------------------
    $userEp = @(Get-UcsBpMo -ClassId 'aaaUserEp') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $userEp -Property 'PwdStrengthCheck' -Expected @('yes', 'true', 'enabled') `
        -Category $category -CheckId 'UCS-AUTH-001' -Setting 'Password strength check' `
        -RecommendedValue 'yes (Cisco default, enabled on all management modes)' -Basis 'Best Practice' `
        -Severity 'High' -Reference $reference `
        -Remediation 'Admin > User Management > User Services > Password Strength Check. Disabled, the 8 character minimum and dictionary check stop applying to new local accounts.'

    # --- Password profile ------------------------------------------------------------------------
    $pwdProfile = @(Get-UcsBpMo -ClassId 'aaaPwdProfile') | Select-Object -First 1
    if ($null -ne $pwdProfile) {
        $historyCount = [string](Get-UcsBpProperty -InputObject $pwdProfile -Name 'HistoryCount' -Default '')
        Add-UcsBpRow -Category $category -CheckId 'UCS-AUTH-002' -Setting 'Password history count' `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $pwdProfile -Name 'Dn' -Default '')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $pwdProfile -Name 'PolicyOwner' -Default '')) `
            -CurrentValue $historyCount -RecommendedValue 'Whatever the site password standard requires; 0 disables reuse prevention entirely' `
            -Basis 'Site Policy' -Result 'Review' -Severity 'Low' -Reference $reference `
            -Remediation 'Admin > User Management > User Services > Password Profile.'

        Add-UcsBpRow -Category $category -CheckId 'UCS-AUTH-003' -Setting 'Password change interval' `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $pwdProfile -Name 'Dn' -Default '')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $pwdProfile -Name 'PolicyOwner' -Default '')) `
            -CurrentValue "interval: $(Get-UcsBpProperty -InputObject $pwdProfile -Name 'ChangeInterval' -Default '?'), changes allowed: $(Get-UcsBpProperty -InputObject $pwdProfile -Name 'ChangeCount' -Default '?')" `
            -RecommendedValue 'As required by the site password standard' -Basis 'Site Policy' -Result 'Review' `
            -Severity 'Info' -Reference $reference `
            -Remediation 'Admin > User Management > User Services > Password Profile.'
    }
    else {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-AUTH-002' -Setting 'Password profile' `
            -ClassId 'aaaPwdProfile' -RecommendedValue 'As required by the site password standard' -Severity 'Low' -Reference $reference
    }

    # --- Authentication realms --------------------------------------------------------------------
    $defaultAuth = @(Get-UcsBpMo -ClassId 'aaaDefaultAuth') | Select-Object -First 1
    $defaultRealm = [string](Get-UcsBpProperty -InputObject $defaultAuth -Name 'Realm' -Default '')
    $defaultIsRemote = ($defaultRealm -and $defaultRealm -inotmatch '^(local|none)$')
    Add-UcsBpRow -Category $category -CheckId 'UCS-AUTH-010' -Setting 'Default authentication realm' `
        -ObjectDn ([string](Get-UcsBpProperty -InputObject $defaultAuth -Name 'Dn' -Default '')) `
        -Owner ([string](Get-UcsBpProperty -InputObject $defaultAuth -Name 'PolicyOwner' -Default '')) `
        -CurrentValue $defaultRealm -RecommendedValue 'A remote realm (ldap, radius or tacacs) so accounts are managed centrally and revoked centrally' `
        -Basis 'Best Practice' -Result $(if ($defaultIsRemote) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'Medium' -Reference $reference `
        -Remediation 'Admin > User Management > Authentication > Native Authentication. Local-only accounts survive the departure of the person they belong to.'

    $consoleAuth = @(Get-UcsBpMo -ClassId 'aaaConsoleAuth') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $consoleAuth -Property 'Realm' -Expected @('local') `
        -Category $category -CheckId 'UCS-AUTH-011' -Setting 'Console authentication realm' `
        -RecommendedValue 'local - keeps console access working when the remote authentication servers are unreachable' `
        -Basis 'Best Practice' -Severity 'High' -Reference $reference `
        -Remediation 'Admin > User Management > Authentication > Native Authentication > Console Authentication. This is the way back in when LDAP is down.'

    # --- Remote providers ---------------------------------------------------------------------
    foreach ($providerSet in @(
            @{ ClassId = 'aaaLdapProvider';       Realm = 'ldap';   CheckId = 'UCS-AUTH-012'; Label = 'LDAP' },
            @{ ClassId = 'aaaRadiusProvider';     Realm = 'radius'; CheckId = 'UCS-AUTH-013'; Label = 'RADIUS' },
            @{ ClassId = 'aaaTacacsPlusProvider'; Realm = 'tacacs'; CheckId = 'UCS-AUTH-014'; Label = 'TACACS+' })) {

        $providers = @(Get-UcsBpMo -ClassId $providerSet.ClassId)
        if ($providers.Count -eq 0 -and $defaultRealm -inotmatch $providerSet.Realm) { continue }

        Add-UcsBpRow -Category $category -CheckId $providerSet.CheckId -Setting "$($providerSet.Label) providers configured" `
            -CurrentValue $providers.Count -RecommendedValue 'At least 2, so the loss of one authentication server does not lock the domain out' `
            -Basis 'Best Practice' -Result $(if ($providers.Count -ge 2) { 'Meets' } else { 'Does Not Meet' }) `
            -Severity $(if ($defaultRealm -imatch $providerSet.Realm) { 'High' } else { 'Low' }) -Reference $reference `
            -Remediation "Admin > User Management > $($providerSet.Label) > Providers." `
            -Detail (@($providers | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')
    }

    # --- Local accounts -------------------------------------------------------------------------
    $localUsers = @(Get-UcsBpMo -ClassId 'aaaUser')
    $nonAdminLocals = @($localUsers | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '') -inotmatch '^admin$' })
    Add-UcsBpRow -Category $category -CheckId 'UCS-AUTH-020' -Setting 'Local user accounts' `
        -CurrentValue $localUsers.Count -RecommendedValue 'The built-in admin plus only the local break-glass accounts the site has agreed to' `
        -Basis 'Site Policy' -Result 'Review' -Severity 'Low' -Reference $reference `
        -Remediation 'Admin > User Management > User Services > Locally Authenticated Users. Each local account is one that central account revocation does not reach.' `
        -Detail "Non-admin local accounts: $(@($nonAdminLocals | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')"
}

function Test-UcsBpBackup {
    <#
    .SYNOPSIS
        Audits the scheduled full state backup and all-configuration export policies.

    .DESCRIPTION
        Both are disabled by default, which is the whole reason this check exists. The full state
        backup is what a fabric interconnect is rebuilt from after a hardware replacement; the
        all-configuration export is the readable XML that a single deleted policy is restored from.
        A domain with neither has no route back from a configuration mistake.

    .EXAMPLE
        Test-UcsBpBackup
    #>
    [CmdletBinding()]
    param()

    $category = 'Backup'
    $reference = 'Cisco UCS Manager Administration Management Guide - Backup and Restore'

    foreach ($policy in @(
            @{ ClassId = 'mgmtBackupPolicy';    CheckId = 'UCS-BAK-001'; Label = 'Full state backup policy';        Why = 'This is what a replaced fabric interconnect is restored from.' },
            @{ ClassId = 'mgmtCfgExportPolicy'; CheckId = 'UCS-BAK-002'; Label = 'All configuration export policy'; Why = 'This is the readable export a single deleted policy is recovered from.' })) {

        $mo = @(Get-UcsBpMo -ClassId $policy.ClassId) | Select-Object -First 1

        if ($null -eq $mo) {
            Add-UcsBpUnreadableClassRow -Category $category -CheckId $policy.CheckId -Setting $policy.Label `
                -ClassId $policy.ClassId -RecommendedValue 'enabled, on a schedule, to a remote host' -Severity 'High' -Reference $reference
            continue
        }

        Add-UcsBpPropertyCheck -Mo $mo -Property 'AdminState' -Expected @('enable', 'enabled') `
            -Category $category -CheckId $policy.CheckId -Setting $policy.Label `
            -RecommendedValue 'enabled - scheduled backup policies are disabled by default' -Basis 'Best Practice' `
            -Severity 'High' -Reference $reference `
            -Remediation "Admin > All > Policy Backup and Export. $($policy.Why)"

        $backupHost = [string](Get-UcsBpProperty -InputObject $mo -Name 'Host' -Default '')
        Add-UcsBpRow -Category $category -CheckId ($policy.CheckId + '-HOST') -Setting "$($policy.Label) - remote host" `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $mo -Name 'Dn' -Default '')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $mo -Name 'PolicyOwner' -Default '')) `
            -CurrentValue $backupHost -RecommendedValue 'A remote host off this domain - a backup stored on the fabric interconnect is lost with it' `
            -Basis 'Best Practice' -Result $(if ([string]::IsNullOrWhiteSpace($backupHost)) { 'Does Not Meet' } else { 'Meets' }) `
            -Severity 'High' -Reference $reference `
            -Remediation 'Admin > All > Policy Backup and Export.'

        Add-UcsBpRow -Category $category -CheckId ($policy.CheckId + '-SCHED') -Setting "$($policy.Label) - schedule" `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $mo -Name 'Dn' -Default '')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $mo -Name 'PolicyOwner' -Default '')) `
            -CurrentValue ([string](Get-UcsBpProperty -InputObject $mo -Name 'Schedule' -Default '')) `
            -RecommendedValue 'daily, weekly or bi-weekly, matched to how often this domain actually changes' `
            -Basis 'Site Policy' -Result 'Review' -Severity 'Medium' -Reference $reference `
            -Remediation 'Admin > All > Policy Backup and Export.'
    }
}

# ---------------------------------------------------------------------------------------------
# Checks - equipment policies
# ---------------------------------------------------------------------------------------------

function Test-UcsBpEquipment {
    <#
    .SYNOPSIS
        Audits the global equipment policies: chassis discovery, power, and the information policy.

    .DESCRIPTION
        Two of these are Cisco recommendations with real consequences. Link Grouping Preference set
        to Port Channel puts every IOM-to-fabric-interconnect link into a fabric port channel, so
        blade traffic is hashed across all of them instead of being pinned to one; and the power
        redundancy setting is what decides whether the loss of a supply, or of a whole grid feed,
        takes chassis with it.

    .EXAMPLE
        Test-UcsBpEquipment
    #>
    [CmdletBinding()]
    param()

    $category = 'Equipment'
    $reference = 'Cisco UCS Manager Infrastructure Management Guide - Equipment Policies'

    # --- Chassis/FEX discovery policy -----------------------------------------------------------
    $chassisDisc = @(Get-UcsBpMo -ClassId 'computeChassisDiscPolicy') | Select-Object -First 1

    Add-UcsBpPropertyCheck -Mo $chassisDisc -Property 'LinkAggregationPref' -Expected @('port-channel') `
        -Category $category -CheckId 'UCS-EQP-001' -Setting 'Chassis/FEX discovery policy - link grouping preference' `
        -RecommendedValue 'port-channel - groups all IOM to fabric interconnect links into a fabric port channel' `
        -Basis 'Best Practice' -Severity 'High' -Reference $reference `
        -Remediation 'Equipment > Policies > Global Policies > Chassis/FEX Discovery Policy. Set to None, each blade is pinned to a single IOM link and the others sit idle. Changing this afterwards requires an IOM acknowledgement - acknowledge the IO modules one at a time, not the chassis.'

    $discAction = [string](Get-UcsBpProperty -InputObject $chassisDisc -Name 'Action' -Default '')
    Add-UcsBpRow -Category $category -CheckId 'UCS-EQP-002' -Setting 'Chassis/FEX discovery policy - link count' `
        -ObjectDn ([string](Get-UcsBpProperty -InputObject $chassisDisc -Name 'Dn' -Default '')) `
        -Owner ([string](Get-UcsBpProperty -InputObject $chassisDisc -Name 'PolicyOwner' -Default '')) `
        -CurrentValue $discAction -RecommendedValue 'The minimum number of IOM links actually cabled on any chassis in this domain' `
        -Basis 'Best Practice' -Result 'Review' -Severity 'Medium' -Reference $reference `
        -Remediation 'Equipment > Policies > Global Policies. UCS Manager cannot discover a chassis wired for fewer links than this policy requires, so where chassis are cabled differently Cisco recommends setting it to the smallest link count in the domain.'

    # --- Rack server discovery ------------------------------------------------------------------
    $serverDisc = @(Get-UcsBpMo -ClassId 'computeServerDiscPolicy') | Select-Object -First 1
    if ($null -ne $serverDisc) {
        Add-UcsBpRow -Category $category -CheckId 'UCS-EQP-003' -Setting 'Rack server discovery policy - action' `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $serverDisc -Name 'Dn' -Default '')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $serverDisc -Name 'PolicyOwner' -Default '')) `
            -CurrentValue ([string](Get-UcsBpProperty -InputObject $serverDisc -Name 'Action' -Default '')) `
            -RecommendedValue 'immediate (Cisco default), or user-acknowledged where new rack servers must not be discovered unattended' `
            -Basis 'Cisco Default' -Result 'Review' -Severity 'Low' -Reference $reference `
            -Remediation 'Equipment > Policies > Global Policies > Rack Server Discovery Policy.'

        # A scrub policy attached to discovery runs against every newly discovered server. If that
        # policy scrubs disks, re-discovering an existing server destroys its data.
        $discScrub = [string](Get-UcsBpProperty -InputObject $serverDisc -Name 'ScrubPolicyName' -Default '')
        Add-UcsBpRow -Category $category -CheckId 'UCS-EQP-004' -Setting 'Rack server discovery policy - scrub policy' `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $serverDisc -Name 'Dn' -Default '')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $serverDisc -Name 'PolicyOwner' -Default '')) `
            -CurrentValue $discScrub -RecommendedValue 'None, or a scrub policy that is verified not to scrub disks' `
            -Basis 'Best Practice' -Result $(if ([string]::IsNullOrWhiteSpace($discScrub)) { 'Meets' } else { 'Review' }) `
            -Severity 'High' -Reference $reference `
            -Remediation 'A disk-scrubbing policy bound to discovery wipes any server that is re-discovered. Confirm what this policy does before leaving it attached.'
    }

    # --- Rack management connection policy --------------------------------------------------------
    $serverMgmt = @(Get-UcsBpMo -ClassId 'computeServerMgmtPolicy') | Select-Object -First 1
    if ($null -ne $serverMgmt) {
        Add-UcsBpRow -Category $category -CheckId 'UCS-EQP-005' -Setting 'Rack management connection policy' `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $serverMgmt -Name 'Dn' -Default '')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $serverMgmt -Name 'PolicyOwner' -Default '')) `
            -CurrentValue ([string](Get-UcsBpProperty -InputObject $serverMgmt -Name 'Action' -Default '')) `
            -RecommendedValue 'auto-acknowledged (Cisco default)' -Basis 'Cisco Default' -Result 'Review' `
            -Severity 'Info' -Reference $reference `
            -Remediation 'Equipment > Policies > Global Policies > Rack Management Connection Policy.'
    }

    # --- Power redundancy -------------------------------------------------------------------------
    $psuPolicy = @(Get-UcsBpMo -ClassId 'computePsuPolicy') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $psuPolicy -Property 'Redundancy' -Expected @('grid', 'n-plus-1') `
        -Category $category -CheckId 'UCS-EQP-010' -Setting 'Power policy - PSU redundancy' `
        -RecommendedValue 'grid where the chassis are fed from two independent supplies, otherwise n-plus-1. non-redund tolerates no supply failure at all' `
        -Basis 'Best Practice' -Severity 'High' -Reference $reference `
        -Remediation 'Equipment > Policies > Global Policies > Power Policy.'

    # --- Global power allocation -------------------------------------------------------------------
    $powerMgmt = @(Get-UcsBpMo -ClassId 'computePowerMgmtPolicy') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $powerMgmt -Property 'Style' -Expected @('intelligent-policy-driven') `
        -Category $category -CheckId 'UCS-EQP-011' -Setting 'Global power allocation policy' `
        -RecommendedValue 'intelligent-policy-driven (Policy Driven Chassis Group Cap) - power is allocated from the power control policy rather than capped per blade by hand' `
        -Basis 'Best Practice' -Severity 'Medium' -Reference $reference `
        -Remediation 'Equipment > Policies > Global Policies > Global Power Allocation Policy. Manual per-blade capping does not adjust as blades are added and is a common cause of blades that will not power on.'

    # --- Information policy -------------------------------------------------------------------------
    $infoPolicy = @(Get-UcsBpMo -ClassId 'topInfoPolicy') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $infoPolicy -Property 'State' -Expected @('enabled') `
        -Category $category -CheckId 'UCS-EQP-012' -Setting 'Information policy (uplink neighbour discovery)' `
        -RecommendedValue 'enabled - required to see which upstream switches the fabric interconnects are cabled to' `
        -Basis 'Best Practice' -Severity 'Low' -Reference $reference `
        -Remediation 'Equipment > Policies > Global Policies > Info Policy. Disabled, the LAN Uplinks Manager shows no neighbours and cabling has to be traced by hand.'

    # --- Chassis inventory ----------------------------------------------------------------------
    $chassis = @(Get-UcsBpMo -ClassId 'equipmentChassis')
    if ($chassis.Count -gt 0) {
        $inoperableChassis = @($chassis | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Operability' -Default '') -inotmatch '^(operable|)$' })
        Add-UcsBpRow -Category $category -CheckId 'UCS-EQP-020' -Setting 'Chassis operability' `
            -CurrentValue "$($chassis.Count) chassis, $($inoperableChassis.Count) not operable" `
            -RecommendedValue 'All chassis operable' -Basis 'Best Practice' `
            -Result $(if ($inoperableChassis.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) `
            -Severity 'High' -Reference $reference `
            -Remediation 'Resolve chassis hardware faults before treating the domain as compliant.' `
            -Detail (@($inoperableChassis | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Dn' -Default '?')=$(Get-UcsBpProperty -InputObject $_ -Name 'Operability' -Default '?')" }) -join ', ')
    }
}

# ---------------------------------------------------------------------------------------------
# Checks - LAN, QoS
# ---------------------------------------------------------------------------------------------

function Test-UcsBpLan {
    <#
    .SYNOPSIS
        Audits the Ethernet side: switching mode, uplinks, server ports, VLANs, and network
        control policies.

    .DESCRIPTION
        The uplink checks are the ones Cisco states plainly: use port channels for connectivity to
        upstream resources, so that pinned server interfaces take advantage of the port channel
        hashing algorithm. A standalone uplink is a hard-pinned failure domain - every vNIC pinned
        to it loses its path when that one link goes down, rather than rehashing across the bundle.

        Fabric symmetry is checked for the same reason: A and B are supposed to be interchangeable,
        and a domain with four uplinks on A and two on B halves its bandwidth on failover without
        telling anyone.

    .EXAMPLE
        Test-UcsBpLan
    #>
    [CmdletBinding()]
    param()

    $category = 'LAN'
    $reference = 'Cisco UCS Manager Network Management Guide - LAN Connectivity and LAN Ports and Port Channels'

    # --- Switching mode -------------------------------------------------------------------------
    $lanCloud = @(Get-UcsBpMo -ClassId 'fabricLanCloud') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $lanCloud -Property 'Mode' -Expected @('end-host') `
        -Category $category -CheckId 'UCS-LAN-001' -Setting 'Ethernet switching mode' `
        -RecommendedValue 'end-host - the default and recommended mode; it removes spanning tree from the fabric interconnects' `
        -Basis 'Best Practice' -Severity 'High' `
        -Reference 'https://www.cisco.com/c/en/us/solutions/collateral/data-center-virtualization/unified-computing/whitepaper_c11-701962.html' `
        -Remediation 'LAN > LAN Cloud > Fabric A/B. Switching mode is disruptive to change - it reboots the fabric interconnect - so plan it into a window.'

    if (Test-UcsBpPropertyPresent -InputObject $lanCloud -Name 'MacAging') {
        Add-UcsBpPropertyCheck -Mo $lanCloud -Property 'MacAging' -Expected @('mode-default') `
            -Category $category -CheckId 'UCS-LAN-002' -Setting 'MAC address table aging' `
            -RecommendedValue 'mode-default (Cisco default)' -Basis 'Cisco Default' -Severity 'Low' -Reference $reference `
            -Remediation 'LAN > LAN Cloud > Global Policies > MAC Address Table Aging.'
    }

    # --- Uplinks --------------------------------------------------------------------------------
    $uplinkPcs = @(Get-UcsBpMo -ClassId 'fabricEthLanPc')
    $uplinkPcMembers = @(Get-UcsBpMo -ClassId 'fabricEthLanPcEp')
    $standaloneUplinks = @(Get-UcsBpMo -ClassId 'fabricEthLanEp')
    $serverPorts = @(Get-UcsBpMo -ClassId 'fabricDceSwSrvEp')

    foreach ($fabricId in @('A', 'B')) {
        $fabricPcs = @($uplinkPcs | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '') -ieq $fabricId })

        Add-UcsBpRow -Category $category -CheckId 'UCS-LAN-010' -Setting "Uplink port channels on fabric $fabricId" `
            -ObjectDn "fabric/lan/$fabricId" `
            -CurrentValue $fabricPcs.Count -RecommendedValue 'At least 1 uplink port channel per fabric' -Basis 'Best Practice' `
            -Result $(if ($fabricPcs.Count -ge 1) { 'Meets' } else { 'Does Not Meet' }) -Severity 'High' -Reference $reference `
            -Remediation 'LAN > LAN Cloud > Fabric > Port Channels. Cisco recommends port channels to upstream switches so pinned server interfaces use the port channel hashing algorithm.' `
            -Detail (@($fabricPcs | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?')($(Get-UcsBpProperty -InputObject $_ -Name 'PortId' -Default '?'))=$(Get-UcsBpProperty -InputObject $_ -Name 'OperState' -Default '?')" }) -join ', ')

        foreach ($pc in $fabricPcs) {
            $pcDn = [string](Get-UcsBpProperty -InputObject $pc -Name 'Dn' -Default '')
            $members = @($uplinkPcMembers | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Dn' -Default '') -like "$pcDn/*" })

            Add-UcsBpRow -Category $category -CheckId 'UCS-LAN-011' `
                -Setting "Uplink port channel '$(Get-UcsBpProperty -InputObject $pc -Name 'Name' -Default $pcDn)' member count" `
                -ObjectDn $pcDn -Owner ([string](Get-UcsBpProperty -InputObject $pc -Name 'PolicyOwner' -Default '')) `
                -CurrentValue $members.Count -RecommendedValue 'At least 2 member ports, so the bundle survives a single link or upstream line card failure' `
                -Basis 'Best Practice' -Result $(if ($members.Count -ge 2) { 'Meets' } else { 'Does Not Meet' }) `
                -Severity 'High' -Reference $reference `
                -Remediation 'A one-member port channel has the management overhead of a bundle and the resilience of a single link.'

            Add-UcsBpPropertyCheck -Mo $pc -Property 'OperState' -Expected @('up') `
                -Category $category -CheckId 'UCS-LAN-012' `
                -Setting "Uplink port channel '$(Get-UcsBpProperty -InputObject $pc -Name 'Name' -Default $pcDn)' operational state" `
                -RecommendedValue 'up' -Basis 'Best Practice' -Severity 'High' -Reference $reference `
                -Remediation 'LAN > LAN Cloud > Fabric > Port Channels.'
        }

        # --- Server ports -----------------------------------------------------------------------
        $fabricServerPorts = @($serverPorts | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '') -ieq $fabricId })
        Add-UcsBpRow -Category $category -CheckId 'UCS-LAN-013' -Setting "Server ports on fabric $fabricId" `
            -ObjectDn "fabric/server/sw-$fabricId" `
            -CurrentValue $fabricServerPorts.Count -RecommendedValue 'At least 2 per fabric, matching the IOM links cabled' -Basis 'Best Practice' `
            -Result $(if ($fabricServerPorts.Count -ge 2) { 'Meets' } else { 'Does Not Meet' }) -Severity 'High' -Reference $reference `
            -Remediation 'Equipment > Fabric Interconnects > Fixed Module > Ethernet Ports - configure as Server.'
    }

    # --- Standalone uplinks ---------------------------------------------------------------------
    Add-UcsBpRow -Category $category -CheckId 'UCS-LAN-014' -Setting 'Uplink ports not in a port channel' `
        -ObjectDn 'fabric/lan' `
        -CurrentValue $standaloneUplinks.Count -RecommendedValue '0 - bundle every uplink into a port channel' -Basis 'Best Practice' `
        -Result $(if ($standaloneUplinks.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) -Severity 'Medium' -Reference $reference `
        -Remediation 'LAN > LAN Cloud > Fabric > Port Channels. vNICs pinned to a standalone uplink lose their path when that one link fails, instead of rehashing across a bundle.' `
        -Detail (@($standaloneUplinks | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Dn' -Default '?' }) -join ', ')

    # --- Fabric symmetry ------------------------------------------------------------------------
    $uplinkCountA = @($uplinkPcMembers | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '') -ieq 'A' }).Count +
                    @($standaloneUplinks | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '') -ieq 'A' }).Count
    $uplinkCountB = @($uplinkPcMembers | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '') -ieq 'B' }).Count +
                    @($standaloneUplinks | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '') -ieq 'B' }).Count

    Add-UcsBpRow -Category $category -CheckId 'UCS-LAN-015' -Setting 'Uplink symmetry between fabric A and B' `
        -ObjectDn 'fabric/lan' `
        -CurrentValue "A: $uplinkCountA, B: $uplinkCountB" -RecommendedValue 'The same uplink count on both fabrics' -Basis 'Best Practice' `
        -Result $(if ($uplinkCountA -eq $uplinkCountB) { 'Meets' } else { 'Does Not Meet' }) -Severity 'Medium' -Reference $reference `
        -Remediation 'Asymmetric uplinks mean a fabric failover lands the whole domain on the smaller side. Cable and configure both fabrics the same.'

    $serverPortCountA = @($serverPorts | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '') -ieq 'A' }).Count
    $serverPortCountB = @($serverPorts | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '') -ieq 'B' }).Count
    Add-UcsBpRow -Category $category -CheckId 'UCS-LAN-016' -Setting 'Server port symmetry between fabric A and B' `
        -ObjectDn 'fabric/server' `
        -CurrentValue "A: $serverPortCountA, B: $serverPortCountB" -RecommendedValue 'The same server port count on both fabrics' -Basis 'Best Practice' `
        -Result $(if ($serverPortCountA -eq $serverPortCountB) { 'Meets' } else { 'Does Not Meet' }) -Severity 'Medium' -Reference $reference `
        -Remediation 'Equipment > Fabric Interconnects > Fixed Module > Ethernet Ports.'

    # VLANs are audited in their own section - see Test-UcsBpVlan. This deployment carries
    # everything over Ethernet VLANs, so they warrant more than two rows tacked onto the end of
    # the LAN checks.

    # --- Network control policies ------------------------------------------------------------------
    $nwPolicies = @(Get-UcsBpMo -ClassId 'nwctrlDefinition')
    if ($nwPolicies.Count -eq 0) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-LAN-030' -Setting 'Network control policies' `
            -ClassId 'nwctrlDefinition' -RecommendedValue 'CDP enabled, uplink fail action link-down' -Severity 'Medium' -Reference $reference
    }

    foreach ($policy in $nwPolicies) {
        $policyName = [string](Get-UcsBpProperty -InputObject $policy -Name 'Name' -Default '?')

        Add-UcsBpPropertyCheck -Mo $policy -Property 'UplinkFailAction' -Expected @('link-down') `
            -Category $category -CheckId 'UCS-LAN-030' -Setting "Network control policy '$policyName' - action on uplink fail" `
            -RecommendedValue 'link-down (Cisco default) - brings the vNIC down so the OS fails over' -Basis 'Best Practice' `
            -Severity 'High' -Reference $reference `
            -Remediation 'LAN > Policies > Network Control Policies. Set to warning, the vNIC stays up with no path behind it and the operating system never fails over.'

        Add-UcsBpPropertyCheck -Mo $policy -Property 'Cdp' -Expected @('enabled') `
            -Category $category -CheckId 'UCS-LAN-031' -Setting "Network control policy '$policyName' - CDP" `
            -RecommendedValue 'enabled - without it neither UCS nor the hypervisor can see what a vNIC is cabled to' `
            -Basis 'Best Practice' -Severity 'Medium' -Reference $reference `
            -Remediation 'LAN > Policies > Network Control Policies. The built-in "default" policy ships with CDP disabled.'

        foreach ($lldpPair in @(
                @{ Property = 'LldpTransmit'; CheckId = 'UCS-LAN-032'; Label = 'LLDP transmit' },
                @{ Property = 'LldpReceive';  CheckId = 'UCS-LAN-033'; Label = 'LLDP receive' })) {

            if (Test-UcsBpPropertyPresent -InputObject $policy -Name $lldpPair.Property) {
                Add-UcsBpPropertyCheck -Mo $policy -Property $lldpPair.Property -Expected @('enabled') `
                    -Category $category -CheckId $lldpPair.CheckId -Setting "Network control policy '$policyName' - $($lldpPair.Label)" `
                    -RecommendedValue 'enabled where the upstream network uses LLDP rather than CDP' -Basis 'Site Policy' `
                    -Severity 'Low' -Reference $reference `
                    -Remediation 'LAN > Policies > Network Control Policies.'
            }
        }
    }
}

function Test-UcsBpQos {
    <#
    .SYNOPSIS
        Audits the system QoS classes.

    .DESCRIPTION
        Two things are worth checking here and only two.

        MTU: Cisco's guidance on jumbo frames is that if you use them, 9216 must be configured
        along the entire path - the fabric interconnects, the upstream switches and their
        interswitch links, the storage target, and the host. A class set to some intermediate
        value such as 9000 satisfies nobody: it is not the UCS jumbo MTU and it will silently drop
        or fragment against equipment configured for 9216.

        CoS 3: FCoE uses class of service 3. A second enabled class sharing it puts lossless
        storage traffic and best-effort traffic in the same no-drop queue, which shows up later as
        storage timeouts that look like a fault on the array.

    .EXAMPLE
        Test-UcsBpQos
    #>
    [CmdletBinding()]
    param()

    $category = 'QoS'
    $reference = 'Cisco UCS Manager Network Management Guide - Quality of Service; Configure UCS with VMware ESXi End-to-End Jumbo MTU'

    $classes = New-Object System.Collections.Generic.List[object]
    foreach ($classId in @('qosclassEthClassified', 'qosclassEthBE', 'qosclassFc')) {
        foreach ($mo in @(Get-UcsBpMo -ClassId $classId)) { $classes.Add($mo) }
    }

    if ($classes.Count -eq 0) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-QOS-001' -Setting 'System QoS classes' `
            -ClassId 'qosclassEthClassified' -RecommendedValue 'MTU normal or 9216 on every enabled class' -Severity 'Medium' -Reference $reference
        return
    }

    $enabledClasses = @($classes | Where-Object {
            $state = [string](Get-UcsBpProperty -InputObject $_ -Name 'AdminState' -Default 'enabled')
            $state -ieq 'enabled'
        })

    foreach ($class in $enabledClasses) {
        $className = [string](Get-UcsBpProperty -InputObject $class -Name 'Priority' -Default ([string](Get-UcsBpProperty -InputObject $class -Name 'Rn' -Default '?')))
        $mtu = [string](Get-UcsBpProperty -InputObject $class -Name 'Mtu' -Default '')

        if ([string]::IsNullOrWhiteSpace($mtu)) { continue }

        # 'normal', 'fc' and 9216 are the values that are coherent end to end. Anything else is a
        # number somebody typed, and it will not match the upstream switches.
        $mtuOk = ($mtu -ieq 'normal' -or $mtu -ieq 'fc' -or $mtu -eq '9216')
        Add-UcsBpRow -Category $category -CheckId 'UCS-QOS-001' -Setting "QoS class '$className' MTU" `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $class -Name 'Dn' -Default '')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $class -Name 'PolicyOwner' -Default '')) `
            -CurrentValue $mtu -RecommendedValue 'normal (1500) or 9216. Jumbo MTU must be 9216 and must be configured end to end, including the upstream interswitch links' `
            -Basis 'Best Practice' -Result $(if ($mtuOk) { 'Meets' } else { 'Does Not Meet' }) `
            -Severity 'High' -Reference $reference `
            -Remediation 'LAN > LAN Cloud > QoS System Class. An intermediate MTU such as 9000 is neither the standard frame nor the UCS jumbo frame and will not match the rest of the path.'
    }

    # --- CoS 3 ------------------------------------------------------------------------------------
    $cos3Users = @($enabledClasses | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Cos' -Default '') -eq '3' })
    Add-UcsBpRow -Category $category -CheckId 'UCS-QOS-002' -Setting 'Classes using CoS 3 (reserved for FCoE)' `
        -ObjectDn 'fabric/lan/classes' `
        -CurrentValue "$($cos3Users.Count): $(@($cos3Users | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Priority' -Default (Get-UcsBpProperty -InputObject $_ -Name 'Rn' -Default '?') }) -join ', ')" `
        -RecommendedValue 'Exactly 1 - the Fibre Channel class. No Ethernet class should share CoS 3' `
        -Basis 'Best Practice' -Result $(if ($cos3Users.Count -le 1) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'High' -Reference $reference `
        -Remediation 'LAN > LAN Cloud > QoS System Class. An Ethernet class sharing CoS 3 with FCoE puts best-effort traffic into the lossless storage queue.'

    # --- Enabled classes ----------------------------------------------------------------------------
    Add-UcsBpRow -Category $category -CheckId 'UCS-QOS-003' -Setting 'Enabled QoS system classes' `
        -ObjectDn 'fabric/lan/classes' -CurrentValue $enabledClasses.Count `
        -RecommendedValue 'Only the classes actually referenced by a QoS policy - each enabled class takes bandwidth allocation from the others' `
        -Basis 'Site Policy' -Result 'Review' -Severity 'Info' -Reference $reference `
        -Remediation 'LAN > LAN Cloud > QoS System Class.' `
        -Detail (@($enabledClasses | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Priority' -Default (Get-UcsBpProperty -InputObject $_ -Name 'Rn' -Default '?'))/cos=$(Get-UcsBpProperty -InputObject $_ -Name 'Cos' -Default '?')/weight=$(Get-UcsBpProperty -InputObject $_ -Name 'Weight' -Default '?')" }) -join ', ')
}

# ---------------------------------------------------------------------------------------------
# Checks - VLANs
# ---------------------------------------------------------------------------------------------

function Test-UcsBpVlan {
    <#
    .SYNOPSIS
        Audits the VLAN configuration in depth.

    .DESCRIPTION
        This domain carries everything over Ethernet VLANs, so the VLAN definitions are the
        configuration - not a supporting detail of it. Four things are worth asserting:

          - A VLAN defined on one fabric only. In a dual-fabric design that is almost always an
            omission rather than a decision, and it is invisible until a fabric failover puts the
            traffic on the side where the VLAN does not exist.
          - The same VLAN ID under two different names. UCS will accept it; what it produces is
            two objects that look independent and are not.
          - VLANs no vNIC references. Each one is a broadcast domain the fabric interconnects
            carry for nobody, and they accumulate because deleting a VLAN feels riskier than
            leaving it.
          - VLAN count against what the fabric interconnect can hold, before the limit is found
            the hard way.

    .EXAMPLE
        Test-UcsBpVlan
    #>
    [CmdletBinding()]
    param()

    $category = 'VLAN'
    $reference = 'Cisco UCS Manager Network Management Guide - LAN Connectivity'

    $vlans = @(Get-UcsBpMo -ClassId 'fabricVlan')
    if (-not (Test-UcsBpClassReadable -ClassId 'fabricVlan')) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-VLAN-001' -Setting 'VLANs' `
            -ClassId 'fabricVlan' -RecommendedValue 'Defined on both fabrics, referenced by a vNIC' -Severity 'Medium' -Reference $reference
        return
    }

    # --- Inventory --------------------------------------------------------------------------------
    Add-UcsBpRow -Category $category -CheckId 'UCS-VLAN-001' -Setting 'VLANs defined' `
        -ObjectDn 'fabric/lan' -CurrentValue $vlans.Count `
        -RecommendedValue 'Only the VLANs this domain actually carries. The 6400 series supports up to 3000 VLANs; approaching that needs VLAN compression and planning' `
        -Basis 'Site Policy' -Result $(if ($vlans.Count -lt 2000) { 'Review' } else { 'Does Not Meet' }) `
        -Severity $(if ($vlans.Count -lt 2000) { 'Info' } else { 'High' }) -Reference $reference `
        -Remediation 'LAN > LAN Cloud > VLANs. Every trunked VLAN is a broadcast domain the fabric interconnects have to carry.'

    # --- VLAN 1 -----------------------------------------------------------------------------------
    $vlan1DataUse = @($vlans | Where-Object {
            ([string](Get-UcsBpProperty -InputObject $_ -Name 'Id' -Default '') -eq '1') -and
            ([string](Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '') -inotmatch '^default$')
        })
    Add-UcsBpRow -Category $category -CheckId 'UCS-VLAN-002' -Setting 'VLAN 1 used for production traffic' `
        -ObjectDn 'fabric/lan' -CurrentValue $vlan1DataUse.Count `
        -RecommendedValue '0 - carry production traffic on a named VLAN, not the default VLAN 1' -Basis 'Best Practice' `
        -Result $(if ($vlan1DataUse.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) -Severity 'Low' -Reference $reference `
        -Remediation 'LAN > LAN Cloud > VLANs.' `
        -Detail (@($vlan1DataUse | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')

    # --- Single-fabric VLANs -----------------------------------------------------------------------
    # SwitchId is 'dual' for a VLAN present on both fabrics, or 'A'/'B' for one defined on a single
    # fabric. The second form is what breaks on failover.
    $singleFabric = @($vlans | Where-Object {
            $switchId = [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default 'dual')
            $switchId -ieq 'A' -or $switchId -ieq 'B'
        })
    Add-UcsBpRow -Category $category -CheckId 'UCS-VLAN-003' -Setting 'VLANs defined on one fabric only' `
        -ObjectDn 'fabric/lan' -CurrentValue $singleFabric.Count `
        -RecommendedValue '0 - define VLANs as dual (both fabrics) unless the single-fabric scope is deliberate' -Basis 'Best Practice' `
        -Result $(if ($singleFabric.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) -Severity 'High' -Reference $reference `
        -Remediation 'LAN > LAN Cloud > VLANs - create as "Common/Global" rather than under a single fabric. A single-fabric VLAN disappears from under the traffic when the other fabric takes over.' `
        -Detail (@($singleFabric | Select-Object -First 20 | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?')(id $(Get-UcsBpProperty -InputObject $_ -Name 'Id' -Default '?') on $(Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '?'))" }) -join ', ')

    if ($singleFabric.Count -gt 0) {
        $emitted = Add-UcsBpOffenderRows -Offender $singleFabric -Category $category -CheckId 'UCS-VLAN-003' `
            -Setting 'VLAN defined on one fabric only' `
            -CurrentValueScript { param($mo) "$(Get-UcsBpProperty -InputObject $mo -Name 'Name' -Default '?') (id $(Get-UcsBpProperty -InputObject $mo -Name 'Id' -Default '?')) on fabric $(Get-UcsBpProperty -InputObject $mo -Name 'SwitchId' -Default '?')" } `
            -RecommendedValue 'Defined on both fabrics (dual)' -Basis 'Best Practice' -Severity 'High' `
            -Remediation 'LAN > LAN Cloud > VLANs.' -Reference $reference
        if ($emitted -lt $singleFabric.Count) {
            Add-UcsBpRow -Category $category -CheckId 'UCS-VLAN-003-CAP' -Setting 'Single-fabric VLAN detail rows truncated' `
                -CurrentValue "$emitted of $($singleFabric.Count) listed" -RecommendedValue 'n/a' -Basis 'Site Policy' `
                -Result 'Review' -Severity 'Info' `
                -Remediation "Re-run with -MaxDetailRowsPerCheck $($singleFabric.Count) to list them all."
        }
    }

    # --- Duplicate VLAN IDs -------------------------------------------------------------------------
    $duplicateIds = @(
        $vlans | Group-Object -Property { [string](Get-UcsBpProperty -InputObject $_ -Name 'Id' -Default '') } |
            Where-Object {
                $_.Count -gt 1 -and
                (@($_.Group | ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '') } | Select-Object -Unique).Count -gt 1)
            }
    )
    Add-UcsBpRow -Category $category -CheckId 'UCS-VLAN-004' -Setting 'VLAN IDs defined under more than one name' `
        -ObjectDn 'fabric/lan' -CurrentValue $duplicateIds.Count `
        -RecommendedValue '0 - one name per VLAN ID' -Basis 'Best Practice' `
        -Result $(if ($duplicateIds.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) -Severity 'Medium' -Reference $reference `
        -Remediation 'LAN > LAN Cloud > VLANs. Two names over one ID look like two independent VLANs to whoever edits them next, and are not.' `
        -Detail (@($duplicateIds | ForEach-Object { "id $($_.Name): $(@($_.Group | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join '/')" }) -join '; ')

    # --- Unreferenced VLANs ---------------------------------------------------------------------------
    # vnicEtherIf is the VLAN membership entry on a vNIC or vNIC template. A VLAN that appears in
    # none of them is carried by the fabric interconnects for nobody.
    $vnicVlanRefs = @(Get-UcsBpMo -ClassId 'vnicEtherIf')
    if (Test-UcsBpClassReadable -ClassId 'vnicEtherIf') {
        $referencedNames = @($vnicVlanRefs | ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '') } | Where-Object { $_ } | Select-Object -Unique)
        $unreferenced = @($vlans | Where-Object {
                $vlanName = [string](Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '')
                $vlanName -and ($referencedNames -notcontains $vlanName)
            })

        Add-UcsBpRow -Category $category -CheckId 'UCS-VLAN-005' -Setting 'VLANs not referenced by any vNIC' `
            -ObjectDn 'fabric/lan' -CurrentValue $unreferenced.Count `
            -RecommendedValue '0 - remove VLANs nothing uses, or record why they are staged' -Basis 'Best Practice' `
            -Result $(if ($unreferenced.Count -eq 0) { 'Meets' } else { 'Review' }) -Severity 'Low' -Reference $reference `
            -Remediation 'LAN > LAN Cloud > VLANs. Staged VLANs for planned work are legitimate; the rest are trunked broadcast domains nobody owns.' `
            -Detail (@($unreferenced | Select-Object -First 30 | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?')($(Get-UcsBpProperty -InputObject $_ -Name 'Id' -Default '?'))" }) -join ', ')
    }
    else {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-VLAN-005' -Setting 'VLANs not referenced by any vNIC' `
            -ClassId 'vnicEtherIf' -RecommendedValue '0' -Severity 'Low' -Reference $reference
    }

    # --- Native VLAN --------------------------------------------------------------------------------
    $nativeVlans = @($vlans | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'DefaultNet' -Default 'no') -ieq 'yes' })
    Add-UcsBpRow -Category $category -CheckId 'UCS-VLAN-006' -Setting 'VLANs marked as native' `
        -ObjectDn 'fabric/lan' -CurrentValue $nativeVlans.Count `
        -RecommendedValue 'At most 1, and matched to the native VLAN on the upstream trunk' -Basis 'Best Practice' `
        -Result $(if ($nativeVlans.Count -le 1) { 'Meets' } else { 'Does Not Meet' }) -Severity 'Medium' -Reference $reference `
        -Remediation 'LAN > LAN Cloud > VLANs. A native VLAN mismatch with the upstream switch drops untagged traffic silently.' `
        -Detail (@($nativeVlans | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?')($(Get-UcsBpProperty -InputObject $_ -Name 'Id' -Default '?'))" }) -join ', ')

    # --- VLAN groups ---------------------------------------------------------------------------------
    $vlanGroups = @(Get-UcsBpMo -ClassId 'fabricNetGroup')
    Add-UcsBpRow -Category $category -CheckId 'UCS-VLAN-007' -Setting 'VLAN groups' `
        -ObjectDn 'fabric/lan' -CurrentValue $vlanGroups.Count `
        -RecommendedValue 'VLAN groups pinning each set of VLANs to the uplinks that actually carry them upstream' `
        -Basis 'Best Practice' -Result $(if ($vlanGroups.Count -ge 1) { 'Meets' } else { 'Review' }) `
        -Severity 'Low' -Reference $reference `
        -Remediation 'LAN > LAN Cloud > LAN Uplinks Manager > VLAN Groups. Without groups every VLAN is trunked on every uplink, so a VLAN missing upstream on one uplink blackholes whatever gets pinned there.' `
        -Detail (@($vlanGroups | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')

    # --- Ownership under UCS Central ---------------------------------------------------------------
    $localVlans = @($vlans | Where-Object { -not (Test-UcsBpOwnerIsGlobal -Owner ([string](Get-UcsBpProperty -InputObject $_ -Name 'PolicyOwner' -Default 'local'))) })
    Add-UcsBpRow -Category $category -CheckId 'UCS-VLAN-008' -Setting 'VLANs defined locally rather than in UCS Central' `
        -ObjectDn 'fabric/lan' -CurrentValue "$($localVlans.Count) of $($vlans.Count)" `
        -RecommendedValue 'Whatever the UCS Central design says. VLANs meant to be consistent across domains should be global; domain-specific ones stay local' `
        -Basis 'Site Policy' -Result 'Review' -Severity 'Medium' -Reference 'Cisco UCS Central Operations Guide' `
        -Remediation 'A locally defined VLAN will not follow a service profile moved between domains by UCS Central. Confirm the split is deliberate.'
}

# ---------------------------------------------------------------------------------------------
# Checks - SAN / Fibre Channel
# ---------------------------------------------------------------------------------------------

function Test-UcsBpSan {
    <#
    .SYNOPSIS
        Confirms the Fibre Channel side is unconfigured, and audits it if it is not.

    .DESCRIPTION
        This deployment is Ethernet only, so the interesting finding here is not a misconfigured
        SAN - it is any SAN configuration at all. An FC uplink, a SAN port channel or a VSAN
        beyond the shipped default in an Ethernet-only domain is either left over from a build
        that changed direction or was added without the design changing, and both are worth
        knowing about.

        Where FC configuration is found the section audits it properly rather than only flagging
        it, so the rows are useful if the deployment later gains a SAN.

    .EXAMPLE
        Test-UcsBpSan
    #>
    [CmdletBinding()]
    param()

    $category = 'SAN'
    $reference = 'Cisco UCS Manager SAN Management Guide'

    $fcUplinks = @(Get-UcsBpMo -ClassId 'fabricFcSanEp')
    $fcPortChannels = @(Get-UcsBpMo -ClassId 'fabricFcSanPc')
    $vsans = @(Get-UcsBpMo -ClassId 'fabricVsan')
    $nonDefaultVsans = @($vsans | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Id' -Default '') -ne '1' })

    $fcConfigured = (($fcUplinks.Count + $fcPortChannels.Count + $nonDefaultVsans.Count) -gt 0)

    Add-UcsBpRow -Category $category -CheckId 'UCS-SAN-001' -Setting 'Fibre Channel configuration present' `
        -ObjectDn 'fabric/san' `
        -CurrentValue "FC uplinks: $($fcUplinks.Count), SAN port channels: $($fcPortChannels.Count), non-default VSANs: $($nonDefaultVsans.Count)" `
        -RecommendedValue 'None - this deployment is Ethernet only' -Basis 'Site Policy' `
        -Result $(if ($fcConfigured) { 'Does Not Meet' } else { 'Meets' }) `
        -Severity $(if ($fcConfigured) { 'Medium' } else { 'Info' }) -Reference $reference `
        -Remediation 'SAN > SAN Cloud. Remove the leftover Fibre Channel configuration, or correct the design record if this domain does carry FC.' `
        -Detail (@($nonDefaultVsans | ForEach-Object { "VSAN $(Get-UcsBpProperty -InputObject $_ -Name 'Id' -Default '?') ($(Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?'))" }) -join ', ')

    if (-not $fcConfigured) {
        foreach ($skipped in @(
                @{ CheckId = 'UCS-SAN-002'; Setting = 'FC switching mode';                   Recommended = 'end-host' },
                @{ CheckId = 'UCS-SAN-003'; Setting = 'FC uplinks bundled into SAN port channels'; Recommended = 'All FC uplinks in a SAN port channel' },
                @{ CheckId = 'UCS-SAN-004'; Setting = 'FCoE VLAN and Ethernet VLAN ID collision'; Recommended = 'No FCoE VLAN ID reused as an Ethernet VLAN ID' },
                @{ CheckId = 'UCS-SAN-005'; Setting = '6400 unified port placement for FC';   Recommended = 'FC ports contiguous from port 1, within ports 1-16' })) {

            Add-UcsBpRow -Category $category -CheckId $skipped.CheckId -Setting $skipped.Setting `
                -ObjectDn 'fabric/san' -CurrentValue '(no Fibre Channel configuration on this domain)' `
                -RecommendedValue $skipped.Recommended -Basis 'Best Practice' -Result 'Not Applicable' `
                -Severity 'Info' -Reference $reference `
                -Remediation 'Not checked - this domain carries no Fibre Channel configuration.'
        }
        return
    }

    # --- FC is configured after all: audit it -------------------------------------------------------
    $sanCloud = @(Get-UcsBpMo -ClassId 'fabricSanCloud') | Select-Object -First 1
    Add-UcsBpPropertyCheck -Mo $sanCloud -Property 'Mode' -Expected @('end-host') `
        -Category $category -CheckId 'UCS-SAN-002' -Setting 'FC switching mode' `
        -RecommendedValue 'end-host (NPV) - the fabric interconnects present as N_Port proxies rather than joining the FC fabric as switches' `
        -Basis 'Best Practice' -Severity 'High' -Reference $reference `
        -Remediation 'SAN > SAN Cloud > Fabric A/B.'

    Add-UcsBpRow -Category $category -CheckId 'UCS-SAN-003' -Setting 'FC uplinks not in a SAN port channel' `
        -ObjectDn 'fabric/san' -CurrentValue $fcUplinks.Count `
        -RecommendedValue '0 - bundle FC uplinks into SAN port channels' -Basis 'Best Practice' `
        -Result $(if ($fcUplinks.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) -Severity 'Medium' -Reference $reference `
        -Remediation 'SAN > SAN Cloud > Fabric > FC Port Channels.'

    # FCoE carries Fibre Channel inside an Ethernet VLAN. If that VLAN ID is also defined as an
    # Ethernet VLAN, the two collide and storage traffic is dropped - a fault whose symptom is on
    # the array and whose cause is here.
    $ethernetVlanIds = @(Get-UcsBpMo -ClassId 'fabricVlan' | ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Id' -Default '') } | Where-Object { $_ })
    $collisions = @(
        $vsans | Where-Object {
            $fcoeVlan = [string](Get-UcsBpProperty -InputObject $_ -Name 'FcoeVlan' -Default '')
            $fcoeVlan -and ($ethernetVlanIds -contains $fcoeVlan)
        }
    )
    Add-UcsBpRow -Category $category -CheckId 'UCS-SAN-004' -Setting 'FCoE VLAN and Ethernet VLAN ID collision' `
        -ObjectDn 'fabric/san' -CurrentValue $collisions.Count `
        -RecommendedValue '0 - an FCoE VLAN ID must not also exist as an Ethernet VLAN' -Basis 'Best Practice' `
        -Result $(if ($collisions.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) -Severity 'Critical' -Reference $reference `
        -Remediation 'SAN > SAN Cloud > VSANs. Change the FCoE VLAN ID to one not used by any Ethernet VLAN.' `
        -Detail (@($collisions | ForEach-Object { "VSAN $(Get-UcsBpProperty -InputObject $_ -Name 'Id' -Default '?') FCoE VLAN $(Get-UcsBpProperty -InputObject $_ -Name 'FcoeVlan' -Default '?')" }) -join ', ')

    # --- 6400 unified port placement ------------------------------------------------------------------
    if ($script:FabricFamily -ne '6400') {
        Add-UcsBpRow -Category $category -CheckId 'UCS-SAN-005' -Setting '6400 unified port placement for FC' `
            -ObjectDn 'fabric/san' -CurrentValue "fabric interconnect family is $($script:FabricFamily)" `
            -RecommendedValue 'FC ports contiguous from port 1, within ports 1-16 (6400 series rule)' -Basis 'Best Practice' `
            -Result 'Not Applicable' -Severity 'Info' -Reference $reference `
            -Remediation 'This rule is specific to the 6400 series.'
    }
    else {
        $fcPortIds = @(
            @($fcUplinks) + @(Get-UcsBpMo -ClassId 'fabricFcSanPcEp') |
                ForEach-Object { [int](Get-UcsBpProperty -InputObject $_ -Name 'PortId' -Default 0) } |
                Where-Object { $_ -gt 0 } | Sort-Object -Unique
        )
        $outOfRange = @($fcPortIds | Where-Object { $_ -gt 16 })
        Add-UcsBpRow -Category $category -CheckId 'UCS-SAN-005' -Setting '6400 unified port placement for FC' `
            -ObjectDn 'fabric/san' -CurrentValue (@($fcPortIds) -join ', ') `
            -RecommendedValue 'FC ports within ports 1-16 and contiguous from port 1 - only the first 16 ports on a 6400 can carry Fibre Channel' `
            -Basis 'Best Practice' -Result $(if ($outOfRange.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) `
            -Severity 'High' `
            -Reference 'https://www.cisco.com/c/en/us/td/docs/unified_computing/ucs/hw/6454-install-guide/6454/6454_chapter_0111.html' `
            -Remediation 'Equipment > Fabric Interconnects > Configure Unified Ports.'
    }
}

# ---------------------------------------------------------------------------------------------
# Checks - server policies
# ---------------------------------------------------------------------------------------------

function Test-UcsBpServerPolicies {
    <#
    .SYNOPSIS
        Audits maintenance, local disk, scrub, boot and power control policies.

    .DESCRIPTION
        The maintenance policy is the one with teeth. Cisco's own documentation says the default
        policy is configured for immediate reboot after any change, and that production
        environments should use a policy set to user acknowledge instead - so that a service
        profile edit schedules a reboot rather than causing one. On an estate running ESXi and
        Windows this is the difference between a change that waits for the host to be evacuated
        and a change that reboots it under load.

        Local disk protect configuration and the scrub policies are the other two that destroy
        data rather than merely disrupt it.

    .EXAMPLE
        Test-UcsBpServerPolicies
    #>
    [CmdletBinding()]
    param()

    $category = 'Server Policies'
    $reference = 'Cisco UCS Manager Administration Management Guide - Deferred Deployments of Service Profile Updates'

    # --- Maintenance policies ---------------------------------------------------------------------
    $maintPolicies = @(Get-UcsBpMo -ClassId 'lsmaintMaintPolicy')
    if ($maintPolicies.Count -eq 0) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-SRV-001' -Setting 'Maintenance policies' `
            -ClassId 'lsmaintMaintPolicy' -RecommendedValue 'user-ack' -Severity 'High' -Reference $reference
    }

    foreach ($policy in $maintPolicies) {
        $policyName = [string](Get-UcsBpProperty -InputObject $policy -Name 'Name' -Default '?')
        Add-UcsBpPropertyCheck -Mo $policy -Property 'UptimeDisr' -Expected @('user-ack') `
            -Category $category -CheckId 'UCS-SRV-001' -Setting "Maintenance policy '$policyName' - reboot policy" `
            -RecommendedValue 'user-ack - UCS Manager waits for an acknowledgement instead of rebooting the server when the service profile changes' `
            -Basis 'Best Practice' -Severity 'High' -Reference $reference `
            -Remediation 'Servers > Policies > Maintenance Policies. The built-in "default" policy ships as immediate; Cisco recommends user acknowledge for production. An ESXi host rebooted immediately has not been put in maintenance mode first.'
    }

    # --- Local disk configuration policies ------------------------------------------------------------
    $localDiskPolicies = @(Get-UcsBpMo -ClassId 'storageLocalDiskConfigPolicy')
    foreach ($policy in $localDiskPolicies) {
        $policyName = [string](Get-UcsBpProperty -InputObject $policy -Name 'Name' -Default '?')
        Add-UcsBpPropertyCheck -Mo $policy -Property 'ProtectConfig' -Expected @('yes', 'true') `
            -Category $category -CheckId 'UCS-SRV-010' -Setting "Local disk policy '$policyName' - protect configuration" `
            -RecommendedValue 'yes - preserves the local disk configuration when a service profile is disassociated' `
            -Basis 'Best Practice' -Severity 'High' -Reference 'Cisco UCS Manager Storage Management Guide' `
            -Remediation 'Servers > Policies > Local Disk Config Policies. Set to no, disassociating a service profile can destroy the local RAID configuration - and with it a locally booted ESXi or Windows install.'
    }

    # --- Scrub policies -------------------------------------------------------------------------------
    $scrubPolicies = @(Get-UcsBpMo -ClassId 'computeScrubPolicy')
    foreach ($policy in $scrubPolicies) {
        $policyName = [string](Get-UcsBpProperty -InputObject $policy -Name 'Name' -Default '?')
        Add-UcsBpPropertyCheck -Mo $policy -Property 'DiskScrub' -Expected @('no', 'false') `
            -Category $category -CheckId 'UCS-SRV-011' -Setting "Scrub policy '$policyName' - disk scrub" `
            -RecommendedValue 'no, unless this policy exists specifically to wipe decommissioned servers' `
            -Basis 'Best Practice' -Severity 'Critical' -Reference 'Cisco UCS Manager Server Management Guide' `
            -Remediation 'Servers > Policies > Scrub Policies. Disk scrub runs on disassociation and destroys the contents of the local disks.'
    }

    # --- Boot policies ---------------------------------------------------------------------------------
    $bootPolicies = @(Get-UcsBpMo -ClassId 'lsbootPolicy')
    Add-UcsBpRow -Category $category -CheckId 'UCS-SRV-020' -Setting 'Boot policies defined' `
        -CurrentValue $bootPolicies.Count -RecommendedValue 'A boot policy per boot method in use, referenced by every service profile' `
        -Basis 'Best Practice' -Result $(if ($bootPolicies.Count -ge 1) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'Medium' -Reference 'Cisco UCS Manager Server Management Guide' `
        -Remediation 'Servers > Policies > Boot Policies.' `
        -Detail (@($bootPolicies | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')

    foreach ($policy in $bootPolicies) {
        $policyName = [string](Get-UcsBpProperty -InputObject $policy -Name 'Name' -Default '?')

        Add-UcsBpPropertyCheck -Mo $policy -Property 'RebootOnUpdate' -Expected @('no', 'false') `
            -Category $category -CheckId 'UCS-SRV-021' -Setting "Boot policy '$policyName' - reboot on boot order change" `
            -RecommendedValue 'no - so editing the boot order does not immediately reboot every server using this policy' `
            -Basis 'Best Practice' -Severity 'High' -Reference 'Cisco UCS Manager Server Management Guide' `
            -Remediation 'Servers > Policies > Boot Policies. Set to yes, this bypasses the maintenance policy: the reboot happens on save.'

        Add-UcsBpPropertyCheck -Mo $policy -Property 'EnforceVnicName' -Expected @('yes', 'true') `
            -Category $category -CheckId 'UCS-SRV-022' -Setting "Boot policy '$policyName' - enforce vNIC/vHBA name" `
            -RecommendedValue 'yes - the boot device is matched by name, so a service profile missing that vNIC fails loudly instead of booting from something else' `
            -Basis 'Best Practice' -Severity 'Medium' -Reference 'Cisco UCS Manager Server Management Guide' `
            -Remediation 'Servers > Policies > Boot Policies.'
    }

    # --- Power control policies -------------------------------------------------------------------------
    $powerPolicies = @(Get-UcsBpMo -ClassId 'powerPolicy')
    foreach ($policy in $powerPolicies) {
        $policyName = [string](Get-UcsBpProperty -InputObject $policy -Name 'Name' -Default '?')
        Add-UcsBpRow -Category $category -CheckId 'UCS-SRV-030' -Setting "Power control policy '$policyName' - priority" `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $policy -Name 'Dn' -Default '')) `
            -Owner ([string](Get-UcsBpProperty -InputObject $policy -Name 'PolicyOwner' -Default '')) `
            -CurrentValue ([string](Get-UcsBpProperty -InputObject $policy -Name 'Prio' -Default '')) `
            -RecommendedValue 'no-cap for hypervisor hosts, so a chassis power cap never throttles a host running virtual machines' `
            -Basis 'Site Policy' -Result 'Review' -Severity 'Medium' -Reference 'Cisco UCS Manager Server Management Guide' `
            -Remediation 'Servers > Policies > Power Control Policies. A capped ESXi host loses CPU frequency under chassis power pressure, which surfaces as unexplained VM performance loss.'
    }
}

function Test-UcsBpBios {
    <#
    .SYNOPSIS
        Audits BIOS policies against what ESXi 8.x and Windows Server need.

    .DESCRIPTION
        Both operating systems on this estate are hypervisor or hypervisor-capable, so the same
        small set of BIOS settings matters for all of them:

          - Intel Virtualization Technology, and VT for Directed I/O. ESXi 8.x requires VT for
            64-bit guests and VT-d for passthrough, SR-IOV and DirectPath I/O; Windows needs the
            same pair for Hyper-V, Credential Guard and VBS, which Windows Server 2016 and later
            enable by default.
          - Processor C states and the CPU performance profile. Deep C states cost latency on
            wake, and the platform default is not always the performance profile - which is why
            an otherwise identical pair of hosts can perform differently.

        A policy left at platform-default is reported for review rather than failed: the platform
        default may well be correct, but it is decided by the server model rather than by this
        policy, so it is not something the audit can confirm from here.

    .EXAMPLE
        Test-UcsBpBios
    #>
    [CmdletBinding()]
    param()

    $category = 'BIOS'
    $reference = 'Cisco UCS Manager Server Management Guide - BIOS Policies; Cisco UCS Performance Tuning Guide'

    $biosPolicies = @(Get-UcsBpMo -ClassId 'biosVProfile')
    Add-UcsBpRow -Category $category -CheckId 'UCS-BIOS-001' -Setting 'BIOS policies defined' `
        -CurrentValue $biosPolicies.Count `
        -RecommendedValue 'At least one BIOS policy, referenced by every service profile, so BIOS settings are managed rather than inherited from whatever the server shipped with' `
        -Basis 'Best Practice' -Result $(if ($biosPolicies.Count -ge 1) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'Medium' -Reference $reference `
        -Remediation 'Servers > Policies > BIOS Policies.' `
        -Detail (@($biosPolicies | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')

    # Each BIOS setting is a child object of the policy, so the settings are read per class and
    # matched back to their parent by Dn prefix.
    $biosSettings = @(
        @{ ClassId = 'biosVfIntelVirtualizationTechnology'; Property = 'VpIntelVirtualizationTechnology'; CheckId = 'UCS-BIOS-010';
           Label = 'Intel Virtualization Technology (VT-x)'; Expected = @('enabled');
           Why = 'ESXi 8.x needs VT-x for 64-bit guests; Windows needs it for Hyper-V and virtualization-based security.' },
        @{ ClassId = 'biosVfIntelVTForDirectedIO'; Property = 'VpIntelVTForDirectedIO'; CheckId = 'UCS-BIOS-011';
           Label = 'Intel VT for Directed I/O (VT-d)'; Expected = @('enabled');
           Why = 'Required for DirectPath I/O, SR-IOV and PCI passthrough on ESXi, and for Credential Guard on Windows.' },
        @{ ClassId = 'biosVfProcessorCState'; Property = 'VpProcessorCState'; CheckId = 'UCS-BIOS-012';
           Label = 'Processor C state'; Expected = @('disabled');
           Why = 'Deep C states add wake latency. Cisco performance guidance disables them for latency-sensitive and virtualized workloads.' },
        @{ ClassId = 'biosVfProcessorC1E'; Property = 'VpProcessorC1E'; CheckId = 'UCS-BIOS-013';
           Label = 'Processor C1E'; Expected = @('disabled');
           Why = 'Same reason as the C state setting above.' },
        @{ ClassId = 'biosVfCPUPerformance'; Property = 'VpCPUPerformance'; CheckId = 'UCS-BIOS-014';
           Label = 'CPU performance profile'; Expected = @('enterprise', 'high-throughput');
           Why = 'Enterprise is the profile Cisco documents for virtualized server workloads.' }
    )

    foreach ($setting in $biosSettings) {
        $settingMos = @(Get-UcsBpMo -ClassId $setting.ClassId)

        if ($settingMos.Count -eq 0) {
            Add-UcsBpRow -Category $category -CheckId $setting.CheckId -Setting $setting.Label `
                -CurrentValue '(not reported)' -RecommendedValue ($setting.Expected -join ' or ') -Basis 'Best Practice' `
                -Result 'Unknown' -Severity 'Medium' -Reference $reference `
                -Remediation "Check Servers > Policies > BIOS Policies by hand. $($setting.Why)" `
                -Detail "Class '$($setting.ClassId)' returned no objects on this UCSM version."
            continue
        }

        foreach ($mo in $settingMos) {
            $dn = [string](Get-UcsBpProperty -InputObject $mo -Name 'Dn' -Default '')
            $policyName = if ($dn -match 'bios-prof-([^/]+)') { $Matches[1] } else { $dn }
            $value = [string](Get-UcsBpProperty -InputObject $mo -Name $setting.Property -Default '')

            # platform-default means the setting is left to the server model's own default. That
            # may be right, but this policy is not what decides it, so it cannot be confirmed here.
            if ($value -ieq 'platform-default') {
                Add-UcsBpRow -Category $category -CheckId $setting.CheckId -Setting "BIOS policy '$policyName' - $($setting.Label)" `
                    -ObjectDn $dn -Owner ([string](Get-UcsBpProperty -InputObject $mo -Name 'PolicyOwner' -Default '')) `
                    -CurrentValue $value -RecommendedValue ($setting.Expected -join ' or ') -Basis 'Best Practice' `
                    -Result 'Review' -Severity 'Low' -Reference $reference `
                    -Remediation "Left to the server model's platform default rather than set by this policy. Confirm the platform default is correct for this hardware. $($setting.Why)"
                continue
            }

            Add-UcsBpPropertyCheck -Mo $mo -Property $setting.Property -Expected $setting.Expected `
                -Category $category -CheckId $setting.CheckId -Setting "BIOS policy '$policyName' - $($setting.Label)" `
                -RecommendedValue ($setting.Expected -join ' or ') -Basis 'Best Practice' -Severity 'Medium' -Reference $reference `
                -Remediation "Servers > Policies > BIOS Policies. $($setting.Why)"
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Checks - vNICs, adapter policies, service profiles
# ---------------------------------------------------------------------------------------------

function Test-UcsBpVnic {
    <#
    .SYNOPSIS
        Audits vNICs, vNIC templates and Ethernet adapter policies against what ESXi and Windows
        need.

    .DESCRIPTION
        Fabric redundancy is asserted where it can be: every service profile should present at
        least two vNICs, and those vNICs should not all sit on the same fabric. That holds for
        ESXi and for Windows alike, and it is checkable from here.

        Fabric failover is reported rather than failed, because the right answer depends on the
        operating system and this domain runs both. Cisco's guidance for ESXi is to leave fabric
        failover off and let the vSwitch or distributed switch team two vNICs across fabric A and
        B - failover in two places fights itself and turns a clean path failure into a slow one.
        For a bare metal Windows server with no NIC teaming, fabric failover is the mechanism that
        provides the redundancy, so there it belongs on. The row carries the counts and the rule;
        which servers are which is not something UCS Manager knows.

        The adapter policy check is blunt and worth being blunt about: the built-in 'default'
        Ethernet adapter policy is tuned for nothing in particular. Cisco ships VMWare and Windows
        policies with the ring sizes, interrupt counts and receive-side scaling settings each
        operating system actually wants.

    .EXAMPLE
        Test-UcsBpVnic
    #>
    [CmdletBinding()]
    param()

    $category = 'vNIC and Adapter'
    $reference = 'Cisco UCS Manager Network Management Guide - Network-Related Policies; VMware and Cisco UCS adapter policy guidance'

    $vnics = @(Get-UcsBpMo -ClassId 'vnicEther')
    if (-not (Test-UcsBpClassReadable -ClassId 'vnicEther')) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-VNIC-001' -Setting 'vNICs' `
            -ClassId 'vnicEther' -RecommendedValue 'At least 2 per service profile, split across fabric A and B' -Severity 'High' -Reference $reference
        return
    }

    # --- vNICs per service profile -----------------------------------------------------------------
    # Group by the service profile Dn, which is everything to the left of the trailing /ether-<name>.
    $byProfile = @{}
    foreach ($vnic in $vnics) {
        $dn = [string](Get-UcsBpProperty -InputObject $vnic -Name 'Dn' -Default '')
        if ([string]::IsNullOrWhiteSpace($dn)) { continue }
        $profileDn = $dn -replace '/ether-[^/]+$', ''
        if (-not $byProfile.ContainsKey($profileDn)) { $byProfile[$profileDn] = New-Object System.Collections.Generic.List[object] }
        $byProfile[$profileDn].Add($vnic)
    }

    $singleVnicProfiles = New-Object System.Collections.Generic.List[object]
    $singleFabricProfiles = New-Object System.Collections.Generic.List[object]

    foreach ($profileDn in $byProfile.Keys) {
        $profileVnics = $byProfile[$profileDn].ToArray()
        if ($profileVnics.Count -lt 2) {
            $singleVnicProfiles.Add([pscustomobject]@{ Dn = $profileDn; Count = $profileVnics.Count })
            continue
        }

        # SwitchId is A, B, A-B or B-A. The first letter is the primary fabric.
        $fabrics = @(
            $profileVnics | ForEach-Object {
                $switchId = [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '')
                if ($switchId.Length -ge 1) { $switchId.Substring(0, 1).ToUpperInvariant() } else { '' }
            } | Where-Object { $_ } | Select-Object -Unique
        )
        if ($fabrics.Count -lt 2) {
            $singleFabricProfiles.Add([pscustomobject]@{ Dn = $profileDn; Fabrics = ($fabrics -join ',') })
        }
    }

    Add-UcsBpRow -Category $category -CheckId 'UCS-VNIC-001' -Setting 'Service profiles with fewer than 2 vNICs' `
        -CurrentValue $singleVnicProfiles.Count -RecommendedValue '0 - two vNICs so the host survives the loss of a fabric' `
        -Basis 'Best Practice' -Result $(if ($singleVnicProfiles.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'High' -Reference $reference `
        -Remediation 'Servers > Service Profiles > vNICs. A single vNIC gives the operating system nothing to fail over to.' `
        -Detail (@($singleVnicProfiles | Select-Object -First 20 | ForEach-Object { $_.Dn }) -join ', ')

    Add-UcsBpRow -Category $category -CheckId 'UCS-VNIC-002' -Setting 'Service profiles with all vNICs on one fabric' `
        -CurrentValue $singleFabricProfiles.Count -RecommendedValue '0 - split the vNICs across fabric A and fabric B' `
        -Basis 'Best Practice' -Result $(if ($singleFabricProfiles.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'High' -Reference $reference `
        -Remediation 'Servers > Service Profiles > vNICs. Two vNICs on the same fabric is one fabric of redundancy, whatever the operating system thinks it has.' `
        -Detail (@($singleFabricProfiles | Select-Object -First 20 | ForEach-Object { "$($_.Dn) [$($_.Fabrics)]" }) -join ', ')

    # --- Fabric failover ------------------------------------------------------------------------------
    $failoverEnabled = @($vnics | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '') -match '-' })
    Add-UcsBpRow -Category $category -CheckId 'UCS-VNIC-003' -Setting 'vNICs with fabric failover enabled' `
        -CurrentValue "$($failoverEnabled.Count) of $($vnics.Count)" `
        -RecommendedValue 'Off for ESXi hosts - let the vSwitch or distributed switch team two vNICs across both fabrics. On for bare metal Windows servers that are not using NIC teaming' `
        -Basis 'Best Practice' -Result 'Review' -Severity 'Medium' -Reference $reference `
        -Remediation 'Servers > Service Profiles > vNICs > Enable Failover. UCS Manager cannot tell which servers run ESXi and which run Windows, so this row reports the split for you to confirm against the build standard.'

    # --- Adapter policies ---------------------------------------------------------------------------------
    $defaultAdapterVnics = @($vnics | Where-Object {
            $adapterPolicy = [string](Get-UcsBpProperty -InputObject $_ -Name 'AdaptorProfileName' -Default '')
            [string]::IsNullOrWhiteSpace($adapterPolicy) -or $adapterPolicy -ieq 'default'
        })
    Add-UcsBpRow -Category $category -CheckId 'UCS-VNIC-010' -Setting 'vNICs using the default Ethernet adapter policy' `
        -CurrentValue "$($defaultAdapterVnics.Count) of $($vnics.Count)" `
        -RecommendedValue 'The operating system specific adapter policy - VMWare for ESXi hosts, Windows for Windows servers - not the built-in "default"' `
        -Basis 'Best Practice' -Result $(if ($defaultAdapterVnics.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'Medium' -Reference $reference `
        -Remediation 'Servers > Policies > Adapter Policies, then set it on the vNIC or vNIC template. The default policy uses conservative ring sizes and interrupt counts that suit neither ESXi nor Windows.' `
        -Detail (@($defaultAdapterVnics | Select-Object -First 20 | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Dn' -Default '?' }) -join ', ')

    $adapterPolicies = @(Get-UcsBpMo -ClassId 'adaptorHostEthIfProfile')
    $adapterPolicyNames = @($adapterPolicies | ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '') } | Where-Object { $_ })
    foreach ($expectedPolicy in @(
            @{ Name = 'VMWare'; CheckId = 'UCS-VNIC-011'; Workload = 'ESXi 8.x hosts' },
            @{ Name = 'Windows'; CheckId = 'UCS-VNIC-012'; Workload = 'Windows Server hosts' })) {

        $present = @($adapterPolicyNames | Where-Object { $_ -ieq $expectedPolicy.Name }).Count -gt 0
        Add-UcsBpRow -Category $category -CheckId $expectedPolicy.CheckId -Setting "Ethernet adapter policy '$($expectedPolicy.Name)' available" `
            -CurrentValue $(if ($present) { 'present' } else { 'not present' }) `
            -RecommendedValue "Present and applied to the vNICs of $($expectedPolicy.Workload)" -Basis 'Best Practice' `
            -Result $(if ($present) { 'Meets' } else { 'Does Not Meet' }) -Severity 'Low' -Reference $reference `
            -Remediation 'Servers > Policies > Adapter Policies. UCS Manager ships these policies; if one is missing it has been deleted.' `
            -Detail "Adapter policies present: $($adapterPolicyNames -join ', ')"
    }

    # --- vNIC MTU against the QoS system classes ---------------------------------------------------------
    # A vNIC set to a jumbo MTU while no QoS class carries 9216 is the misconfiguration that
    # produces working pings and failing large transfers.
    $jumboVnics = @($vnics | Where-Object {
            $mtu = [string](Get-UcsBpProperty -InputObject $_ -Name 'Mtu' -Default '1500')
            ($mtu -match '^\d+$') -and ([int]$mtu -gt 1500)
        })
    if ($jumboVnics.Count -gt 0) {
        $qosClasses = New-Object System.Collections.Generic.List[object]
        foreach ($classId in @('qosclassEthClassified', 'qosclassEthBE')) {
            foreach ($mo in @(Get-UcsBpMo -ClassId $classId)) { $qosClasses.Add($mo) }
        }
        $jumboClassPresent = @($qosClasses | Where-Object {
                ([string](Get-UcsBpProperty -InputObject $_ -Name 'AdminState' -Default 'enabled') -ieq 'enabled') -and
                ([string](Get-UcsBpProperty -InputObject $_ -Name 'Mtu' -Default '') -eq '9216')
            }).Count -gt 0

        Add-UcsBpRow -Category $category -CheckId 'UCS-VNIC-020' -Setting 'Jumbo MTU vNICs backed by a jumbo QoS class' `
            -CurrentValue "$($jumboVnics.Count) vNIC(s) above MTU 1500; QoS class at MTU 9216 present: $jumboClassPresent" `
            -RecommendedValue 'A QoS system class at MTU 9216, enabled, and the same MTU configured end to end on the upstream switches and the storage or vMotion target' `
            -Basis 'Best Practice' -Result $(if ($jumboClassPresent) { 'Meets' } else { 'Does Not Meet' }) `
            -Severity 'High' -Reference 'https://www.cisco.com/c/en/us/support/docs/servers-unified-computing/ucs-b-series-blade-servers/117601-configure-UCS-00.html' `
            -Remediation 'LAN > LAN Cloud > QoS System Class. A jumbo vNIC with no jumbo class behind it fragments or drops large frames while small ones pass, so the fault looks intermittent.' `
            -Detail (@($jumboVnics | Select-Object -First 20 | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Dn' -Default '?')=$(Get-UcsBpProperty -InputObject $_ -Name 'Mtu' -Default '?')" }) -join ', ')
    }

    # --- vNIC templates ---------------------------------------------------------------------------------
    $vnicTemplates = @(Get-UcsBpMo -ClassId 'vnicLanConnTempl')
    foreach ($template in $vnicTemplates) {
        $templateName = [string](Get-UcsBpProperty -InputObject $template -Name 'Name' -Default '?')
        Add-UcsBpPropertyCheck -Mo $template -Property 'TemplType' -Expected @('updating-template') `
            -Category $category -CheckId 'UCS-VNIC-030' -Setting "vNIC template '$templateName' - type" `
            -RecommendedValue 'updating-template - so a VLAN or policy change reaches the vNICs already created from it' `
            -Basis 'Best Practice' -Severity 'Medium' -Reference $reference `
            -Remediation 'LAN > Policies > vNIC Templates. An initial template stops applying the moment the vNIC is created, so the template and the running configuration drift apart silently.'
    }
}

function Test-UcsBpServiceProfile {
    <#
    .SYNOPSIS
        Audits service profiles for the policies they should be carrying.

    .DESCRIPTION
        A service profile is where every policy above either lands or does not. A profile with no
        host firmware package, no BIOS policy, or a maintenance policy that reboots immediately
        undoes the corresponding policy check higher up, however well configured that policy is.

        Aggregate counts come first so the CSV is readable on a large domain; individual profiles
        are then listed for each failing check, capped by -MaxDetailRowsPerCheck and never
        truncated silently.

    .EXAMPLE
        Test-UcsBpServiceProfile
    #>
    [CmdletBinding()]
    param()

    $category = 'Service Profiles'
    $reference = 'Cisco UCS Manager Server Management Guide'

    $allProfiles = @(Get-UcsBpMo -ClassId 'lsServer')
    if (-not (Test-UcsBpClassReadable -ClassId 'lsServer')) {
        Add-UcsBpUnreadableClassRow -Category $category -CheckId 'UCS-SP-001' -Setting 'Service profiles' `
            -ClassId 'lsServer' -RecommendedValue 'Every profile carrying a maintenance policy, host firmware package and BIOS policy' `
            -Severity 'High' -Reference $reference
        return
    }

    # Templates carry Type initial-template or updating-template; only the instances are servers.
    $profiles = @($allProfiles | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Type' -Default 'instance') -ieq 'instance' })
    $templates = @($allProfiles | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Type' -Default '') -imatch 'template' })

    Add-UcsBpRow -Category $category -CheckId 'UCS-SP-001' -Setting 'Service profiles and templates' `
        -CurrentValue "$($profiles.Count) profiles, $($templates.Count) templates" `
        -RecommendedValue 'Profiles created from templates, so a policy change is made once' -Basis 'Best Practice' `
        -Result 'Review' -Severity 'Info' -Reference $reference `
        -Remediation 'Servers > Service Profile Templates.'

    # --- Templates should be updating -----------------------------------------------------------------
    $initialTemplates = @($templates | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Type' -Default '') -ieq 'initial-template' })
    if ($templates.Count -gt 0) {
        Add-UcsBpRow -Category $category -CheckId 'UCS-SP-002' -Setting 'Service profile templates that are initial rather than updating' `
            -CurrentValue "$($initialTemplates.Count) of $($templates.Count)" `
            -RecommendedValue 'updating templates, so a policy change reaches the profiles already created from them' -Basis 'Best Practice' `
            -Result $(if ($initialTemplates.Count -eq 0) { 'Meets' } else { 'Review' }) -Severity 'Medium' -Reference $reference `
            -Remediation 'Servers > Service Profile Templates. An initial template is a one-time stamp; it is a legitimate choice, but it means the template no longer describes the servers made from it.' `
            -Detail (@($initialTemplates | Select-Object -First 20 | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')
    }

    if ($profiles.Count -eq 0) { return }

    # --- Policies each profile should carry ---------------------------------------------------------
    # Maintenance policy is resolved by name against the policies read earlier, so a profile
    # pointing at a policy set to immediate is caught even when the policy itself is compliant.
    $userAckPolicyNames = @(
        Get-UcsBpMo -ClassId 'lsmaintMaintPolicy' |
            Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'UptimeDisr' -Default '') -ieq 'user-ack' } |
            ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '') } |
            Where-Object { $_ }
    )

    $profileChecks = @(
        @{ CheckId = 'UCS-SP-010'; Property = 'MaintPolicyName'; Label = 'maintenance policy set to user acknowledge'; OffenderLabel = 'no maintenance policy set to user acknowledge';
           Recommended = 'A maintenance policy whose reboot policy is user-ack';
           Severity = 'High';
           Test = { param($value) ($value -and ($userAckPolicyNames -contains $value)) };
           Remediation = 'Servers > Service Profiles > Policies > Maintenance Policy. A profile with no maintenance policy, or one set to immediate, reboots the server the moment the profile is edited.' },
        @{ CheckId = 'UCS-SP-011'; Property = 'HostFwPolicyName'; Label = 'host firmware package'; OffenderLabel = 'no host firmware package';
           Recommended = 'A host firmware package, so blade and adapter firmware is managed by the profile';
           Severity = 'High';
           Test = { param($value) -not [string]::IsNullOrWhiteSpace($value) };
           Remediation = 'Servers > Service Profiles > Policies > Host Firmware Package. Without one the server keeps whatever firmware it shipped with, and no two servers end up alike.' },
        @{ CheckId = 'UCS-SP-012'; Property = 'BiosProfileName'; Label = 'BIOS policy'; OffenderLabel = 'no BIOS policy';
           Recommended = 'A BIOS policy, so virtualization and power settings are managed rather than inherited';
           Severity = 'Medium';
           Test = { param($value) -not [string]::IsNullOrWhiteSpace($value) };
           Remediation = 'Servers > Service Profiles > Policies > BIOS Policy. ESXi and Windows both depend on VT-x and VT-d being on.' },
        @{ CheckId = 'UCS-SP-013'; Property = 'LocalDiskPolicyName'; Label = 'local disk configuration policy'; OffenderLabel = 'no local disk configuration policy';
           Recommended = 'A local disk configuration policy with protect configuration set to yes';
           Severity = 'Medium';
           Test = { param($value) -not [string]::IsNullOrWhiteSpace($value) };
           Remediation = 'Servers > Service Profiles > Policies > Local Disk Configuration Policy.' },
        @{ CheckId = 'UCS-SP-014'; Property = 'SrcTemplName'; Label = 'created from a service profile template'; OffenderLabel = 'not created from a service profile template';
           Recommended = 'Created from a service profile template';
           Severity = 'Low';
           Test = { param($value) -not [string]::IsNullOrWhiteSpace($value) };
           Remediation = 'Servers > Service Profile Templates. A hand-built profile is one more thing to change by hand every time a policy changes.' }
    )

    foreach ($check in $profileChecks) {
        if (-not (Test-UcsBpPropertyPresent -InputObject $profiles[0] -Name $check.Property)) {
            Add-UcsBpRow -Category $category -CheckId $check.CheckId -Setting "Service profiles - $($check.Label)" `
                -CurrentValue '(property not reported)' -RecommendedValue $check.Recommended -Basis 'Best Practice' `
                -Result 'Unknown' -Severity $check.Severity -Reference $reference `
                -Remediation $check.Remediation `
                -Detail "Property '$($check.Property)' is not present on lsServer in this UCSM/PowerTool version."
            continue
        }

        $failing = @($profiles | Where-Object {
                $value = [string](Get-UcsBpProperty -InputObject $_ -Name $check.Property -Default '')
                -not (& $check.Test $value)
            })

        Add-UcsBpRow -Category $category -CheckId $check.CheckId -Setting "Service profiles - $($check.Label)" `
            -CurrentValue "$($profiles.Count - $failing.Count) of $($profiles.Count) compliant" `
            -RecommendedValue $check.Recommended -Basis 'Best Practice' `
            -Result $(if ($failing.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) `
            -Severity $check.Severity -Reference $reference -Remediation $check.Remediation

        if ($failing.Count -gt 0) {
            $emitted = Add-UcsBpOffenderRows -Offender $failing -Category $category -CheckId $check.CheckId `
                -Setting "Service profile - $($check.OffenderLabel)" `
                -CurrentValueScript { param($mo, $propertyName) "$(Get-UcsBpProperty -InputObject $mo -Name 'Name' -Default '?'): $propertyName=$(Get-UcsBpProperty -InputObject $mo -Name $propertyName -Default '(not set)')" } `
                -CurrentValueArgument $check.Property `
                -RecommendedValue $check.Recommended -Basis 'Best Practice' -Severity $check.Severity `
                -Remediation $check.Remediation -Reference $reference

            if ($emitted -lt $failing.Count) {
                Add-UcsBpRow -Category $category -CheckId ($check.CheckId + '-CAP') -Setting "Detail rows truncated - $($check.Label)" `
                    -CurrentValue "$emitted of $($failing.Count) listed" -RecommendedValue 'n/a' -Basis 'Site Policy' `
                    -Result 'Review' -Severity 'Info' `
                    -Remediation "Re-run with -MaxDetailRowsPerCheck $($failing.Count) to list them all."
            }
        }
    }

    # --- Association state ----------------------------------------------------------------------------
    $unassociated = @($profiles | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'AssocState' -Default '') -inotmatch '^associated$' })
    Add-UcsBpRow -Category $category -CheckId 'UCS-SP-020' -Setting 'Service profiles not associated with a server' `
        -CurrentValue $unassociated.Count -RecommendedValue 'Only the profiles deliberately staged ahead of hardware' -Basis 'Site Policy' `
        -Result 'Review' -Severity 'Low' -Reference $reference `
        -Remediation 'Servers > Service Profiles. Unassociated profiles still hold identities from the pools.' `
        -Detail (@($unassociated | Select-Object -First 20 | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?')=$(Get-UcsBpProperty -InputObject $_ -Name 'AssocState' -Default '?')" }) -join ', ')

    # --- Operating system support ----------------------------------------------------------------------
    Add-UcsBpRow -Category $category -CheckId 'UCS-SP-030' -Setting 'Operating system interoperability' `
        -CurrentValue 'ESXi 8.x and Windows Server 2012 or later, on blades and rack mounts' `
        -RecommendedValue 'Every running UCS release, adapter firmware and OS driver combination present on the Cisco UCS Hardware and Software Interoperability Matrix' `
        -Basis 'Site Policy' -Result 'Review' -Severity 'Medium' `
        -Reference 'https://ucshcltool.cloudapps.cisco.com/public/' `
        -Remediation 'Check the interoperability matrix for the running UCS release against ESXi 8.x (nenic and nfnic driver versions) and against each Windows Server release still in the estate. Note that Windows Server 2012 and 2012 R2 left Microsoft extended support in October 2023 and may not be listed as supported on current UCS releases. This script has no route to Cisco to check the matrix for you.'
}

# ---------------------------------------------------------------------------------------------
# Checks - identity pools
# ---------------------------------------------------------------------------------------------

function Test-UcsBpPools {
    <#
    .SYNOPSIS
        Audits the identity pools: management IP, MAC, UUID and IQN.

    .DESCRIPTION
        A pool that has run out is not reported as a configuration error by UCS Manager - it is
        reported later, as a service profile that will not associate, or as a KVM session that
        will not open. The ext-mgmt IP pool is the one that hurts most: when it is exhausted, new
        servers come up with no CIMC address and there is no out-of-band console to any of them.

        Pool ownership is reported because these domains are registered with UCS Central. A MAC or
        UUID pool defined locally in each domain is only unique within that domain, which is fine
        until a service profile moves between domains and brings its identity with it.

    .EXAMPLE
        Test-UcsBpPools
    #>
    [CmdletBinding()]
    param()

    $category = 'Pools'
    $reference = 'Cisco UCS Manager Server Management Guide - Pools; Cisco UCS Central Operations Guide'

    $poolClasses = @(
        @{ ClassId = 'ippoolPool';   CheckId = 'UCS-POOL-001'; Label = 'Management IP pool';  Severity = 'Critical' },
        @{ ClassId = 'macpoolPool';  CheckId = 'UCS-POOL-002'; Label = 'MAC pool';            Severity = 'High' },
        @{ ClassId = 'uuidpoolPool'; CheckId = 'UCS-POOL-003'; Label = 'UUID suffix pool';    Severity = 'High' },
        @{ ClassId = 'iqnpoolPool';  CheckId = 'UCS-POOL-004'; Label = 'IQN pool';            Severity = 'Low' }
    )

    foreach ($poolClass in $poolClasses) {
        $pools = @(Get-UcsBpMo -ClassId $poolClass.ClassId)

        if ($pools.Count -eq 0) {
            if (-not (Test-UcsBpClassReadable -ClassId $poolClass.ClassId)) {
                Add-UcsBpUnreadableClassRow -Category $category -CheckId $poolClass.CheckId -Setting $poolClass.Label `
                    -ClassId $poolClass.ClassId -RecommendedValue 'A pool with addresses still free' -Severity $poolClass.Severity -Reference $reference
            }
            continue
        }

        foreach ($pool in $pools) {
            $poolName = [string](Get-UcsBpProperty -InputObject $pool -Name 'Name' -Default '?')
            $size = [string](Get-UcsBpProperty -InputObject $pool -Name 'Size' -Default '')
            $assigned = [string](Get-UcsBpProperty -InputObject $pool -Name 'Assigned' -Default '')

            if (($size -notmatch '^\d+$') -or ($assigned -notmatch '^\d+$')) {
                Add-UcsBpRow -Category $category -CheckId $poolClass.CheckId -Setting "$($poolClass.Label) '$poolName' - free identities" `
                    -ObjectDn ([string](Get-UcsBpProperty -InputObject $pool -Name 'Dn' -Default '')) `
                    -Owner ([string](Get-UcsBpProperty -InputObject $pool -Name 'PolicyOwner' -Default '')) `
                    -CurrentValue "size=$size assigned=$assigned" -RecommendedValue 'Free identities remaining' `
                    -Basis 'Best Practice' -Result 'Unknown' -Severity $poolClass.Severity -Reference $reference `
                    -Detail 'Size or Assigned was not reported as a number.'
                continue
            }

            $free = [int]$size - [int]$assigned
            $result = if ([int]$size -eq 0) { 'Does Not Meet' } elseif ($free -le 0) { 'Does Not Meet' } else { 'Meets' }

            Add-UcsBpRow -Category $category -CheckId $poolClass.CheckId -Setting "$($poolClass.Label) '$poolName' - free identities" `
                -ObjectDn ([string](Get-UcsBpProperty -InputObject $pool -Name 'Dn' -Default '')) `
                -Owner ([string](Get-UcsBpProperty -InputObject $pool -Name 'PolicyOwner' -Default '')) `
                -CurrentValue "$free free of $size (assigned $assigned)" `
                -RecommendedValue 'At least enough free identities for the servers still to be built, and headroom for a rebuild' `
                -Basis 'Best Practice' -Result $result -Severity $poolClass.Severity -Reference $reference `
                -Remediation $(if ($poolClass.ClassId -eq 'ippoolPool') {
                        'LAN > Pools > IP Pools > ext-mgmt. An exhausted management pool leaves new servers with no CIMC address and no out-of-band console.'
                    } else {
                        'Add a block to the pool before it is needed - an exhausted pool surfaces as a service profile that will not associate.'
                    })
        }

        # --- Ownership under UCS Central --------------------------------------------------------
        if ($poolClass.ClassId -in @('macpoolPool', 'uuidpoolPool')) {
            $localPools = @($pools | Where-Object { -not (Test-UcsBpOwnerIsGlobal -Owner ([string](Get-UcsBpProperty -InputObject $_ -Name 'PolicyOwner' -Default 'local'))) })
            Add-UcsBpRow -Category $category -CheckId ($poolClass.CheckId + '-OWNER') -Setting "$($poolClass.Label)s defined locally rather than in UCS Central" `
                -CurrentValue "$($localPools.Count) of $($pools.Count)" `
                -RecommendedValue 'Global pools in UCS Central where identities must be unique across domains; local pools only where the identity never leaves this domain' `
                -Basis 'Best Practice' -Result $(if ($localPools.Count -eq 0) { 'Meets' } else { 'Review' }) `
                -Severity 'Medium' -Reference 'Cisco UCS Central Operations Guide' `
                -Remediation 'A locally defined pool is unique within this domain only. Two domains each handing out from their own local pool can issue the same MAC address, and the symptom appears upstream, not here.' `
                -Detail (@($localPools | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')
        }
    }

    # No Fibre Channel on this deployment, so the WWNN and WWPN pools are not expected to exist.
    $wwnPools = @(Get-UcsBpMo -ClassId 'fcpoolInitiators')
    Add-UcsBpRow -Category $category -CheckId 'UCS-POOL-010' -Setting 'WWNN/WWPN pools' `
        -CurrentValue $wwnPools.Count -RecommendedValue 'None - this deployment is Ethernet only' -Basis 'Site Policy' `
        -Result $(if ($wwnPools.Count -eq 0) { 'Meets' } else { 'Review' }) -Severity 'Info' -Reference $reference `
        -Remediation 'SAN > Pools. World wide name pools on an Ethernet-only domain are leftovers; confirm nothing is using them before removing them.' `
        -Detail (@($wwnPools | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')

    # --- Server pools ------------------------------------------------------------------------------
    $serverPools = @(Get-UcsBpMo -ClassId 'computePool')
    Add-UcsBpRow -Category $category -CheckId 'UCS-POOL-020' -Setting 'Server pools' `
        -CurrentValue $serverPools.Count `
        -RecommendedValue 'Server pools with qualification policies, so blades and rack mounts are assigned by capability rather than by hand' `
        -Basis 'Best Practice' -Result $(if ($serverPools.Count -ge 1) { 'Meets' } else { 'Review' }) `
        -Severity 'Low' -Reference $reference `
        -Remediation 'Servers > Pools > Server Pools. With blades and rack mounts in the same domain, qualification is what keeps a profile built for one from landing on the other.' `
        -Detail (@($serverPools | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?')($(Get-UcsBpProperty -InputObject $_ -Name 'Size' -Default '?'))" }) -join ', ')
}

# ---------------------------------------------------------------------------------------------
# Checks - what actually breaks when one fabric interconnect goes away
# ---------------------------------------------------------------------------------------------

function Get-UcsBpFabricOf {
    <#
    .SYNOPSIS
        Works out which fabric interconnect an object belongs to.

    .DESCRIPTION
        Different UCSM classes say this differently - SwitchId on most fabric objects, Id on an
        IO module, and for anything else the fabric is embedded in the Dn as /A/ or /B/. Rather
        than every check knowing all three, they ask here.

        A vNIC reports A, B, A-B or B-A, where the pair form means fabric failover is on and the
        first letter is the primary. Only the first letter is returned, because for the question
        this section asks - what is lost when a fabric goes - the primary is what matters.

    .PARAMETER Mo
        The managed object.

    .PARAMETER NumericIdIsFabric
        Treat Id 1 as fabric A and Id 2 as fabric B. IO modules number themselves that way rather
        than lettering themselves, and nothing else does - so it is opt-in. Left on by default it
        would resolve a port channel with Id 1 to fabric A, silently and wrongly.

    .EXAMPLE
        $fabric = Get-UcsBpFabricOf -Mo $uplink

    .EXAMPLE
        $fabric = Get-UcsBpFabricOf -Mo $ioModule -NumericIdIsFabric
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        $Mo,

        [switch]$NumericIdIsFabric
    )

    foreach ($property in @('SwitchId', 'Fabric', 'Id')) {
        $value = [string](Get-UcsBpProperty -InputObject $Mo -Name $property -Default '')
        if ($value -match '^([AaBb])') { return $Matches[1].ToUpperInvariant() }
    }

    $dn = [string](Get-UcsBpProperty -InputObject $Mo -Name 'Dn' -Default '')
    if ($dn -match '/(?:sw-)?([AB])(?:/|$)') { return $Matches[1].ToUpperInvariant() }

    if ($NumericIdIsFabric) {
        $id = [string](Get-UcsBpProperty -InputObject $Mo -Name 'Id' -Default '')
        if ($id -eq '1') { return 'A' }
        if ($id -eq '2') { return 'B' }
    }

    return ''
}

function Test-UcsBpFabricFailover {
    <#
    .SYNOPSIS
        Audits what the domain loses when a single fabric interconnect is rebooted.

    .DESCRIPTION
        A subordinate fabric interconnect reboot is supposed to be a non-event: the surviving
        fabric carries everything until the other comes back. When it is not a non-event, the
        cause is almost always one of a small number of configurations, and every one of them is
        visible here while both fabrics are up. That is the point - none of these show as a fault,
        and the domain looks healthy right up until the reboot.

        The section asks one question per fabric: if this one disappeared right now, what would
        have no path? It looks at six ways the answer can be "everything":

          1. THE SURVIVING FABRIC HAS NO WORKING UPLINKS. If one fabric's uplinks are already down
             or were never configured, the domain has been running on a single fabric without
             anyone noticing, and rebooting that one is a total outage rather than a failover.
             This is the first thing to rule out and the most commonly missed, because the domain
             raises no fault for it - the traffic is flowing, just all through one side.

          2. THE FABRIC INTERCONNECTS ARE IN SWITCHING MODE. In end-host mode a fabric interconnect
             does not run spanning tree; it is invisible to the upstream topology, and rebooting
             one changes nothing outside the domain. In switching mode it joins the spanning tree,
             and a reboot triggers a topology change the upstream network has to reconverge around.
             That is how a subordinate reboot takes out things that are nothing to do with UCS.

          3. A VLAN, OR A WHOLE VLAN GROUP, LIVES ON ONE FABRIC ONLY. A VLAN defined on one fabric
             disappears with it. A VLAN group bound only to uplinks on one fabric is worse: the
             VLANs in it have no upstream path from the other fabric at all, so the traffic dies
             even for servers whose vNIC is on the surviving side.

          4. TRAFFIC IS PINNED TO ONE FABRIC. A LAN pin group targeting a single fabric's uplink
             overrides dynamic pinning, so the vNICs using it do not repin to the surviving fabric.

          5. SERVERS HAVE NO SECOND PATH. A service profile whose vNICs are all on one fabric has
             nothing to fail over to, whatever the network above it does.

          6. THE FAILURE IS SILENT. This is the one that turns a survivable event into an outage.
             A network control policy with Action on Uplink Fail set to warning leaves the vNIC UP
             when its fabric loses its uplinks. The operating system sees a live link, keeps using
             it, and never fails over - so instead of a brief repin, the host blackholes for as
             long as the fabric is gone. ESXi and Windows teaming both depend on the link going
             down to react.

        Where a check cannot read what it needs it says so rather than passing. On this question in
        particular, an absent row is worse than useless: it reads as "checked, fine".

    .EXAMPLE
        Test-UcsBpFabricFailover
    #>
    [CmdletBinding()]
    param()

    $category = 'Fabric Failover'
    $reference = 'Cisco UCS Manager Network Management Guide - LAN Connectivity, LAN Uplinks Manager, Pin Groups'
    $fabrics = @('A', 'B')

    # --- Which fabric is subordinate right now --------------------------------------------------
    $mgmtEntities = @(Get-UcsBpMo -ClassId 'mgmtEntity')
    $leadership = @($mgmtEntities | ForEach-Object {
            "$(Get-UcsBpProperty -InputObject $_ -Name 'Id' -Default '?')=$(Get-UcsBpProperty -InputObject $_ -Name 'LeadershipState' -Default '?')"
        })
    Add-UcsBpRow -Category $category -CheckId 'UCS-FO-001' -Setting 'Cluster leadership (which fabric interconnect is subordinate)' `
        -ObjectDn 'sys' -CurrentValue ($leadership -join ', ') `
        -RecommendedValue 'One primary and one subordinate. Recorded so a reboot can be correlated with the fabric it happened on' `
        -Basis 'Site Policy' -Result 'Review' -Severity 'Info' -Reference $reference `
        -Remediation 'Equipment > Fabric Interconnects. Leadership moves on failover, so the fabric that was subordinate during an incident is not necessarily the subordinate now.'

    # --- 1. Is either fabric already carrying everything? ----------------------------------------
    $uplinkPcs = @(Get-UcsBpMo -ClassId 'fabricEthLanPc')
    $uplinkPcMembers = @(Get-UcsBpMo -ClassId 'fabricEthLanPcEp')
    $standaloneUplinks = @(Get-UcsBpMo -ClassId 'fabricEthLanEp')

    $upCountByFabric = @{}
    foreach ($fabric in $fabrics) {
        # Members of an operationally up port channel, plus any standalone uplink that is up.
        $upPcs = @($uplinkPcs | Where-Object {
                ((Get-UcsBpFabricOf -Mo $_) -eq $fabric) -and
                ([string](Get-UcsBpProperty -InputObject $_ -Name 'OperState' -Default '') -imatch '^(up|indeterminate)$')
            })
        $upPcNames = @($upPcs | ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Dn' -Default '') })

        $upMembers = @($uplinkPcMembers | Where-Object {
                $memberDn = [string](Get-UcsBpProperty -InputObject $_ -Name 'Dn' -Default '')
                $parent = $memberDn -replace '/[^/]+$', ''
                ($upPcNames -contains $parent)
            })

        $upStandalone = @($standaloneUplinks | Where-Object {
                ((Get-UcsBpFabricOf -Mo $_) -eq $fabric) -and
                ([string](Get-UcsBpProperty -InputObject $_ -Name 'OperState' -Default '') -imatch '^up$')
            })

        $upCount = $upPcs.Count + $upStandalone.Count
        $upCountByFabric[$fabric] = $upCount

        Add-UcsBpRow -Category $category -CheckId 'UCS-FO-002' -Setting "Fabric $fabric - working northbound uplinks" `
            -ObjectDn "fabric/lan/$fabric" `
            -CurrentValue "$upCount up ($($upPcs.Count) port channel(s) with $($upMembers.Count) member port(s), $($upStandalone.Count) standalone)" `
            -RecommendedValue 'At least one operationally up uplink per fabric. A fabric with none is not a redundant path - the domain is already running on one side' `
            -Basis 'Best Practice' -Result $(if ($upCount -ge 1) { 'Meets' } else { 'Does Not Meet' }) `
            -Severity 'Critical' -Reference $reference `
            -Remediation "LAN > LAN Cloud > Fabric $fabric > Port Channels. If this fabric has no working uplink, every server is reaching the network through the other one - and rebooting THAT one is a total outage, not a failover. UCS Manager raises no fault for this: the traffic is flowing, just all through one side."
    }

    # The cross-check that matters most for a subordinate reboot that took everything down.
    $fabricsWithUplinks = @($fabrics | Where-Object { $upCountByFabric[$_] -ge 1 })
    Add-UcsBpRow -Category $category -CheckId 'UCS-FO-003' -Setting 'Both fabrics have a working northbound path' `
        -ObjectDn 'fabric/lan' `
        -CurrentValue "A: $($upCountByFabric['A']) up, B: $($upCountByFabric['B']) up" `
        -RecommendedValue 'Both fabrics with at least one working uplink, so either can be rebooted without taking the domain off the network' `
        -Basis 'Best Practice' -Result $(if ($fabricsWithUplinks.Count -eq 2) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'Critical' -Reference $reference `
        -Remediation 'If only one fabric has working uplinks, that fabric is a single point of failure for the whole domain and rebooting it explains a complete downstream outage exactly. Fix the dead fabric''s uplinks before the next reboot of either.'

    # --- 2. Switching mode and spanning tree -----------------------------------------------------
    $lanCloud = @(Get-UcsBpMo -ClassId 'fabricLanCloud') | Select-Object -First 1
    $switchingMode = [string](Get-UcsBpProperty -InputObject $lanCloud -Name 'Mode' -Default '')
    $isEndHost = ($switchingMode -imatch 'end-host')
    Add-UcsBpRow -Category $category -CheckId 'UCS-FO-010' -Setting 'Ethernet switching mode, and whether a reboot disturbs the upstream network' `
        -ObjectDn 'fabric/lan' -Owner ([string](Get-UcsBpProperty -InputObject $lanCloud -Name 'PolicyOwner' -Default '')) `
        -CurrentValue $switchingMode `
        -RecommendedValue 'end-host - the fabric interconnects stay out of the spanning tree, so rebooting one changes nothing outside the domain' `
        -Basis 'Best Practice' -Result $(if ($isEndHost) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'Critical' `
        -Reference 'https://www.cisco.com/c/en/us/solutions/collateral/data-center-virtualization/unified-computing/whitepaper_c11-701962.html' `
        -Remediation 'LAN > LAN Cloud > Fabric A/B. In switching mode the fabric interconnect participates in spanning tree, so rebooting one raises a topology change the upstream network must reconverge around - which is how a subordinate reboot takes down things unrelated to UCS. Changing the mode reboots the fabric interconnect, so it is a change-window job.'

    if (-not $isEndHost) {
        $stpInstances = @(Get-UcsBpMo -ClassId 'stpInstance')
        Add-UcsBpRow -Category $category -CheckId 'UCS-FO-011' -Setting 'Spanning tree instances (switching mode only)' `
            -ObjectDn 'fabric/lan' -CurrentValue $stpInstances.Count `
            -RecommendedValue 'Reviewed against the upstream design - in switching mode the fabric interconnect is part of the L2 topology and its priority, root placement and port roles all matter' `
            -Basis 'Site Policy' -Result 'Review' -Severity 'High' -Reference $reference `
            -Remediation 'Confirm with the network team where the root bridge sits and what happens to it when a fabric interconnect reboots. This is the most likely explanation for an upstream outage triggered by a UCS reboot.' `
            -Detail (@($stpInstances | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Dn' -Default '?')" }) -join ', ')
    }

    # --- 3. VLANs and VLAN groups that live on one fabric only -----------------------------------
    $vlans = @(Get-UcsBpMo -ClassId 'fabricVlan')
    $singleFabricVlans = @($vlans | Where-Object {
            $switchId = [string](Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default 'dual')
            $switchId -ieq 'A' -or $switchId -ieq 'B'
        })
    Add-UcsBpRow -Category $category -CheckId 'UCS-FO-020' -Setting 'VLANs that disappear with a single fabric' `
        -ObjectDn 'fabric/lan' -CurrentValue $singleFabricVlans.Count `
        -RecommendedValue '0 - a VLAN defined on one fabric only ceases to exist while that fabric is rebooting' `
        -Basis 'Best Practice' -Result $(if ($singleFabricVlans.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'High' -Reference $reference `
        -Remediation 'LAN > LAN Cloud > VLANs. See UCS-VLAN-003 for the same finding with the offending VLANs named.' `
        -Detail (@($singleFabricVlans | Select-Object -First 20 | ForEach-Object { "$(Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?')(id $(Get-UcsBpProperty -InputObject $_ -Name 'Id' -Default '?')) on $(Get-UcsBpProperty -InputObject $_ -Name 'SwitchId' -Default '?')" }) -join ', ')

    # A VLAN group bound only to one fabric's uplinks is the nastier version: the VLANs in it have
    # no upstream path from the other fabric at all, so traffic dies even for servers on the
    # surviving side. The binding objects differ across releases, so several are tried.
    $vlanGroups = @(Get-UcsBpMo -ClassId 'fabricNetGroup')
    if ($vlanGroups.Count -eq 0) {
        Add-UcsBpRow -Category $category -CheckId 'UCS-FO-021' -Setting 'VLAN groups bound to one fabric only' `
            -ObjectDn 'fabric/lan' -CurrentValue 'no VLAN groups defined' `
            -RecommendedValue 'Where VLAN groups are used, each should be bound to uplinks on both fabrics' `
            -Basis 'Best Practice' -Result 'Not Applicable' -Severity 'Info' -Reference $reference `
            -Remediation 'Without VLAN groups every VLAN is trunked on every uplink, so there is no per-group fabric binding to get wrong.'
    }
    else {
        $groupRefs = @()
        $refClassUsed = ''
        foreach ($refClass in @('fabricNetGroupRef', 'fabricPooledVlan', 'fabricVlanReq')) {
            $candidate = @(Get-UcsBpMo -ClassId $refClass)
            if ($candidate.Count -gt 0) { $groupRefs = $candidate; $refClassUsed = $refClass; break }
        }

        if ($groupRefs.Count -eq 0) {
            Add-UcsBpRow -Category $category -CheckId 'UCS-FO-021' -Setting 'VLAN groups bound to one fabric only' `
                -ObjectDn 'fabric/lan' -CurrentValue '(bindings could not be read)' `
                -RecommendedValue 'Each VLAN group bound to uplinks on BOTH fabrics' -Basis 'Best Practice' `
                -Result 'Unknown' -Severity 'High' -Reference $reference `
                -Remediation 'Check this by hand: LAN > LAN Cloud > LAN Uplinks Manager > VLAN Groups, and confirm every group lists uplinks on fabric A and fabric B. A group bound to one fabric only leaves its VLANs with no upstream path from the other fabric - traffic dies even for servers whose vNIC is on the surviving side.' `
                -Detail "None of fabricNetGroupRef, fabricPooledVlan or fabricVlanReq returned objects on this UCSM version, so the group-to-uplink binding could not be determined."
        }
        else {
            foreach ($group in $vlanGroups) {
                $groupName = [string](Get-UcsBpProperty -InputObject $group -Name 'Name' -Default '?')
                $groupDn = [string](Get-UcsBpProperty -InputObject $group -Name 'Dn' -Default '')

                # A binding that names this group, wherever it hangs. The fabric comes from the Dn
                # of the object the binding sits under - an uplink port or port channel.
                $bindings = @($groupRefs | Where-Object {
                        ([string](Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '') -ieq $groupName) -and
                        ([string](Get-UcsBpProperty -InputObject $_ -Name 'Dn' -Default '') -notlike "$groupDn/*")
                    })
                $boundFabrics = @($bindings | ForEach-Object { Get-UcsBpFabricOf -Mo $_ } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)

                if ($bindings.Count -eq 0) {
                    Add-UcsBpRow -Category $category -CheckId 'UCS-FO-021' -Setting "VLAN group '$groupName' - uplink bindings" `
                        -ObjectDn $groupDn -Owner ([string](Get-UcsBpProperty -InputObject $group -Name 'PolicyOwner' -Default '')) `
                        -CurrentValue '(no uplink binding found)' -RecommendedValue 'Bound to uplinks on both fabric A and fabric B' `
                        -Basis 'Best Practice' -Result 'Review' -Severity 'High' -Reference $reference `
                        -Remediation "LAN > LAN Cloud > LAN Uplinks Manager > VLAN Groups > $groupName. No binding was found for this group by reading $refClassUsed - confirm by hand which uplinks it is associated with."
                    continue
                }

                Add-UcsBpRow -Category $category -CheckId 'UCS-FO-021' -Setting "VLAN group '$groupName' - uplink bindings span both fabrics" `
                    -ObjectDn $groupDn -Owner ([string](Get-UcsBpProperty -InputObject $group -Name 'PolicyOwner' -Default '')) `
                    -CurrentValue ("bound on fabric(s): " + ($boundFabrics -join ', ')) `
                    -RecommendedValue 'Bound to uplinks on both fabric A and fabric B' -Basis 'Best Practice' `
                    -Result $(if ($boundFabrics.Count -ge 2) { 'Meets' } else { 'Does Not Meet' }) `
                    -Severity 'Critical' -Reference $reference `
                    -Remediation "LAN > LAN Cloud > LAN Uplinks Manager > VLAN Groups > $groupName. A group bound to one fabric only leaves every VLAN in it with no upstream path from the other fabric, so rebooting the bound fabric drops that traffic for ALL servers - including those whose vNIC is on the surviving side." `
                    -Detail "Read from $refClassUsed; $($bindings.Count) binding(s)."
            }
        }
    }

    # --- 4. Static pinning ------------------------------------------------------------------------
    $pinGroups = @(Get-UcsBpMo -ClassId 'fabricLanPinGroup')
    $pinTargets = @(Get-UcsBpMo -ClassId 'fabricLanPinTarget')
    if ($pinGroups.Count -eq 0) {
        Add-UcsBpRow -Category $category -CheckId 'UCS-FO-030' -Setting 'LAN pin groups (static uplink pinning)' `
            -ObjectDn 'fabric/lan' -CurrentValue 'none defined' `
            -RecommendedValue 'None - dynamic pinning repins a vNIC to a surviving uplink automatically; a static pin does not' `
            -Basis 'Best Practice' -Result 'Meets' -Severity 'Info' -Reference $reference `
            -Remediation 'Nothing to do. Dynamic pinning is what lets a vNIC move to another uplink when its own goes away.'
    }
    else {
        foreach ($pinGroup in $pinGroups) {
            $pinName = [string](Get-UcsBpProperty -InputObject $pinGroup -Name 'Name' -Default '?')
            $pinDn = [string](Get-UcsBpProperty -InputObject $pinGroup -Name 'Dn' -Default '')
            $targets = @($pinTargets | Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Dn' -Default '') -like "$pinDn/*" })
            $targetFabrics = @($targets | ForEach-Object {
                    $epDn = [string](Get-UcsBpProperty -InputObject $_ -Name 'EpDn' -Default '')
                    $fabricFromEp = if ($epDn -match '/(?:sw-)?([AB])(?:/|$)') { $Matches[1].ToUpperInvariant() } else { Get-UcsBpFabricOf -Mo $_ }
                    $fabricFromEp
                } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)

            Add-UcsBpRow -Category $category -CheckId 'UCS-FO-030' -Setting "LAN pin group '$pinName' - fabrics targeted" `
                -ObjectDn $pinDn -Owner ([string](Get-UcsBpProperty -InputObject $pinGroup -Name 'PolicyOwner' -Default '')) `
                -CurrentValue $(if ($targetFabrics.Count -gt 0) { $targetFabrics -join ', ' } else { '(no target found)' }) `
                -RecommendedValue 'A target on both fabrics, or no pin group at all so dynamic pinning applies' `
                -Basis 'Best Practice' -Result $(if ($targetFabrics.Count -ge 2) { 'Meets' } else { 'Does Not Meet' }) `
                -Severity 'High' -Reference $reference `
                -Remediation "LAN > LAN Cloud > LAN Pin Groups > $pinName. A vNIC pinned to one fabric's uplink does not repin to the surviving fabric when that uplink goes away - it simply loses its path." `
                -Detail "$($targets.Count) target(s): $(@($targets | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'EpDn' -Default '?' }) -join ', ')"
        }
    }

    # --- 5. Servers with no second path -----------------------------------------------------------
    $vnics = @(Get-UcsBpMo -ClassId 'vnicEther')
    $byProfile = @{}
    foreach ($vnic in $vnics) {
        $dn = [string](Get-UcsBpProperty -InputObject $vnic -Name 'Dn' -Default '')
        if ([string]::IsNullOrWhiteSpace($dn)) { continue }
        $profileDn = $dn -replace '/ether-[^/]+$', ''
        if (-not $byProfile.ContainsKey($profileDn)) { $byProfile[$profileDn] = New-Object System.Collections.Generic.List[object] }
        $byProfile[$profileDn].Add($vnic)
    }

    $strandedByFabric = @{ 'A' = 0; 'B' = 0 }
    $strandedProfiles = New-Object System.Collections.Generic.List[object]
    foreach ($profileDn in $byProfile.Keys) {
        $profileVnics = $byProfile[$profileDn].ToArray()
        $profileFabrics = @($profileVnics | ForEach-Object { Get-UcsBpFabricOf -Mo $_ } | Where-Object { $_ } | Select-Object -Unique)
        if ($profileFabrics.Count -eq 1) {
            $only = $profileFabrics[0]
            if ($strandedByFabric.ContainsKey($only)) { $strandedByFabric[$only]++ }
            $strandedProfiles.Add([pscustomobject]@{ Dn = $profileDn; Fabric = $only })
        }
    }

    Add-UcsBpRow -Category $category -CheckId 'UCS-FO-040' -Setting 'Service profiles that lose all networking with one fabric' `
        -ObjectDn 'org-root' `
        -CurrentValue "$($strandedProfiles.Count) (A only: $($strandedByFabric['A']), B only: $($strandedByFabric['B']))" `
        -RecommendedValue '0 - every service profile with vNICs on both fabrics' -Basis 'Best Practice' `
        -Result $(if ($strandedProfiles.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'Critical' -Reference $reference `
        -Remediation 'Servers > Service Profiles > vNICs. A server whose vNICs are all on one fabric has nothing to fail over to, whatever the network above it does.' `
        -Detail (@($strandedProfiles | Select-Object -First 20 | ForEach-Object { "$($_.Dn) [fabric $($_.Fabric) only]" }) -join ', ')

    if ($strandedProfiles.Count -gt 0) {
        $emitted = Add-UcsBpOffenderRows -Offender $strandedProfiles.ToArray() -Category $category -CheckId 'UCS-FO-040' `
            -Setting 'Service profile with vNICs on one fabric only' `
            -CurrentValueScript { param($mo, $arg) "$($mo.Dn) has vNICs on fabric $($mo.Fabric) only" } `
            -RecommendedValue 'vNICs on both fabric A and fabric B' -Basis 'Best Practice' -Severity 'Critical' `
            -Remediation 'Servers > Service Profiles > vNICs.' -Reference $reference
        if ($emitted -lt $strandedProfiles.Count) {
            Add-UcsBpRow -Category $category -CheckId 'UCS-FO-040-CAP' -Setting 'Stranded service profile detail rows truncated' `
                -CurrentValue "$emitted of $($strandedProfiles.Count) listed" -RecommendedValue 'n/a' -Basis 'Site Policy' `
                -Result 'Review' -Severity 'Info' `
                -Remediation "Re-run with -MaxDetailRowsPerCheck $($strandedProfiles.Count) to list them all."
        }
    }

    # --- 6. Whether the loss is signalled to the operating system ----------------------------------
    # The one that turns a survivable event into an outage.
    $nwPolicies = @(Get-UcsBpMo -ClassId 'nwctrlDefinition')
    $silentPolicies = @($nwPolicies | Where-Object {
            [string](Get-UcsBpProperty -InputObject $_ -Name 'UplinkFailAction' -Default '') -inotmatch '^link-down$'
        })
    $silentPolicyNames = @($silentPolicies | ForEach-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?') })
    $vnicsOnSilentPolicy = @($vnics | Where-Object {
            $policyName = [string](Get-UcsBpProperty -InputObject $_ -Name 'NwCtrlPolicyName' -Default '')
            $policyName -and ($silentPolicyNames -contains $policyName)
        })

    Add-UcsBpRow -Category $category -CheckId 'UCS-FO-050' -Setting 'Uplink loss is signalled to the server (Action on Uplink Fail)' `
        -ObjectDn 'org-root' `
        -CurrentValue "$($silentPolicies.Count) of $($nwPolicies.Count) network control policies set to warning; $($vnicsOnSilentPolicy.Count) vNIC(s) using them" `
        -RecommendedValue 'link-down on every network control policy, so a vNIC whose fabric loses its uplinks goes down and the operating system fails over' `
        -Basis 'Best Practice' -Result $(if ($silentPolicies.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'Critical' -Reference $reference `
        -Remediation 'LAN > Policies > Network Control Policies. Set to warning, the vNIC stays UP when its fabric has no northbound path. ESXi and Windows teaming both react to the link going down, so with warning they keep sending into a fabric that has nowhere to send it - which turns a brief repin into a blackhole lasting as long as the reboot.' `
        -Detail "Policies set to warning: $($silentPolicyNames -join ', ')"

    # --- Do the two fabrics reach the same upstream switch? ----------------------------------------
    # Only visible when the information policy is enabled, which is why that check is not cosmetic.
    $neighbours = @()
    $neighbourClass = ''
    foreach ($candidateClass in @('networkLanNeighborEntry', 'lldpAdjEp', 'cdpAdjEp')) {
        $candidate = @(Get-UcsBpMo -ClassId $candidateClass)
        if ($candidate.Count -gt 0) { $neighbours = $candidate; $neighbourClass = $candidateClass; break }
    }

    if ($neighbours.Count -eq 0) {
        Add-UcsBpRow -Category $category -CheckId 'UCS-FO-060' -Setting 'Upstream switches each fabric connects to' `
            -ObjectDn 'fabric/lan' -CurrentValue '(no neighbour information)' `
            -RecommendedValue 'Each fabric uplinked to a different upstream switch, so one upstream device is not a single point of failure for both' `
            -Basis 'Best Practice' -Result 'Unknown' -Severity 'High' -Reference $reference `
            -Remediation 'Enable Equipment > Policies > Global Policies > Info Policy (see UCS-EQP-012), then re-run - without it UCS Manager reports no LAN neighbours and this cannot be answered from here. Otherwise trace the uplink cabling by hand: if both fabrics land on the same upstream switch, that switch is a single point of failure for the whole domain.'
    }
    else {
        $neighboursByFabric = @{}
        foreach ($fabric in $fabrics) {
            $names = @($neighbours | Where-Object { (Get-UcsBpFabricOf -Mo $_) -eq $fabric } | ForEach-Object {
                    $name = ''
                    foreach ($property in @('SysName', 'DeviceId', 'SystemName', 'ChassisId', 'Name')) {
                        $value = [string](Get-UcsBpProperty -InputObject $_ -Name $property -Default '')
                        if ($value) { $name = $value; break }
                    }
                    $name
                } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
            $neighboursByFabric[$fabric] = $names

            Add-UcsBpRow -Category $category -CheckId 'UCS-FO-060' -Setting "Fabric $fabric - upstream switches seen" `
                -ObjectDn "fabric/lan/$fabric" -CurrentValue $(if ($names.Count) { $names -join ', ' } else { '(none seen)' }) `
                -RecommendedValue 'At least one upstream neighbour, and not the same single device as the other fabric' `
                -Basis 'Best Practice' -Result $(if ($names.Count -ge 1) { 'Meets' } else { 'Review' }) `
                -Severity 'Medium' -Reference $reference `
                -Remediation "Read from $neighbourClass. LAN > LAN Cloud > LAN Uplinks Manager shows the same view."
        }

        $sharedUpstream = @($neighboursByFabric['A'] | Where-Object { $neighboursByFabric['B'] -contains $_ })
        $bothHaveNeighbours = (($neighboursByFabric['A'].Count -gt 0) -and ($neighboursByFabric['B'].Count -gt 0))
        if ($bothHaveNeighbours) {
            $onlyShared = (($sharedUpstream.Count -gt 0) -and
                           ($neighboursByFabric['A'].Count -eq $sharedUpstream.Count) -and
                           ($neighboursByFabric['B'].Count -eq $sharedUpstream.Count))
            Add-UcsBpRow -Category $category -CheckId 'UCS-FO-061' -Setting 'Both fabrics depend on the same upstream switch' `
                -ObjectDn 'fabric/lan' `
                -CurrentValue $(if ($sharedUpstream.Count -gt 0) { "shared: $($sharedUpstream -join ', ')" } else { 'no shared upstream device' }) `
                -RecommendedValue 'Each fabric reaching the network through a different upstream switch, so no single upstream device carries both' `
                -Basis 'Best Practice' -Result $(if ($onlyShared) { 'Does Not Meet' } else { 'Meets' }) `
                -Severity 'High' -Reference $reference `
                -Remediation 'If both fabrics reach the network only through one upstream switch, that switch - not the fabric interconnect - is the single point of failure, and work on it looks exactly like a UCS outage.'
        }
    }

    # --- Chassis reachable from both fabrics -------------------------------------------------------
    $ioCards = @(Get-UcsBpMo -ClassId 'equipmentIOCard')
    if ($ioCards.Count -gt 0) {
        $chassisWithOneSide = New-Object System.Collections.Generic.List[string]
        foreach ($chassisGroup in ($ioCards | Group-Object -Property { [string](Get-UcsBpProperty -InputObject $_ -Name 'ChassisId' -Default '?') })) {
            $sides = @($chassisGroup.Group |
                    Where-Object { [string](Get-UcsBpProperty -InputObject $_ -Name 'OperState' -Default 'operable') -inotmatch 'removed|inoperable' } |
                    ForEach-Object { Get-UcsBpFabricOf -Mo $_ -NumericIdIsFabric } | Where-Object { $_ } | Select-Object -Unique)
            if ($sides.Count -lt 2) { $chassisWithOneSide.Add("chassis $($chassisGroup.Name) [$($sides -join ',')]") }
        }

        Add-UcsBpRow -Category $category -CheckId 'UCS-FO-070' -Setting 'Chassis reachable from one fabric only' `
            -ObjectDn 'sys' -CurrentValue $chassisWithOneSide.Count `
            -RecommendedValue '0 - every chassis with a working IO module on both fabrics' -Basis 'Best Practice' `
            -Result $(if ($chassisWithOneSide.Count -eq 0) { 'Meets' } else { 'Does Not Meet' }) `
            -Severity 'Critical' -Reference $reference `
            -Remediation 'Equipment > Chassis > IO Modules. A chassis with only one working IO module loses every blade in it when that fabric reboots, regardless of how the service profiles are configured.' `
            -Detail ($chassisWithOneSide.ToArray() -join ', ')
    }

    # --- Appliance ports ---------------------------------------------------------------------------
    $appliancePorts = @(Get-UcsBpMo -ClassId 'fabricEthEstcEp')
    $appliancePcs = @(Get-UcsBpMo -ClassId 'fabricEthEstcPc')
    $applianceTotal = $appliancePorts.Count + $appliancePcs.Count
    if ($applianceTotal -gt 0) {
        $applianceFabrics = @(@($appliancePorts) + @($appliancePcs) | ForEach-Object { Get-UcsBpFabricOf -Mo $_ } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
        Add-UcsBpRow -Category $category -CheckId 'UCS-FO-080' -Setting 'Appliance ports present on both fabrics' `
            -ObjectDn 'fabric/eth-estc' -CurrentValue ("$applianceTotal appliance port(s)/port channel(s) on fabric(s): " + ($applianceFabrics -join ', ')) `
            -RecommendedValue 'Appliance connectivity on both fabrics, so directly attached storage or services survive one fabric rebooting' `
            -Basis 'Best Practice' -Result $(if ($applianceFabrics.Count -ge 2) { 'Meets' } else { 'Does Not Meet' }) `
            -Severity 'High' -Reference $reference `
            -Remediation 'LAN > Appliances. Anything cabled to appliance ports on one fabric only goes away with that fabric.'
    }

    # --- vNIC templates -----------------------------------------------------------------------------
    $vnicTemplates = @(Get-UcsBpMo -ClassId 'vnicLanConnTempl')
    if ($vnicTemplates.Count -gt 0 -and (Test-UcsBpPropertyPresent -InputObject $vnicTemplates[0] -Name 'RedundancyPairType')) {
        $unpaired = @($vnicTemplates | Where-Object {
                [string](Get-UcsBpProperty -InputObject $_ -Name 'RedundancyPairType' -Default 'none') -ieq 'none'
            })
        Add-UcsBpRow -Category $category -CheckId 'UCS-FO-090' -Setting 'vNIC templates without a redundancy pair' `
            -ObjectDn 'org-root' -CurrentValue "$($unpaired.Count) of $($vnicTemplates.Count)" `
            -RecommendedValue 'Templates paired primary/secondary across the fabrics, so an A-side and B-side vNIC stay in step' `
            -Basis 'Best Practice' -Result $(if ($unpaired.Count -eq 0) { 'Meets' } else { 'Review' }) `
            -Severity 'Medium' -Reference $reference `
            -Remediation 'LAN > Policies > vNIC Templates. Unpaired templates drift: a VLAN added to the A-side template and forgotten on the B-side is invisible until the A fabric reboots.' `
            -Detail (@($unpaired | Select-Object -First 20 | ForEach-Object { Get-UcsBpProperty -InputObject $_ -Name 'Name' -Default '?' }) -join ', ')
    }
}

# ---------------------------------------------------------------------------------------------
# Checks - UCS Central
# ---------------------------------------------------------------------------------------------

function Test-UcsBpUcsCentral {
    <#
    .SYNOPSIS
        Audits the UCS Central registration and every policy resolution control.

    .DESCRIPTION
        These domains are registered with UCS Central, so the Policy Resolution Control is what
        decides, for each area of configuration, whether the value found by every other check in
        this script is set here or pushed down from UCS Central. A finding against a globally
        resolved area cannot be fixed in UCS Manager - the change is either refused or reverted at
        the next push - which is why every row in the CSV carries the object's owner.

        The controls are read by walking the registration object and reporting every property
        whose value is 'global' or 'local', rather than by asking for a fixed list of property
        names. UCS Manager has gained controls across releases, and a fixed list silently stops
        reporting the ones it does not know about - which is the failure mode that matters here,
        because a missing row reads as "nothing to see".

        Each control is reported as Review, not as pass or fail. Cisco documents both directions
        as correct depending on intent: global is the point of UCS Central, and local is what
        Cisco recommends setting before a domain joins a domain group, so that its existing
        service profiles and maintenance policies are not overwritten.

    .EXAMPLE
        Test-UcsBpUcsCentral
    #>
    [CmdletBinding()]
    param()

    $category = 'UCS Central'
    $reference = 'Cisco UCS Manager Server Management Guide - Registering Cisco UCS Domains with Cisco UCS Central; Cisco UCS Central Operations Guide'

    $controlEp = @(Get-UcsBpMo -ClassId 'policyControlEp') | Select-Object -First 1

    if ($null -eq $controlEp) {
        Add-UcsBpRow -Category $category -CheckId 'UCS-UCSC-001' -Setting 'UCS Central registration' `
            -ObjectDn 'org-root/control-ep-policy' -CurrentValue '(not reported)' `
            -RecommendedValue 'Registered with UCS Central, as this estate is designed to be' -Basis 'Site Policy' `
            -Result 'Unknown' -Severity 'High' -Reference $reference `
            -Remediation 'Check Admin > Communication Management > UCS Central by hand.' `
            -Detail "The policyControlEp object was not returned. $(Get-UcsBpReadFailure -ClassId 'policyControlEp')"
        return
    }

    # --- Registration ---------------------------------------------------------------------------
    $registrationDetail = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @('Name', 'RegState', 'SuspendState', 'AckState', 'UcsCentralIp', 'Hostname', 'Descr')) {
        if (Test-UcsBpPropertyPresent -InputObject $controlEp -Name $candidate) {
            $registrationDetail.Add("$candidate=$(Get-UcsBpProperty -InputObject $controlEp -Name $candidate -Default '(empty)')")
        }
    }

    $registrationState = ''
    foreach ($candidate in @('RegState', 'AckState', 'SuspendState')) {
        if (Test-UcsBpPropertyPresent -InputObject $controlEp -Name $candidate) {
            $registrationState = [string](Get-UcsBpProperty -InputObject $controlEp -Name $candidate -Default '')
            if ($registrationState) { break }
        }
    }

    $registered = ($registrationState -imatch 'registered|ok|on|yes')
    Add-UcsBpRow -Category $category -CheckId 'UCS-UCSC-001' -Setting 'UCS Central registration' `
        -ObjectDn ([string](Get-UcsBpProperty -InputObject $controlEp -Name 'Dn' -Default 'org-root/control-ep-policy')) `
        -CurrentValue $(if ($registrationState) { $registrationState } else { '(state not reported)' }) `
        -RecommendedValue 'Registered - this estate is managed through UCS Central' -Basis 'Site Policy' `
        -Result $(if ($registered) { 'Meets' } elseif ($registrationState) { 'Does Not Meet' } else { 'Review' }) `
        -Severity 'High' -Reference $reference `
        -Remediation 'Admin > Communication Management > UCS Central. An unregistered domain stops receiving updates to every globally resolved policy, and keeps running on the last values it was given.' `
        -Detail ($registrationDetail -join ', ')

    # --- Registration prerequisites -----------------------------------------------------------------
    $ntpCount = @(Get-UcsBpMo -ClassId 'commNtpProvider').Count
    $timezone = [string](Get-UcsBpProperty -InputObject (@(Get-UcsBpMo -ClassId 'commDateTime') | Select-Object -First 1) -Name 'Timezone' -Default '')
    $prereqMet = (($ntpCount -ge 1) -and (-not [string]::IsNullOrWhiteSpace($timezone)))
    Add-UcsBpRow -Category $category -CheckId 'UCS-UCSC-002' -Setting 'UCS Central time synchronisation prerequisites' `
        -ObjectDn 'sys/svc-ext/datetime-svc' `
        -CurrentValue "NTP servers: $ntpCount, time zone: $(if ($timezone) { $timezone } else { '(not set)' })" `
        -RecommendedValue 'An NTP server and the correct time zone configured in both UCS Manager and UCS Central' `
        -Basis 'Best Practice' -Result $(if ($prereqMet) { 'Meets' } else { 'Does Not Meet' }) `
        -Severity 'High' -Reference $reference `
        -Remediation 'Admin > Time Zone Management. Cisco states this explicitly as a registration prerequisite - domains out of sync with UCS Central fail to register, and once registered produce faults nobody can correlate.'

    # --- Policy resolution controls -------------------------------------------------------------------
    # Friendly names for the controls whose property names are known. Anything else still gets a
    # row, under its raw property name.
    $controlLabels = @{
        'infraPack'    = 'Infrastructure and Catalog Firmware'
        'timeZone'     = 'Time Zone Management'
        'commSvc'      = 'Communication Services'
        'fault'        = 'Global Fault Policy'
        'aaa'          = 'User Management'
        'dns'          = 'DNS Management'
        'backupPolicy' = 'Backup and Export Policies'
        'monitoring'   = 'Monitoring'
        'mepPolicy'    = 'SEL Policy'
        'mepLog'       = 'SEL Policy'
        'psuPolicy'    = 'Power Policy'
        'powerMgmt'    = 'Power Allocation Policy'
        'equipment'    = 'Equipment Policy'
        'securityPolicy' = 'Security Policy'
    }

    $controlsFound = 0
    foreach ($property in @($controlEp.PSObject.Properties)) {
        $value = [string]$property.Value
        if ($value -inotmatch '^(global|local)$') { continue }

        $controlsFound++
        $label = if ($controlLabels.ContainsKey($property.Name)) { $controlLabels[$property.Name] } else { $property.Name }
        $isGlobal = ($value -ieq 'global')

        Add-UcsBpRow -Category $category -CheckId ('UCS-UCSC-010-' + $property.Name) `
            -Setting "Policy resolution control - $label" `
            -ObjectDn ([string](Get-UcsBpProperty -InputObject $controlEp -Name 'Dn' -Default 'org-root/control-ep-policy')) `
            -CurrentValue $value `
            -RecommendedValue 'Whichever the UCS Central design says: global to manage this area centrally, local to keep it in this domain. Cisco recommends setting controls to local before a domain joins a domain group, so existing service profiles and maintenance policies are not overwritten' `
            -Basis 'Site Policy' -Result 'Review' -Severity 'Medium' -Reference $reference `
            -Remediation $(if ($isGlobal) {
                    "This area is managed by UCS Central. Findings elsewhere in this CSV that touch $label must be fixed in UCS Central - a change made in UCS Manager is reverted at the next policy push."
                } else {
                    "This area is managed locally in this domain. Findings elsewhere in this CSV that touch $label are fixed here in UCS Manager, and will not be consistent with the other domains unless the same change is made in each."
                })
    }

    Add-UcsBpRow -Category $category -CheckId 'UCS-UCSC-011' -Setting 'Policy resolution controls reported' `
        -ObjectDn ([string](Get-UcsBpProperty -InputObject $controlEp -Name 'Dn' -Default 'org-root/control-ep-policy')) `
        -CurrentValue $controlsFound -RecommendedValue 'All controls read and reviewed' -Basis 'Site Policy' `
        -Result $(if ($controlsFound -gt 0) { 'Review' } else { 'Unknown' }) -Severity 'Info' -Reference $reference `
        -Remediation 'Admin > Communication Management > UCS Central > Policy Resolution Control.' `
        -Detail 'Controls are discovered by reading every property of the registration object whose value is global or local, so controls added in later UCS Manager releases are still reported.'

    # --- Globally owned objects found elsewhere in this run ---------------------------------------------
    $globallyOwned = @($script:Rows | Where-Object { Test-UcsBpOwnerIsGlobal -Owner $_.Owner })
    Add-UcsBpRow -Category $category -CheckId 'UCS-UCSC-020' -Setting 'Settings in this audit owned by UCS Central' `
        -CurrentValue $globallyOwned.Count `
        -RecommendedValue 'Understood - these rows cannot be remediated in UCS Manager' -Basis 'Site Policy' `
        -Result 'Review' -Severity 'Info' -Reference $reference `
        -Remediation 'Filter the CSV on Owner to separate what this domain can fix from what has to be fixed in UCS Central.' `
        -Detail "Categories affected: $(@($globallyOwned | ForEach-Object { $_.Category } | Select-Object -Unique) -join ', ')"
}

# ---------------------------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------------------------

function Get-UcsBpSummaryText {
    <#
    .SYNOPSIS
        Builds the end-of-run summary as a single string.

    .DESCRIPTION
        Returned as text rather than written to the host, so the script's success stream carries
        only the result rows and the summary can go through Write-RichoLog like every other line
        this repo emits.

    .PARAMETER Row
        The audit rows.

    .EXAMPLE
        Write-RichoLog (Get-UcsBpSummaryText -Row $script:Rows) -Level INFO
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyCollection()]
        [array]$Row
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('')
    $lines.Add("Best practice audit of '$($script:FabricName)' - $($Row.Count) settings checked.")
    $lines.Add('')

    foreach ($result in @('Meets', 'Does Not Meet', 'Review', 'Not Applicable', 'Unknown')) {
        $count = @($Row | Where-Object { $_.Result -eq $result }).Count
        $lines.Add(('  {0,-16} {1,5}' -f $result, $count))
    }

    $failing = @($Row | Where-Object { $_.Result -eq 'Does Not Meet' })
    if ($failing.Count -gt 0) {
        $lines.Add('')
        $lines.Add('  Not meeting recommendations, by severity:')
        foreach ($severity in @('Critical', 'High', 'Medium', 'Low', 'Info')) {
            $count = @($failing | Where-Object { $_.Severity -eq $severity }).Count
            if ($count -gt 0) { $lines.Add(('    {0,-10} {1,5}' -f $severity, $count)) }
        }

        $lines.Add('')
        $lines.Add('  Highest severity findings:')
        $top = @($failing | Where-Object { $_.Severity -in @('Critical', 'High') } | Select-Object -First 15)
        if ($top.Count -eq 0) { $lines.Add('    (none above Medium)') }
        foreach ($finding in $top) {
            $lines.Add("    [$($finding.Severity)] $($finding.CheckId) $($finding.Setting)")
            $lines.Add("        is:     $($finding.CurrentValue)")
            $lines.Add("        should: $($finding.RecommendedValue)")
        }
        if ($failing.Count -gt $top.Count) {
            $lines.Add("    ... and $($failing.Count - $top.Count) more in the CSV.")
        }
    }

    $unknown = @($Row | Where-Object { $_.Result -eq 'Unknown' })
    if ($unknown.Count -gt 0) {
        $lines.Add('')
        $lines.Add("  $($unknown.Count) setting(s) could not be read and are reported as Unknown rather than passed. Check those by hand.")
    }

    return ($lines -join [Environment]::NewLine)
}

$transcriptPath = if ($Transcript) { Start-RichoTranscript } else { $null }

try {
    # --- Fabric ---------------------------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($Fabric)) {
        $Fabric = Read-Host -Prompt 'UCS Manager cluster VIP or hostname (one fabric per run)'
    }
    $Fabric = $Fabric.Trim()
    if ([string]::IsNullOrWhiteSpace($Fabric)) { throw 'No fabric address was given.' }

    # CDP and LLDP report a fabric interconnect with a domain suffix in brackets, and that suffix
    # is not part of the hostname - pasted in, it fails as an invalid URI.
    $Fabric = ($Fabric -replace '\s*\([^)]*\)\s*$', '').Trim()
    $script:FabricName = $Fabric

    # --- Credential -----------------------------------------------------------------------------
    if (-not $Credential) {
        if ($CredentialName) {
            $Credential = Get-RichoCredential -Name $CredentialName
        }
        else {
            $Credential = Get-Credential -Message "UCS Manager credentials for $Fabric"
        }
    }
    if (-not $Credential) { throw 'No credential was supplied.' }

    # --- Where the CSV will go ------------------------------------------------------------------
    # Resolved and said out loud before the audit rather than after it. A run that spends two
    # minutes reading a domain and only then mentions where it put the file has already made the
    # operator hunt for it, and a bad path fails here instead of at the very end.
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $repoRoot = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
        $outputDir = Join-Path $repoRoot 'output'
        $safeFabric = ($Fabric -replace '[^A-Za-z0-9._-]', '_')
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $OutputPath = Join-Path $outputDir "UcsBestPractice-$safeFabric-$stamp.csv"
    }

    $outputParent = Split-Path -Path $OutputPath -Parent
    if ($outputParent -and -not (Test-Path $outputParent)) {
        if ($PSCmdlet.ShouldProcess($outputParent, 'Create output directory')) {
            New-Item -Path $outputParent -ItemType Directory -Force | Out-Null
        }
    }

    Write-RichoLog "CSV will be written to: $OutputPath" -Level INFO

    # --- PowerTool ------------------------------------------------------------------------------
    # Whatever PowerTool the host already carries is what gets used. The test is whether Connect-Ucs
    # resolves, not whether a particular module name is installed: Cisco.UCSManager, the older
    # CiscoUcsPS, and a vendored bundle already on $env:PSModulePath all satisfy it, and PowerShell
    # auto-loads on first use so nothing is imported here.
    $connectUcs = Get-Command -Name 'Connect-Ucs' -ErrorAction SilentlyContinue

    if (-not $connectUcs) {
        # Nothing provides it, so name a module in the failure rather than letting the run die
        # several steps later on "term not recognized".
        Assert-RichoModule -Name 'Cisco.UCSManager'
        $connectUcs = Get-Command -Name 'Connect-Ucs' -ErrorAction SilentlyContinue
    }

    # Said out loud, because "do I need to install anything?" is otherwise answered by guesswork.
    # This is the module the run will actually use, and its version is worth having in the
    # transcript when a cmdlet behaves differently from the one it was written against.
    $powerToolName = [string](Get-UcsBpProperty -InputObject $connectUcs -Name 'ModuleName' -Default '')
    $powerToolVersion = [string](Get-UcsBpProperty -InputObject $connectUcs -Name 'Version' -Default '')
    if ($powerToolName) {
        Write-RichoLog "UCS PowerTool: Connect-Ucs comes from '$powerToolName' $powerToolVersion." -Level INFO
    }
    else {
        Write-RichoLog 'UCS PowerTool: Connect-Ucs resolved, but the module providing it was not reported.' -Level WARN
    }

    # --- Connect --------------------------------------------------------------------------------
    if ($IgnoreCertificateError) {
        if (Get-Command -Name 'Set-UcsPowerToolConfiguration' -ErrorAction SilentlyContinue) {
            Set-UcsPowerToolConfiguration -InvalidCertificateAction Ignore -ErrorAction Stop | Out-Null
            Write-RichoLog 'Certificate validation is switched off for this session, at your instruction.' -Level WARN
        }
        else {
            Write-RichoLog 'Set-UcsPowerToolConfiguration is not available, so -IgnoreCertificateError could not be applied.' -Level WARN
        }
    }

    Write-RichoLog "Connecting to UCS Manager '$Fabric' as '$($Credential.UserName)'." -Level INFO
    try {
        $script:UcsHandle = Connect-Ucs -Name $Fabric -Credential $Credential -ErrorAction Stop
    }
    catch {
        # A fabric interconnect normally presents a self-signed certificate, and PowerTool refuses
        # it by default. That failure says "could not establish trust relationship", which reads
        # like a network problem and is not one - so name the actual remedy rather than leaving it
        # to be worked out.
        if ($_.Exception.Message -match '(?i)certificate|SSL|TLS|trust relationship|secure channel') {
            throw ("Could not connect to '$Fabric': $($_.Exception.Message)`n" +
                   "This looks like certificate validation. UCS Manager normally presents a self-signed " +
                   "certificate. Either install the fabric interconnect's certificate into the trusted " +
                   "root store on this host, or re-run with -IgnoreCertificateError to skip validation " +
                   "for this session.")
        }
        throw
    }
    Write-RichoLog "Connected. This audit only reads - nothing on the domain is changed." -Level INFO

    # --- Audit ----------------------------------------------------------------------------------
    # Name doubles as the Category on the row recorded if a section throws, so it matches the
    # category that section's own rows use - an error row filed under a category that appears
    # nowhere else is a gap nobody spots while filtering.
    $sections = @(
        @{ Name = 'System';                 Action = { Test-UcsBpSystem } },
        @{ Name = 'Fabric Failover';        Action = { Test-UcsBpFabricFailover } },
        @{ Name = 'Firmware';               Action = { Test-UcsBpFirmware } },
        @{ Name = 'Time and Name Services'; Action = { Test-UcsBpTimeAndNameServices } },
        @{ Name = 'Monitoring';             Action = { Test-UcsBpMonitoring } },
        @{ Name = 'Security';               Action = { Test-UcsBpSecurity } },
        @{ Name = 'Authentication';         Action = { Test-UcsBpAuthentication } },
        @{ Name = 'Backup';                 Action = { Test-UcsBpBackup } },
        @{ Name = 'Equipment';              Action = { Test-UcsBpEquipment } },
        @{ Name = 'LAN';                    Action = { Test-UcsBpLan } },
        @{ Name = 'VLAN';                   Action = { Test-UcsBpVlan } },
        @{ Name = 'QoS';                    Action = { Test-UcsBpQos } },
        @{ Name = 'SAN';                    Action = { Test-UcsBpSan } },
        @{ Name = 'Server Policies';        Action = { Test-UcsBpServerPolicies } },
        @{ Name = 'BIOS';                   Action = { Test-UcsBpBios } },
        @{ Name = 'vNIC and Adapter';       Action = { Test-UcsBpVnic } },
        @{ Name = 'Service Profiles';       Action = { Test-UcsBpServiceProfile } },
        @{ Name = 'Pools';                  Action = { Test-UcsBpPools } },
        @{ Name = 'UCS Central';            Action = { Test-UcsBpUcsCentral } }
    )

    foreach ($section in $sections) {
        Write-RichoLog "Checking $($section.Name)..." -Level INFO
        try {
            & $section.Action
        }
        catch {
            # One section that throws must not cost the other seventeen. The gap is recorded as a
            # row so it cannot be mistaken for a clean result.
            Write-RichoLog "Section '$($section.Name)' failed: $($_.Exception.Message)" -Level WARN
            Add-UcsBpRow -Category $section.Name -CheckId 'UCS-SECTION-ERROR' -Setting "$($section.Name) checks" `
                -CurrentValue '(section failed)' -RecommendedValue 'All checks in this section run to completion' `
                -Basis 'Best Practice' -Result 'Unknown' -Severity 'High' `
                -Remediation 'Run the section by hand, or re-run with -Verbose to see which read failed.' `
                -Detail $_.Exception.Message
        }
    }

    # --- Output ---------------------------------------------------------------------------------
    if ($PSCmdlet.ShouldProcess($OutputPath, "Write $($script:Rows.Count) audit rows to CSV")) {
        $script:Rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-RichoLog "Wrote $($script:Rows.Count) rows to $OutputPath" -Level INFO
    }
    else {
        Write-RichoLog "-WhatIf: the audit ran and $($script:Rows.Count) rows were produced; the CSV was not written." -Level INFO
    }

    # .ToArray() rather than @(...): the array subexpression operator does not reliably
    # convert a List[object] holding PSCustomObjects, and fails with "Argument types do not
    # match" - after the CSV has already been written, so the run looks like it failed when
    # the audit had in fact completed.
    Write-RichoLog (Get-UcsBpSummaryText -Row $script:Rows.ToArray()) -Level INFO

    if ($script:ReadFailures.Count -gt 0) {
        Write-RichoLog "Classes that could not be read: $(@($script:ReadFailures.Keys) -join ', ')" -Level WARN
    }

    # The rows are the script's return value, so a caller can filter them without reopening the CSV.
    $script:Rows
}
catch {
    $failure = $_

    # Write-RichoLog at ERROR level writes to the error stream, and $ErrorActionPreference is Stop,
    # so logging the failure here would itself throw - replacing the real failure with the log call
    # that reported it, and losing both the message and the line number that matter. Logging is done
    # with that preference relaxed, and the ORIGINAL error record is what gets rethrown.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Write-RichoLog "Failed: $($failure.Exception.Message)" -Level ERROR
    if ($failure.InvocationInfo -and $failure.InvocationInfo.ScriptLineNumber) {
        Write-RichoLog "  raised at line $($failure.InvocationInfo.ScriptLineNumber): $($failure.InvocationInfo.Line.Trim())" -Level ERROR
    }
    if ($script:Rows.Count -gt 0) {
        Write-RichoLog "  $($script:Rows.Count) row(s) had been collected before the failure." -Level WARN
    }
    $ErrorActionPreference = $previousPreference

    throw $failure
}
finally {
    if ($script:UcsHandle) {
        try { Disconnect-Ucs -Ucs $script:UcsHandle -ErrorAction SilentlyContinue | Out-Null }
        catch { Write-RichoLog "Could not cleanly disconnect from '$($script:FabricName)'." -Level DEBUG }
    }
    if ($transcriptPath) { Stop-Transcript | Out-Null }
}
