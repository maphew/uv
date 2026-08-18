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

function Get-UvDirectoryForPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DefaultDirectory,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(DontShow)]
        [scriptblock]$VolumeResolver = {
            param($CandidatePath)
            Resolve-UvCacheVolume -Path $CandidatePath
        }
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "RelativePath must be a non-empty path relative to a volume root."
    }

    $defaultDirectory = [System.IO.Path]::GetFullPath($DefaultDirectory)
    $currentVolume = & $VolumeResolver $Path
    if ($null -eq $currentVolume -or $currentVolume.DriveType -ne [System.IO.DriveType]::Fixed) {
        return $defaultDirectory
    }

    $defaultVolume = & $VolumeResolver $defaultDirectory
    if ($null -ne $defaultVolume) {
        $currentVolumeKey = $currentVolume.Root.TrimEnd('\', '/')
        $defaultVolumeKey = $defaultVolume.Root.TrimEnd('\', '/')
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals($currentVolumeKey, $defaultVolumeKey)) {
            return $defaultDirectory
        }
    }

    return [System.IO.Path]::GetFullPath((Join-Path $currentVolume.Root $RelativePath))
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

    Get-UvDirectoryForPath `
        -Path $Path `
        -DefaultDirectory $DefaultCacheDirectory `
        -RelativePath $CacheRelativePath `
        -VolumeResolver $VolumeResolver
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

function Get-UvBuiltInToolDirectories {
    [CmdletBinding()]
    param()

    $uvCommand = Get-Command uv -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $savedToolDirectory = [Environment]::GetEnvironmentVariable("UV_TOOL_DIR", "Process")
    $toolDirectoryWasSet = Test-Path Env:UV_TOOL_DIR
    $savedToolBinDirectory = [Environment]::GetEnvironmentVariable("UV_TOOL_BIN_DIR", "Process")
    $toolBinDirectoryWasSet = Test-Path Env:UV_TOOL_BIN_DIR

    try {
        Remove-Item Env:UV_TOOL_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:UV_TOOL_BIN_DIR -ErrorAction SilentlyContinue

        $toolDirectory = & $uvCommand.Source tool dir --no-config
        if ($LASTEXITCODE -ne 0) {
            throw "uv tool dir --no-config exited with code $LASTEXITCODE."
        }

        $toolBinDirectory = & $uvCommand.Source tool dir --bin --no-config
        if ($LASTEXITCODE -ne 0) {
            throw "uv tool dir --bin --no-config exited with code $LASTEXITCODE."
        }

        return [pscustomobject]@{
            ToolDirectory    = [System.IO.Path]::GetFullPath(($toolDirectory | Select-Object -Last 1))
            ToolBinDirectory = [System.IO.Path]::GetFullPath(($toolBinDirectory | Select-Object -Last 1))
        }
    }
    finally {
        if ($toolDirectoryWasSet) {
            $env:UV_TOOL_DIR = $savedToolDirectory
        }
        else {
            Remove-Item Env:UV_TOOL_DIR -ErrorAction SilentlyContinue
        }

        if ($toolBinDirectoryWasSet) {
            $env:UV_TOOL_BIN_DIR = $savedToolBinDirectory
        }
        else {
            Remove-Item Env:UV_TOOL_BIN_DIR -ErrorAction SilentlyContinue
        }
    }
}

function Set-UvManagedToolBinPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ToolBinDirectory
    )

    $state = $script:UvCachePerVolumeState
    $pathSeparator = [System.IO.Path]::PathSeparator
    $pathEntries = @($env:PATH -split [regex]::Escape([string]$pathSeparator))

    if ($state.ActiveToolBinWasInserted -and
        -not [string]::IsNullOrWhiteSpace($state.ActiveToolBinDirectory)) {
        $previousDirectory = $state.ActiveToolBinDirectory.TrimEnd('\', '/')
        $pathEntries = @($pathEntries | Where-Object {
                $candidate = $_.TrimEnd('\', '/')
                -not [System.StringComparer]::OrdinalIgnoreCase.Equals($candidate, $previousDirectory)
            })
    }

    $selectedDirectory = [System.IO.Path]::GetFullPath($ToolBinDirectory)
    $selectedKey = $selectedDirectory.TrimEnd('\', '/')
    $alreadyPresent = $false
    foreach ($entry in $pathEntries) {
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals(
                $entry.TrimEnd('\', '/'),
                $selectedKey
            )) {
            $alreadyPresent = $true
            break
        }
    }

    if (-not $alreadyPresent) {
        $pathEntries = @($selectedDirectory) + $pathEntries
    }

    $env:PATH = $pathEntries -join $pathSeparator
    $state.ActiveToolBinDirectory = $selectedDirectory
    $state.ActiveToolBinWasInserted = -not $alreadyPresent
}

function Set-UvCacheForCurrentVolume {
    [CmdletBinding()]
    param(
        [switch]$PassThru
    )

    if ($null -eq $script:UvCachePerVolumeState -or -not $script:UvCachePerVolumeState.Enabled) {
        throw "Enable-UvCachePerVolume must be called first."
    }

    $location = $null
    $isFileSystemLocation = $false
    try {
        $location = Get-Location
        $isFileSystemLocation = $location.Provider.Name -eq "FileSystem"
        if ($isFileSystemLocation) {
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

    $selectedToolDirectory = $null
    $selectedToolBinDirectory = $null
    if ($script:UvCachePerVolumeState.ManageTools) {
        try {
            if ($isFileSystemLocation) {
                $selectedToolDirectory = Get-UvDirectoryForPath `
                    -Path $location.Path `
                    -DefaultDirectory $script:UvCachePerVolumeState.DefaultToolDirectory `
                    -RelativePath $script:UvCachePerVolumeState.ToolDirectoryRelativePath
                $selectedToolBinDirectory = Get-UvDirectoryForPath `
                    -Path $location.Path `
                    -DefaultDirectory $script:UvCachePerVolumeState.DefaultToolBinDirectory `
                    -RelativePath $script:UvCachePerVolumeState.ToolBinDirectoryRelativePath
            }
            else {
                $selectedToolDirectory = $script:UvCachePerVolumeState.DefaultToolDirectory
                $selectedToolBinDirectory = $script:UvCachePerVolumeState.DefaultToolBinDirectory
            }
        }
        catch {
            Write-Verbose "Unable to select tool directories for the current volume: $_"
            $selectedToolDirectory = $script:UvCachePerVolumeState.DefaultToolDirectory
            $selectedToolBinDirectory = $script:UvCachePerVolumeState.DefaultToolBinDirectory
        }

        $env:UV_TOOL_DIR = $selectedToolDirectory
        $env:UV_TOOL_BIN_DIR = $selectedToolBinDirectory
        Set-UvManagedToolBinPath -ToolBinDirectory $selectedToolBinDirectory
    }

    if ($PassThru) {
        return [pscustomobject]@{
            CacheDirectory   = $selectedCacheDirectory
            ToolDirectory    = $selectedToolDirectory
            ToolBinDirectory = $selectedToolBinDirectory
        }
    }
}

function Enable-UvCachePerVolume {
    [CmdletBinding()]
    param(
        [string]$DefaultCacheDirectory,
        [string]$CacheRelativePath = ".local\uv\cache",
        [switch]$ManageTools,
        [string]$DefaultToolDirectory,
        [string]$DefaultToolBinDirectory,
        [string]$ToolDirectoryRelativePath = ".local\uv\tools",
        [string]$ToolBinDirectoryRelativePath = ".local\uv\bin"
    )

    if ($null -ne $script:UvCachePerVolumeState -and $script:UvCachePerVolumeState.Enabled) {
        throw "The per-volume uv cache hook is already enabled."
    }

    if ([string]::IsNullOrWhiteSpace($CacheRelativePath) -or
        [System.IO.Path]::IsPathRooted($CacheRelativePath)) {
        throw "CacheRelativePath must be a non-empty path relative to a volume root."
    }

    if ($ManageTools) {
        if ([string]::IsNullOrWhiteSpace($ToolDirectoryRelativePath) -or
            [System.IO.Path]::IsPathRooted($ToolDirectoryRelativePath)) {
            throw "ToolDirectoryRelativePath must be a non-empty path relative to a volume root."
        }
        if ([string]::IsNullOrWhiteSpace($ToolBinDirectoryRelativePath) -or
            [System.IO.Path]::IsPathRooted($ToolBinDirectoryRelativePath)) {
            throw "ToolBinDirectoryRelativePath must be a non-empty path relative to a volume root."
        }
    }
    elseif ($PSBoundParameters.ContainsKey("DefaultToolDirectory") -or
        $PSBoundParameters.ContainsKey("DefaultToolBinDirectory") -or
        $PSBoundParameters.ContainsKey("ToolDirectoryRelativePath") -or
        $PSBoundParameters.ContainsKey("ToolBinDirectoryRelativePath")) {
        throw "Specify -ManageTools to manage UV_TOOL_DIR and UV_TOOL_BIN_DIR."
    }

    if ([string]::IsNullOrWhiteSpace($DefaultCacheDirectory)) {
        $DefaultCacheDirectory = Get-UvBuiltInCacheDirectory
    }
    else {
        $DefaultCacheDirectory = [System.IO.Path]::GetFullPath($DefaultCacheDirectory)
    }

    if ($ManageTools) {
        if ([string]::IsNullOrWhiteSpace($DefaultToolDirectory) -or
            [string]::IsNullOrWhiteSpace($DefaultToolBinDirectory)) {
            $builtInToolDirectories = Get-UvBuiltInToolDirectories
        }
        if ([string]::IsNullOrWhiteSpace($DefaultToolDirectory)) {
            $DefaultToolDirectory = $builtInToolDirectories.ToolDirectory
        }
        else {
            $DefaultToolDirectory = [System.IO.Path]::GetFullPath($DefaultToolDirectory)
        }
        if ([string]::IsNullOrWhiteSpace($DefaultToolBinDirectory)) {
            $DefaultToolBinDirectory = $builtInToolDirectories.ToolBinDirectory
        }
        else {
            $DefaultToolBinDirectory = [System.IO.Path]::GetFullPath($DefaultToolBinDirectory)
        }
    }

    $originalPrompt = (Get-Item Function:\prompt).ScriptBlock
    $originalCacheDirectory = [Environment]::GetEnvironmentVariable("UV_CACHE_DIR", "Process")
    $originalCacheDirectoryWasSet = Test-Path Env:UV_CACHE_DIR
    $originalToolDirectory = [Environment]::GetEnvironmentVariable("UV_TOOL_DIR", "Process")
    $originalToolDirectoryWasSet = Test-Path Env:UV_TOOL_DIR
    $originalToolBinDirectory = [Environment]::GetEnvironmentVariable("UV_TOOL_BIN_DIR", "Process")
    $originalToolBinDirectoryWasSet = Test-Path Env:UV_TOOL_BIN_DIR

    $promptWrapper = {
        Set-UvCacheForCurrentVolume
        & $originalPrompt
    }.GetNewClosure()

    $script:UvCachePerVolumeState = [pscustomobject]@{
        Enabled                         = $true
        DefaultCacheDirectory           = $DefaultCacheDirectory
        CacheRelativePath               = $CacheRelativePath
        OriginalPrompt                  = $originalPrompt
        PromptWrapper                   = $promptWrapper
        OriginalCacheDirectory          = $originalCacheDirectory
        OriginalCacheDirectoryWasSet    = $originalCacheDirectoryWasSet
        ManageTools                     = [bool]$ManageTools
        DefaultToolDirectory            = $DefaultToolDirectory
        DefaultToolBinDirectory         = $DefaultToolBinDirectory
        ToolDirectoryRelativePath       = $ToolDirectoryRelativePath
        ToolBinDirectoryRelativePath    = $ToolBinDirectoryRelativePath
        OriginalToolDirectory           = $originalToolDirectory
        OriginalToolDirectoryWasSet     = $originalToolDirectoryWasSet
        OriginalToolBinDirectory        = $originalToolBinDirectory
        OriginalToolBinDirectoryWasSet  = $originalToolBinDirectoryWasSet
        ActiveToolBinDirectory          = $null
        ActiveToolBinWasInserted        = $false
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

    if ($script:UvCachePerVolumeState.ManageTools) {
        if ($script:UvCachePerVolumeState.ActiveToolBinWasInserted) {
            $activeToolBinDirectory = $script:UvCachePerVolumeState.ActiveToolBinDirectory.TrimEnd('\', '/')
            $pathSeparator = [System.IO.Path]::PathSeparator
            $pathEntries = @($env:PATH -split [regex]::Escape([string]$pathSeparator) | Where-Object {
                    $candidate = $_.TrimEnd('\', '/')
                    -not [System.StringComparer]::OrdinalIgnoreCase.Equals(
                        $candidate,
                        $activeToolBinDirectory
                    )
                })
            $env:PATH = $pathEntries -join $pathSeparator
        }

        if ($script:UvCachePerVolumeState.OriginalToolDirectoryWasSet) {
            $env:UV_TOOL_DIR = $script:UvCachePerVolumeState.OriginalToolDirectory
        }
        else {
            Remove-Item Env:UV_TOOL_DIR -ErrorAction SilentlyContinue
        }

        if ($script:UvCachePerVolumeState.OriginalToolBinDirectoryWasSet) {
            $env:UV_TOOL_BIN_DIR = $script:UvCachePerVolumeState.OriginalToolBinDirectory
        }
        else {
            Remove-Item Env:UV_TOOL_BIN_DIR -ErrorAction SilentlyContinue
        }
    }

    $script:UvCachePerVolumeState = $null
}
