# Shareable Windows x64 MSVC build

This folder contains the automated build for the patched Codex CLI and the zip
bundle you can hand to someone else. It is written for GitHub Actions, but the
same script runs on any Windows machine.

If you have never used GitHub Actions: a **workflow** is a recipe that GitHub
runs on a computer it lends you. You start it by hand from the repository's
**Actions** tab. Nothing in this folder runs by itself.

## What the workflow does

The workflow file is `.github/workflows/build-windows-msvc.yml` (that exact
name is the one referenced from this document and by the release checks).
It runs only when a person starts it.
It is `workflow_dispatch` only: no push, pull request, schedule or release can
trigger it, and it asks for read-only permission on the repository. It never
publishes a release, so it cannot change anything on GitHub.

Each run:

1. Sets the runner's git to allow long paths (before checkout, because the
   upstream tree has very deep folders that Windows refuses otherwise).
2. Checks out this repository with `actions/checkout` pinned to a commit SHA.
3. Runs `build/tests/Test-BuildScripts.ps1`, which refuses to continue if any
   pinned digest, the patch or the workflow shape has drifted.
4. Runs `build/Build-NativeRuntime.ps1`, which does the real work.
5. Uploads the finished zip as a build artifact.

Everything the build needs is pinned in [pins.json](pins.json): the upstream
commit, the patch digest, the Rust version, the nextest version and the SHA256
of every downloaded file.

## Starting a run

In the repository: **Actions** -> **build-windows-msvc** -> **Run workflow**.

Inputs:

| Input | Default | What it means |
| --- | --- | --- |
| `profile` | `dev-small` | Cargo profile, see the trade-off below. |
| `run_tests` | `true` | Run the focused `codex-core` role tests. |
| `run_integration_tests` | `false` | Also run the multi-agent integration tests. |
| `work_root` | `C:\build` | Where the build goes on the runner. |
| `retention_days` | `7` | How long the artifact is kept. |

When it finishes, download the artifact from the run page. The zip is also
listed with its SHA256 in the run's summary.

## The profile trade-off

The upstream `release` profile uses thin LTO, four codegen units and keeps
symbols. On a four-core GitHub-hosted runner that is the slowest option by a
wide margin, and a full debug build of this workspace has been measured at
roughly 200 GiB of logical disk. The default here is deliberately cheaper:

| Profile | Settings | Trade-off |
| --- | --- | --- |
| `dev-small` (default) | `opt-level = 0`, `debug = none`, `strip = symbols` | Fastest and smallest CI run. The binary is unoptimized and slower to execute than a release build, and has no debug info. |
| `dev` | upstream `debug = "limited"`, forced to `debug = 0` by this script | Slightly heavier than `dev-small`; still unoptimized. |
| `release` | `lto = "thin"`, `codegen-units = 4`, `debug = line-tables-only`, symbols kept | Optimized and faster at runtime, much slower to build and much larger. Use it when the extra minutes and disk are worth it. |

Incremental compilation is switched off in every profile, and the job asks for
at least 45 GiB of free disk before it starts. The `dev-small` profile is
defined upstream in `codex-rs/Cargo.toml` at the pinned commit.

**The MSVC path is new and unvalidated.** The earlier build of this project was
tested locally with the GNU toolchain (`x86_64-pc-windows-gnu`). This workflow
builds `x86_64-pc-windows-msvc` instead, which had never been run for this
patch when the workflow was written. Treat the first run as the validation
attempt, not as a promised success. If it fails, the failure is real evidence
about the MSVC path; the log will say which step.

## What ends up in the zip

| File | Where it comes from |
| --- | --- |
| `codex.exe` | Built here from source, patched, path-remapped. |
| `codex-code-mode-host.exe` | Official `openai/codex` `rust-v0.153.4` release asset, SHA256 verified. |
| `codex-command-runner.exe` | Same source, SHA256 verified. |
| `codex-windows-sandbox-setup.exe` | Same source, SHA256 verified. |
| `LICENSE`, `NOTICE.txt` | Apache-2.0 license text and the upstream notice from this repository. |
| `PROVENANCE.txt` | Commit, tag, patch digest, toolchain, profile, remap pairs, per-file digests. |
| `runtime-manifest.json` | Machine-readable version and SHA256 of the four runtime executables, plus the patched commit and patch digest. |
| `source/codex-native-provider.patch` | The exact patch used for this build. |
| `SHA256SUMS.txt` | SHA256 of every other file in the bundle. |

A release bundle never contains `build-receipt.json`. That file is build state and
stays in the work root under `state/`.

The three companion executables are copied from the official release, not
rebuilt, and are renamed to drop the target suffix. Nothing is copied from a
local Codex installation, and the bundle contains no user configuration, no
model settings and no credentials.

## The runtime manifest

`runtime-manifest.json` sits next to `codex.exe` and is the file the installer
picks up automatically. Its schema is set by the installer in
`scripts/DeepSeekNative.Common.ps1` (`Test-DseRuntimeManifest`) and the name
comes from `config/defaults.json` (`runtimeManifestFileName`). The build writes
the object form:

```json
{
  "schemaVersion": 1,
  "product": "codex-deepseek-native",
  "kind": "source-build",
  "version": "0.153.4",
  "builtAtUtc": "2026-01-01T00:00:00Z",
  "bundleName": "codex-native-deepseek-0.153.4-windows-x86_64-msvc",
  "buildProfile": "dev-small",
  "toolchain": "1.95.0-x86_64-pc-windows-msvc",
  "source": {
    "repositoryUrl": "https://github.com/openai/codex.git",
    "tag": "rust-v0.153.4",
    "commit": "<the patched upstream commit>",
    "patchPath": "source/codex-native-provider.patch",
    "patchSha256": "<digest of the patch used>",
    "codexExeSha256": "<digest of the built codex.exe>"
  },
  "files": {
    "codex.exe": "<sha256>",
    "codex-command-runner.exe": "<sha256>",
    "codex-windows-sandbox-setup.exe": "<sha256>",
    "codex-code-mode-host.exe": "<sha256>"
  }
}
```

The installer reads `version` and `files`. Everything else is provenance it
ignores. Two details matter for keeping verification green:

`files` lists only the four runtime executables. The installer hashes each name
it finds in the manifest, so listing `LICENSE`, `NOTICE.txt`, `PROVENANCE.txt`,
`SHA256SUMS.txt` or `source/` would make a user who keeps only the executables
fail verification for the wrong reason. Extra files that are *not* listed are
harmless.

The manifest never lists itself, for the obvious reason that it cannot contain
its own hash. Its own hash is recorded in `SHA256SUMS.txt` instead.

`build/tests/Test-BuildScripts.ps1` proves this end to end: it generates a
manifest for a fixture runtime directory, runs the installer's own
`Test-DseRuntimeManifest` against it, checks that the commit and patch digest
survive the round trip, checks that extra bundle files do not break it, and
checks that a tampered executable does fail it.

## Path remapping

A binary normally remembers the folder it was built in. That is how a leaked
`C:\Users\<name>\...` string ends up in a shared file. This build passes
`--remap-path-prefix` for the checkout, the cargo home, the rustup home, the
target directory and the builder repository, all pointing at neutral `C:/build`
prefixes. After staging, the script scans `codex.exe` for the real build root,
the builder checkout and the user profile directory, and **refuses to publish
the bundle** if any of them are still present.

The scan reads the binary as raw bytes and looks for both plain and
UTF-16 text, so it catches wide strings too. It is a safety net, not a proof;
the `PROVENANCE.txt` remap list is the record of what was rewritten.

## Offline versus downloads

The build needs two things from the network: the cargo registry (crates the
upstream workspace depends on) and the pinned downloads.

| Download | When | Pinned by |
| --- | --- | --- |
| Rust `1.95.0-x86_64-pc-windows-msvc` | every run, via `rustup` | `toolchain.rustupToolchain` in `pins.json` |
| Crates from crates.io | every uncached run | `codex-rs/Cargo.lock` at the pinned commit, plus `--locked` |
| `cargo-nextest 0.9.144` zip | only when tests run | URL and SHA256 in `pins.json` |
| Three official `.exe` assets | every run | `verification/official-downloads.json`, SHA256 checked |
| `openai/codex` source at one commit | every run | tag object and commit SHA in `pins.json` |

`--offline` mode is supported and is meant for a runner where those things
already exist: pass `-Offline` to the script and it will not download anything,
will skip the tag check against the remote, and will fail with a clear message
if a required file is missing. With `Offline`, the source must already be at
the pinned commit under the work root, and the cargo registry cache must
already be populated.

The workflow does not use `--offline`, because a GitHub-hosted runner starts
empty each time.

## Credentials

No registry-based authentication is used or needed. Before building, the
script:

- refuses to run if the cargo home contains `credentials.toml` or
  `credentials`, and
- clears any `CARGO_REGISTRY_TOKEN`, `CARGO_REGISTRIES_CRATES_IO_TOKEN`,
  `CARGO_REGISTRIES_CRATES_IO_SECRET_KEY`, `CARGO_HTTP_TOKEN` or
  `RUSTUP_TOKEN` from the process environment.

The workflow itself reads no repository secrets, so no token is available to
the build in the first place.

## Disk and cleanup

The script creates a folder per purpose under the work root (`src`, `cargo`,
`rustup`, `target`, `tools`, `downloads`, `patches`, `stage`, `dist`, `tmp`).
Every recursive delete it performs is checked to be inside the work root, and
it refuses to use a drive root, a folder inside the repository, the user
profile itself, or anything under `Program Files` or `Windows` as the work
root.

`-PruneBuildOutputs` deletes the cargo `target` directory after a successful
package. It is off by default, because that directory is what makes a second
run incremental.

## Running it on your own Windows machine

```powershell
pwsh -File build/tests/Test-BuildScripts.ps1          # read-only checks
pwsh -File build/Build-NativeRuntime.ps1 -DryRun      # show the plan
pwsh -File build/Build-NativeRuntime.ps1 -WorkRoot C:\build
```

Useful switches: `-Profile`, `-SkipTests`, `-SkipBuild` (reuse an existing
binary), `-SkipPackage`, `-Offline`, `-MinimumFreeGiB`, `-Jobs`,
`-PruneBuildOutputs`.

The script requires `git` and `rustup` on `PATH`. It installs the Rust
toolchain into its own `RUSTUP_HOME` and `CARGO_HOME` **inside the work root**,
so it never changes the machine-wide default Rust.

## Tests

The patch changes `codex-core`, so the focused tests run with `cargo-nextest`,
which is what the upstream `just test` target uses. `cargo test` is not used.

Default selection:

| Scope | Filter | Declared in |
| --- | --- | --- |
| Unit tests (`--lib`) | `agent::role::tests` | `codex-rs/core/src/agent/role.rs` (`#[path = "role_tests.rs"] mod tests;`) |
| Unit tests (`--lib`) | `tools::handlers::multi_agents::tests` | `codex-rs/core/src/tools/handlers/multi_agents.rs` (`#[path = "multi_agents_tests.rs"] mod tests;`) |

With `run_integration_tests`:

| Scope | Filter |
| --- | --- |
| Integration tests (`--test all`) | `suite::multi_agent_resume` |
| Integration tests (`--test all`) | `suite::subagent_notifications` |

Integration tests are opt-in because they spawn processes and are the slow part
of the run. The full workspace suite is deliberately not run: it is known to
have unrelated failures and timeouts, and it would multiply the disk and time
cost. `NEXTEST_PROFILE=local` and `RUST_MIN_STACK=8388608` match the repository's
own test target.

These filters are **compiled module paths**, not file names. `role_tests.rs` and
`multi_agents_tests.rs` are file names; a filter written that way matches zero
tests, and a green run would prove nothing. Three things guard against that:

- The run passes `-E` with `test(<module path>)` predicates, so the match is
  against the compiled test name.
- The run passes `--no-tests fail`, so a filter that matches nothing makes the
  step fail instead of passing quietly. (`--no-tests` accepts
  `auto`, `pass`, `warn`, `fail`.)
- Before calling nextest, the build script resolves each filter against the
  checked-out source and fails with a specific message if a segment is not a
  module declared by its parent. That turns a stale filter into a clear error
  rather than an empty run.

`--test-threads 2` keeps Windows test-subprocess contention down on a four-core
hosted runner.

No test in this selection calls a live model or needs an API key. The tests use
local fixtures and loopback endpoints.

## Build receipt: what stops a fake package

Only a real compile may produce a bundle that looks like a release. The build
step writes `state/build-receipt.json` **only after** `cargo build` exits zero
and the executable is found, and packaging refuses to run without a receipt
whose contents match the current run:

| Receipt field | Checked against |
| --- | --- |
| `sourceCommit` | the pinned upstream commit |
| `patchSha256` | the digest of the patch that was applied |
| `profile`, `toolchain`, `targetTriple` | the current run's plan |
| `binarySha256` | the executable about to be packaged, hashed again now |

So a codex.exe left over from another run, a different profile or a different
patch cannot be packaged silently. `-SkipBuild` therefore fails at the packaging
step unless a matching receipt already exists from an earlier successful build.

The embedded-path scan is also fail-closed: if the binary is larger than the
400 MiB scan limit, the scan does not run and **packaging fails** rather than
shipping unscanned bytes with a privacy claim attached. The `dev-small` profile
keeps the binary far below that limit.

### Fixture route

`-FixtureBinary <path>` exercises the packaging pipeline without compiling. It
writes a receipt marked `"kind": "fixture"` and `"publishable": false`, appends
`-fixture` to the bundle name, and records `kind: "fixture"` and
`publishable: false` in `runtime-manifest.json`. A fixture bundle is obvious in
its own file name and cannot pass as a release. `Test-BuildScripts.ps1
-IncludeFixtureRun` asserts all of that, and asserts that a `-SkipBuild` run
without a receipt fails.

Do not confuse a fixture bundle with a real one: it contains whatever executable
was passed in, not a compiled Codex.

## Refreshing the pins

When the patch, the upstream commit or a downloaded tool changes, update
`build/pins.json` deliberately and re-run `Test-BuildScripts.ps1`. It will tell
you exactly which digest or file list no longer matches. The patch digest is
computed over the normalized text (UTF-8 without BOM, LF line endings, one
trailing newline), so it is stable on a Windows checkout, which may rewrite
line endings.

## What this folder does not do

- It does not publish releases. A release job would need a separate workflow
  with `contents: write`, and the initial artifact does not need one.
- It does not build GCC, w64devkit or the GNU target.
- It does not build the code-mode host from source. That project depends on V8
  and is far more expensive; the official prebuilt helper is used instead.
- It does not touch the running Codex installation, its configuration or a
  user's environment variables.
