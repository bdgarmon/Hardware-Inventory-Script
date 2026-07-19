# Hardware Inventory Export - Audited v4
# Windows 11 / PowerShell 5.1+
# Saves CSV to C:\Temp\<Manufacturer> <Model>.csv
#
# v4 additions:
#   - GPU driver version
#   - GPU driver date
#   - Current display resolution
#   - Current refresh rate
#   - Active display connection type
#   - Audio devices
#   - CPU family/model/stepping metadata
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


function Normalize-Text {
    param([string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ($Value -replace '\s+', ' ').Trim()
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

    if ($null -eq $Bytes -or $Bytes -eq 0) {
        return $null
    }

    return [math]::Round(([double]$Bytes / 1000000000), 2)
}


function Convert-BytesToGiB {
    param([Nullable[UInt64]]$Bytes)

    if ($null -eq $Bytes -or $Bytes -eq 0) {
        return $null
    }

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


function Get-GpuDisplayName {
    param(
        [string]$AdapterCompatibility,
        [string]$Name
    )

    $CompatText = Normalize-Text $AdapterCompatibility
    $NameText = Normalize-Text $Name

    if ([string]::IsNullOrWhiteSpace($CompatText)) {
        return $NameText
    }

    if ([string]::IsNullOrWhiteSpace($NameText)) {
        return $CompatText
    }

    if ($NameText.StartsWith($CompatText,[System.StringComparison]::OrdinalIgnoreCase)) {
        return $NameText
    }

    return "$CompatText $NameText"
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
        return 800 + [math]::Min($a.Length,$b.Length)
    }

    $aTokens = @($a.Split(' ') | Where-Object {$_.Length -ge 2})
    $bTokens = @($b.Split(' ') | Where-Object {$_.Length -ge 2})

    if ($aTokens.Count -eq 0 -or $bTokens.Count -eq 0) {
        return 0
    }

    $common = @(
        $aTokens |
        Where-Object {$bTokens -contains $_} |
        Select-Object -Unique
    )

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
                return [BitConverter]::ToUInt64($Value,0)
            }

            if ($Value.Length -ge 4) {
                return [UInt64][BitConverter]::ToUInt32($Value,0)
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

        $Lines = & $NvidiaSmi `
            --query-gpu=name,memory.total `
            --format=csv,noheader,nounits `
            2>$null


        foreach ($Line in $Lines) {

            if ([string]::IsNullOrWhiteSpace($Line)) {
                continue
            }


            $Parts = $Line -split ',',2


            if ($Parts.Count -ne 2) {
                continue
            }


            $Name = $Parts[0].Trim()

            $MemoryMiB = 0.0


            if (
                [double]::TryParse(
                    $Parts[1].Trim(),
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$MemoryMiB
                )
            ) {

                $Results += [PSCustomObject]@{
                    Name        = $Name
                    MemoryBytes = Convert-MiBToBytes $MemoryMiB
                    Source      = "NVIDIA-SMI"
                }

            }

        }

    }
    catch {
        # Continue to fallback methods
    }


    return $Results
}


function Get-RegistryGpuMemory {

    $Results = @()

    $Seen = @{}

    $DisplayClassGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'

    $ClassPath =
        "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$DisplayClassGuid"


    if (Test-Path $ClassPath) {

        foreach ($Key in Get-ChildItem $ClassPath -ErrorAction SilentlyContinue) {

            $Props = Get-ItemProperty $Key.PSPath -ErrorAction SilentlyContinue

            $Bytes =
                Convert-RegistryMemoryValueToUInt64 `
                $Props.'HardwareInformation.qwMemorySize'


            if ($Bytes -and $Bytes -gt 0) {

                $Name = $Props.DriverDesc

                if (-not $Name) {
                    $Name = $Props.'HardwareInformation.AdapterString'
                }


                $Identity =
                    "$(Normalize-GpuName $Name)|$Bytes"


                if (-not $Seen.ContainsKey($Identity)) {

                    $Seen[$Identity]=$true


                    $Results += [PSCustomObject]@{
                        Name        = [string]$Name
                        MemoryBytes = [UInt64]$Bytes
                        Source      = "Driver Registry (64-bit)"
                    }

                }

            }

        }

    }


    return $Results
}
function Select-BestGpuMemoryMatch {

    param(
        [Parameter(Mandatory=$true)]$VideoController,
        [array]$Candidates
    )


    $Best = $null
    $BestScore = 0


    foreach ($Candidate in $Candidates) {

        $Score =
            Get-NameMatchScore `
            -Left $VideoController.Name `
            -Right $Candidate.Name


        if ($Score -gt $BestScore) {

            $BestScore = $Score
            $Best = $Candidate

        }

    }


    if ($BestScore -ge 40) {

        return $Best

    }


    return $null
}



function Convert-CimDateTimeToIsoDate {

    param([object]$Value)


    if ($null -eq $Value -or
        [string]::IsNullOrWhiteSpace([string]$Value)) {

        return ""

    }


    try {

        if ($Value -is [datetime]) {

            return $Value.ToString("yyyy-MM-dd")

        }


        return (
            [System.Management.ManagementDateTimeConverter]::ToDateTime(
                [string]$Value
            )
        ).ToString("yyyy-MM-dd")

    }
    catch {

        return Normalize-Text ([string]$Value)

    }

}



function Get-AccurateGpuInventory {

    $VideoControllers =
        @(Get-CimInstance Win32_VideoController)


    $NvidiaCandidates =
        @(Get-NvidiaGpuMemory)


    $RegistryCandidates =
        @(Get-RegistryGpuMemory)


    $Results = @()


    foreach ($Controller in $VideoControllers) {


        $MemoryBytes = $null
        $MemorySource = $null
        $Match = $null



        if ($Controller.Name -match 'NVIDIA') {

            $Match =
                Select-BestGpuMemoryMatch `
                -VideoController $Controller `
                -Candidates $NvidiaCandidates

        }



        if ($Match) {

            $MemoryBytes = [UInt64]$Match.MemoryBytes
            $MemorySource = $Match.Source

        }
        else {


            $Match =
                Select-BestGpuMemoryMatch `
                -VideoController $Controller `
                -Candidates $RegistryCandidates



            if ($Match) {

                $MemoryBytes = [UInt64]$Match.MemoryBytes
                $MemorySource = $Match.Source

            }

        }



        if (-not $MemoryBytes -and $Controller.AdapterRAM) {

            $MemoryBytes = [UInt64]$Controller.AdapterRAM

            $MemorySource =
                "Win32_VideoController.AdapterRAM fallback; may be capped near 4GB"

        }



        $MemoryMiB =
            if ($MemoryBytes) {
                [math]::Round(
                    ([double]$MemoryBytes / 1MB),
                    0
                )
            }
            else {
                $null
            }



        $MemoryGiB =
            if ($MemoryBytes) {
                [math]::Round(
                    ([double]$MemoryBytes / 1GB),
                    2
                )
            }
            else {
                $null
            }



        $MemoryText =
            if ($MemoryGiB) {
                "$MemoryGiB GiB"
            }
            else {
                "Unknown / Not Reported"
            }



        $MemoryLabel =
            if ($MemorySource -eq "NVIDIA-SMI") {
                "Dedicated VRAM"
            }
            else {
                "Dedicated/Preallocated Adapter Memory"
            }



        $Results += [PSCustomObject]@{

            AdapterCompatibility =
                $Controller.AdapterCompatibility

            Name =
                $Controller.Name

            DisplayName =
                Get-GpuDisplayName `
                -AdapterCompatibility $Controller.AdapterCompatibility `
                -Name $Controller.Name

            PNPDeviceID =
                $Controller.PNPDeviceID


            DriverVersion =
                Normalize-Text $Controller.DriverVersion


            DriverDate =
                Convert-CimDateTimeToIsoDate `
                $Controller.DriverDate


            GPUMemoryBytes =
                $MemoryBytes


            GPUMemoryMiB =
                $MemoryMiB


            GPUMemoryGiB =
                $MemoryGiB


            GPUMemoryLabel =
                $MemoryLabel


            VRAMSource =
                $MemorySource


            DisplayText =
                "$(
                    Get-GpuDisplayName `
                    -AdapterCompatibility $Controller.AdapterCompatibility `
                    -Name $Controller.Name
                ) - $MemoryLabel : $MemoryText - Memory Source: $MemorySource - Driver Version: $($Controller.DriverVersion) - Driver Date: $(Convert-CimDateTimeToIsoDate $Controller.DriverDate)"

        }

    }


    return $Results

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

        default {
            "Other ($FormFactor)"
        }

    }

}




function Get-MemoryTypeName {

    param([int]$Type)


    switch ($Type) {

        20 { "DDR" }
        21 { "DDR2" }
        24 { "DDR3" }
        26 { "DDR4" }
        27 { "LPDDR" }
        30 { "LPDDR4" }
        34 { "DDR5" }
        35 { "LPDDR5" }

        default {
            "Unknown / Not Reported ($Type)"
        }

    }

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

            3  { return "Desktop" }
            4  { return "Desktop" }
            5  { return "Desktop" }
            6  { return "Desktop" }
            7  { return "Desktop" }

            35 { return "Mini PC" }
            36 { return "Stick PC" }

        }

    }


    return "Unknown"

}




function Get-NicSpeed {

    param([UInt64]$Speed)


    if ($null -eq $Speed -or $Speed -eq 0) {

        return "Unknown / Not Connected"

    }


    if ($Speed -ge 1000000000) {

        return (
            "{0:0.##} Gbps" -f
            ($Speed / 1000000000.0)
        )

    }


    if ($Speed -ge 1000000) {

        return (
            "{0:0.##} Mbps" -f
            ($Speed / 1000000.0)
        )

    }


    return "$Speed bps"

}




function Test-PlaceholderIdentifier {

    param([string]$Value)


    if ([string]::IsNullOrWhiteSpace($Value)) {

        return $true

    }


    $v =
        ($Value -replace '[^A-Fa-f0-9]','')
        .ToUpperInvariant()


    if ($v -and
        ($v -match '^0+$' -or $v -match '^F+$')) {

        return $true

    }


    return (
        $Value -match
        'To Be Filled|Default String|System Serial|Unknown|None'
    )

}
function Get-CpuFamilyModelStepping {

    param($Processor)


    $Description =
        Normalize-Text $Processor.Description


    if ($Description -match
        'Family\s+(\d+)\s+Model\s+(\d+)\s+Stepping\s+(\d+)') {

        return (
            "Family $($Matches[1]) " +
            "Model $($Matches[2]) " +
            "Stepping $($Matches[3])"
        )

    }


    return $Description

}




function Get-VideoOutputTechnologyName {

    param([Nullable[Int32]]$Code)


    switch ([int]$Code) {

        -2 { "Uninitialized" }
        -1 { "Other" }
         0 { "HD15 / VGA" }
         4 { "DVI" }
         5 { "HDMI" }
         6 { "Internal Laptop Panel" }
        10 { "DisplayPort" }
        11 { "Embedded DisplayPort" }
        15 { "Miracast" }

        default {
            "Unknown / Not Reported"
        }

    }

}




function Get-DisplayInventory {

    $Results = @()


    try {

        $Controllers =
            @(Get-CimInstance Win32_VideoController)


        foreach ($Controller in $Controllers) {


            if (
                $Controller.CurrentHorizontalResolution -or
                $Controller.CurrentVerticalResolution -or
                $Controller.CurrentRefreshRate
            ) {


                $Resolution =
                    if (
                        $Controller.CurrentHorizontalResolution -and
                        $Controller.CurrentVerticalResolution
                    ) {

                        "$($Controller.CurrentHorizontalResolution)x$($Controller.CurrentVerticalResolution)"

                    }
                    else {

                        "Unknown / Not Reported"

                    }



                $Refresh =
                    if ($Controller.CurrentRefreshRate) {

                        "$($Controller.CurrentRefreshRate) Hz"

                    }
                    else {

                        "Unknown / Not Reported"

                    }



                $Results += [PSCustomObject]@{

                    DisplayName =
                        Normalize-Text $Controller.Name

                    Resolution =
                        $Resolution

                    RefreshRate =
                        $Refresh

                    Connection =
                        "Unknown / Not Reported"

                    Source =
                        "Win32_VideoController"

                }

            }

        }

    }
    catch {

        Add-InventoryWarning `
            "Display inventory failed: $($_.Exception.Message)"

    }



    try {

        $Connections =
            @(Get-CimInstance `
                -Namespace root\wmi `
                -ClassName WmiMonitorConnectionParams)


        foreach ($Connection in $Connections) {


            $Results += [PSCustomObject]@{

                DisplayName =
                    "Connected Display"

                Resolution =
                    "Unknown / Not Reported"

                RefreshRate =
                    "Unknown / Not Reported"

                Connection =
                    Get-VideoOutputTechnologyName `
                    $Connection.VideoOutputTechnology

                Source =
                    "WmiMonitorConnectionParams"

            }

        }

    }
    catch {

        Add-InventoryWarning `
            "Display connection inventory failed: $($_.Exception.Message)"

    }


    return $Results

}




function Get-AudioDeviceInventory {

    try {

        return @(
            Get-CimInstance Win32_SoundDevice |
            ForEach-Object {

                "$(Normalize-Text $_.Manufacturer) $(Normalize-Text $_.Name) - Status: $($_.Status)"

            }
        )

    }
    catch {

        Add-InventoryWarning `
            "Audio inventory failed: $($_.Exception.Message)"

        return @()

    }

}




# -----------------------------
# COMPUTER INFORMATION
# -----------------------------

$ComputerSystem =
    Get-CimInstance Win32_ComputerSystem

$ComputerProduct =
    Get-CimInstance Win32_ComputerSystemProduct

$BIOS =
    Get-CimInstance Win32_BIOS

$Enclosure =
    Get-CimInstance Win32_SystemEnclosure

$OS =
    Get-CimInstance Win32_OperatingSystem



$ComputerManufacturer =
    Normalize-Text $ComputerSystem.Manufacturer


$ComputerModel =
    Normalize-Text $ComputerSystem.Model


$ComputerType =
    Get-ChassisType $Enclosure.ChassisTypes



$WindowsVersion =
    Get-WindowsDisplayVersion


$WindowsBuild =
    "$($OS.BuildNumber).$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)"



$WindowsFullName =
    "$($OS.Caption), Version $WindowsVersion, Build $WindowsBuild"





# -----------------------------
# CPU
# -----------------------------

$CPUObjects =
    @(Get-CimInstance Win32_Processor)


$CPUCount =
    $CPUObjects.Count


$CPUManufacturer =
    (
        $CPUObjects |
        Select-Object -ExpandProperty Manufacturer -Unique
    ) -join " | "


$CPUModel =
    (
        $CPUObjects |
        Select-Object -ExpandProperty Name -Unique
    ) -join " | "


$CPUCores =
    [int](($CPUObjects |
    Measure-Object NumberOfCores -Sum).Sum)


$CPULogicalProcessors =
    [int](($CPUObjects |
    Measure-Object NumberOfLogicalProcessors -Sum).Sum)


$CPUMaxClockMHz =
    [int](($CPUObjects |
    Measure-Object MaxClockSpeed -Maximum).Maximum)


$CPUDescription =
    (
        $CPUObjects |
        ForEach-Object {
            Normalize-Text $_.Description
        }
    ) -join " | "


$CPUFamilyModelStepping =
    (
        $CPUObjects |
        ForEach-Object {
            Get-CpuFamilyModelStepping $_
        }
    ) -join " | "





# -----------------------------
# GPU
# -----------------------------

$GpuInventory =
    @(Get-AccurateGpuInventory)


$GPUs =
    $GpuInventory.DisplayText -join " | "


$GPUDriverVersions =
    (
        $GpuInventory |
        ForEach-Object {
            $_.DriverVersion
        }
    ) -join " | "


$GPUDriverDates =
    (
        $GpuInventory |
        ForEach-Object {
            $_.DriverDate
        }
    ) -join " | "


$GPUMemoryGiB =
    (
        $GpuInventory |
        ForEach-Object {
            $_.GPUMemoryGiB
        }
    ) -join " | "


$GPUMemorySources =
    (
        $GpuInventory |
        ForEach-Object {
            $_.VRAMSource
        }
    ) -join " | "





# -----------------------------
# DISPLAY / AUDIO
# -----------------------------

$DisplayInventory =
    @(Get-DisplayInventory)


$DisplayDetails =
    (
        $DisplayInventory |
        ForEach-Object {

            "$($_.DisplayName) - Resolution: $($_.Resolution) - Refresh: $($_.RefreshRate) - Connection: $($_.Connection)"

        }
    ) -join " | "


$CurrentDisplayResolutions =
    (
        $DisplayInventory.Resolution |
        Select-Object -Unique
    ) -join " | "


$CurrentDisplayRefreshRates =
    (
        $DisplayInventory.RefreshRate |
        Select-Object -Unique
    ) -join " | "


$ActiveDisplayConnections =
    (
        $DisplayInventory.Connection |
        Select-Object -Unique
    ) -join " | "


$AudioDevices =
    (
        Get-AudioDeviceInventory
    ) -join " | "





# -----------------------------
# EXPORT OBJECT
# -----------------------------

$Inventory =
[PSCustomObject]@{

    ComputerManufacturer =
        $ComputerManufacturer

    ComputerModel =
        $ComputerModel

    ComputerSerialNumber =
        $BIOS.SerialNumber

    ComputerUUID =
        $ComputerProduct.UUID

    ComputerType =
        $ComputerType



    Windows =
        $WindowsFullName


    CPUManufacturer =
        $CPUManufacturer

    CPUModel =
        $CPUModel

    CPUPhysicalPackageCount =
        $CPUCount

    CPUCores =
        $CPUCores

    CPULogicalProcessors =
        $CPULogicalProcessors

    CPUMaxClockMHz =
        $CPUMaxClockMHz

    CPUDescription =
        $CPUDescription

    CPUFamilyModelStepping =
        $CPUFamilyModelStepping



    GPU =
        $GPUs

    GPUDriverVersions =
        $GPUDriverVersions

    GPUDriverDates =
        $GPUDriverDates

    GPUMemoryGiB =
        $GPUMemoryGiB

    GPUMemorySources =
        $GPUMemorySources



    DisplayDetails =
        $DisplayDetails

    CurrentDisplayResolutions =
        $CurrentDisplayResolutions

    CurrentDisplayRefreshRates =
        $CurrentDisplayRefreshRates

    ActiveDisplayConnections =
        $ActiveDisplayConnections



    AudioDevices =
        $AudioDevices



    Drives =
        ($Drives -join " | ")


    TotalRAMGiB =
        $TotalRAMGB


    RAMModules =
        ($RAMDetails -join " | ")


    NetworkAdapters =
        ($NICDetails -join " | ")


    InventoryWarnings =
        ($Warnings -join " | ")

}



$SafeFileName =
    Clean-FileName "$ComputerManufacturer $ComputerModel.csv"


$OutFile =
    Join-Path $OutDir $SafeFileName


$Inventory |
Export-Csv `
-Path $OutFile `
-NoTypeInformation `
-Encoding UTF8



Write-Output `
"Hardware inventory saved to: $OutFile"


$GpuInventory |
Select-Object `
DisplayName,
DriverVersion,
DriverDate,
GPUMemoryGiB,
VRAMSource |
Format-Table -AutoSize
