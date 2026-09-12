# Building the patched Codex from source

This page is for the person who wants to create the patched Codex `.exe` from
the official source instead of receiving one that is already built. It is the
most technical page in this folder. Budget a few hours and a lot of disk
space, and read the warnings before you start.

If you only want to use the setup, you can skip this page, provided the
patched runtime is available some other way.

## What you are building, and why

DeepSeek can only appear as a real subagent type if Codex itself accepts a
provider override when it creates a subagent. The stock Codex does not, so we
apply one patch and rebuild:

```
source:  openai/codex
tag:     rust-v0.153.4
commit:  3d2ee51ca2d5db578f328aa75e20aa22c0197c9a
patch:   patches/codex-native-provider.patch
```

The patch also carries a `Cargo.lock` change that restamps workspace package
versions, plus regression tests. Apply it to a clean checkout of exactly that
commit.

## The toolchain that was actually tested

Do not substitute "latest" for these. The versions below are the ones that
were proven to work on Windows:

| Tool | Version used |
| --- | --- |
| Rust | `1.95.0-x86_64-pc-windows-gnu` |
| Compiler | w64devkit `2.0.0`, which bundles GCC `14.2` |
| Build helpers | `just`, `nextest`, `cmake`, `ninja` in an isolated folder |

The exact combination matters. `rustc` for the GNU target needs a compiler
runtime that matches closely; GCC 14.2 was verified to work, and the
instructions assume it. Do not mix headers from a different GCC into this
build.

## Keep everything isolated

The single most important habit here is to keep the build tools and the build
output out of your normal user folders:

- Use a dedicated build root, for example
  `C:\Users\<you>\.codex-native-build`.
- Keep `RUSTUP_HOME`, `CARGO_HOME`, and `CARGO_TARGET_DIR` inside that root.
- Use **short** paths for Cargo's home. Windows has a long-path limit that
  native C headers can hit, and a short Cargo path avoids it.
- Never install this toolchain as your machine-wide default Rust. It is a
  temporary, task-specific install.

Set the environment for each build session rather than changing the system.
The tested values looked like this:

```powershell
$env:RUSTUP_HOME = "C:\Users\<you>\.codex-native-build\rustup"
$env:CARGO_HOME  = "C:\Users\<you>\.codex-native-build\cargo"
$env:RUSTUP_TOOLCHAIN = "1.95.0-x86_64-pc-windows-gnu"
$env:CARGO_TARGET_DIR = "C:\Users\<you>\.codex-native-build\target"
$env:CARGO_BUILD_JOBS = "4"
```

Use a modest job count. High parallelism is what caused test timeouts under
load in the original work.

## Steps

### 1. Get the source at the pinned commit

Download the source archive from the official OpenAI repository release page
listed in [downloads.md](downloads.md), extract it, and confirm the commit in
the checkout:

```powershell
git clone https://github.com/openai/codex.git
cd codex
git checkout 3d2ee51ca2d5db578f328aa75e20aa22c0197c9a
```

### 2. Apply the patch

Set `$kitRoot` to the folder where you cloned this kit, then apply the patch
by absolute path from inside the Codex source checkout:

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
$codexPatch = Join-Path $kitRoot 'patches\codex-native-provider.patch'

git apply --check $codexPatch
git apply $codexPatch
```

The check command must be silent. If it complains, stop and fix the checkout
first.

### 3. Install the isolated toolchain

Install the GNU Rust toolchain and w64devkit into the isolated build root,
using the official installers from [downloads.md](downloads.md). Point the
build at the compiler and its libraries explicitly:

```powershell
$env:CC = "<build-root>\w64devkit\bin\gcc.exe"
$env:CXX = "<build-root>\w64devkit\bin\g++.exe"
$env:AR = "<build-root>\w64devkit\bin\ar.exe"
$env:LIBRARY_PATH = "<build-root>\w64devkit\x86_64-w64-mingw32\lib"
$env:RUSTFLAGS = "-C link-self-contained=yes"
```

`link-self-contained=yes` is not optional. Without it, linking fails because
the GNU toolchain is missing a piece of the exception-handling runtime that
Rust ships. A stack size argument was also used in the tested build:

```powershell
$env:RUSTFLAGS = "-C link-self-contained=yes -C link-arg=-Wl,--stack,8388608"
```

### 4. Sanity-check the toolchain

Before building anything large, prove that the compiler and Rust agree:

```powershell
cargo --version
rustc --version
gcc --version
```

All three should report the pinned versions. Then compile a tiny program that
starts a thread and joins it, and run it. If that works, the compiler and
runtime are compatible. If it crashes, fix the toolchain before continuing;
you will otherwise waste an hour and a half of compilation.

### 5. Check, then build

An initial check that only compiles the core crate and its tests is a good
first gate:

```powershell
cargo check -p codex-core --tests --locked
```

When that passes, build the CLI binary:

```powershell
cargo build -p codex-cli --bin codex --locked
```

The result lands in the target directory you set, under
`debug\codex.exe`. Copy the binary and its companion helper executables into
the runtime folder the launcher expects.

### 6. Run the focused tests

The focused tests that passed for this patch are the agent role tests and the
multi-agent resume tests:

```powershell
cargo test -p codex-core --locked -E "test(agent::role) | test(multi_agent_resume)"
```

That selection is **29 tests**, and they passed when this patch was prepared.
The wider agent-related selection is described in
[verification.md](verification.md).

## Disk space: the part that surprises people

A debug build of this workspace is enormous. The measured figures were:

- about **200 GiB logical** size,
- about **100 GiB physical** size on disk.

That means a machine with "enough" free space can still run out of space
halfway through. Practical rules:

- Avoid a full default debug build unless you have the room. Prefer the
  scoped commands above.
- Keep the target directory in an isolated build root, not inside the source
  folder you back up.
- Turn off incremental compilation for a distribution-style build. The lean
  recipe described below has **not** been executed end to end; treat it as a
  recommendation, not a tested result.
- When you are done, clean with an **explicit** target directory so you cannot
  delete the wrong thing:

```powershell
cargo clean --target-dir "C:\Users\<you>\.codex-native-build\target"
```

Never delete an active runtime folder or your Codex user configuration to
reclaim space.

### The lean build recipe (unexecuted)

This recipe is provided because it is the sensible way to shrink the build,
but it was not run as part of the evidence for this setup. If you use it,
label your own result accordingly:

```powershell
$env:CARGO_PROFILE_DEV_DEBUG = "0"
$env:CARGO_PROFILE_DEV_INCREMENTAL = "false"
cargo build -p codex-cli --bin codex --release --locked
```

Also consider building with path remapping so the binary does not record your
personal folder names, which matters if you plan to share the result. Again,
that remapping was reasoned about but not executed here, so describe it as
untested if you rely on it.

## What the finished runtime looked like

For scale: the debug runtime that resulted from the tested build was about
**1.3 GiB** uncompressed and about **256 MiB** once compressed. The source
patch and the rebuild materials are what you need to reproduce it; the
compressed binary alone is not a substitute for them.

## Substitutions you should not make

- Do not build against a newer `codex` commit and assume the patch applies.
- Do not use a different GCC major version and assume linking works.
- Do not run the full workspace suite as your only test and call it a pass;
  see [verification.md](verification.md) for why.
- Do not distribute a build that still contains your own folder names if you
  intend to share it.
