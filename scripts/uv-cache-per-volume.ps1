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

$script:UvCachePerVolumeScopeMarker = [object]::new()

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
    $isExtendedLocalPath = $false
    if ($fullPath.StartsWith("\\?\UNC\", [System.StringComparison]::OrdinalIgnoreCase)) {
        $fullPath = "\\" + $fullPath.Substring(8)
    }
    elseif ($fullPath.StartsWith("\\?\", [System.StringComparison]::OrdinalIgnoreCase)) {
        $isExtendedLocalPath = $true
        $strippedPath = $fullPath.Substring(4)
        if ([System.IO.Path]::IsPathRooted($strippedPath)) {
            $fullPath = $strippedPath
        }
    }

    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($pathRoot)) {
        return $null
    }
    if (-not $isExtendedLocalPath -and $pathRoot.StartsWith("\\")) {
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

function ConvertTo-UvAbsoluteDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    if ([System.IO.Path]::IsPathRooted($Directory)) {
        return [System.IO.Path]::GetFullPath($Directory)
    }

    $location = Get-Location
    if ($location.Provider.Name -ne "FileSystem") {
        throw "uv returned a relative directory outside a filesystem location: $Directory"
    }
    return [System.IO.Path]::GetFullPath((Join-Path $location.ProviderPath $Directory))
}

function Get-UvDefaultCacheDirectory {
    [CmdletBinding()]
    param()

    $uvCommand = Get-Command uv -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $savedCacheDirectory = [Environment]::GetEnvironmentVariable("UV_CACHE_DIR", "Process")
    $cacheDirectoryWasSet = Test-Path Env:UV_CACHE_DIR

    try {
        Remove-Item Env:UV_CACHE_DIR -ErrorAction SilentlyContinue
        $cacheDirectory = & $uvCommand.Source cache dir
        if ($LASTEXITCODE -ne 0) {
            throw "uv cache dir exited with code $LASTEXITCODE."
        }
        return ConvertTo-UvAbsoluteDirectory -Directory ($cacheDirectory | Select-Object -Last 1)
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

function Get-UvDefaultToolDirectories {
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

        $toolDirectory = & $uvCommand.Source tool dir
        if ($LASTEXITCODE -ne 0) {
            throw "uv tool dir exited with code $LASTEXITCODE."
        }

        $toolBinDirectory = & $uvCommand.Source tool dir --bin
        if ($LASTEXITCODE -ne 0) {
            throw "uv tool dir --bin exited with code $LASTEXITCODE."
        }

        return [pscustomobject]@{
            ToolDirectory    = ConvertTo-UvAbsoluteDirectory -Directory ($toolDirectory | Select-Object -Last 1)
            ToolBinDirectory = ConvertTo-UvAbsoluteDirectory -Directory ($toolBinDirectory | Select-Object -Last 1)
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
    if ($null -eq $state -or -not $state.Enabled) {
        throw "Enable-UvCachePerVolume must be called first."
    }

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

    $state = $script:UvCachePerVolumeState
    if ($null -eq $state -or -not $state.Enabled) {
        throw "Enable-UvCachePerVolume must be called first."
    }

    $location = $null
    $locationPath = $null
    $locationKey = $null
    $isFileSystemLocation = $false
    try {
        $location = Get-Location
        $isFileSystemLocation = $location.Provider.Name -eq "FileSystem"
        if ($isFileSystemLocation) {
            $locationPath = $location.ProviderPath
        }
        $locationKey = "{0}|{1}" -f $location.Provider.Name, $(
            if ($isFileSystemLocation) {
                $locationPath
            }
            else {
                $location.Path
            }
        )
    }
    catch {
        Write-Verbose "Unable to inspect the current location: $_"
    }

    $selectionIsCached = $null -ne $locationKey -and
        [System.StringComparer]::OrdinalIgnoreCase.Equals($state.LastLocationKey, $locationKey)

    if ($selectionIsCached) {
        $selectedCacheDirectory = $state.SelectedCacheDirectory
        $selectedToolDirectory = $state.SelectedToolDirectory
        $selectedToolBinDirectory = $state.SelectedToolBinDirectory
    }
    else {
        $resolvedVolumes = @{}
        $volumeResolver = {
            param($CandidatePath)

            $candidateKey = [System.IO.Path]::GetFullPath($CandidatePath)
            if (-not $resolvedVolumes.ContainsKey($candidateKey)) {
                $resolvedVolumes[$candidateKey] = Resolve-UvCacheVolume -Path $candidateKey
            }
            return $resolvedVolumes[$candidateKey]
        }.GetNewClosure()

        try {
            if ($isFileSystemLocation) {
                $selectedCacheDirectory = Get-UvCacheDirectoryForPath `
                    -Path $locationPath `
                    -DefaultCacheDirectory $state.DefaultCacheDirectory `
                    -CacheRelativePath $state.CacheRelativePath `
                    -VolumeResolver $volumeResolver
            }
            else {
                $selectedCacheDirectory = $state.DefaultCacheDirectory
            }
        }
        catch {
            Write-Verbose "Unable to select a cache for the current volume: $_"
            $selectedCacheDirectory = $state.DefaultCacheDirectory
        }

        $selectedToolDirectory = $null
        $selectedToolBinDirectory = $null
        if ($state.ManageTools) {
            try {
                if ($isFileSystemLocation) {
                    $selectedToolDirectory = Get-UvDirectoryForPath `
                        -Path $locationPath `
                        -DefaultDirectory $state.DefaultToolDirectory `
                        -RelativePath $state.ToolDirectoryRelativePath `
                        -VolumeResolver $volumeResolver
                    $selectedToolBinDirectory = Get-UvDirectoryForPath `
                        -Path $locationPath `
                        -DefaultDirectory $state.DefaultToolBinDirectory `
                        -RelativePath $state.ToolBinDirectoryRelativePath `
                        -VolumeResolver $volumeResolver
                }
                else {
                    $selectedToolDirectory = $state.DefaultToolDirectory
                    $selectedToolBinDirectory = $state.DefaultToolBinDirectory
                }
            }
            catch {
                Write-Verbose "Unable to select tool directories for the current volume: $_"
                $selectedToolDirectory = $state.DefaultToolDirectory
                $selectedToolBinDirectory = $state.DefaultToolBinDirectory
            }
        }

        $state.LastLocationKey = $locationKey
        $state.SelectedCacheDirectory = $selectedCacheDirectory
        $state.SelectedToolDirectory = $selectedToolDirectory
        $state.SelectedToolBinDirectory = $selectedToolBinDirectory
    }

    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            $env:UV_CACHE_DIR,
            $selectedCacheDirectory
        )) {
        $env:UV_CACHE_DIR = $selectedCacheDirectory
    }

    if ($state.ManageTools) {
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
                $env:UV_TOOL_DIR,
                $selectedToolDirectory
            )) {
            $env:UV_TOOL_DIR = $selectedToolDirectory
        }
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
                $env:UV_TOOL_BIN_DIR,
                $selectedToolBinDirectory
            )) {
            $env:UV_TOOL_BIN_DIR = $selectedToolBinDirectory
        }
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
                $state.ActiveToolBinDirectory,
                $selectedToolBinDirectory
            )) {
            Set-UvManagedToolBinPath -ToolBinDirectory $selectedToolBinDirectory
        }
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

    $globalScopeMarker = Get-Variable `
        -Name UvCachePerVolumeScopeMarker `
        -Scope Global `
        -ErrorAction SilentlyContinue
    if ($null -eq $globalScopeMarker -or
        -not [object]::ReferenceEquals($script:UvCachePerVolumeScopeMarker, $globalScopeMarker.Value)) {
        throw @"
uv-cache-per-volume.ps1 must be dot-sourced directly from the global scope.
Dot-source it from an interactive prompt or your PowerShell profile, not from a nested installer script.
"@
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
        $DefaultCacheDirectory = Get-UvDefaultCacheDirectory
    }
    else {
        $DefaultCacheDirectory = [System.IO.Path]::GetFullPath($DefaultCacheDirectory)
    }

    if ($ManageTools) {
        if ([string]::IsNullOrWhiteSpace($DefaultToolDirectory) -or
            [string]::IsNullOrWhiteSpace($DefaultToolBinDirectory)) {
            $defaultToolDirectories = Get-UvDefaultToolDirectories
        }
        if ([string]::IsNullOrWhiteSpace($DefaultToolDirectory)) {
            $DefaultToolDirectory = $defaultToolDirectories.ToolDirectory
        }
        else {
            $DefaultToolDirectory = [System.IO.Path]::GetFullPath($DefaultToolDirectory)
        }
        if ([string]::IsNullOrWhiteSpace($DefaultToolBinDirectory)) {
            $DefaultToolBinDirectory = $defaultToolDirectories.ToolBinDirectory
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

    $hookState = [pscustomobject]@{
        Enabled                         = $true
        DefaultCacheDirectory           = $DefaultCacheDirectory
        CacheRelativePath               = $CacheRelativePath
        OriginalPrompt                  = $originalPrompt
        PromptWrapper                   = $null
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
        LastLocationKey                 = $null
        SelectedCacheDirectory          = $null
        SelectedToolDirectory           = $null
        SelectedToolBinDirectory        = $null
    }

    $promptWrapper = {
        $lastCommandSucceeded = $?
        if ($hookState.Enabled) {
            try {
                Set-UvCacheForCurrentVolume
            }
            catch {
                # A persistent failure would repeat on every prompt render; keep it
                # out of the console unless verbose output is requested.
                Write-Verbose "Unable to update uv directories for the current prompt: $_"
            }
        }

        if (-not $lastCommandSucceeded) {
            Write-Error "Preserving the previous command status for the prompt." -ErrorAction Ignore
        }
        & $originalPrompt
    }.GetNewClosure()

    $hookState.PromptWrapper = $promptWrapper
    $script:UvCachePerVolumeState = $hookState

    Set-Item Function:\global:prompt $promptWrapper
    Set-UvCacheForCurrentVolume
}

function Disable-UvCachePerVolume {
    [CmdletBinding()]
    param()

    $state = $script:UvCachePerVolumeState
    if ($null -eq $state -or -not $state.Enabled) {
        return
    }

    $state.Enabled = $false

    $currentPrompt = (Get-Item Function:\prompt).ScriptBlock
    if ($currentPrompt.ToString() -eq $state.PromptWrapper.ToString()) {
        Set-Item Function:\global:prompt $state.OriginalPrompt
    }
    else {
        Write-Warning "The prompt changed after the uv cache hook was enabled; it was not replaced."
    }

    if ($state.OriginalCacheDirectoryWasSet) {
        $env:UV_CACHE_DIR = $state.OriginalCacheDirectory
    }
    else {
        Remove-Item Env:UV_CACHE_DIR -ErrorAction SilentlyContinue
    }

    if ($state.ManageTools) {
        if ($state.ActiveToolBinWasInserted) {
            $activeToolBinDirectory = $state.ActiveToolBinDirectory.TrimEnd('\', '/')
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

        if ($state.OriginalToolDirectoryWasSet) {
            $env:UV_TOOL_DIR = $state.OriginalToolDirectory
        }
        else {
            Remove-Item Env:UV_TOOL_DIR -ErrorAction SilentlyContinue
        }

        if ($state.OriginalToolBinDirectoryWasSet) {
            $env:UV_TOOL_BIN_DIR = $state.OriginalToolBinDirectory
        }
        else {
            Remove-Item Env:UV_TOOL_BIN_DIR -ErrorAction SilentlyContinue
        }
    }

    $script:UvCachePerVolumeState = $null
}
