<!-- _codex-unknown-model- on behalf of Matt Wilkie_ -->

# Per-volume uv cache hook for Windows

This is an opt-in prototype for using uv across multiple Windows volumes while retaining uv's
normal cache on its original volume.

The hook selects the cache as follows:

1. On the volume containing uv's built-in cache, keep using the built-in cache.
2. On another fixed local volume, use `.uv\cache` at that volume's root.
3. On mapped drives, UNC shares, removable drives, and non-filesystem PowerShell providers, use the
   built-in cache instead of creating a cache there.

For example, if uv's normal cache is `C:\Users\me\AppData\Local\uv\cache`:

| Current directory | Selected cache |
| --- | --- |
| `C:\work\project` | `C:\Users\me\AppData\Local\uv\cache` |
| `D:\work\project` | `D:\.uv\cache` |
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

To use another path on secondary volumes:

```powershell
Enable-UvCachePerVolume -CacheRelativePath ".local\uv\cache"
```

To override the fallback cache explicitly:

```powershell
Enable-UvCachePerVolume `
    -DefaultCacheDirectory "C:\Users\me\AppData\Local\uv\cache"
```

Inspect the current selection with:

```powershell
uv cache dir
```

Remove the prompt hook and restore the previous process-level `UV_CACHE_DIR` with:

```powershell
Disable-UvCachePerVolume
```

## Limitations

- Cache selection follows the interactive shell's current directory, not an explicit environment
  passed through `--python`, `UV_PROJECT_ENVIRONMENT`, or `--active`.
- A script that changes directory and invokes uv before PowerShell renders another prompt retains the
  previous selection. It can call `Set-UvCacheForCurrentVolume` after changing directory.
- The script intentionally excludes removable and RAM disks as well as network locations. This can
  be made configurable after the safety of those cases is understood.
- The volume root must permit creation of the configured relative cache path.
- `.uv\cache` is shared by users who select the same volume. On a multi-user machine, configure a
  per-user path such as `.uv\cache\$env:USERNAME` and ensure its access controls are appropriate.
- The process-level `UV_CACHE_DIR` selected by the hook takes precedence over `cache-dir` values in
  uv configuration files.
- Separate volume caches can contain duplicate packages and initially require separate downloads.
- This prototype does not change `uv cache clean`, `uv cache prune`, or cache discovery semantics.

This is an interim shell workaround, not the proposed multi-filesystem cache implementation in uv.

## Test

Run the focused test script with Windows PowerShell or PowerShell 7:

```powershell
pwsh -NoProfile -File scripts\test-uv-cache-per-volume.ps1
```
