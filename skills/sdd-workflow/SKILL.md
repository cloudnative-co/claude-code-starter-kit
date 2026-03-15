---
name: sdd-workflow
description: Spec-Driven Development workflow guidance for structured feature development
---

# Spec-Driven Development (SDD) Workflow

## Overview

SDD places specifications as the Source of Truth. Code implements the spec, not the other way around.

## Workflow: Requirements -> Design -> Tasks -> Implementation

### Phase 1: Requirements (spec.md)

Create `docs/specs/[feature-name]/spec.md`:
- User stories or EARS-format requirements
- Acceptance criteria (testable)
- Non-functional requirements
- Out of scope (explicit exclusions)

### Phase 2: Design (design.md)

Create `docs/specs/[feature-name]/design.md`:
- Architecture decisions (reference ADRs if applicable)
- API contracts / interface definitions
- Data models
- Sequence diagrams (Mermaid)
- Error handling strategy

### Phase 3: Task Breakdown (tasks.md)

Create `docs/specs/[feature-name]/tasks.md`:
- Ordered list of implementation tasks
- Each task: file paths, estimated complexity, dependencies
- Tasks should be small enough for one agent session (2-5 min each)
- Include test requirements per task

### Phase 4: Implementation

- Implement one task at a time
- Each task: write test (Red) -> implement (Green) -> refactor
- Cross-reference spec on completion
- Update spec if implementation reveals necessary changes

## When to Use SDD

- Team features with multiple contributors
- Medium to large features (>1 day of work)
- Features requiring cross-team coordination
- Anything needing formal review gates

## When NOT to Use SDD

- Quick bug fixes
- Minor refactors
- Exploratory prototyping (use /research instead)

## Tooling Compatibility

SDD specs work with:
- GitHub Spec Kit
- Kiro Design Docs
- Any agent that reads Markdown specifications
