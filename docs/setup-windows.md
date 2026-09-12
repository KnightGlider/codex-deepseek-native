# Setup on Windows, step by step

This is the main walkthrough. You do not need to write any code, but you do
need to copy commands carefully and read what each one prints. Work through
the stages in order and stop at the first red error rather than pushing ahead.

Every command block on this page is meant for a normal **Windows PowerShell**
window, opened from the Start menu, and each block is written to stand on its
own so you can paste it by itself.

This setup does **not** change which model your main conversation uses.
Nothing here selects DeepSeek as your default or moves your main task off
OpenAI; DeepSeek is only offered as an extra subagent type. Stage 8 shows how
to confirm that.

The stages are:

1. Check prerequisites.
2. Clone this kit and set `$kitRoot`.
3. Get the router on the pinned version, patched.
4. Give the router a DeepSeek API key safely.
5. Get the patched Codex app.
6. Run the installer and launcher.
7. Verify the result.
8. Confirm your main model is unchanged, and keep a rollback path.

## 1. Prerequisites

Collect these before you change anything:

- **Windows** with the Codex desktop app installed and signed in to ChatGPT.
  The tested version is `26.903.9818.0`. You can see your version inside the
  app's settings pages.
- **Codex CLI `0.153.4`**. This ships with the desktop app; the setup checks
  that the version matches rather than replacing it blindly.
- **Node.js 22.19 or newer** (Node.js 24 LTS recommended), **Git**, and
  **Python with `uv`**. The router's own `README.md` is the authority on the
  requirements for the router version you install, so follow that page for
  exact minimums rather than guessing.
- **Enough free disk space.** Reserve at least 120 GiB of free space if you
  plan to build the patched app yourself, as described in
  [build-from-source.md](build-from-source.md). If you use a ready-made
  runtime instead, you need far less.
- **A DeepSeek API key.** You create this on DeepSeek's own website during
  stage 4. Never paste it into this chat, into a document, or into any file
  inside the project folder.

Confirm the basic tools are present:

```powershell
node --version
git --version
python --version
uv --version
```

Each line should print a version. If one says "not recognized", install that
tool from [downloads.md](downloads.md) and reopen PowerShell so the new program
is on the path.

## 2. Clone this kit and set `$kitRoot`

This kit is the folder that holds the two patches and the installer scripts.
Everything later points back at it, so clone it once and keep it:

```powershell
git clone https://github.com/KnightGlider/codex-deepseek-native.git
Set-Location codex-deepseek-native
$PWD.Path
```

The last line prints the full path of the folder you just cloned. Keep that
window open, or note the path down, because later blocks ask you to set
`$kitRoot` to it.

Whether you clone into your Documents folder, your home folder, or somewhere
else does not matter, as long as the path has no surprises in it. This matters
because the router patch is applied later by **absolute path**, so a wrong
`$kitRoot` is the most likely way to end up with an unpatched router.

## 3. Get the router on the pinned version, patched

The router is a small local program that lets Codex talk to models that are
not OpenAI's. This setup uses one specific version, plus one local fix:

```
router:  duolahypercho/codex-router
version: v0.5.1
commit:  b90aa60e257bbcc33855aad7d43954c1a09b1311
patch:   patches/router-followup.patch  (in this kit)
```

### Why we do not use the router's quick install command

The router's `README.md` advertises a one-line installer that downloads and
runs the latest code from its `main` branch. That is fine for ordinary router
users, but it is wrong here: it would quietly install a **newer** router than
the one this setup was tested against, and the pinned commit would be lost.

Instead, keep our own copy of the router in a fixed folder, put it on the
exact commit above, and apply the patch from this kit before installing or
starting anything.

### The clone, pin, and patch block

Run this whole block in one go. Edit the first line so `$kitRoot` matches the
folder you cloned in stage 2.

```powershell
# EDIT THIS: the folder you cloned in stage 2.
$kitRoot = 'C:\Users\you\codex-deepseek-native'

# A stable router folder of our own, deliberately outside the kit.
$routerDir = Join-Path $env:USERPROFILE '.codex-deepseek-native\router'
$routerRepo = 'https://github.com/duolahypercho/codex-router.git'
$routerCommit = 'b90aa60e257bbcc33855aad7d43954c1a09b1311'

$routerPatch = Join-Path $kitRoot 'patches\router-followup.patch'
if (-not (Test-Path $routerPatch)) {
  throw "No router-followup.patch under '$kitRoot'. Set `$kitRoot to the folder you cloned in stage 2."
}

# Clone once, or reuse an existing router checkout. Never clobber a folder
# that is not a Codex Router checkout.
if (Test-Path $routerDir) {
  $manifest = Join-Path $routerDir 'package.json'
  $isRouter = $false
  if (Test-Path $manifest) {
    $isRouter = ((Get-Content $manifest -Raw | ConvertFrom-Json).name -eq 'codex-model-router')
  }
  if (-not $isRouter) {
    throw "'$routerDir' already exists and is not a Codex Router checkout. Move or rename that folder, then re-run this block."
  }
  Write-Host 'Reusing the existing router checkout.'
} else {
  New-Item -ItemType Directory -Force -Path (Split-Path $routerDir) | Out-Null
  git clone $routerRepo $routerDir
  if ($LASTEXITCODE -ne 0) { throw 'git clone failed.' }
}

# Pin the exact tested commit.
$currentCommit = (& git -C $routerDir rev-parse HEAD).Trim()
if ($currentCommit -ne $routerCommit) {
  git -C $routerDir checkout $routerCommit
  if ($LASTEXITCODE -ne 0) {
    throw "Could not check out $routerCommit. If that checkout has local edits, finish or move them first."
  }
}
Write-Host "Router is at commit $routerCommit."

# Apply the follow-up patch from this kit, by absolute path.
git -C $routerDir apply --check $routerPatch *> $null
$patchApplies = ($LASTEXITCODE -eq 0)
git -C $routerDir apply --reverse --check $routerPatch *> $null
$patchAlreadyApplied = ($LASTEXITCODE -eq 0)

if ($patchApplies) {
  git -C $routerDir apply $routerPatch
  if ($LASTEXITCODE -ne 0) { throw 'The router patch failed to apply.' }
  Write-Host 'Router patch applied.'
} elseif ($patchAlreadyApplied) {
  Write-Host 'Router patch is already applied; continuing.'
} else {
  throw "'$routerDir' does not match the expected revision, so the patch cannot be applied safely. Move that folder aside and re-run this block."
}
```

If the last line says the patch is applied, you are ready to install.

### Run the pinned checkout's own installer

Change into the router folder and run the installer that lives **inside that
checkout**. Two things to notice:

- Do not run the router's downloaded `main`-branch installer. Running the
  checkout's own `install.ps1` is what keeps the pin: it detects that it is
  sitting inside a router checkout and installs from *that* folder, and the
  setup step it runs afterwards resolves its own root from its own location.
- Do not add `-CheckoutInstall` to this command. That switch is the internal
  path the installer uses for its own managed download, and it is not the
  guided command you want.

```powershell
$routerDir = Join-Path $env:USERPROFILE '.codex-deepseek-native\router'
Set-Location $routerDir
.\install.ps1 -Target codex -Guided -NoTray
```

`-Target codex` selects the Codex integration. `-Guided` asks which providers
you want and keeps credential entry in a private local prompt. `-NoTray` skips
the optional tray companion, which keeps the install smaller and easier to
reason about.

When it finishes, start the router and confirm it answers:

```powershell
$routerDir = Join-Path $env:USERPROFILE '.codex-deepseek-native\router'
Set-Location $routerDir
.\model-router.ps1 codex start
Invoke-WebRequest http://127.0.0.1:4202/health -UseBasicParsing
```

Do not continue until health answers successfully.

## 4. Give the router a DeepSeek API key safely

Create a DeepSeek API key on DeepSeek's own website, following their official
onboarding. The API documentation is at <https://api-docs.deepseek.com/>.

Add it to the router with the router's own command, which hides what you type
while you type it:

```powershell
$routerDir = Join-Path $env:USERPROFILE '.codex-deepseek-native\router'
Set-Location $routerDir
.\model-router.ps1 codex provider-key deepseek set
```

It asks for the key with the characters hidden, reports only its length, and
saves it to protected local storage. Saving the key also enables the provider.
That prompt is the only place the key should ever be typed.

Rules that keep you safe:

- Never put the API key in this chat.
- Never put it in any file inside the project folder.
- Never put it in a script, a screenshot, or a document.
- Never paste it into an issue or a shared message.

To confirm the provider is enabled and shown to Codex, these do that:

```powershell
$routerDir = Join-Path $env:USERPROFILE '.codex-deepseek-native\router'
Set-Location $routerDir
.\model-router.ps1 codex providers enable deepseek
.\model-router.ps1 codex providers
.\model-router.ps1 codex doctor
```

Resolve every `FAIL` line the doctor prints. Then fully quit and reopen Codex,
because Codex reads the model list only when it starts.

## 5. Get the patched runtime

DeepSeek can only register as a real subagent type if Codex's local backend is
patched. The patch is:

```
Codex base: openai/codex tag rust-v0.153.4
commit:     3d2ee51ca2d5db578f328aa75e20aa22c0197c9a
patch:      patches/codex-native-provider.patch  (in this kit)
```

This is a patched **backend**, not a second copy of the app. You keep using the
Codex desktop app you already have, and the launcher points that app at this
backend for the launch it starts. There is no separate "DeepSeek Codex"
application to install.

You can get the runtime in two ways. Try them in this order:

1. The project's **Releases** page, if a release has been published.
2. The project's **Actions** page, using the newest successful build.

If neither has a usable build yet, build it yourself from the official source
plus the patch, as described in [build-from-source.md](build-from-source.md).
This kit does not ship a compiled runtime, and a published build is not
guaranteed to exist: a build is only usable once its own run has actually
succeeded, with checksums and source provenance.

### Option A: a release ZIP

1. Open <https://github.com/KnightGlider/codex-deepseek-native/releases>.
2. Open the newest release, and under **Assets** download the file whose name
   ends in `-windows-x86_64-msvc.zip`.
3. Extract it. A release asset is a single ZIP, so one extraction is enough.

```powershell
$downloads = Join-Path $env:USERPROFILE 'Downloads'
$runtime = Join-Path $env:USERPROFILE '.codex-deepseek-native\runtime'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null

$releaseZip = Join-Path $downloads 'codex-native-deepseek-0.153.4-windows-x86_64-msvc.zip'
Expand-Archive -LiteralPath $releaseZip -DestinationPath $runtime -Force
```

Adjust `$releaseZip` to the asset name you actually downloaded.

### Option B: an Actions build artifact

1. Open <https://github.com/KnightGlider/codex-deepseek-native/actions>.
2. Choose the `build-windows-msvc.yml` workflow, then pick the newest run with
   a green success check. A run that failed or is still going is not usable.
3. On that run's page, download the artifact listed under **Artifacts**.
   Downloading an artifact requires being signed in to GitHub, and artifacts
   expire after a while.
4. The downloaded artifact is a **ZIP that contains another ZIP**. Extract the
   outer one first, then extract the inner one, which has the
   `-windows-x86_64-msvc.zip` name.

```powershell
$downloads = Join-Path $env:USERPROFILE 'Downloads'
$runtime = Join-Path $env:USERPROFILE '.codex-deepseek-native\runtime'
$stage = Join-Path $env:TEMP 'dse-artifact'
New-Item -ItemType Directory -Force -Path $runtime, $stage | Out-Null

# 1) The artifact you downloaded from the Actions run page.
$artifact = Join-Path $downloads 'codex-native-deepseek-windows-x86_64-msvc.zip'
Expand-Archive -LiteralPath $artifact -DestinationPath $stage -Force

# 2) The nested runtime ZIP inside it.
$inner = (Get-ChildItem -Path $stage -Filter 'codex-native-deepseek-*-windows-x86_64-msvc.zip' |
  Select-Object -First 1).FullName
Expand-Archive -LiteralPath $inner -DestinationPath $runtime -Force
```

Adjust `$artifact` to the file you downloaded. If the nested ZIP extracts into
a subfolder, point the installer at that subfolder instead, as described next.

### Point at the folder that contains `codex.exe`

For both options, give the installer the folder that **directly** contains
`codex.exe`. That is not the outer archive, and not necessarily the parent
folder you extracted into. A complete runtime contains all four files:

```
codex.exe
codex-command-runner.exe
codex-windows-sandbox-setup.exe
codex-code-mode-host.exe
```

Check before you continue:

```powershell
$runtime = Join-Path $env:USERPROFILE '.codex-deepseek-native\runtime'
Test-Path (Join-Path $runtime 'codex.exe')
Get-ChildItem $runtime | Select-Object Name
```

`Test-Path` must print `True`, and the listing must show all four executables.
If `codex.exe` is one level deeper, either move the files up or pass that
deeper folder as `-RuntimeDirectory` in stage 6.

The expected version is `0.153.4`. If the download includes a
`runtime-manifest.json` next to `codex.exe`, the installer can verify the file
hashes for you; if it does not, you can skip that verification. A developer's
debug build hash is never required.

The official Codex release files, with their verified SHA-256 digests, are
listed in `verification/official-downloads.json` and repeated in
[downloads.md](downloads.md).

## 6. Run the installer and launcher

Point the installer at the runtime folder from stage 5. Adjust `$kitRoot` and
the runtime path to your own:

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
Set-Location $kitRoot

.\scripts\Install-DeepSeekNative.ps1 -RuntimeDirectory "C:\path\to\patched-runtime"
```

Read what it prints. It checks the runtime version, writes one clearly marked
block into your Codex configuration, creates the agent role file at
`agents/deepseek_flash.toml` in your Codex home, and keeps a backup of
anything it changes. Useful options:

- `-WhatIf` shows what it would do without changing anything. Run this first
  if you want to see the plan.
- `-CreateDesktopShortcut` adds a desktop shortcut for the launcher.
- `-SkipVersionProbe` and `-SkipManifestVerification` exist for special cases.
  Leave them off unless you have a reason.

If Windows blocks the script with an execution-policy message, run the same
install with an explicit policy for that one command:

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
Set-Location $kitRoot

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-DeepSeekNative.ps1 -RuntimeDirectory "C:\path\to\patched-runtime"
```

The installer never writes your model choice, your ChatGPT login, or your
environment variables, and it does not touch provider settings outside its own
managed block.

The launcher is separate and is meant for ordinary daily use:

```powershell
.\scripts\Start-DeepSeekNative.ps1
```

Two things about the launcher are worth knowing:

- It sets `CODEX_CLI_PATH` only for the copy of Codex it starts, so your
  normal Codex shortcut keeps working as before.
- It refuses to start while Codex desktop is already running, because two
  copies would fight over the same files. Close Codex first, then use the
  launcher. `-CheckOnly` verifies the path and version without launching
  anything.

After the launcher starts Codex, check the native role the way it actually
works. The **Subagents panel is not a role picker**: it lists agents that
already exist, so an empty panel is expected until something spawns. To prove
the role is available:

1. In your task, ask the coordinating agent to inspect its spawn schema and
   confirm it exposes `agent_type` together with the `deepseek_flash` role.
2. Have it spawn one small DeepSeek child, selecting `agent_type="deepseek_flash"`
   and **omitting** any model override, since the role already names DeepSeek
   V4 Flash at high reasoning.
3. The child then appears in the Subagents panel, where you can open it and
   read its transcript.

Stage 7 covers this again with the checks worth keeping.

## 7. Verify the result

Do not trust the setup just because it printed no errors. Repeat the checks in
[verification.md](verification.md). The important ones are:

- The running Codex process is the patched backend, not the stock one.
- The coordinator's spawn schema exposes `agent_type` and the
  `deepseek_flash` role, and a spawned child of that role appears in the
  Subagents panel.
- A DeepSeek child and an OpenAI child can run at the same time.
- A follow-up message to a finished DeepSeek child works.
- Your main conversation is still on its original OpenAI model.

The kit includes a read-only check that covers several of these at once:

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
Set-Location $kitRoot
.\scripts\Test-DeepSeekNative.ps1
```

## 8. Confirm your main model is unchanged, and keep a rollback path

Nothing in this setup selects DeepSeek as your default. To confirm that after
the restart, open the model picker in Codex and check that your usual OpenAI
model is still selected. This setup also never runs the router's
`router-default` command, which is the deliberate, separate step a person
would take if they *wanted* a routed model as their default.

The project includes a rollback script:

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
Set-Location $kitRoot
.\scripts\Uninstall-DeepSeekNative.ps1
```

It removes only the managed block, the managed role file, and the desktop
shortcut this project created. It does not delete unrelated files, and it will
not overwrite configuration that changed after the install. Use `-WhatIf`
first to see the plan, and `-RestoreBackup` if you want it to put the original
configuration back from the installer's backup.

Rollback by hand, if you ever need it, means:

1. Close Codex.
2. Run the uninstall script above, or remove the marked block from your Codex
   configuration yourself.
3. Start Codex again from the **normal** shortcut, not the launcher.

Nothing in this setup modifies your ChatGPT login, and the API key lives only
in the router's credential store. To remove the key later, use the router's
own command:

```powershell
$routerDir = Join-Path $env:USERPROFILE '.codex-deepseek-native\router'
Set-Location $routerDir
.\model-router.ps1 codex provider-key deepseek remove
```

Never delete the folder that holds an active runtime or your user
configuration as a way to "reset" things. That is the fastest way to turn a
small problem into a broken install.
