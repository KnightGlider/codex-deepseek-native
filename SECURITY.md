# Reporting problems safely

For setup bugs, open an issue with the OS, Codex/desktop/router versions, failing command name, and a short redacted error. Do not attach API keys, auth.json, full config.toml, raw traces, account screenshots, or local secrets.

For a suspected credential exposure, rotate the affected credential with its provider before sharing diagnostic material. This repository does not contain or manage a shared API key.

Only run a runtime you trust. Published community artifacts are not official OpenAI releases. Verify their SHA-256 checksums and provenance; building from the pinned source plus patch is an alternative. Do not disable operating-system protections to force a blocked executable to run.