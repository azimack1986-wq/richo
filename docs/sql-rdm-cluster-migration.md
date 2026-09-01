# SQL RDM cluster migration

Cold-migrates clustered SQL VMs that use physical-mode RDMs to another vSphere
cluster, and puts every shared disk back at exactly the SCSI address it came from.

- Script: [`scripts/vsphere/Invoke-SqlRdmClusterMigration.ps1`](../scripts/vsphere/Invoke-SqlRdmClusterMigration.ps1)
- Tests: [`tests/Test-SqlRdmClusterMigration.ps1`](../tests/Test-SqlRdmClusterMigration.ps1)
- Sample CSV: [`scripts/vsphere/SqlRdmClusterMigration.Sample.csv`](../scripts/vsphere/SqlRdmClusterMigration.Sample.csv)

## Running it from a jump host

The script is self-contained: no configuration file, nothing imported from this
repository, and PowerCLI as its only dependency. It carries its own copies of
`Write-RichoLog` and `Get-RichoCredential` so the log format and credential handling
match the rest of the estate without needing `Richo.Common` on the box.

Copy these into one folder on the jump host and it runs there as-is:

```text
Invoke-SqlRdmClusterMigration.ps1
Test-SqlRdmClusterMigration.ps1
SqlRdmClusterMigration.Sample.csv   (or your completed migration CSV)
```

The test script looks for the migration script beside itself first and falls back to
the repository layout, so the same file works in both places.

## Usage

```powershell
# Dry run - reads vCenter, writes evidence, changes nothing.
.\scripts\vsphere\Invoke-SqlRdmClusterMigration.ps1 `
    -VCenter vcenter01.example.com `
    -CsvPath .\SqlRdmClusterMigration.csv `
    -DryRun -PowerAction ShutdownGuest `
    -OutputFolder .\SqlRdmClusterMigrationOutput

# Live run, leaving the VMs powered off at the destination.
.\scripts\vsphere\Invoke-SqlRdmClusterMigration.ps1 `
    -VCenter vcenter01.example.com `
    -CsvPath .\SqlRdmClusterMigration.csv `
    -Execute -PowerAction ShutdownGuest -ShutdownTimeoutMinutes 20 `
    -OutputFolder .\SqlRdmClusterMigrationOutput

# Live run with automatic power-on at the destination, in CSV order.
.\scripts\vsphere\Invoke-SqlRdmClusterMigration.ps1 `
    -VCenter vcenter01.example.com -CsvPath .\SqlRdmClusterMigration.csv `
    -Execute -PowerAction ShutdownGuest -ShutdownTimeoutMinutes 20 -PowerOnAfterMigration

# Live run allowing a hard power-off only where VMware Tools is unavailable.
.\scripts\vsphere\Invoke-SqlRdmClusterMigration.ps1 `
    -VCenter vcenter01.example.com -CsvPath .\SqlRdmClusterMigration.csv `
    -Execute -PowerAction ShutdownGuest -ForcePowerOffIfGuestShutdownUnavailable
```

There are two modes and nothing in between. `-DryRun` announces every change and
makes none; `-Execute` performs them. The plan file a dry run writes is the same list
of operations a live run performs, so what you review is what will happen.

Credentials resolve through the script's own credential helper — SecretManagement
first, then `RICHO_<NAME>_USER` / `RICHO_<NAME>_PASSWORD`, then a prompt. The lookup
name defaults to the vCenter FQDN; override it with `-CredentialName`. `-Credential`
still takes a `PSCredential` directly, which is what an unattended run on a jump host
would normally use.

> `-ForcePowerOffIfGuestShutdownUnavailable` is deliberately opt-in. Without it, a
> powered-on VM whose VMware Tools is not running stops the migration. With it, a hard
> power-off is used **only** in that case — never as a shortcut past a slow guest
> shutdown. A dry run records the proposed hard power-off and does not perform it.

## High-level flow

```text
+-------------------------------+
| 1. COLLECT INVENTORY          |
| VM, RDM and LUN data          |
+---------------+---------------+
                |
                v
+-------------------------------+
| 2. PREPARE MIGRATION CSV      |
| Destination and LUN IDs       |
+---------------+---------------+
                |
                v
+-------------------------------+
| 3. RUN THE NATIVE TESTS       |
| Syntax, CSV rules, guards     |
+---------------+---------------+
                |
                v
+-------------------------------+
| 4. RUN A LIVE DRY RUN         |
| Validate VMs, hosts and LUNs  |
| No VMware changes             |
+---------------+---------------+
                |
                v
+-------------------------------+
| 5. REVIEW THE MIGRATION PLAN  |
| Manifest JSON + change plan   |
+---------------+---------------+
                |
                v
+-------------------------------+
| 6. RUN THE LIVE MIGRATION     |
| Shut down, detach, cold move, |
| recreate controllers and RDMs |
+---------------+---------------+
                |
                v
+-------------------------------+
| 7. POWER ON, OPTIONAL         |
| Automatic or by hand          |
+---------------+---------------+
                |
                v
+-------------------------------+
| 8. VALIDATE VMWARE, WSFC, SQL |
+-------------------------------+
```

Step 8 is partly done for you: an execution run re-reads every VM afterwards and
fails if any disk is not on the address, device and capacity it was planned for.
Validating WSFC and SQL inside the guests is still yours.

## Prerequisites

| Prerequisite | Why |
| --- | --- |
| Destination LUNs presented to the destination hosts, HBAs rescanned | The script never presents or rescans storage; it fails a host that cannot see a LUN |
| Destination resource pool, datastore cluster and RDM pointer datastore exist | Each is resolved by exact, case-sensitive name |
| `VMware.VimAutomation.Core` available on the jump host | The only dependency. Loaded once, behind a `Get-Module` guard; nothing is installed |
| vCenter permissions for cold migration, device add/remove and power operations | Everything the run does |
| An approved outage window | Every VM in a group is shut down before any of them moves |

## CSV format

The grouped-LUN format is unchanged, plus `destination_resource_pool` and
`destination_datastore_cluster`. NAA values are never typed by the operator: each
destination device is resolved from SVM plus LUN ID and then verified by canonical
identity and capacity.

```text
vsphere_cluster
first_vm
other_vms_space_separated
svm
iSCSI_Data_Store
group_1_lun_IDs_ordered_space_separated
group_2_lun_IDs_ordered_space_separated
group_3_lun_IDs_ordered_space_separated
destination_resource_pool
destination_datastore_cluster
```

- `vsphere_cluster` is the **destination** cluster and also names the migration
  group. One row per destination cluster.
- LUN group N becomes SCSI bus N — group 1 to bus 1, and so on. Bus 0 is left alone;
  it carries the OS disk.
- Within a group, LUNs are attached in the order written, at units 0, 1, 2 …,
  skipping unit 7 (the controller's own). A group of more than 15 LUNs is rejected.
- Power-on order is `first_vm` then `other_vms_space_separated`. There is no
  separate power-order column.

Validation refuses, before anything is touched: a missing column, an empty required
cell, a non-numeric or duplicated LUN ID, a duplicated VM name inside a row **or
across rows**, a duplicated destination cluster, and a LUN group too large for one
controller.

## What the script checks against live inventory

Everything below happens during a dry run, so a defect surfaces while the cluster is
still up:

- Destination cluster, resource pool, datastore cluster and RDM datastore each
  resolve to exactly one object, matched case-sensitively.
- Every eligible destination host is connected, out of maintenance mode, mounts the
  destination datastore cluster and the RDM datastore, and resolves every LUN. Hosts
  that fail are logged with the reason; if none qualifies, the reasons are in the
  error.
- Every LUN resolves to the same canonical device on every eligible host.
- No two CSV LUN IDs resolve to the same device.
- Each destination LUN's capacity matches the RDM it replaces, within 1 GB. This is
  what catches a mistyped LUN ID that happens to exist on the same SVM.
- Every VM in the group has the same RDM topology as the first: same buses, units,
  capacities and controller type, all on physical-sharing controllers, and no
  snapshots.
- The source topology matches the CSV order, LUN by LUN.

## What it does at the destination

- Recreates each shared SCSI controller **using the source's own controller type**
  and bus-sharing mode.
- Attaches each RDM with an explicit device spec at the exact bus and unit it had,
  then reads the VM back and fails if the device that landed there is not the one
  planned.
- Reproduces the group's RDM mapping-file arrangement: if the source nodes shared one
  mapping file per LUN (VMware's documented cluster-across-boxes build), the file
  created for the first node is attached to the others; if each node had its own, each
  gets its own. A group that mixes the two is refused rather than guessed at.
- Spreads the VMs across the eligible destination hosts round-robin, and warns when
  only one host qualifies — every node of the cluster would land on it.

## Output

Written to `-OutputFolder` (default `.\SqlRdmClusterMigrationOutput`):

| File | Contents |
| --- | --- |
| `<group>-<mode>-manifest-<stamp>.json` | Pre-change evidence: source and destination placement, every source RDM, every resolved destination LUN, excluded hosts, mapping mode |
| `change-plan-<stamp>.csv` | Every change the run intended, in order — identical in a dry run and a live run |
| `results-<stamp>.csv` | Every change attempted and its outcome |
| `verification-<stamp>.csv` | Post-migration disk-by-disk comparison against the plan (execution runs only) |

Every row carries `$ScriptVersion`, so a change record traces back to the revision
that produced it.

## Run the tests

```powershell
pwsh -File ./tests/Test-SqlRdmClusterMigration.ps1
```

Continue only when the summary reports `Failed: 0`. The suite uses built-in
PowerShell only — no Pester, no PowerCLI, no vCenter. It lifts the helper functions
out of the script with the PowerShell parser, so it tests the code that ships, and it
writes its temporary CSVs to the temporary directory and deletes them.

## Safety notes

- `-DryRun` performs VMware reads and writes local evidence files only.
- The script does not present LUNs on the array and does not rescan ESXi HBAs.
- RDM removal always uses `-DeletePermanently:$false`.
- A hard power-off is unavailable unless the explicit force switch is supplied, and
  then only when VMware Tools is not running.
- Power-on happens only with `-PowerOnAfterMigration`.
- Out of scope, and still yours: DRS rules and VM-VM anti-affinity at the
  destination, in-guest WSFC and SQL validation, and backup or SRM re-protection.
- Prove the whole workflow on non-production VMs and LUNs before using it in anger.
