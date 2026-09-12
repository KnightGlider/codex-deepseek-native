# Optional project instructions

Copy the instructions below into your project's existing AGENTS.md, preserving
the instructions already there. This file is an example, not an installer.

Keep the user's selected OpenAI model as the main conversational agent. Delegate
substantial, well-defined implementation and test work to native DeepSeek Flash
subagents when this integration has been verified. Keep planning, integration,
ambiguous decisions and final verification with the main agent. Do tiny tasks
locally when delegation would add more overhead than it saves.

Before the first native DeepSeek delegation in a session, verify that the desktop
app-server process uses the patched runtime recorded by this kit's installation,
and that the current spawn_agent schema exposes agent_type and deepseek_flash.
The usual install state is under the user's .codex-deepseek-native/state folder;
respect an explicitly configured installation location. A model name alone is
not proof that the patched backend is active.

Use agent_type="deepseek_flash" and omit a model override. The registered role
selects DeepSeek V4 Flash with high reasoning. Do not change the main model,
silently upgrade to DeepSeek Pro, or replace a failed DeepSeek worker with an
OpenAI worker. If the native role is unavailable, explain the failure. Do not
claim a fallback is a native Subagents-panel agent.

Parallelize only independent work. Give each child explicit file ownership,
platform details, relevant paths, constraints and acceptance checks. Tell it
other agents are working in the same repository and not to revert their edits.
Do not pass API keys or unrelated private information to a child.

Use native follow-up and wait tools to supervise work. Inspect actual files and
run relevant checks rather than trusting summaries. If a tool stream fails,
inspect progress before resuming the same child; do not repeatedly restart a
large task from scratch. Interrupt completed children so Codex marks them done.

Ordinary GPT children may run alongside DeepSeek children when the user wants
them; omit the DeepSeek role for GPT children. Never assume infinite context,
unlimited output or guaranteed savings. Provider and application limits apply.
