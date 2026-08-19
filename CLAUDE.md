# CLAUDE.md

## Repository rules

### Git
1. Never push directly to main.
2. Everytime the users request a plan or execution for a new feature o a fix, create a new branch from the development branch and work there. 
3. Never merge the branches without explicit order from the user.
4. Follow the conventional branch guide for naming new branches.
5. Follow the convetional commits to create commits names.

## Agent skills

### Issue tracker

Issues live in GitHub Issues at `roymelgarv/omarchy-keyboard-cleaner`, via the
`gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root, both created
lazily. See `docs/agents/domain.md`.
