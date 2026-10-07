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

## Fallbacks, if `hook.log` does not appear on the TEST PC

1. Look for it on the REGISTER PC. Present there means the box runs on the server.
2. Box line `cmd /c mkdir C:\Kinesis\fired`. A `fired` folder on the TEST PC means
   commands run but PowerShell or internet did not.
3. Download `probe-local.cmd` from this branch into `C:\Kinesis\` on the TEST PC and set
   the boxes to `C:\Kinesis\probe-local.cmd unlock` and `C:\Kinesis\probe-local.cmd lock`.

Empty both boxes before leaving.
