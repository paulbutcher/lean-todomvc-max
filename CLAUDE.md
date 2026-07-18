# CLAUDE.md

Project-specific guidance for Claude Code when working in this repo.

## Verifying Lean changes

- After editing a `.lean` file, verify it with `mcp__lean-lsp__lean_diagnostic_messages`
  (or other lean-lsp-mcp tools — e.g. `lean_goal`/`lean_multi_attempt` for
  interactive proof/termination work).
- Ignore the editor's `<ide_diagnostics>` hook output.
- Before considering a task complete, run both `lake build` and `lake test` from the
  repo root as the final ground truth.
- If a change adds or removes an `import`, use `mcp__lean-lsp__lean_build`
  instead of (or in addition to) plain `lake build`.

## Commenting

- Only add comments which say something over and above what the source code already
  says. Avoid comments which restate what can be derived easily by reading the code.
- This includes header comments for both files and functions. Avoid them unless they
  add real value.
- Do add comments when it's not clear *why* the code is doing what it does just 
  from reading the code.
- Don't refer to previous implementations or rejected designs unless doing so is
  essential to understand the code.
  
