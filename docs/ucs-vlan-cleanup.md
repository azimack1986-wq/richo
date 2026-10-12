# UCS VLAN cleanup: audit, review, remove

Two scripts replace `UCSM-vCenter-Live-Monthly-VLAN-Audit-v7.5`:

| Script | Changes anything? | Does |
| --- | --- | --- |
| `scripts/ucs/Get-UcsVlanAudit.ps1` (8.0.0) | No | Monthly audit. Same sheets and classifications as v7.5, plus `candidates.json` for the removal step. |
| `scripts/ucs/Remove-UcsUnusedVlan.ps1` (1.0.0) | **Yes** | Removes approved candidates from vNIC templates, then the LAN Cloud, after re-checking the live domain. |

They are separate on purpose. The monthly audit stays safe to run by anyone at any time; removal
needs an explicit list of VLAN IDs, a clean and recent audit, and confirmation of each change.

## Runbook

1. **Audit.** Run `Get-UcsVlanAudit.ps1` for the domain, selecting **every** vCenter with hosts on
   it. Answer the confirmations as before (DR side, scope, physical, native, special).

2. **Review the report.**
   - `Executive Summary` → `Overall` must be `COMPLETE`. Anything else means the `Warnings` sheet
     is not empty; fix the causes and audit again. The removal script refuses preliminary
     candidates outright.
   - `UCSM Candidates` is the list to review. `TemplateMemberships` says how many templates each
     sits on; `DirectVnicReferences` > 0 means a vNIC uses it directly, which will block its LAN
     Cloud delete.
   - `Service Profile Mapping` shows which profiles were matched to an ESXi host by MAC. Every
     associated profile that was not matched has **all** of its VLANs protected.
   - `Host Coverage` shows how each host in the domain's clusters was tied to a domain.

3. **Approve specific VLAN IDs** in the change record. The removal script removes only IDs it is
   given, and only if the audit lists them as `UCSM CLEANUP CANDIDATE`.

4. **Dry run.** Attach the plan to the change:

   ```powershell
   .\scripts\ucs\Remove-UcsUnusedVlan.ps1 -ManifestPath <audit folder> -VlanId 2210, 2214 -WhatIf
   ```

   Nothing is changed. `plan.csv` shows every removal and anything blocked, with the reason.

5. **Implement** in the window. If the audit is older than 3 days, audit again first.

   ```powershell
   .\scripts\ucs\Remove-UcsUnusedVlan.ps1 -ManifestPath <audit folder> -VlanId 2210, 2214 -Transcript
   ```

   Each removal is confirmed (Yes to All is offered). Templates first; then, for updating templates,
   it waits for the change to reach every bound service profile; then each LAN Cloud VLAN is
   deleted only if nothing references it any more. To split across two windows, use
   `-Stage Templates` then later `-Stage LanCloud`.

6. **Evidence** is in `output/ucs-vlan-removal/<domain>_VLAN-Removal_<time>/`: `plan.csv`,
   `snapshot.json` (the live objects before the change), `rollback.ps1`, `results.csv`.

### When the removal stops

| Result | Meaning | What to do |
| --- | --- | --- |
| Refused before login | Audit preliminary, stale, or the VLAN is not a candidate | Fix the warnings / re-run the audit |
| `BLOCKED` in the plan | Something changed since the audit, a bound profile was not audited, a pending acknowledgement exists, or the VLAN is native / in-band | Read the reason; re-audit |
| `BLOCKED - LIVE CHECK` | Templates done, but a vNIC, LAN connectivity policy or VLAN group still references the VLAN | Remove that reference (out of this script's scope), then `-Stage LanCloud` |
| `NOT ATTEMPTED` | Template change did not reach the service profiles in time, or UCSM raised a **pending reboot acknowledgement** | Check Pending Activities in UCSM. The script never acknowledges. |
| `F0933` logged as ERROR | A deleted VLAN is still named by a vNIC | Investigate immediately; `rollback.ps1` re-creates what was removed |

## Review of v7.5

Findings from reviewing v7.5. Each one is either fixed in 8.0.0 or recorded as a deliberate
behaviour change; items marked *(tested)* are reproduced by a test in `tests/`.

### Could produce a wrong candidate (unsafe direction)

1. **VLAN names were resolved without regard to fabric.** vNICs reference VLANs by name, and
   UCSM allows the same name on fabric A and B with different IDs. v7.5 took the first VLAN with a
   matching name from either fabric. 8.0.0 resolves per fabric and treats every ID a name could
   mean as in use. *(tested)*
2. **VLANs used directly on a service profile vNIC looked unused.** v7.5 read every `vnicEtherIf`
   but kept only template ones, so a bare-metal profile's VLANs were protected only if someone
   typed them into the physical list. 8.0.0 matches profiles to ESXi hosts by MAC and protects
   every VLAN on any associated profile it cannot match. *(tested)*
3. **Guest-tagging port groups (VLAN 4095) protected nothing.** 4095 was treated as a VLAN ID. Now
   any 4095 port group in use protects every VLAN, and trunk / PVLAN port groups in use protect
   their range. *(tested)*
4. **VM templates were not counted.** `Get-VM` excludes templates, so a VLAN only a template uses
   looked unused. *(tested)*
5. **VLAN groups and the in-band management VLAN were not considered.** Both now protect.
   *(tested)*
6. **Appliance-cloud VLANs were counted as LAN Cloud VLANs.** `Get-UcsVlan` returns every
   `fabricVlan`; only `fabric/lan/*` is now considered. *(tested — but see "not verified" below)*
7. **Native VLANs came from templates only**, not service profile vNICs or the LAN Cloud's own
   native VLAN. All three now protect. *(tested)*

### Made every run preliminary for reasons unrelated to the candidates

8. **CDP read `DevId` only.** On LLDP-only fabric interconnects every host was unmapped. CDP
   `SystemName` and LLDP are now read, as the firmware controller already does. *(tested)*
9. **A documented CDP format never matched.** `FI-A PD84000001SS028` (from v7.5's own comment)
   failed because whitespace was removed before the boundary check. *(tested)*
10. **Any CDP failure anywhere in the vCenter** — including clusters on other domains — made the
    run preliminary. Only failures on this domain's clusters now do. *(tested)*
11. **A distributed port group shared with an unselected cluster** raised `USAGE COUNT MISMATCH`,
    which made the run preliminary — routine with one VDS per vCenter. The usage is still
    counted (conservatively); it is no longer a warning.
12. **A DR VLAN missing from the LAN Cloud** made the run preliminary. It is still reported (DR
    Coverage, Summary) but no longer blocks: a missing VLAN cannot be deleted. *(tested)*
13. **One vCenter per run.** The menu offered All / Multiple and then rejected them. Several
    vCenters are now scanned in one run, which is what lets a domain spanning vCenters be
    validated at all.

### Correctness of the report

14. Template pair audit merged same-named templates from different orgs, and an odd-numbered
    template with no partner was not reported. *(tested)*
15. `$discoveredPhysical` was always empty, so `Physical discovered` could never appear.
16. Under `Set-StrictMode`, which v7.5 did not set, several patterns throw — notably member
    enumeration on an empty collection (`$data.Memberships.VLANID`).
17. Excel cells were written as strings one COM call at a time, so numeric columns such as VLAN
    ID landed as text. Numbers are now written as numbers, and columns holding text are formatted
    as text first — which matters because 8.0.0 adds range values such as `100-110` that Excel
    would otherwise turn into dates.

### Performance

v7.5's cost grew with every host, VM and port group:

| Step | v7.5 | 8.0.0 |
| --- | --- | --- |
| vCenter logins | 2 per vCenter | 1 |
| Hosts, port groups, VMs | per-host `Get-VMHost`/`Get-View`/`Get-VDSwitch`/`Get-VirtualPortGroup`, per-VM `Get-View`, per-port-group `Get-VM -RelatedObject` | 5 `Get-View -ViewType` calls per vCenter, needed properties only |
| CDP/LLDP | `Get-View` ×2 + `QueryNetworkHint` per host | one batched `Get-View` + `QueryNetworkHint` per connected host |
| Template memberships | every membership scanned for every template | grouped once by parent |
| Excel | one COM call per cell | one call per sheet |
| Excel present? | starts Excel | ProgID lookup |

The call counts are structural. **Run time has not been measured** — there is no vCenter or UCSM
in the environment these were written in. Compare the first 8.0.0 run against a v7.5 run of the
same domain.

## What has and has not been verified

**Verified** (PowerShell 7.4 on Linux, PSScriptAnalyzer with the repo settings, the repo's own
lint suite): both scripts parse and are analyzer-clean; 250 assertions across
`Test-UcsVlanAudit.ps1`, `Test-UcsVlanRemoval.ps1` and `Test-UcsVlanEndToEnd.ps1` cover the
classification rules, every removal gate, ordering, propagation and acknowledgement stops, and
that `-WhatIf` on the real script entry point changes nothing. The end-to-end suite runs both
real scripts against stub UCS PowerTool / PowerCLI modules.

**Not verified** — check these on a jump host before the first live removal:

- **Removal cmdlets.** `Remove-UcsVnicInterface` follows the documented
  `Get-UcsVnicTemplate | Get-UcsVnicInterface` pipeline. `Remove-UcsVlan` is assumed from
  PowerTool's naming convention. The script checks both exist before doing anything, and
  `-WhatIf` exercises everything up to the call itself.
- **Rollback cmdlets.** `rollback.ps1` uses `Get-UcsLanCloud`, `Get-UcsFiLanCloud`, `Add-UcsVlan`
  and `Add-UcsVnicInterface`; none has been run. Each step reports and continues on failure, and
  `snapshot.json` holds the data to re-create by hand.
- **UCSM object properties** read: `vnicEther.Addr` / `OperNwTemplName` / `NwTemplName`,
  `vnicLanConnTempl.TemplType`, `lsServer.Type` / `AssocState`, `fabricPooledVlan`,
  `mgmtInbandProfile.DefaultVlanName`, `lsmaintAck`, `faultInst.Code`. A property missing on your
  UCSM version reads as empty rather than failing, so check the first audit's `Service Profile
  Mapping` sheet — a profile with no MACs is the symptom.
- **Whether `Get-UcsVlan` returns appliance-cloud VLANs.** Excluding them is harmless if it does
  not.
- **Pending acknowledgements after a template VLAN change.** VLAN changes on vNICs are generally
  applied without a reboot, but this was not confirmed for every adapter and UCSM release, so the
  script does not rely on it: it stops before the LAN Cloud stage if one appears.
- **MAC matching.** An ESXi vmnic on a VIC presents its UCS vNIC's MAC. Overlapping MAC pools
  between domains are detected (`AMBIGUOUS`) and make the run preliminary.
- **Windows PowerShell 5.1** syntax is checked by the analyzer's 5.1 compatibility rule; the tests
  ran on PowerShell 7.4 only. The Excel COM path was not exercised.

Suggested first use: run the 8.0.0 audit alongside v7.5 for one domain and compare the candidate
lists; then a `-WhatIf` removal; then one low-risk VLAN with `-Stage Templates`.
