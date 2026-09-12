# How the pieces fit together

You do not need this page to install the setup. Read it when you want to
understand why a step exists, or when something breaks and you need a mental
picture to reason about it.

## The short version

Codex desktop is a window that talks to a local program. That local program is
what actually runs your conversation and your subagents. Normally it only
knows how to talk to OpenAI. This setup swaps in a patched copy of that local
program and adds a small local server called the **router** that knows how to
talk to DeepSeek.

Here is the whole picture:

```
Codex desktop window
        |
        |  talks to a local program
        v
patched codex.exe  ----------------->  OpenAI   (your main model)
        |                                  ^
        |  when a subagent runs            |
        v                                  |
   subagent role  --->  codex-router  -----+---> DeepSeek (deepseek_flash)
                          (local server)
```

## The pieces, one at a time

**The Codex desktop app** is the window you click in. It does not talk to model
servers directly. It starts and talks to a local helper program instead.

**The local helper program** (`codex.exe`, also called the CLI or the app
server) does the real work: it manages the conversation, calls models, and runs
subagents. It is the piece we patch.

That means this setup replaces a **backend**, not the desktop app. You keep the
Codex window you already have, and no second application appears on your
machine. The desktop app just needs to be pointed at the patched backend for
the launch the launcher starts.

**`CODEX_CLI_PATH`** is an environment variable the desktop app understands.
If it is set, the desktop app uses the program at that path instead of the
installed one. The launcher sets it for the single copy of Codex it starts, so
your normal Codex shortcut is unaffected.

**The router** (`codex-router`) is a small server that runs on your machine
and listens on a local address. Codex sends it model requests that are not
OpenAI's, and the router forwards them to the right provider using the API key
you stored in it. It never sends your requests anywhere except the provider
you selected.

**The agent role** is a small configuration file that defines a subagent type.
For this setup it is called `deepseek_flash` and it records three things: which
provider to use, which model to use, and the reasoning effort.

## What the patch changes

This is the single most important technical detail, and it is why a patched
binary is required at all.

In stock Codex, when you start a subagent, Codex looks at the subagent's role
but **throws away the provider name**, keeping only the model name. The result
is that a child agent always inherits the parent's provider. A role that says
"use DeepSeek" is quietly ignored, and the child ends up on OpenAI.

The patch teaches Codex to honor the provider named by the role. It does not
invent new providers, change credentials, or widen any permissions. It only
lets a role select a provider that the machine already has configured.

That is why the role file and the patch must match. The role alone does
nothing, and the patch alone has nothing to read.

## Why the router needs its own patch

The router has a different issue. When a DeepSeek turn produces both a
follow-up request and a normal completion in the same response, the stock
router can interrupt the follow-up it just started. The router patch stops
that automatic interruption, tracks the new completion properly, and leaves
explicit interrupts and normal cleanup alone.

The practical symptom without this patch is a child whose status flickers
between completed and interrupted, with a follow-up that never really lands.

## Where things live

The installer keeps its own state in a dedicated folder in your user profile,
separate from the Codex application and from this source project. Inside it
are:

| Folder | Holds |
| --- | --- |
| `runtime` | The patched `codex.exe` and its helper executables. |
| `state` | A small record of what was installed and when. |
| `logs` | Logs written by this project's scripts. |
| `backups` | Copies of any configuration changed before it was changed. |

The agent role file itself belongs to Codex, under your Codex home folder, in
`agents/deepseek_flash.toml`. The installer writes it and the uninstaller
removes it.

## What the installer deliberately does not touch

- Your ChatGPT login and account.
- Your selected main model and default provider.
- Environment variables outside the launcher's own child process.
- Provider settings other than the one managed block it owns.
- API keys, other than directing you to the router's own hidden prompt.

Those boundaries are the reason the setup can be rolled back cleanly, and why
nothing here can silently move your main conversation onto a different model.

## Why this is Windows only

The patched runtime used here was built on Windows, for Windows, against a
specific compiler. The launcher relies on how the Windows Codex desktop app
finds its local helper, and on Windows packaging details. None of that has
been proven on macOS or Linux, so this project does not claim it.
