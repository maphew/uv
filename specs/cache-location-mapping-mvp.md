# Target-aware cache location mapping MVP

**Status:** Draft for maintainer discussion

Related issues: [#6613](https://github.com/astral-sh/uv/issues/6613),
[#10595](https://github.com/astral-sh/uv/issues/10595), and
[#15878](https://github.com/astral-sh/uv/issues/15878).

Issue #15878 carries the `needs-design` label, and uv's contributing guide asks that no pull request
be opened for such issues. This document is therefore written to be posted into that issue or a
linked discussion for maintainer review, not to be merged into the rendered documentation. It lives
outside `docs/` so the strict documentation build does not treat it as an orphaned page.

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
- Sharing a cache between users. Every configured cache is single-user (see Security).

The two-tier cache is the preferred long-term direction, but independent complete caches make a
smaller feature that can validate target selection and multi-cache lifecycle semantics first.

## Costs and tradeoffs

Because configured caches are independent and share nothing (a non-goal above), the MVP has real
costs that the design accepts deliberately:

- **Duplicated acquisition.** A wheel needed by projects under two different rules is downloaded and
  stored once per cache. An sdist is built once per cache. N caches can hold N copies of common
  packages. The two-tier follow-up removes this duplication; the MVP does not.
- **Per-cache maintenance.** `uv cache prune` and `uv cache clean` operate on one cache root and are
  blind to the others unless `--all` is used. Administrators must prune each cache or use `--all`.
- **Consistent selection matters.** To avoid paying acquisition twice inside a single workflow,
  commands that cooperate on one project must select the same cache. The target table below
  therefore maps `uv lock` and `uv sync` for the same project to the same cache, rather than sending
  metadata-only commands to the fallback cache.

## Alternatives considered

- **Filesystem or volume-identity auto-detection.** Select a cache by querying the volume or
  filesystem identity of the nearest existing ancestor of the target. This avoids the mount-alias
  and multi-prefix limitations of lexical matching, and uv already probes filesystem behavior
  empirically at link time in `crates/uv-fs/src/link.rs`. It is rejected for the MVP, not forever:
  it requires OS calls against paths that may not exist yet, identity is unreliable on network
  filesystems, and a policy is still needed for where the cache lives on each detected volume.
  Explicit rules validate target resolution and multi-cache lifecycle first; auto-detection can
  later generate rules on top of the same selection machinery.
- **A scalar `cache-dir` in a volume-root `uv.toml`.** Configuration discovery walks parent
  directories from the working directory, not from the target environment, so this selects the wrong
  cache in exactly the cross-volume invocations the feature exists for (for example
  `uv sync --project D:\proj` run from `C:\`). A scalar also cannot express several mappings in one
  user or system configuration.
- **A delimiter-separated environment variable of mappings.** Rejected (non-goal): paths containing
  the delimiter cannot be expressed portably, and the TOML form is strictly more capable.
- **The two-tier cache first.** Described in the follow-up section; it needs cross-store locking,
  ownership, and recovery semantics that are better designed after target selection is proven.

## Terminology

- **Platform default cache**: the cache uv selects today when no `--cache-dir`, `UV_CACHE_DIR`, or
  `cache-dir` setting is effective.
- **Scalar override**: an effective `--cache-dir`, `UV_CACHE_DIR`, or `cache-dir` value from any
  configuration source.
- **Fallback cache**: the cache used when mapping applies but no rule matches. Because a scalar
  override disables mapping entirely (see Selection precedence), the fallback cache is always the
  platform default cache.
- **Cache location rule**: one target prefix and either a corresponding cache directory or an
  explicit `use-fallback` marker.
- **Logical target**: the environment path derived from command arguments and environment settings,
  before following symlinks and before centralized project environment redirection.
- **Selected cache**: the cache used by the command after target resolution.
- **Configured cache set**: when a scalar override is effective, exactly that one cache; otherwise
  the fallback cache plus the de-duplicated cache directories from all effective rules.

## Security

Mapping makes it easy to configure caches in shared locations, and uv hardlinks files from the cache
into environments. A user with write access to a cache can therefore modify code that runs in every
environment served by that cache. Two requirements follow:

- **Caches are single-user.** Each configured `cache-dir` must be a directory owned and writable by
  only the invoking user. The documentation for this feature must state the hardlink-poisoning risk
  explicitly, and the examples below use per-user paths. On multi-user workstations and clusters —
  the audience of Goal 6 — administrators must generate per-user configuration (for example with
  configuration management) rather than pointing all users at one shared directory. The MVP does not
  provide variable interpolation, so a path containing a literal `$VAR` pattern is almost certainly
  a misconfiguration; validation warns on it (see Validation).
- **Untrusted sources cannot contribute rules.** PEP 723 script metadata embeds uv's global options
  and combines at the highest precedence, so without an exclusion a downloaded script could redirect
  the user's cache to an attacker-chosen path and have uv hardlink from it. `cache-location` is
  therefore ignored in script metadata (and in `pyproject.toml`, see Configuration), with a warning
  naming the supported sources.

## Configuration

### Proposed syntax

The setting is named `cache-location` and is an array of tables:

```toml
preview-features = ["cache-location-mapping"]

[[cache-location]]
target-prefix = "D:\\"
cache-dir = "D:\\uv-cache"

[[cache-location]]
target-prefix = "E:\\projects"
cache-dir = "E:\\uv-cache"
```

A per-user Unix example, written into one user's configuration:

```toml
[[cache-location]]
target-prefix = "/scratch/alice"
cache-dir = "/scratch/alice/.cache/uv"
```

Environment-variable interpolation in paths is not part of this MVP. Administrators who need
per-user paths on shared storage must template per-user configuration files; a literal
`/scratch/$USER/...` value would create a single shared directory named `$USER` and is warned about
during validation.

Each rule contains exactly one of `cache-dir` or `use-fallback`:

| Field           | Meaning                                                                       |
| --------------- | ----------------------------------------------------------------------------- |
| `target-prefix` | Absolute logical path prefix against which the target is matched.             |
| `cache-dir`     | Absolute path to a complete uv cache selected by the rule.                    |
| `use-fallback`  | `true` maps the prefix back to the fallback cache, overriding a broader rule. |

`use-fallback` exists so a higher-precedence source can opt a subtree out of an inherited rule. For
example, if system configuration maps `/scratch` to a shared location, a user can map
`/scratch/alice/experiments` back to their default cache without hardcoding the platform default
path. Because merging is additive (see Configuration layering), there is otherwise no way to express
"no mapping" for a subtree.

### Accepted sources

The setting is read from user configuration, system configuration, project `uv.toml`, and an
explicit `--config-file`. It is not honored from `[tool.uv]` in `pyproject.toml` or from PEP 723
script metadata.

This exclusion needs explicit enforcement, and the spec must be honest about the starting point:
today uv deserializes the full options schema from `[tool.uv]` without rejecting storage-layout
settings, and `cache-dir` from that source is honored — the `uv_toml_only` marker currently affects
documentation rendering only. The MVP therefore adds a post-deserialization filter for options
originating from `pyproject.toml` and script sources: a `cache-location` value from those sources is
dropped and a warning names the supported sources. A test pins the warning and the dropped value.

### Preview gating

`cache-location` is gated by the `cache-location-mapping` preview feature. Preview flags resolve
after all configuration sources are combined, so configured rules cannot be rejected during parsing,
and a hard error after merging would break every uv invocation for users who have not opted in the
moment an administrator deploys system-wide rules — the opposite of a gradual rollout. When rules
are configured but the preview feature is not enabled, uv warns once per invocation, naming the
required feature, and ignores the rules. This matches the warn-or-ignore behavior of existing
preview-gated settings.

### Validation

Configuration loading fails if:

- `target-prefix` is missing, or neither `cache-dir` nor `use-fallback = true` is present;
- both `cache-dir` and `use-fallback` are present;
- either path is not absolute;
- a Windows prefix is drive-relative, such as `D:projects`;
- a Windows UNC prefix does not include both a server and share;
- lexical `..` resolution would escape the path's root (matching the behavior of uv's existing
  absolute-path normalization, which rejects such paths);
- two rules in the same configuration file normalize to the same target prefix; or
- the target prefix cannot be represented in the platform path syntax.

Validation warns, without failing, if a path contains a `$VAR`-style pattern, naming the missing
interpolation feature (see Security).

The cache directory does not need to exist. uv creates it using the existing cache initialization
path after the rule is selected.

### Configuration layering

Rules from configuration sources are combined in the same order as other list settings: rules from
the higher-precedence source appear first. A normalized prefix may appear in different sources. If
it does, the first rule wins, so project configuration overrides user configuration and user
configuration overrides system configuration for an equal prefix.

Rules with different prefix lengths still use longest-prefix matching regardless of configuration
source. A more specific system rule therefore beats a less specific project rule. This makes path
specificity the primary policy and configuration precedence the tie-breaker. To override a broader
inherited rule for a subtree, a source declares a more specific rule — with `cache-dir` for a
different cache, or `use-fallback` for none.

An empty `cache-location = []` contributes no rules and does not mask lower-precedence sources;
masking is expressed per prefix with `use-fallback` or an equal-prefix re-declaration.

Two scoping behaviors of uv's existing configuration loading apply to rules unchanged and must be
documented and tested, because they surprise exactly this feature's audience:

- An explicit `--config-file` replaces discovered configuration entirely; project, user, and system
  rules do not merge beneath it. A CI job that passes `--config-file` therefore does not see an
  administrator's system rules.
- `uv tool` and `uv self` load only user and system configuration, so project-source rules never
  apply to tool environments. User- and system-source rules do.

## Selection precedence

For an invocation, select the cache in this order:

1. If `--no-cache` is effective, use one temporary cache for the invocation.
2. If a scalar override is effective from `--cache-dir`, `UV_CACHE_DIR`, or `cache-dir`, use it and
   ignore `cache-location` rules. If rules are configured, warn once per invocation that they are
   shadowed, naming the override's source. Without this warning the feature silently appears broken
   to its primary audience, since most users affected by the underlying issues already set
   `UV_CACHE_DIR` or `cache-dir` as today's workaround.
3. If the logical target lies inside a cache directory of the configured cache set — for example a
   centralized project environment or ephemeral environment that resides in a mapped cache — select
   that containing cache. This keeps every command that addresses an environment consistent with the
   command that created it, even when another rule's prefix also covers the cache's location.
4. Normalize the logical target and select its longest matching `target-prefix`. A matching
   `use-fallback` rule selects the fallback cache.
5. If no rule matches, use the fallback cache.

Commands without a logical target use the fallback cache. A command selects at most one cache for
ordinary work; only cache administration with `--all` intentionally visits several caches.

`uv --show-settings` should display the resolved scalar override, ordered rules with their sources,
the logical target when present, the selected rule, and the selected cache.

## Prefix matching

Matching is lexical and path-component aware:

- Match the absolute path that uv's existing resolution produced for the target. The mapping layer
  never resolves a relative path against the working directory itself, because different settings
  use different bases today — a relative `UV_PROJECT_ENVIRONMENT` resolves against the workspace
  root, while a relative `VIRTUAL_ENV` resolves against the working directory — and re-resolving
  would reintroduce the working-directory dependence this feature exists to remove.
- On Windows, strip verbatim prefixes before matching, on both rules and targets: `\\?\C:\...`
  becomes `C:\...` and `\\?\UNC\server\share\...` becomes `\\server\share\...`. This is required,
  not cosmetic: uv's own canonicalization produces verbatim environment roots (for example in the
  centralized-environments flow), and without stripping, no rule would ever match them.
- On Windows, absolutize a drive-relative target such as `D:file` using that drive's current
  directory, per platform semantics, before matching. Drive-relative rule prefixes remain rejected.
- Remove `.` components and resolve `..` lexically without requiring the target to exist. `..` that
  would escape the root is a normalization error.
- Normalize directory separators for the current platform.
- Ignore redundant trailing separators except on a filesystem root.
- Compare complete path components; `/scratch/a` does not match `/scratch-old/a`.
- On Unix, compare bytes exactly. Note that macOS APFS volumes are case-insensitive by default, so
  two spellings of one directory can select different rules there; users must configure the spelling
  uv's target resolution produces. This is a documented limitation of lexical matching.
- On Windows, compare drive letters and path components case-insensitively. Normalize `C:` to `c:`
  internally and treat `/` and `\\` as separators.
- Treat a UNC server and share as the path root. Compare both case-insensitively.
- Choose the matching rule whose normalized prefix has the greatest number of components after its
  root; the root itself — `/`, a drive root such as `D:\`, or a UNC `\\server\share` — counts as
  zero. Two distinct prefixes that both match one target cannot have equal counts, so no further
  tie-break is needed; an identical normalized prefix appearing in several sources was already
  reduced to one rule by configuration layering.

The MVP does not call `canonicalize` and does not resolve symlinks, junctions, mount aliases, or
bind mounts. This is deliberate: targets may not exist yet, canonicalization can fail, and resolving
a link can change after selection. Users who address the same storage through more than one logical
prefix must configure each prefix. Documented consequences of this stance:

- Matching a prefix does not prove filesystem locality; the existing link-mode fallback still
  governs what happens at install time.
- Lexical `..` through a symlinked directory can select a cache for a different physical location
  than the one files land on.
- A Windows path expressed with DOS 8.3 short names (as an interpreter's `sys.prefix` sometimes is)
  does not match a long-name rule. Best-effort long-name expansion for paths that exist is a
  candidate follow-up, not part of the MVP.

## Determining the logical target

Selection must happen from the path of the environment that receives package files. It must not use
the working directory merely because the final target has not yet been discovered.

| Command family                                                                | Logical target for the MVP                                                                                                                                                                                                 |
| ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Project commands that sync or run                                             | The resolved project environment path, including `UV_PROJECT_ENVIRONMENT` and `--active`.                                                                                                                                  |
| Project commands that lock, export, or inspect metadata                       | The same resolved project environment path, even though they do not write to it, so `uv lock` and `uv sync` for one project populate one cache instead of paying acquisition twice.                                        |
| `uv venv [PATH]`                                                              | The environment path that will be created.                                                                                                                                                                                 |
| `uv pip` commands against an environment                                      | The environment root belonging to the selected interpreter, including `--python` and `VIRTUAL_ENV` — unless `--target DIR` or `--prefix DIR` is given, in which case that directory is the logical target.                 |
| `uv tool install`, `upgrade`, and `uninstall`                                 | The tool environment that is modified (project-source rules never apply here; see layering).                                                                                                                               |
| PEP 723 scripts and `uvx` ephemeral environments                              | The external environment when one is honored (for example `--active` with an active virtual environment); otherwise no external target: the fallback cache is selected and the ephemeral environment is created inside it. |
| `uv build`, `uv publish`, `uv python`, `uv self`, and authentication commands | No target; use the fallback cache.                                                                                                                                                                                         |
| Cache administration                                                          | The explicit `--for`, `--all`, scalar override, or fallback behavior described below.                                                                                                                                      |

Flag-dependent cases the table's rows must not leave ambiguous:

- **Dispatch order for `uv run`.** Whether an invocation is a project run or a PEP 723 script run is
  decided exactly where uv decides it today — after reading the script's inline metadata, before any
  distribution is acquired. A script with inline metadata gets the script row even when invoked
  inside a project directory; a project run gets the project row.
- **`uv run --active`.** When the command honors an active virtual environment — including for a PEP
  723 script — that environment is the logical target, not the fallback cache.
- **`uv run --with`.** The invocation still selects exactly one cache, from the project environment
  (or script rule) as above; the `--with` overlay environment is cache-resident and is created
  inside that selected cache. Selection precedence rule 3 then keeps later commands that address the
  overlay consistent.

Read-only environment commands such as `uv pip list` resolve the same selected cache as a write to
that environment. Consistency makes diagnostics predictable even when the operation does not
populate the cache.

If a future command can write to more than one environment in one invocation, it must either reject
targets that select different caches or explicitly define multi-cache behavior. It must not silently
choose from the first target.

### Centralized project environments

When `centralized-project-envs` is enabled, select from the logical project environment before the
environment is redirected into `environments-v2`. The centralized environment is then created in the
selected cache. This avoids a cache-selection cycle and gives a project on a mapped filesystem a
centralized environment in that filesystem's cache.

Centralized environments living in mapped caches make lifecycle rules load-bearing, and the MVP must
define them rather than inherit single-cache assumptions:

- **Classification checks span the cache set.** uv decides whether an environment path is a
  centralized environment (and may replace paths that are not) by testing it against a cache root.
  With mapping, those checks must test membership against every cache in the configured cache set,
  not only the current command's selected cache — otherwise a command that selected a different
  cache misclassifies a mapped-cache environment as foreign and can destroy it. Selection precedence
  rule 3 keeps commands addressing such an environment inside its home cache, and the classification
  code must be equally set-aware.
- **Destructive commands say what they will do.** `uv cache prune` and `uv cache clean` remove the
  environments bucket today; that is unchanged per cache, since centralized environments are
  rebuildable state. But with `--all` this now removes every live centralized environment in every
  configured cache, so `--all` output must list each cache root before processing it, and the
  feature documentation must state that pruning removes centralized environments, which are rebuilt
  on the next sync.
- **Removing a rule orphans its cache.** uv never deletes a cache that configuration no longer
  references, and `--all` reflects only current configuration, so a removed rule's cache — with any
  centralized environments inside it — simply stops being visible to cache commands, while `.venv`
  redirections into it keep working. The documentation must describe decommissioning: re-sync the
  affected projects (recreating their environments in the newly selected cache), then point
  `UV_CACHE_DIR` at the old root to clean it, and remove the directory.

## Cache command behavior

Cache commands gain a selector flag named `--for PATH`, not `--target PATH`: `uv pip install`
already uses `--target` for an install destination, and reusing the name with the inverse meaning
("which cache serves this destination") invites confusion between the two.

### `uv cache dir`

Keep the current no-argument output unchanged: print the scalar override or fallback cache as a
single path.

Add:

```console
uv cache dir --for D:\work\project\.venv
uv cache dir --all
```

- `--for PATH` prints the cache selected for that logical target.
- `--all` prints every cache in the configured cache set, one per line, with the fallback cache
  first and mapped caches in effective rule order.
- Paths that normalize to the same cache directory are printed once.
- `--for` and `--all` conflict, and both conflict with `--no-cache`.
- If a scalar override is effective, the configured cache set is exactly that cache, so `--all`
  prints only it, with the rule-shadowing warning from Selection precedence on stderr.

The one-path-per-line format remains scriptable. A later structured-output feature can expose rules
and target prefixes without blocking this MVP.

### `clean`, `prune`, and `size`

Keep no-argument behavior scoped to the scalar override or fallback cache. Add the same mutually
exclusive selectors, with `--all` scoped to the configured cache set exactly as for `uv cache dir` —
in particular, a scalar override reduces `--all` to that single cache for every cache command, so no
command's `--all` reaches caches that selection would never use:

- `--for PATH` operates on the cache selected for that target.
- `--all` operates on every cache in the configured cache set.
- `uv cache clean PACKAGE...` combines with either selector: the named packages are removed from the
  selected cache, or from every cache in the set with `--all`.
- Existing per-command flags keep their current meaning within each cache.

For `--all`, de-duplicate cache roots, print each root before processing it, process the roots
sequentially in displayed order, and acquire the existing per-cache lock separately for each root
(`uv cache size` remains lockless, as today). Preserve per-cache output; where a command reports
reclaimed or occupied bytes, label each cache's figure with its root and print a final aggregate,
since today's single unlabeled number is ambiguous across several caches. Stop after an error and
identify the cache that failed; completed earlier caches are not rolled back.

This conservative default prevents a new configuration rule from making `uv cache clean`
unexpectedly delete several locations.

## Proposed code shape

Names are illustrative, but the separation of policy from an initialized cache is required.

```rust
struct CacheLocation {
    target_prefix: PathBuf,
    /// `None` expresses `use-fallback = true`.
    cache_dir: Option<PathBuf>,
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
   prefixes within each source and retain merged order for equal-prefix precedence.
4. Filter `cache-location` out of options originating from `pyproject.toml` `[tool.uv]` and PEP 723
   script metadata, with the warning described under Accepted sources. This is new machinery: no
   per-field source filtering exists today.
5. Generate `uv.schema.json` through `cargo dev generate-json-schema`.
6. Add `cache-location-mapping` to `uv-preview` and surface it in the generated preview and settings
   documentation.

### Runtime layer

Today `crates/uv/src/lib.rs` constructs and initializes `Cache` inside each of the several dozen
command dispatch arms, and `Cache` is threaded through the command function signatures from there.
Replacing that boundary with `CachePolicy` is a wide, mostly mechanical refactor of command entry
points — the spec states this plainly so the MVP is not estimated as a small adapter:

1. Construct a bootstrap cache from the existing scalar/default rules. It serves the pre-dispatch
   consumers that need a concrete cache root before any target can be known: configuration and
   workspace discovery, the project-inside-cache guard, and `WorkspaceCache` invalidation. Guard
   checks that ran against the bootstrap root are re-evaluated against the selected root after
   selection. Early discovery must not download, build, or install artifacts.
2. Resolve configuration into `CachePolicy` and pass it, not a `Cache`, into command dispatch.
3. During command setup, resolve the command's logical target, then select and initialize the
   `Cache` before acquiring or materializing package distributions. Selection cannot happen before
   the first cache access of any kind: interpreter discovery both reads and writes interpreter
   metadata, and managed-interpreter staging can occur, before a pip command's target — which is
   defined by the discovered interpreter — even exists. Those interpreter-discovery accesses go to
   the bootstrap cache and are exempt from the "populates only its selected cache" property, which
   is scoped to distribution acquisition and installation buckets.
4. If the selected root differs from the bootstrap root, discard the bootstrap `WorkspaceCache`
   exactly as the current scalar-cache change path does.
5. Pass the selected `Cache` through the existing command implementation unchanged from that point
   on.

Target discovery should be a small per-command-family adapter rather than a second independent
environment resolver: project, pip, and tool commands expose their resolved environment path at the
point where they already determine it. To bound the first change, the MVP may land in phases —
project, venv, pip, and tool families selecting by target first, with all remaining families routed
to the fallback cache through a shim that preserves today's behavior exactly.

### Cache crate

Keep `Cache::from_settings` as the constructor for one cache so internal crates and embedders do not
need multi-cache semantics. Put path-rule normalization and selection in a narrow module that can be
unit-tested independently. The CLI owns configuration precedence and command target selection;
`uv-cache` continues to own one cache root, buckets, locks, and initialization.

## Diagnostics and errors

- At `-v`, log the logical target, matched prefix with its configuration source, and selected cache.
- If no rule matches, log that the fallback cache was selected at debug level only.
- If rules are configured but shadowed by a scalar override, warn once per invocation, naming the
  override's source (see Selection precedence).
- If rules are configured but the preview feature is disabled, warn once per invocation, naming the
  feature (see Preview gating).
- If a rule comes from an unsupported source (`pyproject.toml`, script metadata), warn and ignore it
  (see Accepted sources).
- If a selected cache cannot be created, include both its path and the matching target prefix in the
  error context.
- Keep the existing link fallback warning, and when a mapped cache was selected, extend it to name
  the matched `target-prefix` so users can correct the rule rather than guess why linking degraded.
- Do not warn merely because multiple rules resolve to the same cache; `--all` de-duplicates them.
- Include normalized duplicate prefixes and their configuration source in validation errors.

## Compatibility

- With the preview feature disabled and no `cache-location` setting, behavior and output are
  unchanged.
- Existing scalar settings override mappings, so scripts and CI jobs using `UV_CACHE_DIR` retain
  their exact cache behavior; the only observable difference is the stderr shadowing warning when
  rules are also configured.
- Each mapped directory has the current cache layout. It can be used directly with an older uv via
  `UV_CACHE_DIR` subject to the existing bucket-version compatibility guarantees.
- `uv cache dir` without new flags continues to emit exactly one path.
- The default scope of cache deletion remains one cache.

## Test plan

### Unit tests

- Longest-prefix selection with overlapping rules, including root prefixes, and component counting
  for drive roots and UNC roots.
- Path-component boundaries (`/work` versus `/workspace`).
- Unix byte-wise comparison and separator handling.
- Windows drive-letter, separator, case-folding, verbatim-prefix stripping, drive-relative target
  absolutization, and UNC cases using host-independent path fixtures.
- Root prefixes and trailing separators.
- Lexical `.` and `..` normalization, and the `..`-escapes-root error.
- `use-fallback` rules overriding broader mapped rules.
- Equal-prefix precedence after configuration merging.
- De-duplication of cache roots for `--all`.
- Invalid relative, drive-relative, and incomplete UNC paths; rules with both or neither of
  `cache-dir` and `use-fallback`; the `$VAR` pattern warning.

### Integration tests

- Parse rules from project, user, system, and explicit configuration, and verify `--config-file`
  replaces rather than merges with discovered sources.
- Verify `[tool.uv]` in `pyproject.toml` and PEP 723 script metadata rules are ignored with the
  warning, via snapshots.
- Verify the preview-disabled warn-and-ignore behavior via snapshots.
- Verify higher-precedence equal-prefix rules win and more-specific lower-precedence rules still
  win.
- Verify `--cache-dir` and `UV_CACHE_DIR` override all mappings and produce the shadowing warning.
- Verify `uv cache dir`, `--for`, and `--all` output with snapshots, including the scalar-override
  single-path case.
- Verify `--show-settings` displays the resolved policy.
- Create environments under two target prefixes and assert each command populates only its selected
  cache's distribution buckets (interpreter-discovery writes to the bootstrap cache are exempt; see
  Runtime layer).
- Cover project, explicit `uv venv`, `uv pip --python`, `uv pip install --target` and `--prefix`,
  active environment, and tool environments.
- Verify `uv lock` and `uv sync` for one project select the same cache.
- Verify a `uv run --with` overlay is created inside the selected cache, and that a follow-up
  command addressing an environment inside a mapped cache selects that cache (selection precedence
  rule 3).
- Verify centralized project environments are created under the selected cache and survive commands
  that select a different cache.
- Verify `clean`, `prune`, and `size` default, `--for`, and `--all` scopes, `clean PACKAGE --all`,
  the `--no-cache` conflicts, and the labeled per-cache `size --all` output.
- Verify paths containing spaces and non-ASCII components.
- Verify a symlinked logical prefix matches lexically rather than by its physical destination.
- Verify validation-error and warning messages via snapshots.

Most selection tests need only separate temporary directories; they do not require separate real
filesystems. For real multi-volume coverage, Windows CI already provisions a Dev Drive and an SMB
share through the `UV_INTERNAL__TEST_ALT_FS` and `UV_INTERNAL__TEST_SMB_FS` plumbing; add a focused
cross-volume test on that infrastructure rather than gating on runner luck, and keep it separate
from the deterministic selection coverage.

## Acceptance criteria

The MVP is complete when:

1. A user can configure at least two absolute target prefixes and caches in `uv.toml`.
2. Project, venv, pip, and tool installation paths select from their resolved environment rather
   than the current directory.
3. Overlapping mappings deterministically use the longest component-aware prefix on Windows and
   Unix, and `use-fallback` opts a subtree out of an inherited rule.
4. Existing scalar cache overrides and no-cache mode remain authoritative, and shadowed rules
   produce the warning.
5. `uv cache dir --for` explains selection, while `--all` exposes every cache in the configured
   cache set.
6. Cache maintenance can explicitly address one target or all configured caches without changing the
   default deletion scope.
7. The generated schema, settings documentation, preview features reference, CLI reference, and
   cache concept documentation describe the feature and its lexical path behavior; the changelog
   entry follows the project's automated release process.
8. The shadowing, preview-disabled, and unsupported-source warnings exist and are covered by
   snapshot tests.
9. Targeted unit and integration tests pass on Windows, macOS, and Linux.

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
