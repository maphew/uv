<!-- _codex-unknown-model- on behalf of Matt Wilkie_ -->

# Per-volume uv directories hook for Windows

This is an opt-in prototype for using uv across multiple Windows volumes while retaining uv's
normal cache on its original volume. It can also manage `UV_TOOL_DIR` and `UV_TOOL_BIN_DIR`, but
that behavior is opt-in because it creates a separate installed-tool set on every local volume.

The hook selects the cache as follows:

1. On the volume containing uv's built-in cache, keep using the built-in cache.
2. On another fixed local volume, use `.local\uv\cache` at that volume's root.
3. On mapped drives, UNC shares, removable drives, and non-filesystem PowerShell providers, use the
   built-in cache instead of creating a cache there.

For example, if uv's normal cache is `C:\Users\me\AppData\Local\uv\cache`:

| Current directory | Selected cache |
| --- | --- |
| `C:\work\project` | `C:\Users\me\AppData\Local\uv\cache` |
| `D:\work\project` | `D:\.local\uv\cache` |
| `Z:\work\project`, where `Z:` is mapped | `C:\Users\me\AppData\Local\uv\cache` |
| `\\server\share\project` | `C:\Users\me\AppData\Local\uv\cache` |

## Installation

Dot-source the script near the end of the PowerShell profile, after prompt tools such as Oh My Posh
or Starship are initialized:

```powershell
. "C:\path\to\uv\scripts\uv-cache-per-volume.ps1"
Enable-UvCachePerVolume
```

The hook wraps the PowerShell `prompt` function. Interactive location changes therefore update
`UV_CACHE_DIR` before the next command is entered. Child processes inherit the selected value.

An existing process-level `UV_CACHE_DIR` does not need to be unset. The hook saves it, overrides it
while enabled, and restores it when disabled. Without `-ManageTools`, other `UV_*` variables are
not changed. If an older persistent `UV_CACHE_DIR` setting is no longer wanted in shells that do
not load this hook, remove it from the user environment before enabling the hook:

```powershell
[Environment]::SetEnvironmentVariable("UV_CACHE_DIR", $null, "User")
Remove-Item Env:UV_CACHE_DIR -ErrorAction SilentlyContinue
```

To use another path on secondary volumes:

```powershell
Enable-UvCachePerVolume -CacheRelativePath ".cache\uv"
```

To override the fallback cache explicitly:

```powershell
Enable-UvCachePerVolume `
    -DefaultCacheDirectory "D:\Caches\uv"
```

With this configuration, `D:` uses `D:\Caches\uv`, other fixed local volumes use their
volume-local `.local\uv\cache`, and mapped drives or UNC shares fall back to `D:\Caches\uv`.

For a persistent profile configuration with a per-user path on secondary volumes:

```powershell
. "C:\path\to\uv\scripts\uv-cache-per-volume.ps1"

$uvCacheOptions = @{
    DefaultCacheDirectory = "D:\Caches\uv"
    CacheRelativePath     = ".local\uv\cache\$env:USERNAME"
}

Enable-UvCachePerVolume @uvCacheOptions
```

## Opt-in tool directories

Yes, the same volume-selection rule can be applied to `UV_TOOL_DIR` and `UV_TOOL_BIN_DIR`.
Enable it explicitly with `ManageTools = $true`. The hook also prepends the selected tool bin
directory to `PATH`, removes the prior bin directory that it inserted when the volume changes, and
cleans up its insertion when disabled.

For the machine whose preferred fallback volume is `A:`:

```powershell
. "C:\path\to\uv\scripts\uv-cache-per-volume.ps1"

$uvOptions = @{
    DefaultCacheDirectory         = "A:\.local\uv\cache\$env:USERNAME"
    CacheRelativePath             = ".local\uv\cache\$env:USERNAME"

    ManageTools                   = $true
    DefaultToolDirectory          = "A:\.local\uv\tools\$env:USERNAME"
    ToolDirectoryRelativePath     = ".local\uv\tools\$env:USERNAME"
    DefaultToolBinDirectory       = "A:\.local\uv\bin\$env:USERNAME"
    ToolBinDirectoryRelativePath  = ".local\uv\bin\$env:USERNAME"
}

Enable-UvCachePerVolume @uvOptions
```

That configuration selects:

| Location | Cache | Tool environments | Tool executables |
| --- | --- | --- | --- |
| Local `A:` | `A:\.local\uv\cache\<user>` | `A:\.local\uv\tools\<user>` | `A:\.local\uv\bin\<user>` |
| Local `C:` | `C:\.local\uv\cache\<user>` | `C:\.local\uv\tools\<user>` | `C:\.local\uv\bin\<user>` |
| Network or UNC | `A:\.local\uv\cache\<user>` | `A:\.local\uv\tools\<user>` | `A:\.local\uv\bin\<user>` |

Existing process-level `UV_TOOL_DIR` and `UV_TOOL_BIN_DIR` values do not need to be unset. When
`-ManageTools` is enabled, the hook saves, overrides, and restores them just like
`UV_CACHE_DIR`. To remove old persistent user settings as well:

```powershell
"UV_CACHE_DIR", "UV_TOOL_DIR", "UV_TOOL_BIN_DIR" | ForEach-Object {
    [Environment]::SetEnvironmentVariable($_, $null, "User")
    Remove-Item "Env:$_" -ErrorAction SilentlyContinue
}
```

If either fallback tool directory is omitted, the script obtains uv's built-in value using
`uv tool dir --no-config` or `uv tool dir --bin --no-config`.

### Important tool-directory tradeoff

A per-volume cache is transparent except for duplicate cached data. A per-volume tool directory is
not: it creates a separate installed-tool inventory on each fixed volume.

For example, a tool installed while the shell is on `A:` will not appear in `uv tool list` while
the shell is on `C:`. Install, upgrade, and uninstall operate on the current volume's
`UV_TOOL_DIR`. The selected bin directory is placed first in `PATH`, but any tool directory that
was already in the original `PATH` remains later in it; an executable from that original directory
can therefore still be found if the selected volume does not contain it.

For a single, machine-wide tool inventory, do not use `-ManageTools`. Manage only the cache and
leave uv's tool directories unchanged. This is the recommended default.

## Inspect and disable

Inspect the current selections with:

```powershell
uv cache dir
uv tool dir
uv tool dir --bin
```

Or return all directories selected by the hook:

```powershell
Set-UvCacheForCurrentVolume -PassThru
```

Remove the prompt hook, restore the previous process-level variables, and remove the active tool-bin
`PATH` entry inserted by the hook with:

```powershell
Disable-UvCachePerVolume
```

## Limitations

- Directory selection follows the interactive shell's current directory, not an explicit environment
  passed through `--python`, `UV_PROJECT_ENVIRONMENT`, or `--active`.
- A script that changes directory and invokes uv before PowerShell renders another prompt retains the
  previous selection. It can call `Set-UvCacheForCurrentVolume` after changing directory.
- The script intentionally excludes removable and RAM disks as well as network locations. This can
  be made configurable after the safety of those cases is understood.
- The volume root must permit creation of the configured relative paths.
- The default `.local\uv` paths are shared by users who select the same volume. On a multi-user
  machine, configure per-user paths containing `$env:USERNAME` and ensure their access controls are
  appropriate.
- The process-level variables selected by the hook take precedence over corresponding values in uv
  configuration files.
- Separate volume caches can contain duplicate packages and initially require separate downloads.
- Separate volume tool directories must be installed and maintained independently.
- This prototype does not change `uv cache clean`, `uv cache prune`, tool inventory, or directory
  discovery semantics.

This is an interim shell workaround, not the proposed multi-filesystem cache implementation in uv.

## Test

Run the focused test script with Windows PowerShell or PowerShell 7:

```powershell
pwsh -NoProfile -File scripts\test-uv-cache-per-volume.ps1
```
