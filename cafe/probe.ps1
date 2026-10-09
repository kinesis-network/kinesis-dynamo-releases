# Kinesis cafe probe.
#
# Records how the AKINSOFT CafePlus "Acma Kapatma Scripti" command runs (which machine, account,
# privilege, parent process, timing) and a full inventory of the machine. Writes only under
# C:\Kinesis on the machine that executed it. Changes nothing else.
#
# Invoked from the CafePlus box as:
#   powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& ([ScriptBlock]::Create((irm <url>))) unlock"
# The event name arrives as the first argument. No "$" in the box line, so the line survives
# cmd.exe, CreateProcess, ShellExecute and a PowerShell host unchanged.
#
# Files:
#   C:\Kinesis\hook.log     one block per firing, appended
#   C:\Kinesis\machine.txt  full inventory, rewritten on every firing
#   C:\Kinesis\boots.log    one line per firing with the boot time. Lines from before a reboot
#                           vanishing after it means the disk is frozen or diskless.
#
# The probe stamps "alive" lines into hook.log as it goes - after the event block, after the
# inventory, and at 30 seconds - each with its real elapsed time, so the log shows how long
# CafePlus let the hook live. The person testing notes whether the customer's unlock waited.

param([string]$Event = 'unknown')
$ErrorActionPreference = 'Continue'
$t0 = Get-Date

function Try-Get([scriptblock]$b) { try { & $b } catch { "ERR: $($_.Exception.Message)" } }
function Join-Multi($v) { if ($null -eq $v) { '' } else { ($v | ForEach-Object { "$_" }) -join ' | ' } }

$dir = 'C:\Kinesis'
try {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        icacls $dir /grant 'Everyone:(OI)(CI)M' | Out-Null
    }
} catch {}
$log = Join-Path $dir 'hook.log'
$inv = Join-Path $dir 'machine.txt'

# ---------------------------------------------------------------- 1. the event block, fast
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
$isAdmin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isInteractive = $pr.IsInRole([Security.Principal.SecurityIdentifier]'S-1-5-4')
$groups = ($id.Groups | ForEach-Object { $_.Value }) -join ' '
$il = 'unknown'
if ($groups -match 'S-1-16-(\d+)') { $il = $matches[1] }   # 4096 low, 8192 medium, 12288 high/admin, 16384 system

$me = Try-Get { Get-CimInstance Win32_Process -Filter "ProcessId=$PID" }
$parent = $null; $gp = $null; $ggp = $null
if ($me -and $me.ParentProcessId) { $parent = Try-Get { Get-CimInstance Win32_Process -Filter "ProcessId=$($me.ParentProcessId)" } }
if ($parent -and $parent.ParentProcessId) { $gp = Try-Get { Get-CimInstance Win32_Process -Filter "ProcessId=$($parent.ParentProcessId)" } }
if ($gp -and $gp.ParentProcessId) { $ggp = Try-Get { Get-CimInstance Win32_Process -Filter "ProcessId=$($gp.ParentProcessId)" } }
$sess = (Get-Process -Id $PID).SessionId
$pipe = Test-Path '\\.\pipe\DynamoSparkGrpc'
$pdw = $false
try {
    if (Test-Path 'C:\ProgramData\Dynamo') {
        $tmp = 'C:\ProgramData\Dynamo\probe.tmp'; [IO.File]::WriteAllText($tmp, 'x'); Remove-Item $tmp; $pdw = $true
    }
} catch {}
$os = Try-Get { Get-CimInstance Win32_OperatingSystem }
$upMin = if ($os.LastBootUpTime) { [int]((Get-Date) - $os.LastBootUpTime).TotalMinutes } else { -1 }
$console = Try-Get { (Get-CimInstance Win32_ComputerSystem).UserName }
$parentIsVisible = Try-Get { (Get-Process -Id $parent.ProcessId -ErrorAction Stop).MainWindowHandle -ne 0 }

$block = @(
    "=== $($t0.ToString('yyyy-MM-dd HH:mm:ss.fff')) event=$Event",
    "host=$env:COMPUTERNAME user=$($id.Name) session=$sess interactive=$isInteractive admin=$isAdmin system=$($id.IsSystem) integrity=$il",
    "my_cmdline=$([Environment]::CommandLine)",
    "parent=$($parent.Name) pid=$($parent.ProcessId) visible_window=$parentIsVisible [$($parent.ExecutablePath)]",
    "parent_cmd=$($parent.CommandLine)",
    "grandparent=$($gp.Name) [$($gp.ExecutablePath)]",
    "greatgrandparent=$($ggp.Name) [$($ggp.ExecutablePath)]",
    "console_user=$console ps=$($PSVersionTable.PSVersion) os=$($os.Caption) build=$($os.BuildNumber) uptime_min=$upMin",
    "spark_pipe_present=$pipe programdata_dynamo_writable=$pdw",
    "groups=$groups",
    ""
)
($block -join "`r`n") | Out-File -FilePath $log -Append -Encoding utf8
function Mark([string]$stage) { "alive $stage +$([int]((Get-Date) - $t0).TotalSeconds)s event=$Event pid=$PID $((Get-Date).ToString('HH:mm:ss.fff'))" | Out-File -FilePath $log -Append -Encoding utf8 }
Mark 'event-logged'
"$($t0.ToString('yyyy-MM-dd HH:mm:ss')) event=$Event last_boot=$($os.LastBootUpTime) uptime_min=$upMin" | Out-File -FilePath (Join-Path $dir 'boots.log') -Append -Encoding utf8

# ---------------------------------------------------------------- 2. the machine inventory
$cs   = Try-Get { Get-CimInstance Win32_ComputerSystem }
$csp  = Try-Get { Get-CimInstance Win32_ComputerSystemProduct }
$bios = Try-Get { Get-CimInstance Win32_BIOS }
$bb   = Try-Get { Get-CimInstance Win32_BaseBoard }
$cpu  = Try-Get { Get-CimInstance Win32_Processor }
$gpus = Try-Get { Get-CimInstance Win32_VideoController }
$mem  = Try-Get { Get-CimInstance Win32_PhysicalMemory }
$disks = Try-Get { Get-CimInstance Win32_DiskDrive }
$vols = Try-Get { Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" }
$nics = Try-Get { Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" }
$tz   = Try-Get { (Get-TimeZone).Id }
$page = Try-Get { Get-CimInstance Win32_PageFileUsage }
$bootcfg = Try-Get { Get-CimInstance Win32_BootConfiguration }
$svcDiskless = Try-Get { Get-Service | Where-Object { $_.Name -match 'iscsi|ccboot|diskless|netboot|ibootnet|pxe|cafe|akin' -or $_.DisplayName -match 'iscsi|ccboot|diskless|netboot|cafe|akin' } | ForEach-Object { "$($_.Name)=$($_.Status)" } }
$freezeSoftware = Try-Get {
    $pattern = 'dfserv|deepfr|faronics|shdserv|shadow ?defender|uwf|rollback|reboot ?restore|returnil|toolwiz|centurion|smartshield|drvfreeze|eyebeam|wondershare|rxsrv|horizon'
    $svc = Get-Service | Where-Object { $_.Name -match $pattern -or $_.DisplayName -match $pattern } | ForEach-Object { "service:$($_.Name)=$($_.Status)" }
    $drv = Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match $pattern -or $_.DisplayName -match $pattern } | ForEach-Object { "driver:$($_.Name)=$($_.State)" }
    @($svc) + @($drv)
}
$uwf = Try-Get { if (Get-Command uwfmgr.exe -ErrorAction SilentlyContinue) { (uwfmgr.exe get-config 2>&1 | Out-String).Trim() -replace "`r?`n", ' / ' } else { 'uwfmgr not present' } }
$bootsSoFar = Try-Get { (Get-Content (Join-Path $dir 'boots.log') -ErrorAction Stop | Measure-Object -Line).Lines }
$procs = Try-Get { (Get-Process | Select-Object -ExpandProperty Name -Unique | Sort-Object) -join ', ' }
$uninst = Try-Get {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'akin|cafe|ccboot|diskless|iscsi|steam|epic|battle|riot|wsl|ubuntu|docker|nvidia|amd|dynamo|kinesis' } | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" } | Sort-Object -Unique
}
$wslFeature = Try-Get { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction Stop).DefaultDistribution }
$optFeatures = Try-Get { dism /online /english /get-features /format:table 2>$null | Select-String 'Microsoft-Windows-Subsystem-Linux|VirtualMachinePlatform|Microsoft-Hyper-V' | ForEach-Object { $_.Line.Trim() } }
# CafePlus starts the probe from a 32-bit shell, where System32 is redirected to SysWOW64 and wsl.exe
# is not there, so "not found" said nothing. Sysnative is the real System32 from a 32-bit process.
$wslExe = if ([Environment]::Is64BitProcess) { "$env:windir\System32\wsl.exe" } else { "$env:windir\Sysnative\wsl.exe" }
$wslStatus = Try-Get { if (Test-Path $wslExe) { ((& $wslExe --status 2>&1 | Out-String) -replace "`0", '').Trim() -replace "`r?`n", ' / ' } else { "wsl.exe not present ($wslExe)" } }
$secureBoot = Try-Get { Confirm-SecureBootUEFI }
$tpm = Try-Get { (Get-CimInstance -Namespace root/cimv2/security/microsofttpm -ClassName Win32_Tpm).SpecVersion }
$powerPlan = Try-Get { (Get-CimInstance -Namespace root/cimv2/power -ClassName Win32_PowerPlan -Filter "IsActive=True").ElementName }
$defender = Try-Get { (Get-MpComputerStatus).RealTimeProtectionEnabled }
$localAdmins = Try-Get { (net localgroup administrators 2>$null | Select-Object -Skip 6 | Where-Object { $_ -and $_ -notmatch 'command completed' }) -join ', ' }
$users = Try-Get { (Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" | ForEach-Object { "$($_.Name)(disabled=$($_.Disabled))" }) -join ', ' }
$sessions = Try-Get { (query user 2>$null | Out-String).Trim() }
$dispRes = Try-Get { ($gpus | ForEach-Object { "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)@$($_.CurrentRefreshRate)" }) -join ' | ' }
$hvPresent = Try-Get { $cs.HypervisorPresent }
$vtFirmware = Try-Get { Join-Multi ($cpu | ForEach-Object { $_.VirtualizationFirmwareEnabled }) }
$kinesisDir = Try-Get { (Get-ChildItem 'C:\Kinesis' -ErrorAction Stop | ForEach-Object { "$($_.Name) $($_.LastWriteTime.ToString('HH:mm:ss'))" }) -join ', ' }
$t1 = Get-Date

# The one line nobody may miss: WSL2, and so Spark, cannot run on a PC whose BIOS has CPU
# virtualization switched off, and at the first venue two PCs of the same chain differed.
# A running hypervisor proves it is on even where the firmware flag reads False.
$virtOn = ($cpu | Where-Object { $_.VirtualizationFirmwareEnabled -eq $true }) -or ($hvPresent -eq $true)
$virtVerdict = if ($virtOn) { 'ON' } else { 'OFF - enable SVM (AMD) or VT-x (Intel) in this PC BIOS before installing Spark' }

$inventory = @(
    "Kinesis cafe probe inventory. Written $($t1.ToString('yyyy-MM-dd HH:mm:ss')) during event=$Event. Probe runtime $([int]($t1 - $t0).TotalMilliseconds) ms.",
    "",
    "VIRTUALIZATION: $virtVerdict",
    "",
    "[identity]",
    "computer_name=$env:COMPUTERNAME domain_or_workgroup=$($cs.Domain) part_of_domain=$($cs.PartOfDomain)",
    "smbios_uuid=$($csp.UUID)",
    "system_manufacturer=$($cs.Manufacturer) model=$($cs.Model) family=$($cs.SystemFamily) sku=$($cs.SystemSKUNumber)",
    "product_identifying_number=$($csp.IdentifyingNumber) product_version=$($csp.Version)",
    "bios_vendor=$($bios.Manufacturer) bios_version=$($bios.SMBIOSBIOSVersion) bios_serial=$($bios.SerialNumber) bios_date=$($bios.ReleaseDate)",
    "baseboard_manufacturer=$($bb.Manufacturer) baseboard_product=$($bb.Product) baseboard_serial=$($bb.SerialNumber)",
    "machine_guid=$(Try-Get { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid })",
    "",
    "[os]",
    "caption=$($os.Caption) version=$($os.Version) build=$($os.BuildNumber) arch=$($os.OSArchitecture)",
    "install_date=$($os.InstallDate) last_boot=$($os.LastBootUpTime) uptime_min=$upMin",
    "locale=$($os.Locale) language=$($os.MUILanguages -join ',') timezone=$tz",
    "windows_dir=$($os.WindowsDirectory) system_drive=$($os.SystemDrive) boot_device=$($os.BootDevice) system_device=$($os.SystemDevice)",
    "boot_configuration=$($bootcfg.BootDirectory) last_drive=$($bootcfg.LastDrive)",
    "secure_boot=$secureBoot tpm_spec=$tpm power_plan=$powerPlan defender_realtime=$defender",
    "pagefile=$(Join-Multi ($page | ForEach-Object { "$($_.Name) $($_.AllocatedBaseSize)MB" }))",
    "",
    "[cpu]",
    "$(Join-Multi ($cpu | ForEach-Object { "$($_.Name) cores=$($_.NumberOfCores) threads=$($_.NumberOfLogicalProcessors) mhz=$($_.MaxClockSpeed) vt_firmware=$($_.VirtualizationFirmwareEnabled) vmm_extensions=$($_.VMMonitorModeExtensions)" }))",
    "hypervisor_present=$hvPresent",
    "",
    "[memory]",
    "total_physical_mb=$([int]($cs.TotalPhysicalMemory / 1MB)) free_mb=$([int]($os.FreePhysicalMemory / 1KB))",
    "modules=$(Join-Multi ($mem | ForEach-Object { "$($_.Manufacturer) $($_.PartNumber) $([int]($_.Capacity/1MB))MB $($_.Speed)MHz serial=$($_.SerialNumber)" }))",
    "",
    "[gpu]",
    "$(Join-Multi ($gpus | ForEach-Object { "$($_.Name) driver=$($_.DriverVersion) date=$($_.DriverDate) vram_mb=$([int]($_.AdapterRAM/1MB)) status=$($_.Status) pnp=$($_.PNPDeviceID)" }))",
    "displays=$dispRes",
    "",
    "[storage]",
    "disks=$(Join-Multi ($disks | ForEach-Object { "$($_.Model) interface=$($_.InterfaceType) size_gb=$([int]($_.Size/1GB)) media=$($_.MediaType) serial=$($_.SerialNumber) pnp=$($_.PNPDeviceID)" }))",
    "volumes=$(Join-Multi ($vols | ForEach-Object { "$($_.DeviceID) fs=$($_.FileSystem) size_gb=$([int]($_.Size/1GB)) free_gb=$([int]($_.FreeSpace/1GB)) label=$($_.VolumeName)" }))",
    "diskless_or_cafe_services=$(Join-Multi $svcDiskless)",
    "freeze_software=$(Join-Multi $freezeSoftware)",
    "uwf=$uwf",
    "boots_log_lines=$bootsSoFar (compare across a reboot: fewer lines than before means writes do not survive)",
    "",
    "[network]",
    "$(Join-Multi ($nics | ForEach-Object { "$($_.Description) mac=$($_.MACAddress) ip=$($_.IPAddress -join ',') gw=$($_.DefaultIPGateway -join ',') dhcp=$($_.DHCPEnabled) dns=$($_.DNSServerSearchOrder -join ',')" }))",
    "",
    "[virtualisation]",
    "wsl_default_distribution_key=$wslFeature",
    "optional_features=$(Join-Multi $optFeatures)",
    "wsl_status=$wslStatus",
    "",
    "[accounts]",
    "local_users=$users",
    "local_administrators=$localAdmins",
    "console_user=$console",
    "sessions=$sessions",
    "",
    "[software]",
    "relevant_installed=$(Join-Multi $uninst)",
    "running_processes=$procs",
    "",
    "[probe]",
    "kinesis_dir=$kinesisDir",
    "invoked_as=$([Environment]::CommandLine)",
    "ps_version=$($PSVersionTable.PSVersion) ps_edition=$($PSVersionTable.PSEdition) execution_policy=$(Get-ExecutionPolicy)",
    ""
)
($inventory -join "`r`n") | Out-File -FilePath $inv -Encoding utf8

# ---------------------------------------------------------------- 3. does the hook get to live
# Last, so the inventory above is written however early CafePlus ends the hook.
Mark 'inventory-written'

# ---------------------------------------------------------------- 4. where CafePlus keeps its state
# No hook fires at boot, and a rented PC stays rented through a restart, so Spark has to read
# "rented or not" from CafePlus itself. Captured 5 and 25 seconds after each hook - once while the
# transition may still be settling, once after - so comparing a rent with an end of session shows
# which registry value, file or window changes with it. Values are cut to 120 characters.
$statePath = Join-Path $dir 'cafeplus-state.txt'
try {
    Add-Type -TypeDefinition @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class KinesisWindows {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    public struct Rect { public int L, T, R, B; }
    public static List<string> Visible(uint[] pids) {
        var found = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (Array.IndexOf(pids, pid) >= 0 && IsWindowVisible(h)) {
                var title = new StringBuilder(256); GetWindowText(h, title, 256);
                Rect r; GetWindowRect(h, out r);
                bool topmost = (GetWindowLong(h, -20) & 0x8) != 0;
                found.Add(string.Format("window pid={0} topmost={1} rect={2},{3} {4}x{5} title={6}", pid, topmost, r.L, r.T, r.R - r.L, r.B - r.T, title));
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
} catch {}

function Capture-CafePlus([string]$stage) {
    $lines = @("=== $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')) event=$Event stage=$stage")
    foreach ($root in 'HKLM:\SOFTWARE\WOW6432Node\AKINSOFT', 'HKLM:\SOFTWARE\AKINSOFT', 'HKCU:\Software\AKINSOFT') {
        if (-not (Test-Path $root)) { continue }
        $keys = @(Get-Item $root) + @(Get-ChildItem $root -Recurse -ErrorAction SilentlyContinue)
        foreach ($k in $keys) {
            foreach ($n in $k.GetValueNames()) {
                $v = "$($k.GetValue($n))"
                if ($v.Length -gt 120) { $v = $v.Substring(0, 120) + '...' }
                $lines += "reg $($k.Name)\$n=$v"
            }
        }
    }
    $cpDir = 'C:\Program Files (x86)\AKINSOFT\CafePlusClient12'
    $recent = (Get-Date).AddMinutes(-3)
    Get-ChildItem $cpDir -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 40 | ForEach-Object {
        $lines += "file $($_.FullName.Substring($cpDir.Length)) size=$($_.Length) written=$($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss.fff'))"
        if ($_.LastWriteTime -gt $recent -and $_.Length -lt 4096 -and $_.Extension -match '^\.(ini|cfg|txt|xml|json|dat)$') {
            Get-Content $_.FullName -TotalCount 30 -ErrorAction SilentlyContinue | ForEach-Object { $lines += "  | $_" }
        }
    }
    try {
        $pids = [uint32[]]@(Get-Process cplusc -ErrorAction Stop | ForEach-Object { $_.Id })
        $lines += [KinesisWindows]::Visible($pids)
    } catch { $lines += "windows: ERR $($_.Exception.Message)" }
    $lines += ''
    ($lines -join "`r`n") | Out-File -FilePath $statePath -Append -Encoding utf8
}

function Wait-Until([int]$seconds) {
    $wait = $t0.AddSeconds($seconds) - (Get-Date)
    if ($wait.TotalMilliseconds -gt 0) { Start-Sleep -Milliseconds ([int]$wait.TotalMilliseconds) }
}

Wait-Until 5
try { Capture-CafePlus 'after-5s' } catch {}
Wait-Until 25
try { Capture-CafePlus 'after-25s' } catch {}
Wait-Until 30
Mark 'held-30s'
