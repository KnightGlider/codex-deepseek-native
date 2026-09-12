# Contributing

Keep changes scoped to the supported versions. Explain which component changes:
Codex source patch, router patch, installer, launcher, or verification.

Run the portable script tests, build-script validation, and observer fixtures
before submitting a change. A live check uses the contributor's own accounts;
never add credentials to CI or publish raw traces.

When updating a source pin, apply the patch to a clean checkout, review conflicts,
and rerun provider-isolation, ordinary-GPT, concurrent-child and follow-up checks.
A configuration-only success does not prove native delegation or UI behavior.

Keep build outputs outside Git. Preserve upstream licenses and modification
notices, and publish runtime artifacts with their source commit, patch digest,
compiler/profile details and SHA-256 manifest. Do not silently reuse a runtime
built from different source or with different helper versions.

Installer changes must preserve unrelated TOML settings, fail before mutation on
unowned role collisions, be idempotent, and refuse rollback that overwrites later
user edits. Test against temporary homes, not a real Codex home.

Use ordinary pull requests. Report limitations and failed checks rather than
changing a test only to make its result green.