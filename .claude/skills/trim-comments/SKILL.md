---
name: trim-comments
description: Trim comments — delete the ones that restate the code or point at code that is gone, and compress the ones that are correct but long-winded into a sentence. Use on "clean up the comments", "too many comments", "compress these comments", "the explanation is excessive", "주석 정리", "주석 줄여줘", "코멘트 압축". Also for the pass right after writing a lot of code, or before opening a PR. Applies the edits without waiting for approval, then reports what changed as a table.
---

# Trimming comments

If the project has written comment conventions of its own, those decide — this skill enforces them
rather than inventing rules. Where it has none, what follows is the rule.

**The hard part is not the deleting, it is recognising what to keep.** Take "trim the comments"
literally and the most valuable comments go first, because the ones recording a trap or a reason are
usually the longest. Those do not come back from reading the code.

## 0. Set the scope

The default is the changed files. If a file or module was named, that is the scope.

The scanner sits next to this file, at `scripts/scan.py`. **Resolve it from this skill's own
directory, not from the working directory** — the working directory is the project being edited,
which is not where the skill is installed:

```bash
SCAN=~/.claude/skills/trim-comments/scripts/scan.py            # installed for all projects
SCAN=<project>/.claude/skills/trim-comments/scripts/scan.py    # installed into one project
```

```bash
python3 "$SCAN"                                  # vs the base branch, plus uncommitted changes
python3 "$SCAN" --base HEAD                      # uncommitted only
python3 "$SCAN" <files...>                       # named files
python3 "$SCAN" --ext .ts,.tsx --skip /dist/,/build/
```

The script **does not judge.** It reports comment lines per file and narrows down where to look —
blocks over the 3-line budget, and blank separator lines inside a short block. It counts line
comments (`//`, `///`, `#`) and block comments (`/* */`, Javadoc and JSDoc), and reads the scope as
the commits on this branch plus the tracked edits not committed yet plus untracked files. Citation and link
lines are the only thing it takes out of the budget. Code examples stay in, but it tells you
`N of them fenced` so you can see whether a block is long because of prose or because of an example.
A procedure whose order carries meaning cannot be recognised by a machine, so when one trips the
budget a person overrides it.

Deciding delete / compress / keep is the three ways below. If nothing is in scope, report that and
stop.

Targets are source files, by extension. **Leave generated output alone** — a generated directory is
overwritten on the next run, and some repos have a hook that blocks editing it outright. Pass
`--skip` for the ones this repo generates into.

This skill gets called before a PR in repos that wire it in, which means it also fires on
docs-only changes — **if no target file is in scope, report "nothing in scope" and stop.** Do not go
looking for markdown prose to shorten.

## 1. Three ways

### Delete

- Restates the code. `// find the string for the current language` sitting above `currentLocale()`
- Says what the type or the name already says. `/// user ID` above `let userID: Int`
- Leftovers from code that is gone. The variable or branch the comment points at does not exist
- Commented-out code. Git has it if it needs reviving
- Change history. `// added 2026-08-01`, `// per review` belong in the commit message
- Section decoration. `// ===== from here =====`. Keep `// MARK:` — the editor reads it

### Compress

Correct in content, excessive in length. Usually **one good comment stretched into three
sentences.**

Strip the background, the process, and the alternatives you considered; keep the conclusion. If the
reasoning is load-bearing, add one clause of it.

**One comment block ends within 3 lines.** A blank `///` separator counts. Go over and you either
compress it or can answer why it cannot be compressed.

Two things come out of the budget.

- **Citation and link lines.** `(signup.md POLICY-002)`, a URL, `docs/decisions/0001`. That is not
  bulk, it is a thread to follow
- **What genuinely cannot compress.** A procedure whose order is the content. Shortening it removes
  the content

**Tables and code examples are not exempt.** Take them out automatically and the biggest blocks
survive untouched.

- **Tables** — if the code below says the same thing, delete the table. The input/output table above
  a `switch` is the classic case. The table goes stale before the code does, and when they disagree
  the reader does not know which to trust
- **Code examples** — keep one only when the signature alone does not show the call shape. An
  example on an API whose argument names are all visible is the type declaration written twice. When
  you do keep one, one is enough

If you cannot justify going past 3 lines, do not go past it. The budget is not "stop here", it is
**"ask once why more is needed"**.

```swift
// before — 4 lines, the first 3 say what the last one says
// Check whether the item already exists before storing the token. The Keychain returns
// errSecDuplicateItem when the same service and account pair is added twice. So this splits
// into update-if-present and add-if-absent. Otherwise the second store fails.

// after — what is left is the one fact the code does not show
// Adding the same service/account twice returns `errSecDuplicateItem` and fails silently.
```

If the same explanation lives in two places, keep one and point the other at it. Two copies drift
apart without exception.

### Leave alone

- **Why it was done this way.** Reading the code does not tell you
- **What breaks if you touch it.** Delete it and the next person steps in the same hole
- **Traps.** "Skip this and you get X"
- **Citations.** Grounds like `(signup.md POLICY-002)`. The thread to follow when the document is
  revised
- **Marks on anything unsettled.** `- Warning: our decision, not in the spec`
- **Doc comments the project's conventions require** on public types and non-obvious members.
  Deleting those breaks the rule

When you are unsure, keep it. Deleting a valuable comment costs more than leaving a long-winded one.

## 2. Apply, then report as a table

Edit directly without waiting for approval. Git handles the undo — which is exactly why rule 1,
keeping what is ambiguous, matters more.

After editing, put it in a table. It is the only place a person can go back over the third way.

| Where | Verdict | What it was | Why |
|---|---|---|---|
| `Tasker.swift:42` | deleted | `// cancel the task` | `task.cancel()` is right below it |
| `APIToken.swift:12` | 4 → 1 line | 3 lines of background + 1 conclusion | The first 3 say what the conclusion says |
| `ServerCode.swift:23` | 3 → 2 lines | blank `///` separator | Two sentences, no reason to split |
| `TokenStore.swift:61` | kept (exception) | 5 lines on an accessibility choice | Cannot compress — three conditions, each needed |

Write a line or two for the kept ones too. Showing what you looked at is what lets a person catch
what you missed.

Report once, all of it. Do not go file by file.

## 3. Do not touch the code

**Comments only.** Even an obvious code problem does not go in the same change — mixed together, the
reviewer cannot tell what changed behaviour. Report it separately.

## 4. Verify

```bash
git diff
```

Run the project's linter too, if it has one — comments are lint targets in some setups (doc comments
must use `///`, block comments banned), so turning a doc comment into a line comment gets caught
there.

Read the diff to confirm only comments changed. If code lines got mixed in, back them out.

## What not to do

- Do not invent rules. The project's conventions decide where it has them
- Do not throw content away to hit 3 lines. If it cannot compress, keep it as an exception and write
  why
- Do not edit comments in generated output
- Do not fix code at the same time
- Do not delete what is ambiguous. Report it as kept and let a person decide
