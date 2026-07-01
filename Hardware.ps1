# Hardware Inventory Export
# Windows 11 / PowerShell 5.1+
# Saves CSV to C:\Temp\<Manufacturer> <Model>.csv

$ErrorActionPreference = "SilentlyContinue"

$OutDir = "C:\Temp"
if (-not (Test-Path $OutDir)) {
    New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
}

function Clean-FileName {
    param([string]$Name)
    $invalid = [IO.Path]::GetInvalidFileNameChars() -join ''
    $regex = "[{0}]" -f [Regex]::Escape($invalid)
    return ($Name -replace $regex, '').Trim()
}

function Convert-BytesToGB {
    param([double]$Bytes)
    if ($null -eq $Bytes -or $Bytes -eq 0) { return $null }
    return [math]::Round($Bytes / 1GB, 2)
}

function Get-MemoryTypeName {
    param([int]$Type)

    switch ($Type) {
        20 { "DDR" }
        21 { "DDR2" }
        24 { "DDR3" }
        26 { "DDR4" }
        34 { "DDR5" }
        default { "Unknown / Not Reported" }
    }
}

function Get-ChassisType {
    param([int[]]$Types)

    $LaptopTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $DesktopTypes = @(3, 4, 5, 6, 7, 13, 15, 16, 35, 36)

    foreach ($Type in $Types) {
        if ($LaptopTypes -contains $Type) { return "Laptop" }
    }

    foreach ($Type in $Types) {
        if ($DesktopTypes -contains $Type) { return "Desktop" }
    }

    return "Unknown"
}

function Get-WindowsDisplayVersion {
    $RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $Props = Get-ItemProperty -Path $RegPath

    if ($Props.DisplayVersion) {
        return $Props.DisplayVersion
    }

    if ($Props.ReleaseId) {
        return $Props.ReleaseId
    }

    return "Unknown"
}

function Get-DriveBusType {
    param([int]$BusType)

    switch ($BusType) {
        3  { "SCSI" }
        7  { "USB" }
        11 { "SATA" }
        12 { "SD" }
        16 { "SAS" }
        17 { "NVMe" }
        default { "Unknown / Not Reported" }
    }
}

function Get-NicSpeed {
    param([UInt64]$Speed)

    if ($null -eq $Speed -or $Speed -eq 0) {
        return "Unknown / Not Connected"
    }

    if ($Speed -ge 10000000000) { return "10Gb" }
    if ($Speed -ge 5000000000)  { return "5Gb" }
    if ($Speed -ge 2500000000)  { return "2.5Gb" }
    if ($Speed -ge 1000000000)  { return "1Gb" }
    if ($Speed -ge 100000000)   { return "100Mb" }

    return "$Speed bps"
}

# --- Computer Info ---
$ComputerSystem = Get-CimInstance Win32_ComputerSystem
$ComputerProduct = Get-CimInstance Win32_ComputerSystemProduct
$BIOS = Get-CimInstance Win32_BIOS
$Enclosure = Get-CimInstance Win32_SystemEnclosure
$OS = Get-CimInstance Win32_OperatingSystem

$ComputerManufacturer = $ComputerSystem.Manufacturer
$ComputerModel = $ComputerSystem.Model
$ComputerType = Get-ChassisType -Types $Enclosure.ChassisTypes

$WindowsVersion = Get-WindowsDisplayVersion
$WindowsCaption = $OS.Caption
$WindowsBuild = "$($OS.BuildNumber).$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)"
$WindowsFullName = "$WindowsCaption, Version $WindowsVersion, Build $WindowsBuild"

# --- CPU ---
$CPU = Get-CimInstance Win32_Processor | Select-Object -First 1
$CPUName = $CPU.Name
$CPUManufacturer = $CPU.Manufacturer
$CPUCores = $CPU.NumberOfCores
$CPULogicalProcessors = $CPU.NumberOfLogicalProcessors

# --- GPUs ---
$GPUs = Get-CimInstance Win32_VideoController | ForEach-Object {
    "$($_.AdapterCompatibility) $($_.Name) - VRAM: $(Convert-BytesToGB $_.AdapterRAM) GB"
}

# --- Drives ---
$Drives = @()

try {
    $PhysicalDisks = Get-PhysicalDisk | Where-Object {
        $_.BusType -ne "USB" -and $_.BusType -ne "File Backed Virtual" -and $_.BusType -ne "iSCSI"
    }

    foreach ($Disk in $PhysicalDisks) {
        $IsSSD = if ($Disk.MediaType -eq "SSD") { "Yes" } elseif ($Disk.MediaType -eq "HDD") { "No" } else { "Unknown" }
        $IsNVMe = if ($Disk.BusType -eq "NVMe") { "Yes" } else { "No" }

        $Drives += "$($Disk.Manufacturer) $($Disk.Model) - Capacity: $(Convert-BytesToGB $Disk.Size) GB - MediaType: $($Disk.MediaType) - SSD: $IsSSD - NVMe: $IsNVMe - Bus: $($Disk.BusType)"
    }
}
catch {
    $DiskDrives = Get-CimInstance Win32_DiskDrive | Where-Object {
        $_.InterfaceType -ne "USB" -and $_.InterfaceType -ne "Network"
    }

    foreach ($Disk in $DiskDrives) {
        $Drives += "$($Disk.Manufacturer) $($Disk.Model) - Capacity: $(Convert-BytesToGB $Disk.Size) GB - MediaType: Unknown - SSD: Unknown - NVMe: Unknown - Bus: $($Disk.InterfaceType)"
    }
}

# --- RAM ---
$RAMModules = Get-CimInstance Win32_PhysicalMemory
$TotalRAMGB = [math]::Round(($RAMModules | Measure-Object Capacity -Sum).Sum / 1GB, 2)
$RAMStickCount = ($RAMModules | Measure-Object).Count

$RAMDetails = $RAMModules | ForEach-Object {
    $TypeName = Get-MemoryTypeName -Type $_.SMBIOSMemoryType

    "$($_.Manufacturer) $($_.PartNumber.Trim()) - Capacity: $(Convert-BytesToGB $_.Capacity) GB - Type: $TypeName - Speed: $($_.Speed) MHz - Slot: $($_.DeviceLocator)"
}

# --- Network Adapters ---
$NetAdapters = Get-NetAdapter -Physical | Where-Object {
    $_.Status -in @("Up", "Disconnected") -and
    $_.HardwareInterface -eq $true
}

$NICDetails = foreach ($Nic in $NetAdapters) {
    $AdapterType = if ($Nic.NdisPhysicalMedium -match "Wireless|802\.11") {
        "Wi-Fi"
    }
    elseif ($Nic.Name -match "Wi-Fi|Wireless|WLAN") {
        "Wi-Fi"
    }
    else {
        "Ethernet"
    }

    "$AdapterType - $($Nic.InterfaceDescription) - Status: $($Nic.Status) - Link Speed: $(Get-NicSpeed -Speed $Nic.Speed) - MAC: $($Nic.MacAddress)"
}

# --- Output Object ---
$Inventory = [PSCustomObject]@{
    ComputerManufacturer     = $ComputerManufacturer
    ComputerModel            = $ComputerModel
    ComputerSerialNumber     = $BIOS.SerialNumber
    ComputerUUID             = $ComputerProduct.UUID
    ComputerType             = $ComputerType

    Windows                  = $WindowsFullName
    WindowsFamilyName        = $WindowsCaption
    WindowsVersion           = $WindowsVersion
    WindowsBuild             = $WindowsBuild

    CPUManufacturer          = $CPUManufacturer
    CPUModel                 = $CPUName
    CPUCores                 = $CPUCores
    CPULogicalProcessors     = $CPULogicalProcessors

    GPU                      = ($GPUs -join " | ")

    Drives                   = ($Drives -join " | ")

    TotalRAMGB               = $TotalRAMGB
    RAMStickCount            = $RAMStickCount
    RAMModules               = ($RAMDetails -join " | ")

    NetworkAdapters          = ($NICDetails -join " | ")
}

$SafeFileName = Clean-FileName "$ComputerManufacturer $ComputerModel.csv"
$OutFile = Join-Path $OutDir $SafeFileName

$Inventory | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8

Write-Output "Hardware inventory saved to: $OutFile"
