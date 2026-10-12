---
name: skill-generator
description: Use when creating a new skill, editing or merging existing skills, or validating a skill before deployment — including requests to turn a workflow into a reusable skill, scaffold a skill directory, write or improve SKILL.md, make a skill trigger more reliably, test a skill with subagents, or package and install a skill.
---

# Skill Generator

Merges two skills: `skill-creator` (scaffolding → packaging pipeline) and `writing-skills` (TDD discipline for authoring). Use the pipeline for the mechanics, the TDD discipline for correctness.

## Overview

**Creating a skill IS Test-Driven Development applied to process documentation.**

A skill is a modular, self-contained package that extends an agent's capabilities: specialized workflows, tool integrations, domain expertise, bundled resources — "onboarding guides" for a domain. A skill is a reference guide for a proven technique, pattern, or tool; it is NOT a narrative about how you solved a problem once.

**Core principle:** If you didn't watch an agent fail without the skill, you don't know if the skill teaches the right thing.

**Iron law: NO SKILL WITHOUT A FAILING TEST FIRST.** This applies to NEW skills AND EDITS to existing skills. Write the skill before testing it? Delete it, start over. No exceptions — not for "simple additions", not for "documentation updates", not for "just adding a section". Don't keep untested content as "reference". Delete means delete.

**REQUIRED BACKGROUND:** You must understand RED-GREEN-REFACTOR — load the `test-driven-development` skill when available.

### When to create a skill

Create when:
- The technique wasn't intuitively obvious
- You'd reference this again across projects
- The pattern applies broadly (not project-specific)
- Others would benefit

Don't create for:
- One-off solutions
- Standard practices well-documented elsewhere
- Project-specific conventions (put those in the project instructions file)
- Mechanical constraints — if it's enforceable with regex/validation, automate it; save documentation for judgment calls

### Skill types

| Type | What it is | Examples | Test approach |
|------|-----------|----------|---------------|
| Technique | Concrete method with steps | condition-based-waiting, root-cause-tracing | Application scenarios |
| Pattern | Way of thinking about problems | flatten-with-flags, test-invariants | Recognition + counter-examples |
| Reference | API docs, syntax guides, tool docs | office docs, library guides | Retrieval + gap testing |
| Discipline-enforcing | Rules agents know but skip under pressure | TDD, verification-before-completion | Pressure scenarios |

## Skill anatomy

Every skill is a directory: a required `SKILL.md` plus optional bundled resources.

```
skill-name/
├── SKILL.md (required)
│   ├── YAML frontmatter metadata (required)
│   │   ├── name: (required)
│   │   └── description: (required)
│   └── Markdown instructions (required)
└── Bundled Resources (optional)
    ├── scripts/          - Executable code (Python/Bash/etc.)
    ├── references/       - Documentation loaded into context as needed
    └── assets/           - Files used in output (templates, icons, fonts, etc.)
```

- **SKILL.md**: the metadata determines when the skill is used; the body holds the process. Write **imperative/infinitive form** (verb-first), not second person. Answer three questions: What is the purpose of the skill? When should it be used? How should the agent use each bundled resource?
- **scripts/**: for repeated code or deterministic reliability. Token efficient — can be executed without loading into context (the agent may still read them to patch). Make execution intent explicit: "Run `analyze_form.py` to extract fields" (execute) vs "See `analyze_form.py` for the algorithm" (read as reference).
- **references/**: schemas, API docs, company policies, detailed workflow guides. Keeps SKILL.md lean; loaded only when needed. If a file is large, add a table of contents and include grep search patterns in SKILL.md. Keep references **one level deep** from SKILL.md — nested references cause partial reads.
- **assets/**: files not loaded into context but used in output — templates (.pptx/.docx), logo.png, boilerplate directories, fonts, sample documents.
- Avoid duplication: information lives in either SKILL.md or a reference file, not both. Keep only essential procedural instructions in SKILL.md; move detail out.
- Delete unneeded example files and directories — most skills won't need all of them.

### Progressive disclosure

Skills use a three-level loading system to manage context:

1. **Metadata** (name + description) — always in context (~100 words)
2. **SKILL.md body** — when the skill triggers (<5k words / <500 lines)
3. **Bundled resources** — as needed by the agent (effectively unlimited; scripts run without loading)

## Lifecycle

Follow these steps in order; skip one only when there is a clear reason it doesn't apply.

### 1. Understand with concrete examples

Clearly understand how the skill will be used, from real user examples or examples validated with the user. Ask questions like: "What functionality should this skill support?", "Give examples of how it would be used", "What would a user say that should trigger this skill?". Ask the most important questions first; don't overwhelm in a single message.

### 2. RED — baseline before writing

Run the scenarios WITHOUT the skill first. Document exact behavior:
- What choices did the agent make?
- What rationalizations did it use (verbatim)?
- Which pressures triggered violations?

This is "watch the test fail". For discipline skills use pressure scenarios (3+ combined pressures). For technique/pattern/reference skills use representative tasks and note missing context, wrong application, or knowledge gaps (see evaluation-driven development in `references/anthropic-best-practices.md`).

**Micro-test wording before full scenarios** (behavior-shaping guidance only): one fresh-context sample per call; always include a no-guidance control; 5+ reps per variant; read every flagged match manually; treat variance as a metric (reps converging on the same shape = wording binds). If the control doesn't exhibit the failure, there is nothing to fix — stop, don't author the guidance.

### 3. Plan reusable contents & pick the guidance form

For each example, analyze how you'd execute it from scratch and what would be useful when done repeatedly: a script (`scripts/rotate_pdf.py`), a template (`assets/hello-world/`), a schema reference (`references/schema.md`). Then classify the baseline failure and choose the matching form (see "Match the Form to the Failure" below) — the wrong form measurably backfires.

### 4. Initialize

```bash
python scripts/init_skill.py <skill-name> [--path <output-directory>]
```

The script creates the skill directory, a SKILL.md template, and example `scripts/`, `references/`, `assets/` files. Without `--path` it creates under the user skills directory (`~/.codebuddy/skills/` on CodeBuddy). Skill name rules: lowercase letters, digits, hyphens only; max 40 characters; must match the directory name exactly. Then customize the SKILL.md and delete unneeded examples.

Skills live in two locations depending on scope:

| Type | Path | Scope |
|------|------|-------|
| User skill | `~/.codebuddy/skills/skill-name/` | Available across all your projects |
| Project skill | `.codebuddy/skills/skill-name/` | Shared with everyone using the repository |

When scope is unclear, prefer a **user skill**; use a **project skill** only when there is a clear need to share (team conventions, project schemas, shared workflows). A repo `skills/` directory may hold the source of truth for a skill that is installed into the user library.

### 5. Write SKILL.md (GREEN)

Write the **minimal** skill that addresses the specific baseline failures — no content for hypothetical cases. Start with the reusable resources (`scripts/`, `references/`, `assets/`), then complete SKILL.md. Follow the SDO rules and structure below. For common structures (workflow-based / task-based / reference-guidelines / capabilities-based), see `references/structure-patterns.md`.

Suggested body skeleton: `## Overview` (what + core principle) → `## When to Use` (symptoms, and when not) → `## Core Pattern` (before/after) → `## Quick Reference` (table for scanning) → `## Implementation` (inline code or link) → `## Common Mistakes` → optional `## Real-World Impact`.

### 6. Test (VERIFY GREEN → REFACTOR) — mandatory

Run the same scenarios WITH the skill. Agent should now comply / apply the technique / find the reference. Then close loopholes: capture NEW rationalizations verbatim, add explicit counters, extend the rationalization table and red flags list, re-test until compliant. Full methodology (scenario formats, pressure types, meta-testing, plugging holes): `references/testing-skills-with-subagents.md`.

### 7. Validate & package

```bash
python scripts/quick_validate.py <skill-directory>
python scripts/package_skill.py <skill-directory> [output-directory]
```

`package_skill.py` validates first (frontmatter format, required fields, naming conventions, structure, description quality, file references) and only then creates `<skill-name>.zip` with the correct directory structure. If validation fails, fix the errors and re-run.

### 8. Install & iterate

Install to the user or project scope from the table above; for repo-managed skills, commit the skill to git and push (consider contributing upstream if broadly useful). Then iterate on real usage:
1. Use the skill on real tasks
2. Notice struggles or inefficiencies (missed links, ignored files, triggers that don't fire, unexpected reading order)
3. Identify how SKILL.md or bundled resources should be updated
4. Implement changes and test again

**STOP: never batch-create multiple skills without testing each one.** Move to the next skill only after the current one is verified. Deploying untested skills = deploying untested code.

## Skill Discovery Optimization (SDO)

Future agents must be able to FIND the skill. Agents read the description to decide "should I read this right now?".

### Description rules

The `description` field drives discovery:

- **Third person** (it is injected into the system prompt): "Processes Excel files..." not "I can help you...".
- Start with **"Use when..."** to focus on triggering conditions: specific symptoms, situations, error messages, file types, contexts.
- Cover **keywords** an agent would search for — error messages ("Hook timed out", "ENOTEMPTY"), symptoms ("flaky", "hanging", "zombie", "pollution"), synonyms ("timeout/hang/freeze", "cleanup/teardown"), actual tools/commands, file types. State the *problem* (race conditions, inconsistent behavior), not language-specific symptoms, unless the skill itself is technology-specific.
- **NEVER summarize the skill's process or workflow.** A workflow-summarizing description becomes a shortcut: agents follow the summary and skip the body. Observed: a description saying "code review between tasks" caused an agent to do ONE review, though the skill's flowchart clearly showed TWO (spec compliance, then code quality); removing the summary fixed compliance.
- Keep under 500 characters if possible; the frontmatter limit is 1024 (name: 64 max, letters/digits/hyphens).

```yaml
# ❌ BAD: summarizes workflow — agents may follow this instead of reading the skill
description: Use when executing plans - dispatches subagent per task with code review between tasks
# ❌ BAD: first person / too abstract
description: I can help you with async tests when they're flaky
# ✅ GOOD: triggering conditions only, searchable problem terms
description: Use when tests have race conditions, timing dependencies, or pass/fail inconsistently
# ✅ GOOD: technology-specific skill with explicit trigger
description: Use when using React Router and handling authentication redirects
```

### Naming

Active voice, verb-first, name by what you DO or the core insight — `creating-skills` not `skill-creation`; `condition-based-waiting` not `async-test-helpers`; `flatten-with-flags` not `data-structure-refactoring`. Gerunds (-ing) work well for processes. Avoid vague names ("Helper", "Utils", "Tools") and inconsistent patterns across a collection.

### Token efficiency

Frequently-loaded skills (getting-started, using-skills) load into EVERY conversation — every token counts. Targets: getting-started workflows <150 words each; frequently-loaded skills <200 words total; other skills <500 words (still be concise). Techniques:

- Move details to tool help ("supports multiple modes and filters, run --help") instead of documenting all flags
- Cross-reference other skills instead of repeating workflows
- Compress examples to the minimum that still teaches
- Eliminate redundancy; don't explain what's obvious from the command
- Verify with `wc -w skills/path/SKILL.md`

### Cross-referencing other skills

Use the skill name with explicit requirement markers: `**REQUIRED SUB-SKILL:** Use skill-name`, `**REQUIRED BACKGROUND:** You MUST understand skill-name`. Never use ambiguous paths ("See skills/testing/...") and never `@`-links — `@` syntax force-loads files immediately, burning context long before they're needed.

## Match the Form to the Failure

Classify the baseline failure before writing guidance: the form that bulletproofs one failure type measurably backfires on another.

| Baseline failure | Right form | Wrong form |
|---|---|---|
| Skips/violates a rule under pressure (knows better, does it anyway) | Prohibition + rationalization table + red flags | Soft guidance ("prefer...", "consider...") |
| Complies, but output has the wrong shape (bloated prompt, buried verdict) | Positive recipe or contract: state what the output IS — its parts, in order | Prohibition list ("don't restate", "never narrate") |
| Omits a required element from something they already produce | Structural: REQUIRED field or slot in the template they fill in | Prose reminders near the template |
| Behavior should depend on a condition | Conditional keyed to an observable predicate ("if the brief exists, reference it") | Unconditional rule + exemption clauses |

**Why prohibitions backfire on shaping problems:** under a competing incentive, agents negotiate with "don't X". Head-to-head wording tests on dispatch-prompt guidance: the prohibition arm produced clearly more of the unwanted content than the recipe arm — and trended worse than the no-guidance control. A recipe leaves nothing to negotiate: the output matches the stated shape or it doesn't. Micro-test your own case rather than assuming, but never reach for the prohibition by default.

**Rules for whichever form you pick:**
- **No nuance clauses.** "Don't X unless it matters" reopens the negotiation — appending one nuance clause degraded a winning recipe from consistent to noisy in the same wording tests. Express a real exception as its own conditional on an observable predicate.
- **Exemption clauses don't scope.** "This limit doesn't apply to code blocks" still suppresses code blocks. If part of the output must be exempt, restructure so the rule can't reach it.

## Bulletproofing (discipline skills)

Scope: for discipline failures — an agent that knows the rule and skips it under pressure. For wrong-shaped output or omitted elements, prohibition-based bulletproofing backfires; use the forms above instead.

- **Close every loophole explicitly** — forbid specific workarounds:
  ```markdown
  Write code before test? Delete it. Start over.

  **No exceptions:**
  - Don't keep it as "reference"
  - Don't "adapt" it while writing tests
  - Don't look at it
  - Delete means delete
  ```
- **Address "spirit vs letter" arguments** with a foundational principle early: "**Violating the letter of the rules is violating the spirit of the rules.**" This cuts off an entire class of rationalizations.
- **Build a rationalization table** from baseline verbatim excuses: `| Excuse | Reality |` (e.g. "Too simple to test" → "Simple code breaks. Test takes 30 seconds.").
- **Create a red flags list** for self-checking: "## Red Flags - STOP and Start Over — code before test; 'I already manually tested it'; 'This is different because...' — All of these mean: delete code, start over."
- **Update the description** with symptoms of being about to violate (e.g. "before writing implementation code").
- Psychology foundation (Cialdini authority/commitment/scarcity/social proof/unity; Meincke et al. 2025: 33% → 72% compliance): `references/persuasion-principles.md`.

## Testing skills (summary)

| TDD concept | Skill creation |
|-------------|----------------|
| Test case | Pressure scenario with subagent |
| Production code | Skill document (SKILL.md) |
| RED | Agent violates rule / misses information without skill (baseline) |
| GREEN | Agent complies with skill present |
| Refactor | Close loopholes while maintaining compliance |
| Watch it fail | Document exact rationalizations verbatim |
| Minimal code | Write skill addressing those specific violations |

Test approach by type:
- **Discipline**: academic questions (do they understand the rules?) + pressure scenarios (do they comply under stress?) + multiple pressures combined. Success = follows rule under maximum pressure.
- **Technique**: application scenarios + variation scenarios + missing-information tests. Success = applies the technique correctly to a new scenario.
- **Pattern**: recognition scenarios + application + counter-examples. Success = knows when NOT to apply.
- **Reference**: retrieval + application + gap testing. Success = finds and correctly applies the information.

Pressure types: time, sunk cost, authority, economic, exhaustion, social, pragmatic — **combine 3+**. Good scenarios force an explicit A/B/C choice with real constraints and make the agent act, not theorize. Common rationalizations for skipping testing ("obviously clear", "it's just a reference", "testing is overkill", "no time") all mean the same thing: **test before deploying. No exceptions.**

## Writing style, examples, flowcharts

- **Concise is key.** Agents are already smart — only add context they don't have. Challenge every paragraph: "Does the agent need this? Can I assume it knows this? Does it justify its token cost?"
- **One excellent example beats many mediocre ones.** Choose the most relevant language (testing techniques → TypeScript/JavaScript; system debugging → Shell/Python; data processing → Python). Make it complete, runnable, well-commented explaining WHY, from a real scenario. Don't implement in 5+ languages, don't create fill-in-the-blank templates, don't write contrived examples.
- **Flowcharts ONLY for**: non-obvious decision points, process loops where you might stop too early, "when to use A vs B" decisions. **Never for**: reference material (tables/lists), code examples (markdown blocks), linear instructions (numbered lists), meaningless labels (step1, helper2). Style rules: `references/graphviz-conventions.dot`. Render a skill's diagrams to SVG for your human partner: `node scripts/render-graphs.js <skill-directory> [--combine]` (requires graphviz).
- **File organization**: self-contained (everything inline) when all content fits; skill with reusable tool (SKILL.md + working example file); skill with heavy reference (SKILL.md + 100+ line reference files + scripts). Invoke bundled scripts through their interpreter in the prose (`python scripts/tool.py`, `node scripts/tool.js`), never by bare path — some packagers strip executable bits.
- Use consistent terminology throughout; avoid time-sensitive information (put legacy content in an "old patterns" section); avoid offering too many options (give a default plus an escape hatch).

### Anti-patterns

- ❌ **Narrative example** — "In session 2025-10-03, we found empty projectDir caused...". Too specific, not reusable.
- ❌ **Multi-language dilution** — example-js.js, example-py.py, example-go.go. Mediocre quality, maintenance burden.
- ❌ **Code in flowcharts** — can't copy-paste, hard to read.
- ❌ **Generic labels** — helper1, step2; labels should carry semantic meaning.

## Deployment checklist (before sharing a skill)

Create a todo for each item:

**RED**
- [ ] Pressure scenarios created (3+ combined pressures for discipline skills)
- [ ] Scenarios run WITHOUT skill; baseline behavior documented verbatim
- [ ] Patterns in rationalizations/failures identified

**GREEN**
- [ ] Name is letters/digits/hyphens only; frontmatter has `name` + `description` (≤1024 chars)
- [ ] Description starts with "Use when...", third person, specific triggers/symptoms, keyword-rich, **no workflow summary**
- [ ] Addresses the specific baseline failures; guidance form matches the failure type
- [ ] Wording micro-tested against a no-guidance control (behavior-shaping guidance; N/A for pure reference skills)
- [ ] Clear overview with core principle; one excellent example; code inline or linked
- [ ] Scenarios run WITH skill — agents comply

**REFACTOR**
- [ ] New rationalizations identified and countered; rationalization table and red flags list built
- [ ] Re-tested until bulletproof for the tested scenarios

**Quality & deployment**
- [ ] Flowchart only if decision is non-obvious; quick reference table; common mistakes section; no narrative
- [ ] SKILL.md body under 500 lines; detail moved to one-level-deep references
- [ ] `quick_validate.py` passes; packaged/installed (user or project scope); committed to git if repo-managed

## Discovery workflow (optimize for this)

1. Agent encounters a problem ("tests are flaky")
2. Searches skills (greps descriptions, browses categories)
3. Finds your SKILL.md (description matches)
4. Scans overview (relevant?)
5. Reads patterns / quick reference table
6. Loads the example only when implementing

Put searchable terms early and often.

## Bundled resources

- `references/anthropic-best-practices.md` — official authoring best practices: conciseness, degrees of freedom, structure patterns, workflows and feedback loops, evaluation-driven development, executable-code guidance, full checklists. Load when writing or restructuring SKILL.md.
- `references/structure-patterns.md` — the four common SKILL.md structures.
- `references/testing-skills-with-subagents.md` — complete RED-GREEN-REFACTOR testing methodology: pressure scenarios, meta-testing, hole-plugging.
- `references/persuasion-principles.md` — persuasion research for bulletproofing discipline skills.
- `references/graphviz-conventions.dot` — graphviz style guide for skill flowcharts.
- `examples/CLAUDE_MD_TESTING.md` — a complete worked test campaign (documentation variants).
- `scripts/init_skill.py` — scaffold a new skill; `scripts/quick_validate.py` — structural validation; `scripts/package_skill.py` — validate + zip; `scripts/render-graphs.js` — render `dot` blocks to SVG.

---

*Merged from Anthropic's `skill-creator` (Apache-2.0; see `LICENSE.txt`) and the `writing-skills` skill (superpowers).*
