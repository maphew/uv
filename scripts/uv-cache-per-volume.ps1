# _codex-unknown-model- on behalf of Matt Wilkie_

if ($env:OS -ne "Windows_NT") {
    throw "uv-cache-per-volume.ps1 only supports Windows."
}

if (-not ("UvCachePerVolume.NativeMethods" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace UvCachePerVolume
{
    public static class NativeMethods
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetVolumePathName(
            string fileName,
            StringBuilder volumePathName,
            uint bufferLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern uint GetDriveType(string rootPathName);
    }
}
"@
}

if (-not (Get-Variable -Name UvCachePerVolumeState -Scope Script -ErrorAction SilentlyContinue)) {
    $script:UvCachePerVolumeState = $null
}

function Resolve-UvCacheVolume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)

    if ($pathRoot.StartsWith("\\")) {
        return [pscustomobject]@{
            Root      = $pathRoot
            DriveType = [System.IO.DriveType]::Network
        }
    }

    $volumePath = [System.Text.StringBuilder]::new(261)
    if ([UvCachePerVolume.NativeMethods]::GetVolumePathName(
            $fullPath,
            $volumePath,
            [uint32]$volumePath.Capacity
        )) {
        $volumeRoot = $volumePath.ToString()
        return [pscustomobject]@{
            Root      = $volumeRoot
            DriveType = [System.IO.DriveType][UvCachePerVolume.NativeMethods]::GetDriveType($volumeRoot)
        }
    }

    try {
        $drive = [System.IO.DriveInfo]::new($pathRoot)
        return [pscustomobject]@{
            Root      = $drive.RootDirectory.FullName
            DriveType = $drive.DriveType
        }
    }
    catch {
        return $null
    }
}

function Get-UvCacheDirectoryForPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DefaultCacheDirectory,

        [string]$CacheRelativePath = ".local\uv\cache",

        [Parameter(DontShow)]
        [scriptblock]$VolumeResolver = {
            param($CandidatePath)
            Resolve-UvCacheVolume -Path $CandidatePath
        }
    )

    if ([System.IO.Path]::IsPathRooted($CacheRelativePath)) {
        throw "CacheRelativePath must be relative to a volume root."
    }

    $defaultCacheDirectory = [System.IO.Path]::GetFullPath($DefaultCacheDirectory)
    $currentVolume = & $VolumeResolver $Path
    if ($null -eq $currentVolume -or $currentVolume.DriveType -ne [System.IO.DriveType]::Fixed) {
        return $defaultCacheDirectory
    }

    $defaultVolume = & $VolumeResolver $defaultCacheDirectory
    if ($null -ne $defaultVolume) {
        $currentVolumeKey = $currentVolume.Root.TrimEnd('\', '/')
        $defaultVolumeKey = $defaultVolume.Root.TrimEnd('\', '/')
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals($currentVolumeKey, $defaultVolumeKey)) {
            return $defaultCacheDirectory
        }
    }

    return [System.IO.Path]::GetFullPath((Join-Path $currentVolume.Root $CacheRelativePath))
}

function Get-UvBuiltInCacheDirectory {
    [CmdletBinding()]
    param()

    $uvCommand = Get-Command uv -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $savedCacheDirectory = [Environment]::GetEnvironmentVariable("UV_CACHE_DIR", "Process")
    $cacheDirectoryWasSet = Test-Path Env:UV_CACHE_DIR

    try {
        Remove-Item Env:UV_CACHE_DIR -ErrorAction SilentlyContinue
        $cacheDirectory = & $uvCommand.Source cache dir --no-config
        if ($LASTEXITCODE -ne 0) {
            throw "uv cache dir --no-config exited with code $LASTEXITCODE."
        }
        return [System.IO.Path]::GetFullPath(($cacheDirectory | Select-Object -Last 1))
    }
    finally {
        if ($cacheDirectoryWasSet) {
            $env:UV_CACHE_DIR = $savedCacheDirectory
        }
        else {
            Remove-Item Env:UV_CACHE_DIR -ErrorAction SilentlyContinue
        }
    }
}

function Set-UvCacheForCurrentVolume {
    [CmdletBinding()]
    param(
        [switch]$PassThru
    )

    if ($null -eq $script:UvCachePerVolumeState -or -not $script:UvCachePerVolumeState.Enabled) {
        throw "Enable-UvCachePerVolume must be called first."
    }

    try {
        $location = Get-Location
        if ($location.Provider.Name -eq "FileSystem") {
            $selectedCacheDirectory = Get-UvCacheDirectoryForPath `
                -Path $location.Path `
                -DefaultCacheDirectory $script:UvCachePerVolumeState.DefaultCacheDirectory `
                -CacheRelativePath $script:UvCachePerVolumeState.CacheRelativePath
        }
        else {
            $selectedCacheDirectory = $script:UvCachePerVolumeState.DefaultCacheDirectory
        }
    }
    catch {
        Write-Verbose "Unable to select a cache for the current volume: $_"
        $selectedCacheDirectory = $script:UvCachePerVolumeState.DefaultCacheDirectory
    }

    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            $env:UV_CACHE_DIR,
            $selectedCacheDirectory
        )) {
        $env:UV_CACHE_DIR = $selectedCacheDirectory
    }

    if ($PassThru) {
        return $selectedCacheDirectory
    }
}

function Enable-UvCachePerVolume {
    [CmdletBinding()]
    param(
        [string]$DefaultCacheDirectory,
        [string]$CacheRelativePath = ".local\uv\cache"
    )

    if ($null -ne $script:UvCachePerVolumeState -and $script:UvCachePerVolumeState.Enabled) {
        throw "The per-volume uv cache hook is already enabled."
    }

    if ([string]::IsNullOrWhiteSpace($CacheRelativePath) -or
        [System.IO.Path]::IsPathRooted($CacheRelativePath)) {
        throw "CacheRelativePath must be a non-empty path relative to a volume root."
    }

    if ([string]::IsNullOrWhiteSpace($DefaultCacheDirectory)) {
        $DefaultCacheDirectory = Get-UvBuiltInCacheDirectory
    }
    else {
        $DefaultCacheDirectory = [System.IO.Path]::GetFullPath($DefaultCacheDirectory)
    }

    $originalPrompt = (Get-Item Function:\prompt).ScriptBlock
    $originalCacheDirectory = [Environment]::GetEnvironmentVariable("UV_CACHE_DIR", "Process")
    $originalCacheDirectoryWasSet = Test-Path Env:UV_CACHE_DIR

    $promptWrapper = {
        Set-UvCacheForCurrentVolume
        & $originalPrompt
    }.GetNewClosure()

    $script:UvCachePerVolumeState = [pscustomobject]@{
        Enabled                      = $true
        DefaultCacheDirectory        = $DefaultCacheDirectory
        CacheRelativePath            = $CacheRelativePath
        OriginalPrompt               = $originalPrompt
        PromptWrapper                = $promptWrapper
        OriginalCacheDirectory       = $originalCacheDirectory
        OriginalCacheDirectoryWasSet = $originalCacheDirectoryWasSet
    }

    Set-Item Function:\global:prompt $promptWrapper
    Set-UvCacheForCurrentVolume
}

function Disable-UvCachePerVolume {
    [CmdletBinding()]
    param()

    if ($null -eq $script:UvCachePerVolumeState -or -not $script:UvCachePerVolumeState.Enabled) {
        return
    }

    $currentPrompt = (Get-Item Function:\prompt).ScriptBlock
    if ($currentPrompt.ToString() -eq $script:UvCachePerVolumeState.PromptWrapper.ToString()) {
        Set-Item Function:\global:prompt $script:UvCachePerVolumeState.OriginalPrompt
    }
    else {
        Write-Warning "The prompt changed after the uv cache hook was enabled; it was not replaced."
    }

    if ($script:UvCachePerVolumeState.OriginalCacheDirectoryWasSet) {
        $env:UV_CACHE_DIR = $script:UvCachePerVolumeState.OriginalCacheDirectory
    }
    else {
        Remove-Item Env:UV_CACHE_DIR -ErrorAction SilentlyContinue
    }

    $script:UvCachePerVolumeState = $null
}
