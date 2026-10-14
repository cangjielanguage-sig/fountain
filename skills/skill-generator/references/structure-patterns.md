# SKILL.md Structure Patterns

Four common structures for a SKILL.md body. Patterns can be mixed — most skills combine them (e.g., start task-based, add a workflow for complex operations). Pick the structure, then delete the unused patterns from the draft.

## 1. Workflow-Based — best for sequential processes

- Works when there are clear step-by-step procedures.
- Example: a DOCX skill with "Workflow Decision Tree" → "Reading" → "Creating" → "Editing".
- Shape: `## Overview` → `## Workflow Decision Tree` → `## Step 1` → `## Step 2` ...

## 2. Task-Based — best for tool collections

- Works when the skill offers different operations or capabilities.
- Example: a PDF skill with "Quick Start" → "Merge PDFs" → "Split PDFs" → "Extract Text".
- Shape: `## Overview` → `## Quick Start` → `## Task Category 1` → `## Task Category 2` ...

## 3. Reference/Guidelines — best for standards or specifications

- Works for brand guidelines, coding standards, requirements.
- Example: brand styling with "Brand Guidelines" → "Colors" → "Typography" → "Features".
- Shape: `## Overview` → `## Guidelines` → `## Specifications` → `## Usage` ...

## 4. Capabilities-Based — best for integrated systems

- Works when the skill provides multiple interrelated features.
- Example: product management with "Core Capabilities" → numbered capability list.
- Shape: `## Overview` → `## Core Capabilities` → `### 1. Feature` → `### 2. Feature` ...

## Cross-cutting sections

Add these to whichever structure fits:

- `## When to Use` — symptom-based triggers; and when NOT to use.
- `## Quick Reference` — table or bullets for scanning common operations.
- `## Common Mistakes` — what goes wrong + fixes.
- `## Real-World Impact` (optional) — concrete results.
- Copyable checklists ("Copy this checklist and track progress") for complex workflows.
- Feedback loops (run validator → fix errors → repeat) for quality-critical output.

For workflow, feedback-loop, and template patterns in detail, see `anthropic-best-practices.md`.
