# CLAUDE.md

Project-specific guidance for Claude Code when working in this repo.

## Verifying Lean changes

- After editing a `.lean` file, verify it with `mcp__lean-lsp__lean_diagnostic_messages`
  (or other lean-lsp-mcp tools, e.g. `lean_goal`/`lean_multi_attempt` for
  interactive proof/termination work).
- Ignore the editor's `<ide_diagnostics>` hook output.
- Before considering a task complete, run both `lake build` and `lake test` from the
  repo root as the final ground truth.
- If a change adds or removes an `import`, use `mcp__lean-lsp__lean_build`
  instead of (or in addition to) plain `lake build`.
- All lean code should compile without warnings.

## Commenting

- Only add comments which say something over and above what the source code already
  says. Avoid comments which restate what can be derived easily by reading the code.
- This includes header comments for both files and functions. Avoid them unless they
  add real value.
- Do add comments when it's not clear *why* the code is doing what it does just 
  from reading the code.
- Don't refer to previous implementations or rejected designs unless doing so is
  essential to understand the code.
- Don't mention project plans, milestones, ticket numbers, or anything similar in
  comments. Comments should remain valid years ahead, when people will not care 
  about the process that led to them.
- Don't add comments explaining Lean language features or quirks. Readers of this
  project understand Lean and don't need it explaining to them.
- All files should start with a copyright statement containing:
  Copyright (c) 2026 Paul Butcher. All rights reserved.
  Released under Apache 2.0 license as described in the file LICENSE.
- Never use an emdash (—). Wherever you might use one, use either a comma or a
  semicolon instead.
  
## Environment

- Installing OS packages should be done by infrastructure external to this project so
  it's controlled. Therefore, never install any OS packages. Always ask before doing
  so. This does not apply to Lean packages (i.e. defined by lake-manifest or lakefile).

## Process

- If the user asks a question, JUST answer it. Do not take a question as an
  instruction or recommendation; take it literally, answer it, and stop.
- Never make any source control (git) changes: no checkins, no pushes or pulls,
  no pull requests.
- If asked to create instructions for another Claude agent, assume that that agent
  is running against a fresh checkout of the library in question, not any of the 
  libraries within the .lake folder.

## Libraries

- If something would be easier to implement as a change to a dependency rather than
  here, stop and ask the user if we should commit that change to the dependency
  instead.
- Similarly if there's any new functionality that is potentially useful to another
  application, either within an existing library or a new one, stop and ask the user
  if we should make the change here or in a library.

## Testing

- Don't write tests which wholely or largely restate literals from the source with no
  computation in between. Before adding a test, ask: could this fail from a real behavior
  regression, or only by retyping the expected value wrong? If only the latter, it's
  not testing anything.
- Don't write tests which validate the functionality of dependencies unless explicitly
  asked to do so, or we have evidence that the dependency has a bug or unexpected 
  behaviour. Assume that dependencies do what they claim to do.
- Don't write UI tests which check HTML structure. Tests like this are too fragile.
  When testing the UI abstract away from the precise HTML structure wherever possible
  so that they continue to work as the UI evolves.
- When creating new code or functionality, always generate tests alongside it, as long
  as those tests comply with the rules above.
- Prefer the strongest form of test a claim admits: a proven theorem over a property
  style test (via Lean's Plausible testing library) over an example and expected result.
  Reach for a weaker form only when the stronger one is out of reach.
- Write a theorem rather than a property when the claim is about a pure total function
  and either the case analysis is finite (encodings, mappings between representations)
  or a counterexample would corrupt output rather than merely look wrong (an invariant
  that a file format or a wire format depends on).
- Time-box the attempt. If a proof will not close in a few tries, fall back to a
  property and record the obstacle in a comment, so that the next person knows it was
  weighed and why it failed. Never leave `sorry` or an admitted goal: the build treats
  warnings as errors, which is also why the `plausible` tactic cannot be used.
- When changing a module that carries properties, re-ask whether each is now provable.
  A property is a fallback, not a resting place.
- Theorems which aren't necessary for the production code should be in test code. They
  need no entry in `runAll`: compiling is passing.

## Lean Code

- Never use a partial function unless it's absolutely essential.
- Never use a function which might panic (typically indicated by an exclamation mark at
  the end of the function name) unless it's absolution essential.

## UI code

- Interaction should be entirely via HTMX whenever possible. Never use Javascript unless
  it's essential.
