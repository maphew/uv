# _codex-unknown-model- on behalf of Matt Wilkie_

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "uv-cache-per-volume.ps1")

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [string]$Expected,

        [Parameter(Mandatory)]
        [string]$Actual,

        [Parameter(Mandatory)]
        [string]$Case
    )

    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($Expected, $Actual)) {
        throw "$Case failed: expected '$Expected', got '$Actual'."
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

Write-Output "All uv cache-per-volume tests passed."
