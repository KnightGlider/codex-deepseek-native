# Native DeepSeek Subagents for Codex on Windows

This folder is a beginner's guide to a community setup that lets the Codex
desktop app run **native DeepSeek subagents** next to its normal OpenAI
subagents. "Native" means DeepSeek appears as a real choice in Codex's own
Subagents panel, rather than a separate tool that imitates one.

If you are new to all of this, read this page first, then follow
[setup-windows.md](setup-windows.md) from top to bottom. The other pages exist
for specific moments: [build-from-source.md](build-from-source.md) when you
want to create the patched app yourself, [verification.md](verification.md)
when you want to check that things really work, and
[troubleshooting.md](troubleshooting.md) when something goes wrong.

## What you end up with

After a successful setup, all of these are true at the same time:

- Your main conversation still runs on the OpenAI model you already chose. The
  setting is not changed for you.
- Your coordinator's spawn schema exposes `agent_type` and a
  `deepseek_flash` role, alongside the ordinary OpenAI choices.
- A `deepseek_flash` subagent runs DeepSeek V4 Flash at reasoning effort
  `high`, on the same machine, under the same Codex interface.
- Ordinary OpenAI subagents keep working, and you can run a DeepSeek subagent
  and an OpenAI subagent at the same time.
- Each spawned child shows up in the Subagents panel, where you can open its
  transcript, and you can send a finished subagent a follow-up message.

One thing to expect: the Subagents panel lists agents that already exist. It
is not a role picker, so it stays empty until a child is spawned, and it does
not prove the role exists by itself.

This was verified with real agents, not only with configuration checks: a
DeepSeek subagent and an OpenAI subagent ran concurrently, each wrote a file,
and each was resumed with a follow-up. See [verification.md](verification.md)
for the exact evidence.

## The honest limitations

Please read this list before you start, because it prevents most disappointment:

- **Windows only, on specific versions.** This was tested with Codex desktop
  `26.903.9818.0` and Codex CLI `0.153.4` on Windows. There is no working
  claim for macOS, Linux, or a newer or older Codex.
- **Not an official OpenAI product.** This is a community experiment. It is
  not made, reviewed, endorsed, or supported by OpenAI.
- **No promise about output length, time, or cost.** DeepSeek can still stop
  early, take a long time, or cost more or less than you expect.
- **A known disconnect can occur.** DeepSeek occasionally streams tool
  arguments in a form that Codex rejects. When that happens an agent turn can
  drop. The fix is to inspect and resume that same child. Do not silently
  switch it to a different model, because that hides the problem.
- **No whole test suite passed in one clean run.** Focused tests and the
  agent-related tests passed, but the full workspace suite has known failures
  and timeouts. Details are in [verification.md](verification.md).
- **Building it yourself is heavy.** A debug build can occupy roughly 200 GiB
  of logical disk space (about 100 GiB physically on disk). The build guide
  explains how to keep that isolated and how to clean it up safely.

## Before you begin

This setup is more advanced than installing an ordinary app. It involves two
patches: one for Codex itself and one for a small local helper program called
the **router**. You do not have to understand every command, but you should be
willing to copy them carefully and read the result of each one.

The pages in this folder are:

| Page | Read it when |
| --- | --- |
| [setup-windows.md](setup-windows.md) | You want the step-by-step install. |
| [build-from-source.md](build-from-source.md) | You need to create the patched Codex `.exe` yourself. |
| [downloads.md](downloads.md) | You need the official place to get each tool. |
| [verification.md](verification.md) | You want to prove the setup works. |
| [troubleshooting.md](troubleshooting.md) | Something failed and you need the fix. |
| [architecture.md](architecture.md) | You want to understand how the pieces fit. |

## How the kit is laid out

These docs live inside the kit itself, so the whole thing arrives in one
clone:

```
codex-deepseek-native/
  docs/          these pages
  patches/       codex-native-provider.patch, router-followup.patch
  scripts/       install, launcher, checks, uninstall
  config/        the agent role template and shared settings
  verification/  recorded evidence and download digests
```

Get started with:

```powershell
git clone https://github.com/KnightGlider/codex-deepseek-native.git
Set-Location codex-deepseek-native
```

Then follow [setup-windows.md](setup-windows.md). The script names you will
run are:

- `scripts/Install-DeepSeekNative.ps1`: the guided install.
- `scripts/Start-DeepSeekNative.ps1`: starts Codex desktop with the patched
  runtime, for that launch only.
- `scripts/Test-DeepSeekNative.ps1`: read-only checks.
- `scripts/Uninstall-DeepSeekNative.ps1`: rollback.

The install itself never touches your model choice, your ChatGPT login, or
your environment variables. It adds one clearly marked block to your Codex
configuration and creates one agent role file, and the uninstall script
removes exactly those.
