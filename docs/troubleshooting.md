# Troubleshooting

Work from the top down. The most common problems come first, and each entry
tells you what to check before you change anything.

When a step fails, stop and fix it rather than continuing. Most of the
confusing failures in this setup are really a single earlier step that did not
finish.

## `deepseek_flash` is missing, or never appears

The Subagents panel is not a role picker. It lists agents that already exist,
so it stays empty until something spawns, and it will never show a role that
nothing has used yet. Check these in order.

**Check the coordinator sees the role.** Ask the coordinating agent in your
task to inspect its own spawn schema and confirm it exposes `agent_type`
alongside the `deepseek_flash` role. If `agent_type` is missing entirely, the
running backend is not the patched one, so go to the launcher checks below.

**Check a child actually spawns.** Have the coordinator spawn one small child
with `agent_type="deepseek_flash"` and no model override. That child should
appear in the Subagents panel. If the spawn is rejected, the message it returns
usually names the reason.

**Check the role file exists.** It belongs to Codex, not to this project:

```powershell
Test-Path "$env:USERPROFILE\.codex\agents\deepseek_flash.toml"
```

If that prints `False`, the installer did not finish. Run it again (adjust
`$kitRoot` to the folder where you cloned this kit):

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
Set-Location $kitRoot

.\scripts\Install-DeepSeekNative.ps1 -RuntimeDirectory "C:\path\to\patched-runtime"
```

**Check you restarted Codex from the launcher.** The agent role and the patched
backend are both loaded when the app starts. If Codex was already open and the
launcher refused to start a second copy, you are still looking at the stock
app.

Close Codex completely, then:

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
Set-Location $kitRoot
.\scripts\Start-DeepSeekNative.ps1
```

**Check the running app is the patched one.** The launcher can verify this
without launching anything:

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
Set-Location $kitRoot
.\scripts\Start-DeepSeekNative.ps1 -CheckOnly
```

If that fails, the runtime path or one of the four required files is wrong.
See the next section.

## The runtime is rejected or "incomplete"

A runtime folder must contain all four files:

```
codex.exe
codex-command-runner.exe
codex-windows-sandbox-setup.exe
codex-code-mode-host.exe
```

If one is missing, the folder is not a complete runtime. Get it again from the
release ZIP or the CI artifact, or build it as described in
[build-from-source.md](build-from-source.md).

If you have a `runtime-manifest.json`, the installer can check the file hashes
against it. If verification fails, delete the download and get it again rather
than disabling the check.

## The version check fails

The expected version is `0.153.4`. If the runtime reports something else, you
are using a build of a different Codex. Do not force the install. Get the
matching runtime, or build from the pinned commit.

The `-SkipVersionProbe` option exists for special cases, but using it when you
actually have a mismatch will produce confusing behavior later. Fix the
version instead.

## The router will not start, or health fails

**Is the router actually running?** Check its health endpoint in a browser or
with PowerShell:

```powershell
Invoke-WebRequest http://127.0.0.1:4202/health -UseBasicParsing
```

A healthy router answers with a success status and a body containing
`ok`. If nothing answers, the router is not running, or it is running on a
different port than the one configured.

**Check the provider is enabled.** From your pinned router folder:

```powershell
$routerDir = Join-Path $env:USERPROFILE '.codex-deepseek-native\router'
Set-Location $routerDir
.\model-router.ps1 codex doctor
```

Resolve every `FAIL` line. A common one is a provider that is enabled but not
ready, which usually means the API key was never stored.

**Check the key was entered through the router.** If you typed your DeepSeek
key anywhere else, remove it there and enter it again with the router's own
prompt:

```powershell
$routerDir = Join-Path $env:USERPROFILE '.codex-deepseek-native\router'
Set-Location $routerDir
.\model-router.ps1 codex provider-key deepseek set
```

The characters should be hidden as you type. The router reports whether a
credential exists, never its value.

**Check you applied the router patch before installing.** If you installed or
started the router first, its running copy may have overwritten your edit.
Confirm the pin and the patch in your router folder:

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
$routerDir = Join-Path $env:USERPROFILE '.codex-deepseek-native\router'
$routerPatch = Join-Path $kitRoot 'patches\router-followup.patch'

git -C $routerDir rev-parse HEAD
git -C $routerDir apply --reverse --check $routerPatch
```

The first command must print `b90aa60e257bbcc33855aad7d43954c1a09b1311`. The
second must succeed silently, which is how you prove the patch is present. If
it prints an error instead, re-run the clone, pin, and patch block in stage 3
of [setup-windows.md](setup-windows.md), then install again.

Also make sure you ran the router checkout's **own** `install.ps1` and not the
downloaded `main`-branch installer. The latter would replace your pinned
checkout with the latest code.

## A subagent turn disconnects mid-way

This is the known DeepSeek streaming issue. DeepSeek sometimes sends tool-call
arguments in a form Codex rejects, and the turn drops.

What to do:

1. Find that same child in the Subagents panel.
2. Inspect what it had already done.
3. Resume that child and continue.

What not to do:

- Do not switch the child to a different model. That hides the problem and
  throws away the work it had already done.
- Do not assume the whole setup is broken. It is a known, occasional
  transport issue on the provider side.

If it happens repeatedly on the same turn, simplify the instruction, or split
the work into smaller pieces, and try again.

## The follow-up message seems to be ignored

Check that the router patch is applied and the router was restarted after you
applied it. The unpatched router can interrupt a follow-up that arrives in the
same response as a completion, which looks exactly like a follow-up being
ignored.

Also confirm the child actually finished before you sent the follow-up. A
child that is still running queues the message rather than acting on it
immediately.

## ChatGPT login stopped working

The setup does not change your login. If you are suddenly signed out, that is
separate from this project. Sign in again normally in Codex.

Do not try to fix a login problem by editing the router's credential files or
your Codex configuration by hand.

## Everything looks installed, but the main model changed

It should not have. The installer never writes your model or default provider
selection, and the launcher does not change it either.

Check what is actually in your configuration, and look for the managed block
that this project owns. It is marked with these exact lines:

```
# BEGIN codex-deepseek-native-managed
# END codex-deepseek-native-managed
```

Only content between those markers belongs to this project. If something
outside them looks wrong, restore it from the installer's backup in the
`backups` folder, or run:

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
Set-Location $kitRoot
.\scripts\Uninstall-DeepSeekNative.ps1 -WhatIf
```

to see what the uninstaller would remove before you decide.

## The disk filled up during a build

See the disk section in [build-from-source.md](build-from-source.md). Clean
only the build's own target directory, using an explicit path:

```powershell
cargo clean --target-dir "C:\Users\<you>\.codex-native-build\target"
```

Never delete a runtime folder or your Codex user configuration to free space.
Those are the two things that turn a recoverable disk problem into a broken
install.

## I want to undo everything

See the rollback section in [setup-windows.md](setup-windows.md). In short:
close Codex, run `.\scripts\Uninstall-DeepSeekNative.ps1` from your kit
folder, and start Codex again from the normal shortcut.

If you also used the router, disable or remove the DeepSeek provider through
the router's own commands rather than editing its files.

## What to include if you ask for help

Include the output of these, and nothing secret:

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
Set-Location $kitRoot
.\scripts\Test-DeepSeekNative.ps1 -AsJson
.\scripts\Start-DeepSeekNative.ps1 -CheckOnly
```

Never include your API key, your login tokens, session identifiers, or raw log
excerpts that contain them. The verification script is designed to report
whether credentials exist without revealing their values, so its output is the
safe thing to share.
