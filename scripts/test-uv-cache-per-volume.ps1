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
Assert-True -Condition $rootedPathRejected -Case "rooted cache path validation"

$normalScriptPath = [System.IO.Path]::GetFullPath($PSScriptRoot)
$normalVolume = Resolve-UvCacheVolume -Path $normalScriptPath
$extendedVolume = Resolve-UvCacheVolume -Path ("\\?\" + $normalScriptPath)
Assert-Equal -Expected $normalVolume.Root -Actual $extendedVolume.Root -Case "extended local path root"
Assert-Equal `
    -Expected ([string]$normalVolume.DriveType) `
    -Actual ([string]$extendedVolume.DriveType) `
    -Case "extended local path drive type"

$extendedUncVolume = Resolve-UvCacheVolume -Path "\\?\UNC\server\share\folder"
Assert-Equal -Expected "\\server\share" -Actual $extendedUncVolume.Root -Case "extended UNC root"
Assert-Equal `
    -Expected ([string][System.IO.DriveType]::Network) `
    -Actual ([string]$extendedUncVolume.DriveType) `
    -Case "extended UNC drive type"

$configTestDirectory = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("uv-cache-config-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $configTestDirectory | Out-Null
$savedConfigTestCache = [Environment]::GetEnvironmentVariable("UV_CACHE_DIR", "Process")
$configTestCacheWasSet = Test-Path Env:UV_CACHE_DIR
try {
    [System.IO.File]::WriteAllText(
        (Join-Path $configTestDirectory "uv.toml"),
        'cache-dir = "configured-cache"'
    )
    Push-Location $configTestDirectory
    try {
        $env:UV_CACHE_DIR = "C:\ignored-environment-cache"
        $configuredCache = Get-UvDefaultCacheDirectory
        Assert-Equal `
            -Expected (Join-Path $configTestDirectory "configured-cache") `
            -Actual $configuredCache `
            -Case "configured default cache"
        Assert-Equal `
            -Expected "C:\ignored-environment-cache" `
            -Actual $env:UV_CACHE_DIR `
            -Case "default cache helper environment restore"
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($configTestCacheWasSet) {
        $env:UV_CACHE_DIR = $savedConfigTestCache
    }
    else {
        Remove-Item Env:UV_CACHE_DIR -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $configTestDirectory -Recurse -Force
}

$nestedScript = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("uv-cache-nested-" + [guid]::NewGuid().ToString("N") + ".ps1")
[System.IO.File]::WriteAllText(
    $nestedScript,
    @"
param(
    [string]`$HookPath,
    [string]`$DefaultCacheDirectory
)

. `$HookPath
try {
    Enable-UvCachePerVolume -DefaultCacheDirectory `$DefaultCacheDirectory
    "unexpectedly enabled"
}
catch {
    `$_.Exception.Message
}
"@
)
$promptBeforeNestedTest = (Get-Item Function:\prompt).ScriptBlock.ToString()
$cacheBeforeNestedTest = [Environment]::GetEnvironmentVariable("UV_CACHE_DIR", "Process")
try {
    $nestedResult = (& $nestedScript `
            (Join-Path $PSScriptRoot "uv-cache-per-volume.ps1") `
            $defaultCacheDirectory) -join [Environment]::NewLine
    Assert-True `
        -Condition $nestedResult.Contains("dot-sourced directly from the global scope") `
        -Case "child-scope enable rejection"
    Assert-Equal `
        -Expected $promptBeforeNestedTest `
        -Actual (Get-Item Function:\prompt).ScriptBlock.ToString() `
        -Case "child-scope prompt unchanged"
    Assert-Equal `
        -Expected $cacheBeforeNestedTest `
        -Actual ([Environment]::GetEnvironmentVariable("UV_CACHE_DIR", "Process")) `
        -Case "child-scope environment unchanged"
}
finally {
    Remove-Item -LiteralPath $nestedScript -Force
}

$pathBeforeDisabledGuard = $env:PATH
$disabledPathGuardThrew = $false
try {
    Set-UvManagedToolBinPath -ToolBinDirectory "C:\should-not-be-added"
}
catch {
    $disabledPathGuardThrew = $true
}
Assert-True -Condition $disabledPathGuardThrew -Case "disabled tool bin guard"
Assert-Equal -Expected $pathBeforeDisabledGuard -Actual $env:PATH -Case "disabled tool bin PATH unchanged"

$testState = @{
    CacheDirectory = [Environment]::GetEnvironmentVariable("UV_CACHE_DIR", "Process")
    CacheWasSet = Test-Path Env:UV_CACHE_DIR
    ToolDirectory = [Environment]::GetEnvironmentVariable("UV_TOOL_DIR", "Process")
    ToolWasSet = Test-Path Env:UV_TOOL_DIR
    ToolBinDirectory = [Environment]::GetEnvironmentVariable("UV_TOOL_BIN_DIR", "Process")
    ToolBinWasSet = Test-Path Env:UV_TOOL_BIN_DIR
    Path = $env:PATH
    Location = (Get-Location).ProviderPath
    Prompt = (Get-Item Function:\prompt).ScriptBlock
}
$hookEnabled = $false
$psDriveName = $null
$originalResolver = $null

try {
    $env:UV_CACHE_DIR = "before-cache"
    $env:UV_TOOL_DIR = "before-tools"
    $env:UV_TOOL_BIN_DIR = "before-bin"

    $currentVolume = Resolve-UvCacheVolume -Path (Get-Location).ProviderPath
    Assert-True `
        -Condition ($null -ne $currentVolume -and
            $currentVolume.DriveType -eq [System.IO.DriveType]::Fixed) `
        -Case "test working directory is on a fixed volume"

    $otherFixedVolume = [System.IO.DriveInfo]::GetDrives() |
        Where-Object {
            $_.IsReady -and
            $_.DriveType -eq [System.IO.DriveType]::Fixed -and
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals(
                $_.RootDirectory.FullName.TrimEnd('\', '/'),
                $currentVolume.Root.TrimEnd('\', '/')
            )
        } |
        Select-Object -First 1
    if ($null -eq $otherFixedVolume) {
        $defaultVolumeRoot = $currentVolume.Root
    }
    else {
        $defaultVolumeRoot = $otherFixedVolume.RootDirectory.FullName
    }

    $uniqueSuffix = [guid]::NewGuid().ToString("N")
    $cacheRelativePath = ".local\uv\test-$uniqueSuffix\cache-local"
    $toolRelativePath = ".local\uv\test-$uniqueSuffix\tools-local"
    $toolBinRelativePath = ".local\uv\test-$uniqueSuffix\bin-local"
    $defaultCache = Join-Path $defaultVolumeRoot ".local\uv\test-$uniqueSuffix\cache-default"
    $defaultTools = Join-Path $defaultVolumeRoot ".local\uv\test-$uniqueSuffix\tools-default"
    $defaultBin = Join-Path $defaultVolumeRoot ".local\uv\test-$uniqueSuffix\bin-default"

    if ([System.StringComparer]::OrdinalIgnoreCase.Equals(
            $defaultVolumeRoot.TrimEnd('\', '/'),
            $currentVolume.Root.TrimEnd('\', '/')
        )) {
        $expectedCache = $defaultCache
        $expectedTools = $defaultTools
        $expectedBin = $defaultBin
    }
    else {
        $expectedCache = Join-Path $currentVolume.Root $cacheRelativePath
        $expectedTools = Join-Path $currentVolume.Root $toolRelativePath
        $expectedBin = Join-Path $currentVolume.Root $toolBinRelativePath
    }

    $global:UvCacheTestPromptStatus = $null
    Set-Item Function:\global:prompt {
        $global:UvCacheTestPromptStatus = $?
        "UVTEST> "
    }

    Enable-UvCachePerVolume `
        -DefaultCacheDirectory $defaultCache `
        -CacheRelativePath $cacheRelativePath `
        -ManageTools `
        -DefaultToolDirectory $defaultTools `
        -DefaultToolBinDirectory $defaultBin `
        -ToolDirectoryRelativePath $toolRelativePath `
        -ToolBinDirectoryRelativePath $toolBinRelativePath
    $hookEnabled = $true

    $selected = Set-UvCacheForCurrentVolume -PassThru
    Assert-Equal -Expected $expectedCache -Actual $selected.CacheDirectory -Case "managed cache selection"
    Assert-Equal -Expected $expectedTools -Actual $selected.ToolDirectory -Case "managed tool selection"
    Assert-Equal -Expected $expectedBin -Actual $selected.ToolBinDirectory -Case "managed tool bin selection"
    Assert-Equal -Expected $expectedTools -Actual $env:UV_TOOL_DIR -Case "UV_TOOL_DIR update"
    Assert-Equal -Expected $expectedBin -Actual $env:UV_TOOL_BIN_DIR -Case "UV_TOOL_BIN_DIR update"

    $pathEntries = @($env:PATH -split [regex]::Escape([string][System.IO.Path]::PathSeparator))
    Assert-Equal -Expected $expectedBin -Actual $pathEntries[0] -Case "tool bin PATH prefix"

    $errorCountBeforeFailure = $Error.Count
    Get-Item "Z:\definitely-missing-uv-cache-test" -ErrorAction SilentlyContinue
    $renderedPrompt = prompt
    Assert-True -Condition (-not $global:UvCacheTestPromptStatus) -Case "failed prompt status"
    Assert-Equal -Expected "UVTEST> " -Actual $renderedPrompt -Case "failed command prompt rendering"
    Assert-True `
        -Condition ($Error.Count -eq $errorCountBeforeFailure + 1) `
        -Case "prompt status replay does not pollute error history"

    Get-Item $PSScriptRoot | Out-Null
    $renderedPrompt = prompt
    Assert-True -Condition $global:UvCacheTestPromptStatus -Case "successful prompt status"
    Assert-Equal -Expected "UVTEST> " -Actual $renderedPrompt -Case "successful command prompt rendering"

    $originalResolver = (Get-Item Function:\Resolve-UvCacheVolume).ScriptBlock
    $resolvedPaths = [System.Collections.Generic.List[string]]::new()
    $trackingResolver = {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        $resolvedPaths.Add([System.IO.Path]::GetFullPath($Path))
        & $originalResolver -Path $Path
    }.GetNewClosure()
    Set-Item Function:\global:Resolve-UvCacheVolume $trackingResolver

    $script:UvCachePerVolumeState.LastLocationKey = $null
    Set-UvCacheForCurrentVolume
    $resolutionCount = $resolvedPaths.Count
    Set-UvCacheForCurrentVolume
    Assert-True -Condition ($resolutionCount -gt 0) -Case "initial location resolution"
    Assert-True `
        -Condition ($resolvedPaths.Count -eq $resolutionCount) `
        -Case "unchanged location memoization"

    $currentProviderPath = [System.IO.Path]::GetFullPath((Get-Location).ProviderPath)
    $currentPathResolutions = @($resolvedPaths | Where-Object {
            [System.StringComparer]::OrdinalIgnoreCase.Equals($_, $currentProviderPath)
        })
    Assert-True `
        -Condition ($currentPathResolutions.Count -eq 1) `
        -Case "shared current-volume resolution"

    Set-Item Function:\global:Resolve-UvCacheVolume $originalResolver
    $originalResolver = $null

    $psDriveName = "UV" + [guid]::NewGuid().ToString("N").Substring(0, 6)
    $psDriveRoot = $PSScriptRoot
    # The script may sit on a different volume than the working directory, so
    # derive the expectation from the drive's underlying path instead of the
    # working directory's selection.
    $psDriveExpectedCache = Get-UvCacheDirectoryForPath `
        -Path $psDriveRoot `
        -DefaultCacheDirectory $defaultCache `
        -CacheRelativePath $cacheRelativePath
    New-PSDrive -Name $psDriveName -PSProvider FileSystem -Root $psDriveRoot -Scope Global | Out-Null
    Set-Location ($psDriveName + ":\")
    $psDriveLocation = Get-Location
    $psDriveSelection = Set-UvCacheForCurrentVolume -PassThru
    Assert-Equal `
        -Expected ("FileSystem|" + $psDriveLocation.ProviderPath) `
        -Actual $script:UvCachePerVolumeState.LastLocationKey `
        -Case "PSDrive provider path location key"
    Assert-Equal `
        -Expected $psDriveExpectedCache `
        -Actual $psDriveSelection.CacheDirectory `
        -Case "PSDrive cache selection"
    Set-Location $testState.Location
    Remove-PSDrive -Name $psDriveName -Scope Global
    $psDriveName = $null

    $alternateBin = Join-Path $currentVolume.Root ".local\uv\test-$uniqueSuffix\alternate-bin"
    Set-UvManagedToolBinPath -ToolBinDirectory $alternateBin
    $pathEntries = @($env:PATH -split [regex]::Escape([string][System.IO.Path]::PathSeparator))
    Assert-Equal -Expected $alternateBin -Actual $pathEntries[0] -Case "switched tool bin PATH prefix"
    $oldBinEntries = @($pathEntries | Where-Object {
            [System.StringComparer]::OrdinalIgnoreCase.Equals(
                $_.TrimEnd('\', '/'),
                $expectedBin.TrimEnd('\', '/')
            )
        })
    Assert-True -Condition ($oldBinEntries.Count -eq 0) -Case "previous tool bin PATH removal"

    Set-UvManagedToolBinPath -ToolBinDirectory $expectedBin

    $installedWrapper = (Get-Item Function:\prompt).ScriptBlock
    $foreignPrompt = {
        & $installedWrapper
    }.GetNewClosure()
    Set-Item Function:\global:prompt $foreignPrompt

    $disableWarnings = @(Disable-UvCachePerVolume 3>&1)
    $hookEnabled = $false
    Assert-True `
        -Condition (($disableWarnings | Out-String).Contains("prompt changed")) `
        -Case "changed prompt warning"

    Get-Item "Z:\definitely-missing-uv-cache-test" -ErrorAction SilentlyContinue
    $renderedPrompt = prompt
    Assert-Equal -Expected "UVTEST> " -Actual $renderedPrompt -Case "orphaned wrapper prompt rendering"
    Assert-True `
        -Condition (-not $global:UvCacheTestPromptStatus) `
        -Case "orphaned wrapper failed status"

    Assert-Equal -Expected "before-cache" -Actual $env:UV_CACHE_DIR -Case "UV_CACHE_DIR restore"
    Assert-Equal -Expected "before-tools" -Actual $env:UV_TOOL_DIR -Case "UV_TOOL_DIR restore"
    Assert-Equal -Expected "before-bin" -Actual $env:UV_TOOL_BIN_DIR -Case "UV_TOOL_BIN_DIR restore"
    Assert-Equal -Expected $testState.Path -Actual $env:PATH -Case "PATH restore"

    $pathBeforeDisabledGuard = $env:PATH
    $disabledPathGuardThrew = $false
    try {
        Set-UvManagedToolBinPath -ToolBinDirectory "C:\should-not-be-added"
    }
    catch {
        $disabledPathGuardThrew = $true
    }
    Assert-True -Condition $disabledPathGuardThrew -Case "post-disable tool bin guard"
    Assert-Equal `
        -Expected $pathBeforeDisabledGuard `
        -Actual $env:PATH `
        -Case "post-disable tool bin PATH unchanged"
}
finally {
    if ($null -ne $originalResolver) {
        Set-Item Function:\global:Resolve-UvCacheVolume $originalResolver
    }
    if ($null -ne $psDriveName) {
        Set-Location $testState.Location
        Remove-PSDrive -Name $psDriveName -Scope Global -ErrorAction SilentlyContinue
    }
    if ($hookEnabled) {
        Disable-UvCachePerVolume
    }

    Set-Location $testState.Location
    Set-Item Function:\global:prompt $testState.Prompt
    Remove-Variable UvCacheTestPromptStatus -Scope Global -ErrorAction SilentlyContinue

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
