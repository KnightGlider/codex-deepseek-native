# Where to download everything

Every download in this setup comes from an official publisher. This page lists
those places so you never have to guess, and so you never pick up a copy from
somewhere unknown.

## Codex itself (OpenAI)

- Project home: <https://github.com/openai/codex>
- The exact release this setup was tested against:
  <https://github.com/openai/codex/releases/tag/rust-v0.153.4>

That release page is where the official Windows files live. The ones this
project verified, with their SHA-256 digests and sizes, are recorded in
`verification/official-downloads.json`. The same list is quoted below so you
can check a download without opening the JSON file.

| File | SHA-256 | Size (bytes) |
| --- | --- | --- |
| `codex-x86_64-pc-windows-msvc.exe` | `444a3f0008050605cae73cd9b7a2dcac61294062dfaab56dd20430fd6498518b` | 295,408,944 |
| `codex-app-server-package-x86_64-pc-windows-msvc.tar.gz` | `69441ca4c8f6197923dc1b70a8aa870ff912b5367347287d021eaca1f3add971` | 114,282,837 |
| `codex-code-mode-host-x86_64-pc-windows-msvc.exe` | `deaebc21f354f151fcebeac46e12c6e8c4ef75ee448e25e3577502074e04b8d9` | 72,475,952 |
| `codex-command-runner-x86_64-pc-windows-msvc.exe` | `3eb267dc1f0d1d80efeacc26a211f26ed0f414466d32a2aa7304a8a0beec170c` | 8,204,592 |
| `codex-windows-sandbox-setup-x86_64-pc-windows-msvc.exe` | `0c3eeb7cee8d2bc4c8644def3c818e8b06760979572dcedc919c38d0f38f64c4` | 15,413,040 |

To check a file you already downloaded, run this in PowerShell and compare the
result against the table:

```powershell
Get-FileHash -Algorithm SHA256 .\codex-x86_64-pc-windows-msvc.exe
```

These are the **stock** OpenAI files. They are the raw material a clean build
uses; they do not contain the DeepSeek patch by themselves.

## The router (community project)

- Project home: <https://github.com/duolahypercho/codex-router>
- The exact release used: <https://github.com/duolahypercho/codex-router/releases/tag/v0.5.1>
- Pinned commit: `b90aa60e257bbcc33855aad7d43954c1a09b1311`

Clone it with Git rather than downloading a ZIP, because the setup needs to
check out that exact commit:

```powershell
$routerDir = Join-Path $env:USERPROFILE '.codex-deepseek-native\router'
git clone https://github.com/duolahypercho/codex-router.git $routerDir
git -C $routerDir checkout b90aa60e257bbcc33855aad7d43954c1a09b1311
```

One deliberate difference from the router's own instructions: this setup does
**not** run the router's advertised one-line installer, because that installs
the latest code from `main` and would lose the pinned commit. Stage 3 of
[setup-windows.md](setup-windows.md) has the complete clone, pin, and patch
sequence, including the patch that must be applied before the router is
installed or started.

Tagged router releases publish `.tar.gz` and `.zip` source archives, SHA-256
checksums, and GitHub build-provenance attestations. The router's own
`README.md` is the authority on its install options and its own prerequisites.

## DeepSeek API access

- API documentation and onboarding: <https://api-docs.deepseek.com/>

You create your own API key there, in your browser. This setup does not
include, resell, or proxy anyone's key. Enter your key only through the
router's own hidden prompt, as described in
[setup-windows.md](setup-windows.md), and never in this chat or in a file
inside the project.

## Build tools

These are only needed if you build the patched app yourself. If a release ZIP
or a clean CI artifact is available, you can skip this section entirely.

| Tool | Official source |
| --- | --- |
| Rust (rustup) | <https://rustup.rs/> |
| w64devkit (GCC 14.2, v2.0.0) | <https://github.com/skeeto/w64devkit/releases/tag/v2.0.0> |
| Node.js | <https://nodejs.org/en/download> |
| Git for Windows | <https://git-scm.com/downloads> |
| MinGW-w64 builds, general index | <https://winlibs.com/> |

What was actually tested: Rust `1.95.0` for the
`x86_64-pc-windows-gnu` target, plus w64devkit `2.0.0` bundling GCC `14.2`.
Other versions may work, but they are not covered by this project's evidence.
See [build-from-source.md](build-from-source.md) for the full recipe.

## This project's own downloads

The kit itself is the starting point:

```powershell
git clone https://github.com/KnightGlider/codex-deepseek-native.git
```

That repository is <https://github.com/KnightGlider/codex-deepseek-native>,
and it contains these docs, the two patches, the installer scripts, and the
verification records.

There are two possible sources of the patched runtime, and a usable build may
not exist yet. Treat a build as available only when its own run has actually
succeeded:

- **Release ZIP** at
  <https://github.com/KnightGlider/codex-deepseek-native/releases>, when one
  has been published. This is the easiest option and the one to prefer. It is
  a single ZIP, so one extraction is enough.
- **Actions artifact** at
  <https://github.com/KnightGlider/codex-deepseek-native/actions>, produced by
  the `build-windows-msvc.yml` workflow. Pick the newest run with a green
  success check, then download the artifact from that run's page. Downloading
  an artifact usually requires being signed in to GitHub, and artifacts
  expire. The artifact is a **ZIP that contains a second ZIP**; extract the
  outer file first, then extract the inner `-windows-x86_64-msvc.zip`.

The extraction steps, including the nested-ZIP case and how to confirm you
have the folder that directly contains `codex.exe`, are in stage 5 of
[setup-windows.md](setup-windows.md).

If neither source has a usable build, build it from source as described in
[build-from-source.md](build-from-source.md). Do not treat any mirrored copy
of a patched `codex.exe` from an unofficial site as trustworthy.

## Official Codex documentation

These are OpenAI's own pages, useful background for how subagents and
configuration are meant to work:

- Subagents: <https://learn.chatgpt.com/docs/agent-configuration/subagents>
- Configuration reference: <https://learn.chatgpt.com/docs/config-file/config-reference>

## What you will not find here

This page deliberately lists no made-up hashes and no prices. Software
versions and prices change; check the official pages above for current facts
rather than trusting a number copied into a document.
