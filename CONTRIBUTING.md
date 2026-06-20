# Contributing to Modelo

## How feature ideas are captured and explored

Modelo uses a two-stage flow so that loose brainstorming and firm proposals don't get tangled
up. **Discussions are for riffing; Issues are for deciding.**

```
Idea  ──►  💡 Ideas Discussion  ──►  💡 Feature idea Issue  ──►  Branch + PR  ──►  Merged
        (explore, riff, debate)   (the decision of record)   (implementation)
```

### 1. Riff in Discussions (optional but encouraged)

Half-formed idea? Start a thread in the **Ideas** category of
[Discussions](../../discussions/categories/ideas). Use the idea template — it just asks for the
idea, why it might matter, and what you're unsure about. Discussions give you upvotes, threaded
replies, and a "mark as answer" flow, which suit open-ended exploration better than an issue.

Nothing in a Discussion is a commitment. This is where an idea gets pressure-tested.

### 2. Propose formally in an Issue

Once an idea is concrete enough to decide on, open a **Feature idea** issue using the
[feature-idea form](../../issues/new?template=feature-idea.yml). This is the **system of
record** — the place where the feature is actually decided and tracked. The form mirrors the
structure that's worked well for us (see issue #2):

- **Problem** — what's missing or wrong, with observed behavior and root cause
- **Options** — the approaches considered, each with explicit trade-offs
- **Decision needed** — the specific call you're asking maintainers to make

If the idea came from a Discussion, link it in the "Originating discussion" field so the
exploration context travels with the proposal.

### 3. Implement via branch + PR

Once an option is chosen on the issue, implement it on a branch and open a pull request that
**references the issue** (e.g. "Closes #12"). Merging the PR closes the loop.

## Where things go

| You have…                                  | Put it in…                          |
| ------------------------------------------ | ----------------------------------- |
| A rough idea you want to explore           | Discussions → Ideas                 |
| A usage question / "how do I…"             | Discussions → Q&A                   |
| A concrete feature proposal to decide on   | Issue → Feature idea                |
| A bug                                      | Issue (blank or bug, if added)      |
| Working code for an agreed change          | Pull request, linked to its issue   |

> **Note:** GitHub Discussions must be enabled for this repository
> (Settings → Features → Discussions) for the Discussion links and template to work. The
> `Ideas` and `Q&A` categories are GitHub defaults when Discussions is turned on.

## Building

See [`README.md`](README.md) — `xcodegen generate`, then build the **Modelo** scheme. No
third-party dependencies.
