#!/usr/bin/env node
// update-deps.mjs [--force]
//
// Auto-updates this skill's dependencies (defuddle, jsdom, pdfjs-dist) to the
// latest released versions, then runs the test suite. If tests fail, the
// update is rolled back. Intended to run in the background from a SessionStart
// hook when Claude Code starts.
//
// Safety:
//   - Throttled to once per 24h (override with --force).
//   - Lock file prevents concurrent runs (e.g. multiple sessions starting).
//   - package.json + package-lock.json are backed up and restored on test fail.
//   - All output is appended to logs/update.log; never writes to stdout JSON.
//
// "Latest release" = npm `latest` dist-tag (`npm view <pkg> version`), which is
// the installable published release and tracks the upstream GitHub release.

import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, copyFileSync, existsSync, mkdirSync, rmSync, statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const SKILL_DIR = join(dirname(fileURLToPath(import.meta.url)), '..')
const LOG_DIR = join(SKILL_DIR, 'logs')
const LOG_FILE = join(LOG_DIR, 'update.log')
const LOCK_FILE = join(LOG_DIR, '.update.lock')
const STAMP_FILE = join(LOG_DIR, '.last-update-check')
const PKG_JSON = join(SKILL_DIR, 'package.json')
const LOCK_JSON = join(SKILL_DIR, 'package-lock.json')

const TARGETS = ['defuddle', 'jsdom', 'pdfjs-dist']
const THROTTLE_MS = 24 * 60 * 60 * 1000 // next check after a clean run
const BACKOFF_MS = 60 * 60 * 1000 // shorter retry after a failed run
const LOCK_STALE_MS = 30 * 60 * 1000 // a lock older than this is considered dead
const force = process.argv.includes('--force')

function ensureLogDir() {
  if (!existsSync(LOG_DIR)) mkdirSync(LOG_DIR, { recursive: true })
}

function log(message) {
  ensureLogDir()
  const line = `[${new Date().toISOString()}] ${message}\n`
  try {
    writeFileSync(LOG_FILE, line, { flag: 'a' })
  } catch {
    /* logging must never throw */
  }
}

/** Compare semver-ish strings. Returns >0 if a>b, <0 if a<b, 0 if equal. */
function compareVersions(a, b) {
  const parse = (v) => {
    const [core, pre] = String(v).split('-')
    const nums = core.split('.').map((n) => Number.parseInt(n, 10) || 0)
    return { nums, pre: pre ?? '' }
  }
  const pa = parse(a)
  const pb = parse(b)
  for (let i = 0; i < 3; i++) {
    const d = (pa.nums[i] ?? 0) - (pb.nums[i] ?? 0)
    if (d !== 0) return d
  }
  // No prerelease (release) ranks higher than a prerelease of the same core.
  if (pa.pre === pb.pre) return 0
  if (pa.pre === '') return 1
  if (pb.pre === '') return -1
  return pa.pre > pb.pre ? 1 : -1
}

function installedVersion(pkg) {
  try {
    return JSON.parse(readFileSync(join(SKILL_DIR, 'node_modules', pkg, 'package.json'), 'utf8')).version
  } catch {
    return null
  }
}

function latestVersion(pkg) {
  // npm view hits the registry; may throw on network failure (handled by caller).
  const out = execFileSync('npm', ['view', pkg, 'version'], {
    cwd: SKILL_DIR,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    timeout: 30000,
  })
  return out.trim()
}

function acquireLock() {
  ensureLogDir()
  try {
    writeFileSync(LOCK_FILE, String(process.pid), { flag: 'wx' }) // atomic create
    return true
  } catch (error) {
    if (error?.code !== 'EEXIST') throw error
    // Lock exists: take it over only if it is stale (previous run likely died).
    try {
      const age = Date.now() - statSync(LOCK_FILE).mtimeMs
      if (age < LOCK_STALE_MS) return false
    } catch {
      return false
    }
    try {
      rmSync(LOCK_FILE, { force: true })
      writeFileSync(LOCK_FILE, String(process.pid), { flag: 'wx' })
      return true
    } catch {
      return false // lost a race with another reclaiming run
    }
  }
}

function releaseLock() {
  try {
    rmSync(LOCK_FILE, { force: true })
  } catch {
    /* ignore */
  }
}

function throttled() {
  if (force) return false
  try {
    // Stamp stores the epoch (ms) at which the next check is allowed.
    const nextAllowed = Number(readFileSync(STAMP_FILE, 'utf8').trim())
    return Number.isFinite(nextAllowed) && Date.now() < nextAllowed
  } catch {
    return false // no stamp yet -> not throttled
  }
}

/** Record when the next check may run: 24h after a clean run, 1h after a failure. */
function stampOutcome(outcome) {
  ensureLogDir()
  const delay = outcome === 'ok' ? THROTTLE_MS : BACKOFF_MS
  writeFileSync(STAMP_FILE, String(Date.now() + delay))
}

function main() {
  if (throttled()) return 0
  if (!acquireLock()) {
    log('skip: another update run is active (lock held)')
    return 0
  }

  let outcome = 'ok' // becomes 'failed' on any check/install/test failure -> short backoff
  try {
    log('check start')

    const updates = []
    for (const pkg of TARGETS) {
      const installed = installedVersion(pkg)
      if (!installed) {
        log(`${pkg}: not installed, skipping`)
        continue
      }
      let latest
      try {
        latest = latestVersion(pkg)
      } catch (error) {
        log(`${pkg}: 最新版の取得に失敗 (${error?.message ?? error}) — skip`)
        outcome = 'failed' // a target could not be checked -> retry sooner
        continue
      }
      if (compareVersions(latest, installed) > 0) {
        log(`${pkg} ${installed} -> ${latest} (update available)`)
        updates.push({ pkg, installed, latest })
      } else {
        log(`${pkg} up-to-date (${installed})`)
      }
    }

    if (updates.length === 0) {
      log('done: all dependencies up-to-date')
      return 0
    }

    // Back up manifests before mutating.
    const backups = []
    for (const f of [PKG_JSON, LOCK_JSON]) {
      if (existsSync(f)) {
        copyFileSync(f, f + '.bak')
        backups.push(f)
      }
    }

    const specs = updates.map((u) => `${u.pkg}@${u.latest}`)
    log(`applying updates: ${specs.join(', ')}`)
    try {
      execFileSync('npm', ['install', ...specs], {
        cwd: SKILL_DIR,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
        timeout: 300000,
      })
    } catch (error) {
      log(`npm install 失敗: ${error?.message ?? error} — rolling back`)
      outcome = 'failed'
      rollback(backups)
      return 1
    }

    // Verify with the test suite.
    try {
      execFileSync('npm', ['test'], {
        cwd: SKILL_DIR,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
        timeout: 300000,
      })
    } catch (error) {
      log(`npm test FAIL after update — rolling back. (${error?.message ?? 'tests failed'})`)
      outcome = 'failed'
      rollback(backups)
      return 1
    }

    // Success: drop backups.
    for (const f of backups) {
      try {
        rmSync(f + '.bak', { force: true })
      } catch {
        /* ignore */
      }
    }
    const summary = updates.map((u) => `${u.pkg} ${u.installed}->${u.latest}`).join(', ')
    log(`DONE updated (tests pass): ${summary}`)
    return 0
  } finally {
    // Stamp AFTER a completed run: 24h on a clean run, 1h backoff on failure, so
    // transient npm/network failures retry sooner. Runs skipped by throttle/lock
    // never reach here, so they don't reset the timer.
    log(`run outcome: ${outcome}`)
    stampOutcome(outcome)
    releaseLock()
  }
}

function rollback(backups) {
  for (const f of backups) {
    try {
      copyFileSync(f + '.bak', f)
      rmSync(f + '.bak', { force: true })
    } catch (error) {
      log(`rollback restore 失敗 (${f}): ${error?.message ?? error}`)
    }
  }
  // `npm ci` reinstalls strictly from the restored lockfile, guaranteeing
  // node_modules matches the previous versions (no partial-upgrade drift).
  try {
    execFileSync('npm', ['ci'], {
      cwd: SKILL_DIR,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 300000,
    })
    log('rollback complete: dependencies restored to previous versions (npm ci)')
  } catch (error) {
    log(`rollback npm ci 失敗: ${error?.message ?? error} — manual fix may be needed`)
  }
}

process.exit(main())
