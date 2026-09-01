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

Nothing about it assumes a particular shell — a VS Code integrated terminal, a plain
PowerShell window or a scheduled run all work the same way, since the only inputs are
the parameters and the CSV.

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

# Live run, powering the VMs on a workload type at a time once every group is done.
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
| One workload type at a time,  |
| after every group is done     |
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
| Destination LUNs presented to the destination hosts, HBAs rescanned | **Yours to do, and not checked by default.** The script prints exactly which devices must be presented, on which hosts, before it changes anything; `-VerifyLunPresentation` makes it read the hosts back |
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
batch                                      whole number, 1 or more
destination_cluster                        where the VMs are going - required
workload_type                              PROD, SIT or DEV
first_vm
other_vms_space_separated
svm
iSCSI_Data_Store                           may be left blank - see below
group_1_lun_IDs_ordered_space_separated
group_2_lun_IDs_ordered_space_separated
group_3_lun_IDs_ordered_space_separated
destination_resource_pool
destination_datastore_cluster
```

- There is no source column. The VMs are found **by name** across the vCenter — each
  name must match exactly one VM, case-sensitively — and where they are now is read off
  them and recorded in the manifest rather than asserted in the CSV. A VM already
  sitting in the destination cluster, or a group whose VMs come from more than one
  cluster, is warned about rather than blocked.
- `destination_cluster` is required. The migration group is named after its `first_vm`,
  which is what appears in the manifest filename and in the plan, results and
  verification rows.
- `batch` groups rows into outage windows. It is stamped on every plan, result and
  verification row, and rows always run in batch order — batch 1 finishes before batch 2
  starts, whatever order the rows sit in the file.
- `workload_type` is `PROD`, `SIT` or `DEV`, in any case. Clusters are shared — one
  cluster carries all three — so the workload type says nothing about the cluster and is
  never checked against its name. What it does is pick the RDM mapping directory, and
  it is stamped on every plan, result and verification row so a change record can be
  filtered to one environment, and it drives the power-on batching below.
- `iSCSI_Data_Store` may be left blank. Blank means the conventional name for that
  cluster and workload type — the cluster, the environment's suffix, then `_i_rdm`:

  | Workload | Destination cluster | Derived datastore |
  | --- | --- | --- |
  | PROD | `d24sql02` | `d24sql02_i_rdm` |
  | SIT | `d24sql02` | `d24sql02sit_i_rdm` |
  | DEV | `d24sql02` | `d24sql02dev_i_rdm` |

  PROD adds nothing, which is why it looks like the bare cluster name. A name that *is*
  typed is used exactly as typed; a derived name is matched without regard to case,
  since nobody typed it. Either way the datastore must be mounted by the destination
  hosts.
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
- Every eligible destination host is connected, powered on, out of maintenance mode and
  mounts both the destination datastore cluster and the RDM datastore. That is read from
  the **datastores' own mount tables** — two queries whatever the cluster size, rather
  than asking each of 42 hosts what it mounts. Hosts that fail are summarised by reason;
  if none qualifies, the reasons are in the error.
- No two disks in the group resolve to the same device.
- The devices to re-attach are the ones the VMs already have — same LUNs, re-presented —
  so nothing has to scan a host to find them and the operator never types an NAA.
- Every VM in the group has the same RDM topology as the first: same buses, units,
  capacities and controller type, all on physical-sharing controllers, and no
  snapshots.
- The source topology matches the CSV order, LUN by LUN.

## What it removes at the source

Once the VMs are powered down, and before anything moves:

- Every physical RDM named in the CSV is detached, never permanently deleted.
- **SCSI 0 is left alone** — it carries the operating system and any plain VMDKs.
- **A controller above bus 0 that carried a LUN is removed with it.** That is the whole
  rule: LUN on it, it goes.
- **A controller that carried no LUN is left where it is**, empty or not. Removing a
  controller detaches whatever is on it, so anything this migration does not describe
  stays put and is noted in the results file. The one exception is a controller sitting
  on a bus the plan needs at the destination — that stops the run, because the rebuild
  cannot put its LUNs there otherwise.
- A controller carrying this migration's LUNs **alongside** a disk the CSV does not
  describe also stops the run. Move that disk to SCSI 0, or take the VM out of the
  migration.

## The presentation prerequisite

Presenting the LUNs to the destination hosts and rescanning the HBAs is the engineer's
job, before the run. The script does not do it and, by default, does not check it —
reading every path on every host to re-confirm it was the slowest thing the script did,
on every run, whether anyone doubted the presentation or not.

What it does instead is **state it**, device by device, before anything changes:

```text
  ---- PREREQUISITE, not checked by this script ----
  Present these LUNs from SVM 'sql-svm01' to esx02, esx04 and rescan the HBAs before running group 'D24SQL01':
    LUN 40  naa.60a98000...4d31  100 GB  -> SCSI 1:0
    LUN 41  naa.60a98000...4d32  250 GB  -> SCSI 1:1
    LUN 42  naa.60a98000...4d33  500 GB  -> SCSI 1:2
  Not verified. Supply -VerifyLunPresentation to have the hosts read back, at one storage enumeration each.
  -------------------------------------------------
```

Run a dry run first and that list is your work order.

One thing **is** checked by default, because of where the failure lands otherwise: that
each destination host can actually see the devices being re-attached. It is one storage
read per destination host — the hosts the VMs are going to, not all of them — and it runs
before anything is powered off. Without it, a device that was never presented is found at
the attach, with the VMs already down, their RDMs detached and the machines relocated.
`-SkipDeviceCheck` turns it off.

`-VerifyLunPresentation` is the deeper check: it reads each host's storage paths and
confirms SVM plus LUN ID resolves to the same device, of the same size, as the RDM being
moved. Worth it the first time through a new cluster, and skippable once the presentation
is routine.

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

## Choosing what to run

All three scopes come out of the same CSV — you never edit the file to run part of it.

```powershell
# Everything in the file, in batch order.
.\Invoke-SqlRdmClusterMigration.ps1 -VCenter vcenter01 -CsvPath .\migration.csv -DryRun

# One batch at a time.
.\Invoke-SqlRdmClusterMigration.ps1 -VCenter vcenter01 -CsvPath .\migration.csv -Execute -Batch 1
.\Invoke-SqlRdmClusterMigration.ps1 -VCenter vcenter01 -CsvPath .\migration.csv -Execute -Batch 2,3

# A single line, named by any VM in it.
.\Invoke-SqlRdmClusterMigration.ps1 -VCenter vcenter01 -CsvPath .\migration.csv -Execute -VMName LABSQL01
```

- `-VMName` selects the **row** the VM appears in, and the whole row runs. A row is one
  SQL cluster; moving one node while its siblings still hold the shared RDMs is not
  something this tool will do. Naming a second or third node selects the same row.
- `-VMName` and `-Batch` cannot be combined, and either one naming nothing in the file
  stops the run — an unknown batch says which batches the file does have.
- The scope is logged at the start and written into every manifest, so a change record
  says what the run covered.
- Nothing else changes with scope: the same validation, the same evidence files, and
  power-on still waits for every group **in that run**.

## What it prints while it runs

Most of a run is spent inside a handful of slow VMware calls, so each one says what it
is doing, and the long ones report a percentage and an elapsed time as they go:

```text
2026-09-01 07:31:02Z [INFO ] Loading PowerCLI. On a cold session this can take a minute.
2026-09-01 07:31:44Z [INFO ] PowerCLI ready (41.8s).
2026-09-01 07:31:46Z [INFO ] Connected to vcenter01 as SVC-MIG (1.9s).
2026-09-01 07:31:46Z [INFO ] Resolving the migration plan against live inventory. No changes are made in this phase.
2026-09-01 07:31:47Z [INFO ]   Checking 8 host(s) in 'd24sql02' for datastore and LUN access. This is the slow part - one storage read per host.
2026-09-01 07:31:47Z [INFO ]     [1/8] esx01: reading storage paths and devices...
2026-09-01 07:32:04Z [INFO ]          all 7 LUN(s) resolved (16.4s).
...
2026-09-01 07:34:10Z [INFO ]   Phase 2 of 3: relocating and re-attaching. A cold move of a large VM takes minutes.
2026-09-01 07:34:25Z [INFO ]       Relocating 'D24SQL01' to esx03 - 34% (15.1s elapsed)
2026-09-01 07:36:58Z [INFO ]       Relocating 'D24SQL01' to esx03 finished in 2m 48s.
```

A guest shutdown says `still waiting ... 2m of 20 minutes` every thirty seconds, and
progress bars run alongside for the host scan, the per-VM phases and every long task.
Nothing waits silently for more than about half a minute.

## Power-on

Nothing is powered on until **every** migration group in the run has been relocated,
re-attached and verified. The VMs then come up a workload type at a time — all `PROD`
groups, then all `SIT`, then all `DEV`, in the order the types first appear in the
CSV — with groups in CSV order and, within a group, `first_vm` before the rest.

A SQL FCI node that boots while a sibling group is still mid-migration can bring
shared disks online against a half-assembled cluster, which is what the wait is for. A
group that fails throws and stops the run before anything is powered on.

Power-on still only happens with `-PowerOnAfterMigration`. Without it the run says so
and leaves the VMs off for you to start by hand.

## Output

Written to `-OutputFolder` (default `.\SqlRdmClusterMigrationOutput`):

| File | Contents |
| --- | --- |
| `<group>-<mode>-manifest-<stamp>.json` | Pre-change evidence: workload type, the clusters the VMs came from and the destination, source and destination placement, every source RDM, every resolved destination LUN, whether the RDM datastore name was derived, excluded hosts, mapping mode |
| `change-plan-<stamp>.csv` | Every change the run intended, in order — identical in a dry run and a live run |
| `results-<stamp>.csv` | Every change attempted and its outcome |
| `verification-<stamp>.csv` | Post-migration disk-by-disk comparison against the plan (execution runs only) |

Every row carries `$ScriptVersion` and `WorkloadType`, so a change record traces back
to the revision that produced it and can be filtered to one environment.

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
- Power-on happens only with `-PowerOnAfterMigration`, and only after every group in
  the run has been verified.
- Out of scope, and still yours: DRS rules and VM-VM anti-affinity at the
  destination, in-guest WSFC and SQL validation, and backup or SRM re-protection.
- Prove the whole workflow on non-production VMs and LUNs before using it in anger.
