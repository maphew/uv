# _codex-unknown-model- on behalf of Matt Wilkie_

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "uv-cache-per-volume.ps1")

function Assert-Equal {
    param(
        [AllowNull()]
        [string]$Expected,

        [AllowNull()]
        [string]$Actual,

        [Parameter(Mandatory)]
        [string]$Case
    )

    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($Expected, $Actual)) {
        throw "$Case failed: expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Case
    )

    if (-not $Condition) {
        throw "$Case failed."
    }
}

$volumeResolver = {
    param($Path)

    if ($Path.StartsWith("D:\projects")) {
        return [pscustomobject]@{ Root = "D:\"; DriveType = [System.IO.DriveType]::Fixed }
    }
    if ($Path.StartsWith("C:\mount\data")) {
        return [pscustomobject]@{ Root = "C:\mount\data\"; DriveType = [System.IO.DriveType]::Fixed }
    }
    if ($Path.StartsWith("Z:\")) {
        return [pscustomobject]@{ Root = "Z:\"; DriveType = [System.IO.DriveType]::Network }
    }
    if ($Path.StartsWith("E:\")) {
        return [pscustomobject]@{ Root = "E:\"; DriveType = [System.IO.DriveType]::Removable }
    }
    if ($Path.StartsWith("\\server\share")) {
        return [pscustomobject]@{ Root = "\\server\share\"; DriveType = [System.IO.DriveType]::Network }
    }
    return [pscustomobject]@{ Root = "C:\"; DriveType = [System.IO.DriveType]::Fixed }
}

$defaultCacheDirectory = "C:\Users\test\AppData\Local\uv\cache"
$cases = @(
    @{
        Name     = "default volume"
        Path     = "C:\projects\example"
        Expected = $defaultCacheDirectory
    },
    @{
        Name     = "secondary fixed volume"
        Path     = "D:\projects\example"
        Expected = "D:\.local\uv\cache"
    },
    @{
        Name     = "fixed mounted volume"
        Path     = "C:\mount\data\example"
        Expected = "C:\mount\data\.local\uv\cache"
    },
    @{
        Name     = "mapped network drive"
        Path     = "Z:\projects\example"
        Expected = $defaultCacheDirectory
    },
    @{
        Name     = "UNC share"
        Path     = "\\server\share\projects\example"
        Expected = $defaultCacheDirectory
    },
    @{
        Name     = "removable drive"
        Path     = "E:\projects\example"
        Expected = $defaultCacheDirectory
    }
)

foreach ($case in $cases) {
    $actual = Get-UvCacheDirectoryForPath `
        -Path $case.Path `
        -DefaultCacheDirectory $defaultCacheDirectory `
        -VolumeResolver $volumeResolver
    Assert-Equal -Expected $case.Expected -Actual $actual -Case $case.Name
}

$toolDirectory = Get-UvDirectoryForPath `
    -Path "D:\projects\example" `
    -DefaultDirectory "C:\Users\test\AppData\Roaming\uv\tools" `
    -RelativePath ".local\uv\tools\test" `
    -VolumeResolver $volumeResolver
Assert-Equal `
    -Expected "D:\.local\uv\tools\test" `
    -Actual $toolDirectory `
    -Case "secondary fixed volume tool directory"

$rootedPathRejected = $false
try {
    Get-UvCacheDirectoryForPath `
        -Path "D:\projects\example" `
        -DefaultCacheDirectory $defaultCacheDirectory `
        -CacheRelativePath "D:\invalid" `
        -VolumeResolver $volumeResolver
}
catch {
    $rootedPathRejected = $true
}

if (-not $rootedPathRejected) {
    throw "rooted cache path validation failed."
}

$testState = @{
    CacheDirectory = [Environment]::GetEnvironmentVariable("UV_CACHE_DIR", "Process")
    CacheWasSet = Test-Path Env:UV_CACHE_DIR
    ToolDirectory = [Environment]::GetEnvironmentVariable("UV_TOOL_DIR", "Process")
    ToolWasSet = Test-Path Env:UV_TOOL_DIR
    ToolBinDirectory = [Environment]::GetEnvironmentVariable("UV_TOOL_BIN_DIR", "Process")
    ToolBinWasSet = Test-Path Env:UV_TOOL_BIN_DIR
    Path = $env:PATH
}
$hookEnabled = $false

try {
    $env:UV_CACHE_DIR = "before-cache"
    $env:UV_TOOL_DIR = "before-tools"
    $env:UV_TOOL_BIN_DIR = "before-bin"

    $currentVolume = Resolve-UvCacheVolume -Path (Get-Location).Path
    Assert-True `
        -Condition ($null -ne $currentVolume -and
            $currentVolume.DriveType -eq [System.IO.DriveType]::Fixed) `
        -Case "test working directory is on a fixed volume"

    $uniqueSuffix = [guid]::NewGuid().ToString("N")
    $defaultCache = Join-Path $currentVolume.Root ".local\uv\test-$uniqueSuffix\cache"
    $defaultTools = Join-Path $currentVolume.Root ".local\uv\test-$uniqueSuffix\tools"
    $defaultBin = Join-Path $currentVolume.Root ".local\uv\test-$uniqueSuffix\bin"

    Enable-UvCachePerVolume `
        -DefaultCacheDirectory $defaultCache `
        -ManageTools `
        -DefaultToolDirectory $defaultTools `
        -DefaultToolBinDirectory $defaultBin
    $hookEnabled = $true

    $selected = Set-UvCacheForCurrentVolume -PassThru
    Assert-Equal -Expected $defaultCache -Actual $selected.CacheDirectory -Case "managed cache selection"
    Assert-Equal -Expected $defaultTools -Actual $selected.ToolDirectory -Case "managed tool selection"
    Assert-Equal -Expected $defaultBin -Actual $selected.ToolBinDirectory -Case "managed tool bin selection"
    Assert-Equal -Expected $defaultTools -Actual $env:UV_TOOL_DIR -Case "UV_TOOL_DIR update"
    Assert-Equal -Expected $defaultBin -Actual $env:UV_TOOL_BIN_DIR -Case "UV_TOOL_BIN_DIR update"

    $pathEntries = @($env:PATH -split [regex]::Escape([string][System.IO.Path]::PathSeparator))
    Assert-Equal -Expected $defaultBin -Actual $pathEntries[0] -Case "tool bin PATH prefix"

    $alternateBin = Join-Path $currentVolume.Root ".local\uv\test-$uniqueSuffix\alternate-bin"
    Set-UvManagedToolBinPath -ToolBinDirectory $alternateBin
    $pathEntries = @($env:PATH -split [regex]::Escape([string][System.IO.Path]::PathSeparator))
    Assert-Equal -Expected $alternateBin -Actual $pathEntries[0] -Case "switched tool bin PATH prefix"
    $oldBinEntries = @($pathEntries | Where-Object {
            [System.StringComparer]::OrdinalIgnoreCase.Equals(
                $_.TrimEnd('\', '/'),
                $defaultBin.TrimEnd('\', '/')
            )
        })
    Assert-True -Condition ($oldBinEntries.Count -eq 0) -Case "previous tool bin PATH removal"

    Set-UvManagedToolBinPath -ToolBinDirectory $defaultBin
    Disable-UvCachePerVolume
    $hookEnabled = $false

    Assert-Equal -Expected "before-cache" -Actual $env:UV_CACHE_DIR -Case "UV_CACHE_DIR restore"
    Assert-Equal -Expected "before-tools" -Actual $env:UV_TOOL_DIR -Case "UV_TOOL_DIR restore"
    Assert-Equal -Expected "before-bin" -Actual $env:UV_TOOL_BIN_DIR -Case "UV_TOOL_BIN_DIR restore"
    Assert-Equal -Expected $testState.Path -Actual $env:PATH -Case "PATH restore"
}
finally {
    if ($hookEnabled) {
        Disable-UvCachePerVolume
    }

    if ($testState.CacheWasSet) {
        $env:UV_CACHE_DIR = $testState.CacheDirectory
    }
    else {
        Remove-Item Env:UV_CACHE_DIR -ErrorAction SilentlyContinue
    }
    if ($testState.ToolWasSet) {
        $env:UV_TOOL_DIR = $testState.ToolDirectory
    }
    else {
        Remove-Item Env:UV_TOOL_DIR -ErrorAction SilentlyContinue
    }
    if ($testState.ToolBinWasSet) {
        $env:UV_TOOL_BIN_DIR = $testState.ToolBinDirectory
    }
    else {
        Remove-Item Env:UV_TOOL_BIN_DIR -ErrorAction SilentlyContinue
    }
    $env:PATH = $testState.Path
}

Write-Output "All uv cache-per-volume tests passed."
