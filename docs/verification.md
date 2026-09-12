# How to check that it works, and what was proven

This page has two halves. The first half is what **you** should run after
setting up. The second half is exactly what was verified when this setup was
prepared, including the parts that did not fully pass. The second half matters
because most projects only publish the happy numbers.

## What you should check yourself

The project includes a read-only verification script. It never changes
anything unless you ask it to write a report:

```powershell
$kitRoot = 'C:\Users\you\codex-deepseek-native'
Set-Location $kitRoot
.\scripts\Test-DeepSeekNative.ps1
```

Useful options:

- `-AsJson` prints machine-readable output.
- `-ReportPath <file>` saves a report.
- `-SkipRouterHealth` or `-SkipVersionProbe` skip individual checks.
- `-RuntimeManifest <file>` verifies the runtime hashes if a manifest exists.

Beyond the script, five things prove the setup is real. Configuration alone
does not:

1. **The running app uses the patched backend.** Confirm that the actual Codex
   process is executing the patched `codex.exe` you chose, not the stock one.
   A version string alone is not enough; check the executable path.
2. **The native role is reachable.** Ask the coordinating agent to inspect its
   spawn schema and confirm it exposes `agent_type` together with the
   `deepseek_flash` role, then spawn one small child of that role with no
   model override. The Subagents panel is not a role picker, so the child
   appearing there is the evidence, not an empty panel.
3. **Concurrency works.** Start one DeepSeek child and one ordinary OpenAI
   child and let them run at the same time. Both should appear in the
   Subagents panel.
4. **Files are actually written.** Have each child write a small file, then
   read that file back yourself and compare the contents.
5. **Follow-up works.** Send a finished DeepSeek child a follow-up message and
   confirm the child resumes, keeps its earlier work, and appends the new
   result.

Point 5 is the one that caught a real bug during development: the router used
to interrupt a DeepSeek follow-up turn that arrived in the same response. That
is what `patches/router-followup.patch` fixes, so apply it before you install
the router.

## What was actually verified

### Portable setup kit checks (September 12, 2026)

The temporary-home setup suite passed **96 tests**, with **0 failures and 2
opt-in checks skipped**, on both Windows PowerShell 5.1 and PowerShell 7.6.
The skipped checks require an explicitly supplied real runtime or a persisted
machine-profile value. The main reviewer independently repeated the 5.1 suite.
The suite covers configuration preservation, reinstall and rollback, runtime
manifests, fixture rejection, launch checks and read-only verification.

The build-script checks passed **113 checks**, with **0 failures and 1 skipped**
on both hosts. The skip was a local PyYAML parse; GitHub accepted and started
the workflow. Synthetic native-observer fixtures also passed. These checks do
not prove a newly compiled runtime works: source compilation and a live
provider test are separate stages. [Current kit checks](https://github.com/KnightGlider/codex-deepseek-native/actions/workflows/check-kit.yml)
and [runtime builds](https://github.com/KnightGlider/codex-deepseek-native/actions/workflows/build-windows-msvc.yml)
report the results for each revision.

### Focused Rust tests

The original focused regression run passed **29 of 29** tests. This is a
historical result, separate from the newer build workflow's broader selection.
The repeatable current filters and commands live in [the build guide](../build/README.md)
and `build/pins.json`; consult the actual CI run for its test count and result.

### Agent-related checks

A larger selection of agent-related tests ran **490** checks. Of those, **488
passed**. The remaining **2** were corrected with test-only fixes and then
passed individually in isolated reruns.

Read that carefully: this is **not** one clean run of 490 passing tests. It is
488 passes plus two corrected tests that each passed in isolation. The two
corrections were:

- One assertion expected the old behavior, where a child kept the parent's
  provider; the new intended behavior is that the child uses the provider its
  role names. The assertion was updated to require the child's provider and to
  require the root task's provider to stay unchanged.
- One stop-hook test was racing against child completion: it checked for log
  entries before the child had actually finished. Test-only synchronization
  was added to wait for the child's turn to complete, keeping every original
  assertion.

Neither correction changed the runtime binary.

### The full workspace suite

A full attempt of the supported workspace ran **15,960** tests:

| Result | Count |
| --- | --- |
| Passed | 15,116 |
| Failed | 553 |
| Timed out | 291 |
| Skipped | 131 |

Three packages that need a JavaScript engine (`codex-code-mode-host`,
`codex-code-mode-runtime`, and `codex-v8-poc`) were **excluded**, because the
upstream runtime publishes no Windows GNU archive. They are unrelated to the
DeepSeek patch, but their tests did not run in this configuration.

This is **not** a full suite pass, and nobody should describe it as one. Much
of the failure load came from running the suite under heavy machine load with
high parallelism; the agent-focused selection was rerun at low concurrency
and its two real failures were resolved as described above.

### Live native behavior

The part that matters most was verified with real agents:

- A DeepSeek `deepseek_flash` subagent and an ordinary OpenAI subagent ran
  **concurrently**, with genuinely overlapping first turns.
- Each child executed real tool calls and wrote a real file; the file contents
  were read back and matched.
- A follow-up was sent to the DeepSeek child. Its earlier content was
  preserved and the new result was appended.
- The Codex **Subagents panel** showed both children, with the active count
  returning to zero and both listed as done.
- The parent task stayed on its original OpenAI model throughout.
- A router-side view confirmed the child requests were actually going to
  `deepseek/deepseek-v4-flash` with the subagent flag set, rather than merely
  being labelled that way locally.

### Known failure mode

DeepSeek occasionally streams tool-call arguments in a form Codex rejects.
When that happens, an agent turn can disconnect. The correct response is to
inspect that same child and resume it. Switching the child to a different
model hides the problem and loses the work, so do not do that.

## What was not proven

Being explicit about this is part of the honest version of the story:

- No single clean run of the entire supported workspace suite passed.
- No claim is made for macOS or Linux, for older or newer Codex versions, or
  for a machine with a different toolchain than the tested one.
- No promise is made about maximum output length, completion time, or cost
  savings. DeepSeek can stop early, take a long time, or cost more than
  expected.
- The exact effective context window depends on the model catalog and your
  account. A large context value can be requested and still be capped by what
  the catalog allows. The observed effective value on the tested machine was
  828,400 tokens after a request for 1,000,000. Do not expect the literal
  request to be granted.

## Who built this

This setup was produced by the work described in this project, not by OpenAI.
It is a community experiment. OpenAI did not build, review, or endorse it, and
the patched runtime is not an official OpenAI release.
