# Verification tools

`harness.mjs` is the actual native-agent observer used during development, with no saved runs or account data included. `verify-observer.mjs` tests its event accounting using synthetic fixtures; those fixtures do **not** prove live provider routing.

## No-account checks

```powershell
node .\verification\verify-observer.mjs
node .\verification\harness.mjs --help
```

## Live check (uses your accounts)

First complete the setup and confirm the router is healthy. Choose an OpenAI model available in your account. The harness's historical default was `gpt-5.6-luna`; do not assume that model is available to everyone.

```powershell
$runtime = Join-Path $env:USERPROFILE '.codex-deepseek-native\runtime\codex.exe'
$runDir = Join-Path $env:TEMP ('codex-deepseek-check-' + [guid]::NewGuid().ToString('N'))
node .\verification\harness.mjs --codex $runtime --out $runDir --parent-model YOUR_AVAILABLE_OPENAI_MODEL --experimental-api --sandbox workspace-write --request-timeout-ms 0
```

Replace `YOUR_AVAILABLE_OPENAI_MODEL` before running. This creates a local test task and native children, invokes both providers, and writes two small test files and local traces. Normal account usage applies. Windows sandbox setup must already work for the selected sandbox; a permissions failure is not a provider-routing pass. The original full-access test run used `--sandbox danger-full-access`; use that only if you deliberately choose that access level. The file instructions are not a substitute for sandboxing.

The harness checks real child IDs and parent relationships, distinct providers/models, overlapping turns, follow-up to the same DeepSeek child, completed turns, exact file bytes and explicit cleanup. It uses `thread/read` evidence rather than accepting the model's final prose as proof. A nonzero exit means a required check was not verified.

The default whole-turn deadline is disabled, but network, provider, context and app limits still exist. Interrupt with Ctrl+C when needed and inspect what actually ran before retrying. Never silently replace a failed DeepSeek child with an OpenAI worker.

Local traces and summaries can contain personal paths, instructions and account-related metadata. Keep the output directory outside Git and do not publish raw runs. No API key is read or copied by the harness; it inherits the existing Codex authentication/configuration. Do not add keys to command arguments.

The Subagents **UI** must also be checked in the desktop app. A protocol test alone cannot prove that the panel renders correctly.

See [the validation record](../docs/verification.md) for the limits of the tests performed during development, and `official-downloads.json` for upstream release metadata rather than custom runtime hashes.