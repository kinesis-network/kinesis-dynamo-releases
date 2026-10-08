# Kinesis cafe probe

Scripts for the first onsite test of the AKINSOFT CafePlus hook. Nothing here installs or
changes anything on a PC beyond creating `C:\Kinesis` and writing two text files into it.
This branch is independent of the Dynamo release feed and of `main`.

## Box lines (REGISTER PC, Genel Client Ayarlari > Acma Kapatma Scripti)

Top box, "Client kullanima acilirken":

    powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& ([ScriptBlock]::Create((irm https://raw.githubusercontent.com/kinesis-network/kinesis-dynamo-releases/cafe-probe/cafe/probe.ps1))) unlock"

Bottom box, "Client kilitlenirken":

    powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& ([ScriptBlock]::Create((irm https://raw.githubusercontent.com/kinesis-network/kinesis-dynamo-releases/cafe-probe/cafe/probe.ps1))) lock"

The line contains no `$`, no `%`, no backtick and no unquoted `&`, so it reads the same
whether CafePlus hands it to cmd.exe, CreateProcess, ShellExecute or a PowerShell host.
The script always downloads fresh; raw.githubusercontent.com may cache a pushed change for
up to five minutes.

## What gets written, on the machine that ran it

- `C:\Kinesis\hook.log`: one block per firing. Machine, account, session, interactive,
  admin, SYSTEM, integrity level, the exact command line the probe was started with, the
  parent process (the CafePlus client) and its command line, grandparent and
  great-grandparent, console user, uptime, whether the Spark pipe exists.
- `C:\Kinesis\machine.txt`: full inventory, rewritten each time. SMBIOS UUID, serials,
  model, BIOS, CPU with virtualisation flags, memory modules, GPUs with driver, disks and
  interfaces, volumes and free space, services that look like diskless or cafe software,
  NICs with MACs, WSL and Hyper-V feature state, secure boot, TPM, local users and
  administrators, sessions, relevant installed software, running process names.

## What to note by hand while testing

- **Did the customer's unlock wait?** The probe deliberately stays alive for 30 seconds. Note
  whether CafePlus held the unlock (or the lock screen) until it finished. `hook.log` shows
  `alive event-logged`, `alive inventory-written` and `alive held-30s` lines with elapsed
  seconds; the last one present says how long CafePlus let the hook live.
- **Run it on at least two PCs.** Per-PC identity will be built from hardware IDs, and only a
  comparison across machines shows which ones are actually unique. A cloned image gives every
  PC the same `machine_guid`, and some boards ship the same placeholder `smbios_uuid`.
- **Reboot one PC once and fire a hook again.** If `boots.log` lost its earlier lines, the
  disk is frozen or diskless. `freeze_software` in `machine.txt` names what does it.

## Fallbacks, if `hook.log` does not appear on the TEST PC

1. Look for it on the REGISTER PC. Present there means the box runs on the server.
2. Box line `cmd /c mkdir C:\Kinesis\fired`. A `fired` folder on the TEST PC means
   commands run but PowerShell or internet did not.
3. Download `probe-local.cmd` from this branch into `C:\Kinesis\` on the TEST PC and set
   the boxes to `C:\Kinesis\probe-local.cmd unlock` and `C:\Kinesis\probe-local.cmd lock`.

Empty both boxes before leaving.
