# Kinesis venue survey. Read-only: reads settings, logs and files, changes nothing.
# Collects everything a later design question might need from a venue PC, in one file.
# Run (admin PowerShell): irm https://raw.githubusercontent.com/kinesis-network/kinesis-dynamo-releases/cafe-probe/cafe/survey.ps1 | iex
# Output: C:\Kinesis\survey-<PC>-<time>.txt

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force C:\Kinesis | Out-Null
$out = "C:\Kinesis\survey-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$sw = [Diagnostics.Stopwatch]::StartNew()

function Section([string]$name, [scriptblock]$body) {
    "`n===== $name ====="
    try { & $body 2>&1 | Out-String -Width 220 } catch { "ERR: $($_.Exception.Message)" }
}
function RegDump([string]$path) {
    if (Test-Path $path) {
        $k = Get-Item $path
        foreach ($n in $k.GetValueNames()) { "$path :: $n = $($k.GetValue($n))" }
    } else { "$path (missing)" }
}

& {
"Kinesis venue survey  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  host=$env:COMPUTERNAME  user=$env:USERNAME"

Section 'OS and boot' {
    $os = Get-CimInstance Win32_OperatingSystem
    "caption=$($os.Caption) build=$($os.BuildNumber) ubr=$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR) installed=$($os.InstallDate) last_boot=$($os.LastBootUpTime)"
    "edition=$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID) displayversion=$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion)"
    "timezone=$((Get-TimeZone).Id) culture=$((Get-Culture).Name) uiculture=$((Get-UICulture).Name)"
    "secureboot=$(try { Confirm-SecureBootUEFI } catch { 'n/a' })"
    Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, ManufacturerIdTxt, ManufacturerVersion
}

Section 'Hardware' {
    Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions
    Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer, Product, SerialNumber
    Get-CimInstance Win32_ComputerSystemProduct | Select-Object UUID, Vendor, Name
    Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion, ReleaseDate
    Get-CimInstance Win32_PhysicalMemory | Select-Object Capacity, Speed, ConfiguredClockSpeed, PartNumber
    "hypervisor_present=$((Get-CimInstance Win32_ComputerSystem).HypervisorPresent)"
}

Section 'GPU: adapters and problem codes' {
    Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, DriverDate, Status, ConfigManagerErrorCode, AdapterRAM, VideoModeDescription, PNPDeviceID | Format-List
    Get-PnpDevice -Class Display | Select-Object FriendlyName, Status, Problem, ProblemDescription, InstanceId | Format-List
}

Section 'GPU: NVIDIA on the Windows side' {
    $smi = @("$env:SystemRoot\System32\nvidia-smi.exe") + (Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository\nv*\nvidia-smi.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName)
    foreach ($s in $smi | Select-Object -Unique) { if (Test-Path $s) { "--- $s"; & $s 2>&1 | Select-Object -First 25; & $s -q 2>&1 | Select-String 'Driver Model|Driver Version|CUDA Version|Product Name|Virtualization Mode|Host VGPU Mode|Persistence|Display Active|MIG Mode' } }
}

Section 'GPU: scheduling, WDDM and GPU-PV settings' {
    RegDump 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    RegDump 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Scheduler'
    RegDump 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization'
    RegDump 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV'
    try { Get-VMHostPartitionableGpu | Select-Object Name, ValidPartitionCounts, PartitionCount | Format-List } catch { "Get-VMHostPartitionableGpu: $($_.Exception.Message)" }
}

Section 'GPU: driver files, links and permissions' {
    $lib = "$env:SystemRoot\System32\lxss\lib"
    "lxss\lib:"; Get-ChildItem $lib -ErrorAction SilentlyContinue | Select-Object Name, Length, LinkType, Target | Format-Table -AutoSize
    $nv = Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" -Directory -Filter 'nv_dispi*' -ErrorAction SilentlyContinue
    foreach ($f in $nv) {
        "--- $($f.FullName)"
        "files=$((Get-ChildItem $f.FullName -File).Count) links=$((Get-ChildItem $f.FullName -File | Where-Object LinkType).Count)"
        icacls $f.FullName
        $t = (Get-Item (Join-Path $f.FullName 'libcuda.so.1.1') -ErrorAction SilentlyContinue).Target
        "libcuda.so.1.1 -> $t"
        if ($t) { icacls (Split-Path $t); icacls $t }
    }
    if (Test-Path B:\) { "--- B:\"; icacls B:\; if (Test-Path B:\pnplib) { icacls B:\pnplib }; Get-ChildItem B:\pnplib -Directory -ErrorAction SilentlyContinue | Select-Object Name, LastWriteTime | Format-Table -AutoSize }
    "drivers in store (display):"; pnputil /enum-drivers /class Display 2>&1
}

Section 'GPU and VM events (System log, last 2 days)' {
    $since = (Get-Date).AddDays(-2)
    try { Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$since} -ErrorAction Stop |
        Where-Object { $_.ProviderName -match 'Dxg|Display|nvlddmkm|Hyper-V|Vmbus|vmwp|Wsl|LxssManager|amdkmdag' -or $_.LevelDisplayName -in 'Error','Critical' } |
        Select-Object -First 60 TimeCreated, ProviderName, Id, LevelDisplayName, @{n='Msg';e={($_.Message -replace '\s+',' ').Substring(0, [Math]::Min(220, ($_.Message -replace '\s+',' ').Length))}} | Format-Table -Wrap } catch { "system log: $($_.Exception.Message)" }
    foreach ($log in 'Microsoft-Windows-Hyper-V-Worker-Admin', 'Microsoft-Windows-Hyper-V-Compute-Admin') {
        "--- $log"; try { Get-WinEvent -LogName $log -MaxEvents 25 -ErrorAction Stop | Select-Object TimeCreated, Id, LevelDisplayName, @{n='Msg';e={($_.Message -replace '\s+',' ').Substring(0, [Math]::Min(220, ($_.Message -replace '\s+',' ').Length))}} | Format-Table -Wrap } catch { "$($_.Exception.Message)" }
    }
}

Section 'WSL' {
    ((wsl.exe --version) -join ' | ') -replace "`0", ''
    ((wsl.exe --status) -join ' | ') -replace "`0", ''
    ((wsl.exe -l -v) -join ' | ') -replace "`0", ''
    try { Get-AppxPackage -AllUsers *WindowsSubsystemForLinux* -ErrorAction Stop | Select-Object Name, Version, InstallLocation } catch { "appx: $($_.Exception.Message)" }
    Get-Service WSLService, LxssManager, vmcompute, vmms, hns -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType
    try { Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { $_.FeatureName -match 'Hyper-V|VirtualMachinePlatform|Subsystem-Linux|Containers|HypervisorPlatform|Sandbox' } | Select-Object FeatureName, State } catch { "features: $($_.Exception.Message)" }
    "--- %USERPROFILE%\.wslconfig"; Get-Content "$env:USERPROFILE\.wslconfig" -ErrorAction SilentlyContinue
}

Section 'Disks, write cache and diskless client' {
    Get-CimInstance Win32_DiskDrive | Select-Object Model, InterfaceType, Size, SerialNumber, MediaType
    Get-Volume | Select-Object DriveLetter, FileSystemLabel, FileSystem, DriveType, Size, SizeRemaining | Format-Table -AutoSize
    Get-Service | Where-Object { $_.Name -match '^lw|cgm|diskless|ccboot|nxd|vhd|iscsi|akinsoft|cafe' -or $_.DisplayName -match 'diskless|CGM|CafePlus|AKINSOFT|LW' } | Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize
    Get-Process | Where-Object { $_.Name -match '^lw|cgm|cplus|cafe|asinj' } | Select-Object Name, Id, Path | Format-Table -AutoSize
    "pagefile:"; Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage
}

Section 'CafePlus client' {
    $dir = 'C:\Program Files (x86)\AKINSOFT\CafePlusClient12'
    Get-ChildItem $dir -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
    "script.cmd:"; Get-Content "$dir\script.cmd" -ErrorAction SilentlyContinue
    "--- how cplusc starts"
    Get-CimInstance Win32_Process -Filter "Name='cplusc.exe'" | Select-Object ProcessId, ParentProcessId, CommandLine, CreationDate
    Get-CimInstance Win32_Process -Filter "Name='cplusc.exe'" | ForEach-Object { $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)"; "parent: $($p.Name) $($p.CommandLine)" }
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon') { RegDump $k }
    "--- AKINSOFT registry (names only for values that look like secrets)"
    foreach ($root in 'HKLM:\SOFTWARE\WOW6432Node\AKINSOFT', 'HKLM:\SOFTWARE\AKINSOFT', 'HKCU:\SOFTWARE\AKINSOFT') {
        if (Test-Path $root) { Get-ChildItem $root -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.Name; foreach ($n in $_.GetValueNames()) { $v = "$($_.GetValue($n))"; if ($n -match 'pass|sifre|key|token|pwd') { "  $n = <hidden>" } else { "  $n = $($v.Substring(0, [Math]::Min(120, $v.Length)))" } } } }
    }
}

Section 'Power and sleep (24/7 matters)' {
    powercfg /getactivescheme
    powercfg /a
    powercfg /q SCHEME_CURRENT SUB_SLEEP 2>&1 | Select-String 'Power Setting GUID|Current AC Power Setting Index'
    powercfg /q SCHEME_CURRENT SUB_VIDEO 2>&1 | Select-String 'Power Setting GUID|Current AC Power Setting Index'
    RegDump 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
}

Section 'Time, proxy, firewall, antivirus, updates' {
    w32tm /query /status 2>&1
    netsh winhttp show proxy
    RegDump 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction
    Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -ErrorAction SilentlyContinue | Select-Object displayName, productState
    Get-Service WinDefend, wuauserv, UsoSvc, BITS -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType
    RegDump 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, InstalledOn
}

Section 'Startup software and scheduled tasks (non-Microsoft)' {
    Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location | Format-Table -Wrap
    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | Select-Object TaskPath, TaskName, State, @{n='Action';e={($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; '}} | Format-Table -Wrap
    Get-CimInstance Win32_Service | Where-Object { $_.PathName -notmatch '\\Windows\\' } | Select-Object Name, State, StartMode, StartName, PathName | Format-Table -Wrap
}

Section 'Sessions and accounts' {
    Get-CimInstance Win32_LoggedOnUser -ErrorAction SilentlyContinue | ForEach-Object { $_.Antecedent.Name } | Sort-Object -Unique
    Get-LocalUser | Select-Object Name, Enabled, LastLogon
    Get-LocalGroupMember Administrators -ErrorAction SilentlyContinue | Select-Object Name
    try { Get-Process -IncludeUserName -ErrorAction Stop | Where-Object { $_.Name -in 'explorer', 'cplusc', 'Dynamo.Spark.Ui', 'Dynamo.Spark.WinService' } | Select-Object Name, Id, UserName, SessionId } catch { "processes: $($_.Exception.Message)" }
}

Section 'Spark' {
    Get-Service | Where-Object { $_.Name -match 'Dynamo' } | Select-Object Name, Status, StartType
    $exe = 'C:\Program Files\Dynamo\Dynamo.Spark.WinService.exe'
    if (Test-Path $exe) { & $exe status --json 2>&1; "version: $((Get-Item $exe).VersionInfo.ProductVersion)" }
    "availability-state.json:"; Get-Content C:\ProgramData\Dynamo\availability-state.json -ErrorAction SilentlyContinue
    Get-ChildItem C:\ProgramData\Dynamo -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
    $log = Get-ChildItem C:\ProgramData\Dynamo\Logs\service -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($log) { "--- milestones in $($log.Name)"; Select-String -Path $log.FullName -Pattern '"EventName":"Milestone"' | Select-Object -Last 25 | ForEach-Object { ($_.Line | ConvertFrom-Json).msg } }
    "--- recent warnings/errors"; if ($log) { Select-String -Path $log.FullName -Pattern '"level":"(Warning|Error|Fatal)"' | Select-Object -Last 15 | ForEach-Object { $j = $_.Line | ConvertFrom-Json; "$($j.ts) $($j.level) $($j.msg)" } }
    Get-Process vmmem*, wsl*, Dynamo* -ErrorAction SilentlyContinue | Select-Object Name, Id, @{n='MB';e={[int]($_.WorkingSet64/1MB)}} | Format-Table -AutoSize
}

Section 'Network adapters' {
    Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress | Format-Table -AutoSize
    Get-NetIPConfiguration | Select-Object InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer | Format-List
    Get-NetIPInterface -AddressFamily IPv4 | Where-Object ConnectionState -eq Connected | Select-Object InterfaceAlias, NlMtu | Format-Table -AutoSize
}

"`nsurvey took $([int]$sw.Elapsed.TotalSeconds)s"
} | Out-File -FilePath $out -Encoding utf8 -Width 220

"Survey written to $out ($([int]((Get-Item $out).Length/1KB)) KB). Send me this file."
