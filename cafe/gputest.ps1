# Kinesis cafe GPU-in-WSL test, run as the signed-in Administrator (NOT through the Spark service).
# Bridges the diskless PC's linked NVIDIA driver files into the Administrator's own Ubuntu-24.04 distro
# exactly as Spark does inside its service-owned distro, then runs nvidia-smi. Comparing the two tells
# whether a failure is about the account/session or about the PC's driver.
# Installs Ubuntu-24.04 for this user if missing (gone at the next restart on a diskless PC).
# Run (admin PowerShell): irm https://raw.githubusercontent.com/kinesis-network/kinesis-dynamo-releases/cafe-probe/cafe/gputest.ps1 | iex

$ErrorActionPreference = 'Continue'
$distro = 'Ubuntu-24.04'
"Kinesis GPU test  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  host=$env:COMPUTERNAME  user=$env:USERNAME"
"wsl: $((wsl.exe --version | Out-String) -replace "`0", '' -replace "`r?`n", ' | ')"
Get-CimInstance Win32_VideoController | ForEach-Object { "gpu: $($_.Name) driver=$($_.DriverVersion) status=$($_.Status)" }

$lxss = Join-Path $env:SystemRoot 'System32\lxss\lib'
$libTarget = Get-ChildItem $lxss -File | ForEach-Object { $_.Target } | Where-Object { $_ } | Select-Object -First 1
if (-not $libTarget) { 'lxss\lib holds ordinary files - nothing to bridge on this PC.'; return }
$libSrc = Split-Path $libTarget
if ($libSrc -like "$env:SystemRoot\*") { "lxss\lib links point inside Windows ($libSrc) - an ordinary PC, nothing to bridge."; return }
$drvFolder = Get-ChildItem (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository') -Directory -Filter 'nv*.inf_amd64_*' |
    Where-Object { Test-Path (Join-Path $_.FullName 'libcuda.so.1.1') } | Select-Object -First 1
$drvTarget = (Get-Item (Join-Path $drvFolder.FullName 'libcuda.so.1.1')).Target
"links in the driver folder, by target folder:"
Get-ChildItem $drvFolder.FullName -File | Where-Object { $_.Target } | Group-Object { Split-Path $_.Target } | ForEach-Object { "  $($_.Count) -> $($_.Name)" }
$drvSrc = Split-Path $drvTarget
"lib source:    $libSrc"
"driver folder: $($drvFolder.Name)"
"driver source: $drvSrc"

if (-not ((wsl.exe -l -q | Out-String) -replace "`0", '' -match [regex]::Escape($distro))) {
    "Installing $distro for $env:USERNAME (a few minutes)..."
    wsl.exe --install -d $distro --no-launch | Out-Null
    $exe = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps" -Filter 'ubuntu*24*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { & $exe.FullName install --root | Out-Null }
}

function ToLinux([string]$p) { "/mnt/sgt-$($p.Substring(0,1).ToLower())/" + $p.Substring(3).Replace('\', '/') }
$drive = $libSrc.Substring(0, 1).ToUpper()
$script = @"
set +e
M=/mnt/sgt-$($drive.ToLower())
mkdir -p `$M; mountpoint -q `$M || mount -t drvfs ${drive}: `$M
LIB='$(ToLinux $libSrc)'
DRV='$(ToLinux $drvSrc)'
D=/usr/lib/wsl/drivers/$($drvFolder.Name)
echo "--- before bridging:"; LD_LIBRARY_PATH=/usr/lib/wsl/lib /usr/lib/wsl/lib/nvidia-smi -L 2>&1 | head -3
ls -l /dev/dxg
while mountpoint -q /usr/lib/wsl/lib; do umount /usr/lib/wsl/lib; done
while mountpoint -q `$D; do umount `$D; done
V=/var/lib/sgt-view; rm -rf `$V; mkdir -p `$V
for f in "`$LIB"/*; do ln -s "`$f" "`$V/`$(basename "`$f" | tr A-Z a-z)"; done
cp --remove-destination "`$(readlink -f `$V/nvidia-smi)" `$V/nvidia-smi; chmod 755 `$V/nvidia-smi
mount --bind `$V /usr/lib/wsl/lib
mount --bind "`$DRV" `$D
echo "--- after bridging (linked):"; LD_LIBRARY_PATH=/usr/lib/wsl/lib /usr/lib/wsl/lib/nvidia-smi -L 2>&1 | head -3
echo "--- driver folder sample:"; ls `$D | head -5
echo "--- CUDA (what jobs use; NVML can refuse while CUDA works):"
LD_LIBRARY_PATH=/usr/lib/wsl/lib python3 -c "import ctypes;c=ctypes.CDLL('libcuda.so.1');r=c.cuInit(0);n=ctypes.c_int(0);c.cuDeviceGetCount(ctypes.byref(n));print('cuInit',r,'devices',n.value)" 2>&1 | tail -2
echo "--- kernel log (dxg = WSL's GPU driver):"
dmesg 2>/dev/null | grep -i -E 'dxg|gpu|nvidia' | tail -20
"@
$path = 'C:\Kinesis\gputest.sh'
New-Item -ItemType Directory -Force C:\Kinesis | Out-Null
[IO.File]::WriteAllText($path, ($script -replace "`r`n", "`n"))
"--- running in $distro as root (Administrator's WSL):"
wsl.exe -d $distro -u root -- bash /mnt/c/Kinesis/gputest.sh
