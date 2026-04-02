# No-Flicker Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `CLAUDE_CODE_NO_FLICKER=1` env var injection to settings.json as a feature toggle (minimal=false, standard=false, full=true)

**Architecture:** Env-only feature (no hooks, no scripts). `hooks.json` contains `{"env": {"CLAUDE_CODE_NO_FLICKER": "1"}}` which is deep-merged into settings.json by `build_settings_file()` via the `_FEATURE_ORDER` / `_FEATURE_FLAGS` registry. Same pattern as `safety-net`'s env key.

**Tech Stack:** Bash, jq (settings merge)

---

### Task 1: Feature Directory

**Files:**
- Create: `features/no-flicker/feature.json`
- Create: `features/no-flicker/hooks.json`

- [ ] **Step 1: Create feature.json**

```json
{
  "name": "no-flicker",
  "displayName": "No Flicker",
  "description": "Enable Claude Code experimental flicker-free terminal renderer via CLAUDE_CODE_NO_FLICKER env var",
  "category": "settings",
  "default": false,
  "profiles": {
    "minimal": false,
    "standard": false,
    "full": true
  },
  "dependencies": [],
  "conflicts": []
}
```

- [ ] **Step 2: Create hooks.json**

```json
{
  "env": {
    "CLAUDE_CODE_NO_FLICKER": "1"
  }
}
```

- [ ] **Step 3: Validate JSON**

Run: `jq . features/no-flicker/feature.json && jq . features/no-flicker/hooks.json`
Expected: Valid JSON output, no errors

---

### Task 2: Feature Registry

**Files:**
- Modify: `lib/features.sh:19-52`

- [ ] **Step 1: Add to `_FEATURE_FLAGS`**

Add `[no-flicker]=ENABLE_NO_FLICKER` after `[doc-size-guard]=ENABLE_DOC_SIZE_GUARD` (line 31).

- [ ] **Step 2: Add to `_FEATURE_ORDER`**

Append `no-flicker` to the end of the array (after `doc-size-guard` on line 52).

- [ ] **Step 3: Verify no script registration needed**

`_FEATURE_HAS_SCRIPTS` should NOT include `no-flicker` (no external scripts).

---

### Task 3: Profile Configs

**Files:**
- Modify: `profiles/minimal.conf`
- Modify: `profiles/standard.conf`
- Modify: `profiles/full.conf`

- [ ] **Step 1: Add to minimal.conf**

After `ENABLE_DOC_SIZE_GUARD=false`, add:
```
ENABLE_NO_FLICKER=false
```

- [ ] **Step 2: Add to standard.conf**

After `ENABLE_DOC_SIZE_GUARD=false`, add:
```
ENABLE_NO_FLICKER=false
```

- [ ] **Step 3: Add to full.conf**

After `ENABLE_DOC_SIZE_GUARD=true`, add:
```
ENABLE_NO_FLICKER=true
```

---

### Task 4: Wizard Integration

**Files:**
- Modify: `wizard/wizard.sh:47` (variable init)
- Modify: `wizard/wizard.sh:145` (`_CONFIG_ALLOWED_KEYS`)
- Modify: `wizard/wizard.sh:261` (`save_config` variable list)
- Modify: `wizard/wizard.sh:955` (`_step_confirm` display)
- Modify: `wizard/wizard.sh:1036` (`_fill_noninteractive_defaults`)

- [ ] **Step 1: Add variable initialization**

After line 47 (`ENABLE_DOC_SIZE_GUARD="${ENABLE_DOC_SIZE_GUARD:-}"`), add:
```bash
ENABLE_NO_FLICKER="${ENABLE_NO_FLICKER:-}"
```

- [ ] **Step 2: Add to `_CONFIG_ALLOWED_KEYS`**

Append ` ENABLE_NO_FLICKER` after `ENABLE_DOC_SIZE_GUARD` in the space-separated string on line 145.

- [ ] **Step 3: Add to `save_config()` variable list**

Add `ENABLE_NO_FLICKER` after `ENABLE_DOC_SIZE_GUARD` on line 261.

- [ ] **Step 4: Add to `_step_confirm()` display**

After line 955 (`STR_CONFIRM_STATUSLINE`), add:
```bash
printf "%-20s : %s\n" "$STR_CONFIRM_NO_FLICKER" "$(_bool_label_enabled "${ENABLE_NO_FLICKER:-false}")"
```

- [ ] **Step 5: Add to `_fill_noninteractive_defaults()`**

After line 1036 (`ENABLE_STATUSLINE`), add:
```bash
[[ -z "${ENABLE_NO_FLICKER:-}" ]] && ENABLE_NO_FLICKER="false"
```

Note: Default `false` because standard profile (default for non-interactive) has it disabled.

---

### Task 5: i18n Strings

**Files:**
- Modify: `i18n/en/strings.sh:55`
- Modify: `i18n/ja/strings.sh:53`

- [ ] **Step 1: Add English string**

After `STR_CONFIRM_STATUSLINE="Status Line"` (line 55), add:
```bash
STR_CONFIRM_NO_FLICKER="No Flicker"
```

- [ ] **Step 2: Add Japanese string**

After `STR_CONFIRM_STATUSLINE="ステータスライン"` (line 53), add:
```bash
STR_CONFIRM_NO_FLICKER="フリッカー防止"
```

---

### Task 6: CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add changelog entry**

Add `## [0.42.0]` section before `## [0.41.0]`:

```markdown
## [0.42.0] - 2026-04-03

### Added
- **No Flicker モード**: Claude Code の実験的フリッカー防止レンダラー (`CLAUDE_CODE_NO_FLICKER=1`) を feature toggle として追加。full プロファイルで有効、minimal/standard では無効
```

---

### Task 7: Verification

- [ ] **Step 1: ShellCheck**

Run: `shellcheck -S warning lib/features.sh wizard/wizard.sh`
Expected: No errors

- [ ] **Step 2: Unit tests**

Run: `bash tests/run-unit-tests.sh`
Expected: All pass

- [ ] **Step 3: JSON validation**

Run: `jq . features/no-flicker/feature.json && jq . features/no-flicker/hooks.json`
Expected: Valid JSON
