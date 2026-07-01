# Hardware Inventory Export
# Windows 11 / PowerShell 5.1+
# Saves CSV to C:\Temp\<Manufacturer> <Model>.csv
#
# GPU memory collection order:
#   1. NVIDIA-SMI for NVIDIA adapters when available
#   2. 64-bit display-driver registry value HardwareInformation.qwMemorySize
#   3. Win32_VideoController.AdapterRAM only as a last-resort fallback
#
# The fallback is explicitly marked because AdapterRAM is UInt32 and cannot
# accurately represent dedicated VRAM above approximately 4 GB.

$ErrorActionPreference = "Stop"
$Warnings = New-Object System.Collections.Generic.List[string]

function Add-InventoryWarning {
    param([string]$Message)
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $Warnings.Add($Message) | Out-Null
        Write-Warning $Message
    }
}

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
    param([Nullable[UInt64]]$Bytes)

    if ($null -eq $Bytes -or $Bytes -eq 0) {
        return $null
    }

    return [math]::Round(([double]$Bytes / 1GB), 2)
}

function Convert-BytesToDecimalGB {
    param([Nullable[UInt64]]$Bytes)
    if ($null -eq $Bytes -or $Bytes -eq 0) { return $null }
    return [math]::Round(([double]$Bytes / 1000000000), 2)
}

function Convert-BytesToGiB {
    param([Nullable[UInt64]]$Bytes)
    if ($null -eq $Bytes -or $Bytes -eq 0) { return $null }
    return [math]::Round(([double]$Bytes / 1GB), 2)
}

function Convert-MiBToBytes {
    param([double]$MiB)

    if ($MiB -le 0) {
        return $null
    }

    return [UInt64]([math]::Round($MiB * 1MB))
}

function Normalize-GpuName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    $normalized = $Name.ToLowerInvariant()
    $normalized = $normalized -replace '\(r\)|\(tm\)', ''
    $normalized = $normalized -replace '\bnvidia\b|\badvanced micro devices,? inc\.?\b|\bamd\b|\bintel corporation\b', ''
    $normalized = $normalized -replace '\bmicrosoft basic display adapter\b', ''
    $normalized = $normalized -replace '[^a-z0-9]+', ' '
    return ($normalized -replace '\s+', ' ').Trim()
}

function Get-NameMatchScore {
    param(
        [string]$Left,
        [string]$Right
    )

    $a = Normalize-GpuName $Left
    $b = Normalize-GpuName $Right

    if (-not $a -or -not $b) {
        return 0
    }

    if ($a -eq $b) {
        return 1000
    }

    if ($a.Contains($b) -or $b.Contains($a)) {
        return 800 + [math]::Min($a.Length, $b.Length)
    }

    $aTokens = @($a.Split(' ') | Where-Object { $_.Length -ge 2 })
    $bTokens = @($b.Split(' ') | Where-Object { $_.Length -ge 2 })

    if ($aTokens.Count -eq 0 -or $bTokens.Count -eq 0) {
        return 0
    }

    $common = @($aTokens | Where-Object { $bTokens -contains $_ } | Select-Object -Unique)
    return $common.Count * 20
}

function Convert-RegistryMemoryValueToUInt64 {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    try {
        if ($Value -is [byte[]]) {
            if ($Value.Length -ge 8) {
                return [BitConverter]::ToUInt64($Value, 0)
            }
            if ($Value.Length -ge 4) {
                return [UInt64][BitConverter]::ToUInt32($Value, 0)
            }
        }

        return [UInt64]$Value
    }
    catch {
        return $null
    }
}

function Get-NvidiaSmiPath {
    $Candidates = @(
        (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'),
        (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe')
    )

    foreach ($Candidate in $Candidates) {
        if ($Candidate -and (Test-Path $Candidate)) {
            return $Candidate
        }
    }

    $Command = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($Command) {
        return $Command.Source
    }

    return $null
}

function Get-NvidiaGpuMemory {
    $Results = @()
    $NvidiaSmi = Get-NvidiaSmiPath

    if (-not $NvidiaSmi) {
        return $Results
    }

    try {
        $Lines = & $NvidiaSmi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null

        foreach ($Line in $Lines) {
            if ([string]::IsNullOrWhiteSpace($Line)) {
                continue
            }

            $Parts = $Line -split ',', 2
            if ($Parts.Count -ne 2) {
                continue
            }

            $Name = $Parts[0].Trim()
            $MemoryMiB = 0.0

            if ([double]::TryParse(
                $Parts[1].Trim(),
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$MemoryMiB
            )) {
                $Results += [PSCustomObject]@{
                    Name        = $Name
                    MemoryBytes = Convert-MiBToBytes $MemoryMiB
                    Source      = 'NVIDIA-SMI'
                }
            }
        }
    }
    catch {
        # Continue to the registry and WMI fallbacks.
    }

    return $Results
}

function Get-RegistryGpuMemory {
    $Results = @()
    $Seen = @{}
    $DisplayClassGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'
    $ClassPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$DisplayClassGuid"

    if (Test-Path $ClassPath) {
        foreach ($Key in Get-ChildItem -Path $ClassPath -ErrorAction SilentlyContinue) {
            $Props = Get-ItemProperty -Path $Key.PSPath -ErrorAction SilentlyContinue
            $Bytes = Convert-RegistryMemoryValueToUInt64 $Props.'HardwareInformation.qwMemorySize'

            if ($Bytes -and $Bytes -gt 0) {
                $Name = $Props.DriverDesc
                if (-not $Name) {
                    $Name = $Props.'HardwareInformation.AdapterString'
                }

                $Identity = "$(Normalize-GpuName $Name)|$Bytes"
                if (-not $Seen.ContainsKey($Identity)) {
                    $Seen[$Identity] = $true
                    $Results += [PSCustomObject]@{
                        Name        = [string]$Name
                        MemoryBytes = [UInt64]$Bytes
                        Source      = 'Driver Registry (64-bit)'
                    }
                }
            }
        }
    }

    # Some display drivers expose the same 64-bit value under Control\Video.
    $VideoPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Video'
    if (Test-Path $VideoPath) {
        foreach ($AdapterKey in Get-ChildItem -Path $VideoPath -ErrorAction SilentlyContinue) {
            foreach ($SubKey in Get-ChildItem -Path $AdapterKey.PSPath -ErrorAction SilentlyContinue) {
                $Props = Get-ItemProperty -Path $SubKey.PSPath -ErrorAction SilentlyContinue
                $Bytes = Convert-RegistryMemoryValueToUInt64 $Props.'HardwareInformation.qwMemorySize'

                if ($Bytes -and $Bytes -gt 0) {
                    $Name = $Props.DriverDesc
                    if (-not $Name) {
                        $Name = $Props.'HardwareInformation.AdapterString'
                    }

                    $Identity = "$(Normalize-GpuName $Name)|$Bytes"
                    if (-not $Seen.ContainsKey($Identity)) {
                        $Seen[$Identity] = $true
                        $Results += [PSCustomObject]@{
                            Name        = [string]$Name
                            MemoryBytes = [UInt64]$Bytes
                            Source      = 'Driver Registry (64-bit)'
                        }
                    }
                }
            }
        }
    }

    return $Results
}

function Select-BestGpuMemoryMatch {
    param(
        [Parameter(Mandatory = $true)]$VideoController,
        [array]$Candidates
    )

    $Best = $null
    $BestScore = 0

    foreach ($Candidate in $Candidates) {
        $Score = Get-NameMatchScore -Left $VideoController.Name -Right $Candidate.Name

        if ($Score -gt $BestScore) {
            $BestScore = $Score
            $Best = $Candidate
        }
    }

    # Require at least two useful tokens or a substring/exact match.
    if ($BestScore -ge 40) {
        return $Best
    }

    return $null
}

function Get-AccurateGpuInventory {
    $VideoControllers = @(Get-CimInstance Win32_VideoController)
    $NvidiaCandidates = @(Get-NvidiaGpuMemory)
    $RegistryCandidates = @(Get-RegistryGpuMemory)
    $Results = @()

    foreach ($Controller in $VideoControllers) {
        $MemoryBytes = $null
        $MemorySource = $null
        $Match = $null

        if ($Controller.Name -match 'NVIDIA') {
            $Match = Select-BestGpuMemoryMatch -VideoController $Controller -Candidates $NvidiaCandidates
        }

        if ($Match) {
            $MemoryBytes = [UInt64]$Match.MemoryBytes
            $MemorySource = $Match.Source
        }
        else {
            $Match = Select-BestGpuMemoryMatch -VideoController $Controller -Candidates $RegistryCandidates

            if ($Match) {
                $MemoryBytes = [UInt64]$Match.MemoryBytes
                $MemorySource = $Match.Source
            }
        }

        if (-not $MemoryBytes -and $Controller.AdapterRAM) {
            $MemoryBytes = [UInt64]$Controller.AdapterRAM
            $MemorySource = 'Win32_VideoController.AdapterRAM fallback; may be capped near 4 GB'
        }

        $MemoryGB = Convert-BytesToGB $MemoryBytes
        $MemoryText = if ($MemoryGB) { "$MemoryGB GB" } else { 'Unknown / Not Reported' }

        $Results += [PSCustomObject]@{
            AdapterCompatibility = $Controller.AdapterCompatibility
            Name                 = $Controller.Name
            PNPDeviceID          = $Controller.PNPDeviceID
            DedicatedVRAMBytes   = $MemoryBytes
            DedicatedVRAMGB      = $MemoryGB
            VRAMSource           = $MemorySource
            DisplayText          = "$($Controller.AdapterCompatibility) $($Controller.Name) - Dedicated/Preallocated Adapter Memory: $MemoryText - Memory Source: $MemorySource"
        }
    }

    return $Results
}

function Get-ChassisType {
    param([int[]]$Types)

    foreach ($Type in $Types) {
        switch ($Type) {
            30 { return "Tablet" }
            31 { return "Convertible / 2-in-1" }
            32 { return "Detachable / 2-in-1" }
            8  { return "Laptop" }
            9  { return "Laptop" }
            10 { return "Laptop" }
            11 { return "Laptop" }
            12 { return "Laptop" }
            14 { return "Laptop" }
            18 { return "Laptop" }
            21 { return "Laptop" }
            3  { return "Desktop" }
            4  { return "Desktop" }
            5  { return "Desktop" }
            6  { return "Desktop" }
            7  { return "Desktop" }
            13 { return "Desktop" }
            15 { return "Desktop" }
            16 { return "Desktop" }
            35 { return "Mini PC" }
            36 { return "Stick PC" }
        }
    }
    return "Unknown"
}

function Get-MemoryFormFactorName {
    param([int]$FormFactor)
    switch ($FormFactor) {
        8  { "DIMM" }
        12 { "SODIMM" }
        14 { "SMD / Soldered" }
        21 { "BGA / Soldered" }
        22 { "FPBGA / Soldered" }
        23 { "LGA / Soldered" }
        0  { "Unknown" }
        default { "Other ($FormFactor)" }
    }
}

function Get-MemoryTypeName {
    param([int]$Type)
    switch ($Type) {
        20 { "DDR" }
        21 { "DDR2" }
        22 { "DDR2 FB-DIMM" }
        24 { "DDR3" }
        26 { "DDR4" }
        27 { "LPDDR" }
        28 { "LPDDR2" }
        29 { "LPDDR3" }
        30 { "LPDDR4" }
        34 { "DDR5" }
        35 { "LPDDR5" }
        default { "Unknown / Not Reported ($Type)" }
    }
}

function Get-WindowsDisplayVersion {
    $RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $Props = Get-ItemProperty -Path $RegPath

    if ($Props.DisplayVersion) { return $Props.DisplayVersion }
    if ($Props.ReleaseId) { return $Props.ReleaseId }
    return "Unknown"
}

function Get-NicSpeed {
    param([UInt64]$Speed)
    if ($null -eq $Speed -or $Speed -eq 0) { return "Unknown / Not Connected" }
    if ($Speed -ge 1000000000) { return ("{0:0.##} Gbps" -f ($Speed / 1000000000.0)) }
    if ($Speed -ge 1000000)    { return ("{0:0.##} Mbps" -f ($Speed / 1000000.0)) }
    if ($Speed -ge 1000)       { return ("{0:0.##} Kbps" -f ($Speed / 1000.0)) }
    return "$Speed bps"
}

function Test-PlaceholderIdentifier {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $v = ($Value -replace '[^A-Fa-f0-9]', '').ToUpperInvariant()
    if ($v -and ($v -match '^0+$' -or $v -match '^F+$')) { return $true }
    return $Value -match 'To Be Filled|Default String|System Serial|Unknown|None'
}

function Normalize-Text {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value -replace '\s+', ' ').Trim()
}

# --- Computer Info ---
$ComputerSystem = Get-CimInstance Win32_ComputerSystem
$ComputerProduct = Get-CimInstance Win32_ComputerSystemProduct
$BIOS = Get-CimInstance Win32_BIOS
$Enclosure = Get-CimInstance Win32_SystemEnclosure
$OS = Get-CimInstance Win32_OperatingSystem

$ComputerManufacturer = Normalize-Text $ComputerSystem.Manufacturer
$ComputerModel = Normalize-Text $ComputerSystem.Model
$ComputerType = Get-ChassisType -Types $Enclosure.ChassisTypes

$WindowsVersion = Get-WindowsDisplayVersion
$WindowsCaption = $OS.Caption
$WindowsBuild = "$($OS.BuildNumber).$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)"
$WindowsFullName = "$WindowsCaption, Version $WindowsVersion, Build $WindowsBuild"

# --- CPU ---
$CPUObjects = @(Get-CimInstance Win32_Processor)
$CPUCount = $CPUObjects.Count
$CPUManufacturer = (($CPUObjects | Select-Object -ExpandProperty Manufacturer -Unique) -join ' | ')
$CPUModels = @($CPUObjects | ForEach-Object { Normalize-Text $_.Name })
$CPUName = ($CPUModels | Group-Object | ForEach-Object {
    if ($_.Count -gt 1) { "$($_.Count)x $($_.Name)" } else { $_.Name }
}) -join ' | '
$CPUCores = [int](($CPUObjects | Measure-Object NumberOfCores -Sum).Sum)
$CPULogicalProcessors = [int](($CPUObjects | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
$CPUMaxClockMHz = [int](($CPUObjects | Measure-Object MaxClockSpeed -Maximum).Maximum)

# --- GPUs ---
$GpuInventory = @(Get-AccurateGpuInventory)
$GPUs = @($GpuInventory | ForEach-Object { $_.DisplayText })

if ($GpuInventory | Where-Object { $_.VRAMSource -like 'Win32_VideoController*' }) {
    Add-InventoryWarning 'At least one GPU used the 32-bit AdapterRAM fallback; VRAM may be truncated.'
}

# --- Drives ---
$Drives = @()
try {
    $DiskObjects = @(Get-Disk | Where-Object { $_.BusType -notin @('USB','iSCSI','File Backed Virtual') })
    $WmiDisks = @(Get-CimInstance Win32_DiskDrive)
    $PhysicalDisks = @(Get-PhysicalDisk)

    foreach ($Disk in ($DiskObjects | Sort-Object @{Expression={-not ($_.IsSystem -or $_.IsBoot)}}, Number)) {
        $Wmi = $WmiDisks | Where-Object { $_.Index -eq $Disk.Number } | Select-Object -First 1
        $Physical = $PhysicalDisks | Where-Object {
            ($_.DeviceId -as [string]) -eq ($Disk.Number -as [string]) -or
            (Normalize-Text $_.FriendlyName) -eq (Normalize-Text $Disk.FriendlyName) -or
            ($Wmi.SerialNumber -and $_.SerialNumber -and (Normalize-Text $_.SerialNumber) -eq (Normalize-Text $Wmi.SerialNumber))
        } | Select-Object -First 1

        $Model = if ($Wmi.Model) { Normalize-Text $Wmi.Model } else { Normalize-Text $Disk.FriendlyName }
        $Manufacturer = if ($Wmi.Manufacturer) { Normalize-Text $Wmi.Manufacturer } else { "" }
        $ReportedBus = [string]$Disk.BusType
        $PnpId = [string]$Wmi.PNPDeviceID

        $Interface = $ReportedBus
        $InterfaceConfidence = 'Reported by Get-Disk'
        if ($ReportedBus -eq 'RAID' -and (($PnpId -match 'NVME') -or ($Model -match '\bNVMe\b'))) {
            $Interface = 'NVMe behind RAID/VMD controller'
            $InterfaceConfidence = 'Inferred from PNP/model because controller masks the native bus'
        }

        $MediaType = if ($Physical -and [string]$Physical.MediaType -notin @('','Unspecified','0')) { [string]$Physical.MediaType } else { 'Unknown / Not Reported' }
        $MediaSource = if ($MediaType -ne 'Unknown / Not Reported') { 'Get-PhysicalDisk' } else { 'Not reliably reported by Windows' }
        if ($MediaType -eq 'Unknown / Not Reported' -and $Interface -match 'NVMe') {
            $MediaType = 'SSD'
            $MediaSource = 'NVMe interface implies solid-state media'
        }

        $IsSystemDisk = [bool]($Disk.IsSystem -or $Disk.IsBoot)
        $CapacityGB = Convert-BytesToDecimalGB $Disk.Size
        $CapacityGiB = Convert-BytesToGiB $Disk.Size
        $Firmware = if ($Physical.FirmwareVersion) { Normalize-Text $Physical.FirmwareVersion } else { '' }
        $Serial = if ($Wmi.SerialNumber) { Normalize-Text $Wmi.SerialNumber } elseif ($Disk.SerialNumber) { Normalize-Text $Disk.SerialNumber } else { '' }

        $Drives += "$Manufacturer $Model - Capacity: $CapacityGB GB decimal ($CapacityGiB GiB) - MediaType: $MediaType - MediaType Source: $MediaSource - Interface: $Interface - Interface Source: $InterfaceConfidence - Reported Bus: $ReportedBus - System Disk: $IsSystemDisk - Firmware: $Firmware - Serial: $Serial"
    }
}
catch {
    Add-InventoryWarning "Primary storage inventory failed: $($_.Exception.Message)"
    $DiskDrives = @(Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -notin @('USB','Network') })
    foreach ($Disk in $DiskDrives) {
        $Drives += "$(Normalize-Text $Disk.Manufacturer) $(Normalize-Text $Disk.Model) - Capacity: $(Convert-BytesToDecimalGB $Disk.Size) GB decimal ($(Convert-BytesToGiB $Disk.Size) GiB) - MediaType: Unknown / Not Reported - Interface: $($Disk.InterfaceType) - System Disk: Unknown - Serial: $(Normalize-Text $Disk.SerialNumber)"
    }
}

# --- RAM ---
$RAMModules = @(Get-CimInstance Win32_PhysicalMemory | Where-Object { $_.Capacity -gt 0 })
$TotalRAMGB = [math]::Round((($RAMModules | Measure-Object Capacity -Sum).Sum / 1GB), 2)
$RAMReportedDeviceCount = $RAMModules.Count
$RAMReplaceableModuleCount = @($RAMModules | Where-Object { $_.FormFactor -in @(8,12) }).Count
$RAMConfiguration = if ($RAMReplaceableModuleCount -gt 0) {
    "$RAMReplaceableModuleCount replaceable DIMM/SODIMM module(s); $RAMReportedDeviceCount SMBIOS memory device record(s)"
} else {
    "Onboard/soldered memory; $RAMReportedDeviceCount SMBIOS memory device record(s)"
}
$RAMDetails = $RAMModules | ForEach-Object {
    $TypeName = Get-MemoryTypeName -Type ([int]$_.SMBIOSMemoryType)
    $FormFactor = Get-MemoryFormFactorName -FormFactor ([int]$_.FormFactor)
    $ConfiguredSpeed = if ($_.ConfiguredClockSpeed -gt 0) { $_.ConfiguredClockSpeed } else { $_.Speed }
    $RatedSpeed = if ($_.Speed -gt 0) { $_.Speed } else { 'Unknown' }
    "$(Normalize-Text $_.Manufacturer) $(Normalize-Text $_.PartNumber) - Capacity: $(Convert-BytesToGiB $_.Capacity) GiB - Type: $TypeName - Form Factor: $FormFactor - Configured Speed: $ConfiguredSpeed MHz - Rated Speed: $RatedSpeed MHz - Slot: $(Normalize-Text $_.DeviceLocator) - Bank: $(Normalize-Text $_.BankLabel) - Replaceable Flag: $($_.Replaceable)"
}

# --- Network Adapters ---
$NetAdapters = @(Get-NetAdapter -Physical -IncludeHidden | Where-Object { $_.HardwareInterface -eq $true })
$NICDetails = foreach ($Nic in $NetAdapters) {
    $Medium = [string]$Nic.NdisPhysicalMedium
    $AdapterType = if ($Medium -match 'Wireless|802\.11|Native 802\.11' -or $Nic.Name -match 'Wi-Fi|Wireless|WLAN') { 'Wi-Fi' } else { 'Ethernet' }
    $CurrentLinkSpeed = Get-NicSpeed -Speed ([UInt64]$Nic.Speed)
    "$AdapterType - $(Normalize-Text $Nic.InterfaceDescription) - Status: $($Nic.Status) - Current Negotiated Link Speed: $CurrentLinkSpeed - MAC: $($Nic.MacAddress) - Interface GUID: $($Nic.InterfaceGuid)"
}

# --- Output Object ---
$Inventory = [PSCustomObject]@{
    ComputerManufacturer     = $ComputerManufacturer
    ComputerModel            = $ComputerModel
    ComputerSerialNumber     = if (Test-PlaceholderIdentifier $BIOS.SerialNumber) { "Unknown / Placeholder" } else { Normalize-Text $BIOS.SerialNumber }
    ComputerUUID             = if (Test-PlaceholderIdentifier $ComputerProduct.UUID) { "Unknown / Placeholder" } else { Normalize-Text $ComputerProduct.UUID }
    ComputerType             = $ComputerType

    Windows                  = $WindowsFullName
    WindowsFamilyName        = $WindowsCaption
    WindowsVersion           = $WindowsVersion
    WindowsBuild             = $WindowsBuild

    CPUManufacturer          = $CPUManufacturer
    CPUModel                 = $CPUName
    CPUPhysicalPackageCount  = $CPUCount
    CPUCores                 = $CPUCores
    CPULogicalProcessors     = $CPULogicalProcessors
    CPUMaxClockMHz           = $CPUMaxClockMHz

    GPU                      = ($GPUs -join " | ")

    Drives                   = ($Drives -join " | ")

    TotalRAMGiB              = $TotalRAMGB
    RAMConfiguration         = $RAMConfiguration
    RAMReportedDeviceCount   = $RAMReportedDeviceCount
    RAMReplaceableModuleCount = $RAMReplaceableModuleCount
    RAMModules               = ($RAMDetails -join " | ")

    NetworkAdapters          = ($NICDetails -join " | ")
    InventoryWarnings        = ($Warnings -join " | ")
}

$SafeFileName = Clean-FileName "$ComputerManufacturer $ComputerModel.csv"
$OutFile = Join-Path $OutDir $SafeFileName
$Inventory | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8

Write-Output "Hardware inventory saved to: $OutFile"

# Also show GPU detection details in the console for validation.
$GpuInventory | Select-Object Name, DedicatedVRAMGB, VRAMSource | Format-Table -AutoSize
