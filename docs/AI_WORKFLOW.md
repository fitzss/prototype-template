# AI Workflow

## Roles
- **Gemini** – writes `SPEC.md` with high-level context and acceptance checks.
- **Codex** – implements the spec, keeps diffs small, and runs the checks.
- **Human** – reviews, decides, and merges.

## Workflow
1. Create a dedicated git branch for the task.
2. Run the starter AI loop commands in order:
   1. `./tools/ai/plan.sh "Task description"`
   2. `./tools/ai/build_from_spec.sh`
   3. `make acceptance`
3. Review the results locally, run any project-specific checks, then commit.
4. Push the branch and open a PR for human review and merge.

## Safety
- No YOLO deployments; keep reviews mandatory.
- Inspect diffs before merging.
- Keep secrets outside the repo (local `.env`, CI secrets, etc.).
