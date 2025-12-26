# Gemini CLI Instructions

When planning a task, output **only** a Markdown `SPEC.md` checklist with the following sections in order:

1. **Goal** – a one-paragraph statement of what success looks like.
2. **Files to touch** – bullet list of paths.
3. **Steps** – numbered list of implementation steps.
4. **Acceptance checks** – exact shell commands to verify completion.

Additional rules:
- Do not include code unless explicitly requested in the task.
- The CLI must write the generated content to `SPEC.md` at the repository root.
