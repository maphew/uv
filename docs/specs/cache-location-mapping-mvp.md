# Target-aware cache location mapping MVP

**Status:** Draft for maintainer review

Related issues: [#6613](https://github.com/astral-sh/uv/issues/6613),
[#10595](https://github.com/astral-sh/uv/issues/10595), and
[#15878](https://github.com/astral-sh/uv/issues/15878)

## Summary

Add an opt-in, preview configuration that selects one complete uv cache from a list of
target-path-prefix rules. The selected cache is based on the environment into which uv will install,
not the current working directory.

This MVP makes installations efficient when environments are spread across Windows volumes or Unix
filesystems. Each configured cache remains a normal, independently versioned uv cache. It does not
split the acquisition and installation portions of the cache.

## Problem

uv currently chooses one cache for an invocation before it resolves the environment targeted by the
command. A cache on the same filesystem as an environment permits hardlinks on Windows and usually
copy-on-write clones on macOS and Linux. If the cache and environment are on different filesystems,
uv falls back to copying package contents.

Users therefore choose between:

- one cache, with copies into environments on other filesystems; or
- manually selected per-filesystem caches, with shell wrappers and duplicated cache contents.

The first choice increases installation time and disk use as the number of environments grows. The
second choice is difficult to configure reliably because `cache-dir` is a scalar and shell wrappers
usually select from the current directory rather than the actual target environment.

## Goals

1. Select a cache from the path of the environment that receives installed packages.
2. Support several explicit path-prefix-to-cache mappings in uv configuration.
3. Use deterministic, component-aware longest-prefix matching on Windows and Unix.
4. Preserve all existing `--cache-dir`, `UV_CACHE_DIR`, `cache-dir`, and `--no-cache` behavior.
5. Make cache inspection and maintenance unambiguous when several caches are configured.
6. Support user and system configuration so workstation and cluster administrators can define the
   storage layout.
7. Keep every selected directory compatible with the existing `Cache` implementation, locking,
   bucket versioning, and garbage collection.

## Non-goals

- Automatically discovering a cache from a filesystem or volume identifier.
- Sharing downloaded archives, built wheels, or metadata between configured caches.
- Implementing a global acquisition cache plus per-filesystem installation stores.
- Migrating entries from an existing cache.
- Guaranteeing that a configured cache and target really reside on the same filesystem.
- Changing link-mode selection or suppressing the existing cross-filesystem fallback warning.
- Selecting a cache from the process's current directory.
- Adding a delimiter-based environment variable for a list of mappings.

The two-tier cache is the preferred long-term direction, but independent complete caches make a
smaller feature that can validate target selection and multi-cache lifecycle semantics first.

## Terminology

- **Fallback cache**: the cache selected by the existing scalar rules when no mapping is used.
- **Cache location rule**: one target prefix and its corresponding cache directory.
- **Logical target**: the environment path derived from command arguments and environment settings,
  before following symlinks and before centralized project environment redirection.
- **Selected cache**: the fallback cache or mapped cache used by the command after target resolution.
- **Configured cache set**: the fallback cache plus the de-duplicated cache directories from all
  effective rules.

## Configuration

### Proposed syntax

The setting is named `cache-location` and is an array of tables:

```toml
preview-features = ["cache-location-mapping"]

[[cache-location]]
target-prefix = "D:\\"
cache-dir = "D:\\.uv\\cache"

[[cache-location]]
target-prefix = "E:\\projects"
cache-dir = "E:\\.uv\\cache"

[[cache-location]]
target-prefix = "/scratch"
cache-dir = "/scratch/$USER/.cache/uv"
```

Environment-variable interpolation in paths is not part of this MVP. The last example is intended
for an administrator-generated user configuration or for a future interpolation feature; `$USER`
is literal in the MVP.

Both fields are required:

| Field | Meaning |
|---|---|
| `target-prefix` | Absolute logical path prefix against which the target is matched. |
| `cache-dir` | Absolute path to a complete uv cache selected by the rule. |

The setting is accepted anywhere that the global `cache-dir` setting is accepted, including user,
system, project `uv.toml`, and an explicit `--config-file`. It is not accepted under `[tool.uv]` in
`pyproject.toml`, matching the intended `uv_toml_only` treatment for storage-layout settings.

`cache-location` is gated by the `cache-location-mapping` preview feature. Configuring a rule without
enabling the feature is an error that names the required preview feature.

### Validation

Configuration loading fails if:

- either field is missing;
- either path is not absolute;
- a Windows prefix is drive-relative, such as `D:projects`;
- a Windows UNC prefix does not include both a server and share;
- two rules in the same configuration file normalize to the same target prefix; or
- the target prefix cannot be represented in the platform path syntax.

The cache directory does not need to exist. uv creates it using the existing cache initialization
path after the rule is selected.

### Configuration layering

Rules from configuration sources are combined in the same order as other list settings: rules from
the higher-precedence source appear first. A normalized prefix may appear in different sources. If
it does, the first rule wins, so project configuration overrides user configuration and user
configuration overrides system configuration for an equal prefix.

Rules with different prefix lengths still use longest-prefix matching regardless of configuration
source. A more specific system rule therefore beats a less specific project rule. This makes path
specificity the primary policy and configuration precedence the tie-breaker.

## Selection precedence

For an invocation with a target, select the cache in this order:

1. If `--no-cache` is effective, use one temporary cache for the invocation.
2. If the existing scalar cache setting is effective from `--cache-dir`, `UV_CACHE_DIR`, or
   `cache-dir`, use it and ignore `cache-location` rules.
3. Normalize the logical target and select its longest matching `target-prefix`.
4. If no rule matches, use the existing platform fallback cache.

Treating every effective scalar `cache-dir` as an override preserves current behavior and avoids
needing to retain source metadata while settings are combined. `uv --show-settings` should display
the resolved scalar override, ordered rules, logical target when present, selected rule, and selected
cache.

Commands without a target use the fallback cache. A command selects at most one cache for ordinary
work; only cache administration with `--all` intentionally visits several caches.

## Prefix matching

Matching is lexical and path-component aware:

- Convert relative command targets to absolute paths before matching.
- Remove `.` components and resolve `..` lexically without requiring the target to exist.
- Normalize directory separators for the current platform.
- Ignore redundant trailing separators except on a filesystem root.
- Compare complete path components; `/scratch/a` does not match `/scratch-old/a`.
- On Unix, compare case-sensitively.
- On Windows, compare drive letters and path components case-insensitively. Normalize `C:` to `c:`
  internally and treat `/` and `\\` as separators.
- Treat a UNC server and share as the path root. Compare both case-insensitively.
- Choose the matching rule with the greatest number of components. If normalized component counts
  are equal, choose the rule that appeared first after configuration merging.

The MVP does not call `canonicalize` and does not resolve symlinks, junctions, mount aliases, or bind
mounts. This is deliberate: targets may not exist yet, canonicalization can fail, and resolving a
link can change after selection. Users who address the same storage through more than one logical
prefix must configure each prefix. The documentation must state that matching a prefix does not
prove filesystem locality.

## Determining the logical target

Selection must happen from the path of the environment that receives package files. It must not use
the working directory merely because the final target has not yet been discovered.

| Command family | Logical target for the MVP |
|---|---|
| Project commands that sync or run | The resolved project environment path, including `UV_PROJECT_ENVIRONMENT` and `--active`. |
| `uv venv [PATH]` | The environment path that will be created. |
| `uv pip` commands against an environment | The environment root belonging to the selected interpreter, including `--python` and `VIRTUAL_ENV`. |
| `uv tool install`, `upgrade`, and `uninstall` | The tool environment that is modified. |
| Project commands that only lock, export, or inspect metadata | No target; use the fallback cache. |
| `uv build`, `uv publish`, `uv python`, `uv self`, and authentication commands | No target; use the fallback cache. |
| PEP 723 and `uvx` ephemeral environments stored inside a cache | No external target; use the fallback cache. |
| Cache administration | The explicit `--target`, `--all`, scalar override, or fallback behavior described below. |

Read-only environment commands such as `uv pip list` should resolve the same selected cache as a
write to that environment. Consistency makes diagnostics predictable even when the operation does
not populate the cache.

When `centralized-project-envs` is enabled, select from the logical project environment before the
environment is redirected into `environments-v2`. The centralized environment is then created in
the selected cache. This avoids a cache-selection cycle and gives a project on a mapped filesystem a
centralized environment in that filesystem's cache.

If a future command can write to more than one environment in one invocation, it must either reject
targets that select different caches or explicitly define multi-cache behavior. It must not silently
choose from the first target.

## Cache command behavior

### `uv cache dir`

Keep the current no-argument output unchanged: print the fallback or scalar-overridden cache as a
single path.

Add:

```console
uv cache dir --target D:\work\project\.venv
uv cache dir --all
```

- `--target PATH` prints the cache selected for that logical target.
- `--all` prints every effective cache path, one per line, with the fallback first and mapped caches
  in effective rule order.
- Paths that normalize to the same cache directory are printed once.
- `--target` and `--all` conflict.
- If a scalar cache override is effective, `--all` prints only that cache.

The one-path-per-line format remains scriptable. A later structured-output feature can expose rules
and target prefixes without blocking this MVP.

### `clean`, `prune`, and `size`

Keep no-argument behavior scoped to the fallback or scalar-overridden cache. Add the same mutually
exclusive selectors:

- `--target PATH` operates on the cache selected for that target.
- `--all` operates on every cache in the configured cache set.

For `--all`, de-duplicate cache roots, process them sequentially in displayed order, and acquire the
existing per-cache lock separately for each root. Preserve per-cache output and print a final
aggregate size where the command already reports reclaimed or occupied bytes. Stop after an error
and identify the cache that failed; completed earlier caches are not rolled back.

This conservative default prevents a new configuration rule from making `uv cache clean`
unexpectedly delete several locations.

## Proposed code shape

Names are illustrative, but the separation of policy from an initialized cache is required.

```rust
struct CacheLocation {
    target_prefix: PathBuf,
    cache_dir: PathBuf,
}

struct CachePolicy {
    no_cache: bool,
    scalar_cache_dir: Option<PathBuf>,
    locations: Vec<CacheLocation>,
}

impl CachePolicy {
    fn select(&self, target: Option<&Path>) -> io::Result<SelectedCache>;
    fn all(&self) -> io::Result<Vec<SelectedCache>>;
}
```

`SelectedCache` carries the normalized root and optional matching rule for diagnostics, and creates
the existing `uv_cache::Cache` only when the command is ready to use it.

### Configuration layer

1. Add the serializable rule type and `Option<Vec<CacheLocation>>` to `GlobalOptions` and
   `OptionsWire` in `uv-settings`.
2. Resolve both paths relative to their configuration source only if relative paths are later
   supported. For the MVP, reject relative paths and avoid implicit rebasing.
3. Rely on the current `Option<Vec<T>>` combination order, then validate duplicate normalized
   prefixes within each source and retain merged order for tie-breaking.
4. Generate `uv.schema.json` through `cargo dev generate-json-schema`.
5. Add `cache-location-mapping` to `uv-preview` and surface it in generated settings documentation.

### Runtime layer

Today `crates/uv/src/lib.rs` constructs `Cache` before command dispatch. Replace the resolved cache
value at that boundary with `CachePolicy`:

1. Construct a bootstrap cache from the existing scalar/default rules for configuration and
   workspace discovery. Early discovery must not download, build, or install artifacts.
2. Resolve configuration into `CachePolicy`.
3. During command setup, resolve the command's logical target before the first cache-writing or
   distribution operation.
4. Call `CachePolicy::select` and initialize the selected existing `Cache`.
5. If the selected root differs from the bootstrap root, discard the bootstrap `WorkspaceCache`
   exactly as the current scalar-cache change path does.
6. Pass the selected `Cache` through the existing command implementation unchanged where possible.

Target discovery should be a small command-family adapter rather than a second independent
environment resolver. Project, pip, and tool commands should expose their resolved environment path
at the point where they already determine it, then select the cache before resolution, building, or
installation begins. If interpreter discovery needs a cache, it may read the bootstrap cache, but it
must switch before acquiring or materializing package distributions.

### Cache crate

Keep `Cache::from_settings` as the constructor for one cache so internal crates and embedders do not
need multi-cache semantics. Put path-rule normalization and selection in a narrow module that can be
unit-tested independently. The CLI owns configuration precedence and command target selection;
`uv-cache` continues to own one cache root, buckets, locks, and initialization.

## Diagnostics and errors

- At `-v`, log the logical target, matched prefix, and selected cache.
- If no rule matches, log that the fallback cache was selected at debug level only.
- If a selected cache cannot be created, include both its path and the matching target prefix in the
  error context.
- Keep the existing link fallback warning. The mapping can still be wrong or point across a
  filesystem boundary.
- Do not warn merely because multiple rules resolve to the same cache; `--all` de-duplicates them.
- Include normalized duplicate prefixes and their configuration source in validation errors.

## Compatibility

- With the preview feature disabled and no `cache-location` setting, behavior and output are
  unchanged.
- Existing scalar settings override mappings, so scripts and CI jobs using `UV_CACHE_DIR` retain
  exact behavior.
- Each mapped directory has the current cache layout. It can be used directly with an older uv via
  `UV_CACHE_DIR` subject to the existing bucket-version compatibility guarantees.
- `uv cache dir` without new flags continues to emit exactly one path.
- The default scope of cache deletion remains one cache.

## Test plan

### Unit tests

- Longest-prefix selection with overlapping rules.
- Path-component boundaries (`/work` versus `/workspace`).
- Unix case sensitivity and separator handling.
- Windows drive-letter, separator, case-folding, and UNC cases using host-independent path fixtures.
- Root prefixes and trailing separators.
- Lexical `.` and `..` normalization.
- Equal-prefix precedence after configuration merging.
- De-duplication of cache roots for `--all`.
- Invalid relative, drive-relative, and incomplete UNC paths.

### Integration tests

- Parse rules from project, user, system, and explicit configuration.
- Verify higher-precedence equal-prefix rules win and more-specific lower-precedence rules still win.
- Verify `--cache-dir` and `UV_CACHE_DIR` override all mappings.
- Verify `uv cache dir`, `--target`, and `--all` output with snapshots.
- Create environments under two target prefixes and assert each command populates only its selected
  cache.
- Cover project, explicit `uv venv`, `uv pip --python`, active environment, and tool environments.
- Verify centralized project environments are created under the selected cache.
- Verify `clean`, `prune`, and `size` default, `--target`, and `--all` scopes.
- Verify paths containing spaces and non-ASCII components.
- Verify a symlinked logical prefix matches lexically rather than by its physical destination.

Most selection tests need only separate temporary directories; they do not require separate real
filesystems. Add a focused Windows CI test using two available volumes only if the runner provides
them, and keep it separate from deterministic selection coverage.

## Acceptance criteria

The MVP is complete when:

1. A user can configure at least two absolute target prefixes and caches in `uv.toml`.
2. Project, venv, pip, and tool installation paths select from their resolved environment rather
   than the current directory.
3. Overlapping mappings deterministically use the longest component-aware prefix on Windows and
   Unix.
4. Existing scalar cache overrides and no-cache mode remain authoritative.
5. `uv cache dir --target` explains selection, while `--all` exposes every effective cache.
6. Cache maintenance can explicitly address one target or all configured caches without changing
   the default deletion scope.
7. Generated schema, settings documentation, CLI reference, cache concept documentation, and
   changelog describe the preview feature and its lexical path behavior.
8. Targeted unit and integration tests pass on Windows, macOS, and Linux.

## Follow-up: two-tier cache

After the mapping MVP proves target selection, uv can avoid duplicate downloads and builds by
separating a global acquisition cache from per-filesystem installation stores:

```text
local installation store hit
    -> link into environment

global acquisition cache hit
    -> materialize once into the local store
    -> link into environment

global miss
    -> download or build into the global cache
    -> materialize into the local store
    -> link into environment
```

That design needs cross-store locking, ownership, versioning, pruning, and failure-recovery rules.
Those concerns should not be hidden inside the prefix-mapping MVP.
