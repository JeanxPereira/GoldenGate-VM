# One-time setup of the VM data disk (a dynamic ext4 VHDX), run from an ELEVATED PowerShell:
#   powershell -ExecutionPolicy Bypass -File <repo>\tools\setup-data-vhd.ps1 [-Vhd <path.vhdx>] [-SizeGB 70] [-Distro Ubuntu]
# Put the VHDX on a fast NVMe drive: the guest disk and the QEMU overlays live there.
# Creates the VHDX (dynamic: grows only with use), formats it ext4 with label ggdata, mounts it
# in WSL at /mnt/wsl/ggdata, and registers a logon task 'GG mount data disk' that re-mounts it
# (wsl --mount needs admin, so the task runs with highest privileges).
# Afterwards, inside WSL, point $GG_HOME (default ~/gg) at it, e.g.:
#   mkdir -p /mnt/wsl/ggdata/gg && ln -s /mnt/wsl/ggdata/gg ~/gg
# Does not restart WSL: running jobs keep going.
param(
  [string]$Vhd = "$env:SystemDrive\WSL\gg-data.vhdx",
  [int]$SizeGB = 70,
  [string]$Distro = 'Ubuntu'
)
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = 1
$dir = Split-Path -Parent $Vhd

New-Item -ItemType Directory -Force $dir | Out-Null
if (-not (Test-Path $Vhd)) {
  "create vdisk file=`"$Vhd`" maximum=$($SizeGB * 1024) type=expandable" | diskpart | Out-Null
  if (-not (Test-Path $Vhd)) { throw "diskpart did not create $Vhd" }
}
# Owner = the normal user, or WSL's attach fails with E_ACCESSDENIED.
icacls $dir /setowner $env:USERNAME /T /C | Out-Null

# Format once: attach bare, find the one blank disk of that size, mkfs it.
$fs = wsl -d $Distro -u root -e blkid -L ggdata 2>$null
if (-not $fs) {
  wsl --mount --vhd $Vhd --bare
  $dev = wsl -d $Distro -u root -e bash -c "lsblk -dpno NAME,SIZE,FSTYPE | awk '`$2==`"$($SizeGB)G`" && `$3==`"`" {print `$1}'"
  $dev = @($dev | Where-Object { $_ })
  if ($dev.Count -ne 1) { wsl --unmount $Vhd; throw "expected one blank $($SizeGB)G disk, found: $($dev -join ',') - nothing formatted" }
  # full path: `wsl -e` does not search /usr/sbin
  wsl -d $Distro -u root -e /usr/sbin/mkfs.ext4 -q -L ggdata -m 0 $dev[0]
  wsl --unmount $Vhd
}

# Mount at /mnt/wsl/ggdata (whole-disk ext4, no partition table).
wsl --mount --vhd $Vhd --name ggdata --type ext4 2>&1 | Out-Host

# Re-mount at every logon.
$action  = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument "--mount --vhd `"$Vhd`" --name ggdata --type ext4"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$princ   = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
Register-ScheduledTask -TaskName 'GG mount data disk' -Action $action -Trigger $trigger -Principal $princ -Force | Out-Null

wsl -d $Distro -e df -h /mnt/wsl/ggdata
Write-Host "Done: data disk mounted at /mnt/wsl/ggdata, logon task 'GG mount data disk' registered." -ForegroundColor Green
