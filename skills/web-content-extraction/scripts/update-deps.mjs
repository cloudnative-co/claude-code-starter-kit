#!/usr/bin/env node
// update-deps.mjs [--force]
//
// Auto-updates this skill's dependencies (defuddle, jsdom, pdfjs-dist, undici) to the
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
import { randomUUID } from 'node:crypto'
import {
  closeSync,
  constants as fsConstants,
  copyFileSync,
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  rmdirSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, resolve } from 'node:path'

const SKILL_DIR = join(dirname(fileURLToPath(import.meta.url)), '..')
const LOG_DIR = join(SKILL_DIR, 'logs')
const LOG_FILE = join(LOG_DIR, 'update.log')
const LOCK_FILE = join(LOG_DIR, '.update.lock')
const IN_PROGRESS_FILE = join(LOG_DIR, '.update-in-progress')
const STAMP_FILE = join(LOG_DIR, '.last-update-check')
const PKG_JSON = join(SKILL_DIR, 'package.json')
const LOCK_JSON = join(SKILL_DIR, 'package-lock.json')
const KIT_MANIFEST = join(SKILL_DIR, '..', '..', '.starter-kit-manifest.json')

const TARGETS = ['defuddle', 'jsdom', 'pdfjs-dist', 'undici']
const THROTTLE_MS = 24 * 60 * 60 * 1000 // next check after a clean run
const BACKOFF_MS = 60 * 60 * 1000 // shorter retry after a failed run
const force = process.argv.includes('--force')

function ensureLogDir() {
  if (!existsSync(LOG_DIR)) mkdirSync(LOG_DIR, { recursive: true })
  const stat = lstatSync(LOG_DIR)
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error(`unsafe log directory: ${LOG_DIR}`)
  }
}

function log(message) {
  const line = `[${new Date().toISOString()}] ${message}\n`
  try {
    ensureLogDir()
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

export function acquireLock(lockFile = LOCK_FILE) {
  const logDir = dirname(lockFile)
  mkdirSync(logDir, { recursive: true })
  const logStat = lstatSync(logDir)
  if (!logStat.isDirectory() || logStat.isSymbolicLink()) {
    throw new Error(`unsafe lock parent: ${logDir}`)
  }
  const token = `${process.pid}:${randomUUID()}`
  try {
    // mkdir is the common shell/Node lock primitive. Unlike shell noclobber
    // redirection it never opens an existing FIFO, symlink, or device.
    mkdirSync(lockFile, { mode: 0o700 })
  } catch (error) {
    if (error?.code === 'EEXIST') return null
    throw error
  }
  try {
    writeFileSync(join(lockFile, 'owner'), `${token}\n`, {
      flag: 'wx',
      mode: 0o600,
    })
    return token
  } catch (error) {
    // The directory is ours because this call created it. Remove only the
    // expected empty/owner-only shape; any foreign addition fails closed.
    try { rmdirSync(lockFile) } catch { /* leave residue for inspection */ }
    throw error
  }
}

function openOwnedLock(token, lockDirectory) {
  let ownerFd
  try {
    const lockStat = lstatSync(lockDirectory)
    const ownerPath = join(lockDirectory, 'owner')
    if (!lockStat.isDirectory() || lockStat.isSymbolicLink()) return null
    ownerFd = openSync(ownerPath,
      fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW | fsConstants.O_NONBLOCK)
    const expected = Buffer.from(`${token}\n`)
    const before = fstatSync(ownerFd)
    if (!before.isFile() || before.size !== expected.length) return null
    const actual = Buffer.alloc(expected.length + 1)
    const bytes = readSync(ownerFd, actual, 0, actual.length, 0)
    const after = fstatSync(ownerFd)
    if (bytes !== expected.length
      || after.dev !== before.dev
      || after.ino !== before.ino
      || after.size !== expected.length
      || !actual.subarray(0, bytes).equals(expected)) return null
    const owned = { fd: ownerFd, dev: before.dev, ino: before.ino }
    ownerFd = undefined
    return owned
  } catch {
    return null
  } finally {
    if (ownerFd !== undefined) {
      try { closeSync(ownerFd) } catch { /* ignore */ }
    }
  }
}

function closeOwnedLock(owned) {
  if (!owned) return
  try { closeSync(owned.fd) } catch { /* ignore */ }
}

function lockOwnerMatchesPinned(owned, lockDirectory) {
  try {
    const ownerStat = lstatSync(join(lockDirectory, 'owner'))
    const fdStat = fstatSync(owned.fd)
    return ownerStat.isFile()
      && !ownerStat.isSymbolicLink()
      && ownerStat.dev === owned.dev
      && ownerStat.ino === owned.ino
      && fdStat.dev === owned.dev
      && fdStat.ino === owned.ino
  } catch {
    return false
  }
}

function lockOwnerOnly(lockDirectory) {
  try {
    const entries = readdirSync(lockDirectory)
    return entries.length === 1 && entries[0] === 'owner'
  } catch {
    return false
  }
}

function pathExistsNoFollow(path) {
  try {
    lstatSync(path)
    return true
  } catch {
    return false
  }
}

export function releaseLock(token, lockFile = LOCK_FILE) {
  if (!/^[A-Za-z0-9._:-]+$/.test(token)) return false
  const quarantine = `${lockFile}.release-${token.replaceAll(':', '-')}`
  let owned = null
  try {
    if (pathExistsNoFollow(quarantine)) {
      owned = openOwnedLock(token, quarantine)
      if (!owned || !lockOwnerOnly(quarantine)) return false
    } else {
      owned = openOwnedLock(token, lockFile)
      if (!owned || !lockOwnerOnly(lockFile)) return false
      renameSync(lockFile, quarantine)
    }
    if (!lockOwnerMatchesPinned(owned, quarantine) || !lockOwnerOnly(quarantine)) {
      // A foreign directory won the read->rename race. Restore it to the
      // canonical name only when no successor owns that name; otherwise
      // retain both paths and let the new canonical owner proceed.
      if (!pathExistsNoFollow(lockFile)) {
        try {
          renameSync(quarantine, lockFile)
        } catch {
          // Preserve every foreign inode for explicit recovery.
        }
      }
      return false
    }
    unlinkSync(join(quarantine, 'owner'))
    rmdirSync(quarantine)
    return true
  } catch {
    return false
  } finally {
    closeOwnedLock(owned)
  }
}

export function installLockSignalHandlers(tokenOrGetter, lockFile = LOCK_FILE) {
  const signalStatuses = [
    ['SIGHUP', 129],
    ['SIGINT', 130],
    ['SIGTERM', 143],
  ]
  const handlers = new Map()
  for (const [signal, status] of signalStatuses) {
    const handler = () => {
      const token = typeof tokenOrGetter === 'function'
        ? tokenOrGetter()
        : tokenOrGetter
      if (token) releaseLock(token, lockFile)
      process.exit(status)
    }
    handlers.set(signal, handler)
    process.once(signal, handler)
  }
  return () => {
    for (const [signal, handler] of handlers) {
      process.off(signal, handler)
    }
  }
}

function backupFiles() {
  const backups = []
  for (const f of [PKG_JSON, LOCK_JSON]) {
    if (existsSync(f)) {
      copyFileSync(f, f + '.bak')
      backups.push(f)
    }
  }
  return backups
}

function existingBackups() {
  return [PKG_JSON, LOCK_JSON].filter((f) => existsSync(f + '.bak'))
}

function markUpdateInProgress(specs) {
  ensureLogDir()
  writeFileSync(IN_PROGRESS_FILE, JSON.stringify({ pid: process.pid, specs, startedAt: new Date().toISOString() }))
}

function clearUpdateInProgress() {
  try {
    rmSync(IN_PROGRESS_FILE, { force: true })
  } catch {
    /* ignore */
  }
}

function runTestGate() {
  execFileSync('npm', ['test'], {
    cwd: SKILL_DIR,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 300000,
  })
}

function recoverInterruptedUpdate() {
  if (!existsSync(IN_PROGRESS_FILE)) return true
  const backups = existingBackups()
  log('found interrupted dependency update; re-running test gate')
  try {
    runTestGate()
    for (const f of backups) rmSync(f + '.bak', { force: true })
    clearUpdateInProgress()
    log('interrupted update accepted: tests pass')
    return true
  } catch (error) {
    log(`interrupted update failed tests — rolling back. (${error?.message ?? 'tests failed'})`)
    rollback(backups)
    clearUpdateInProgress()
    return false
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

function isMdmManaged() {
  try {
    return JSON.parse(readFileSync(KIT_MANIFEST, 'utf8')).mdm_managed === true
  } catch {
    return false
  }
}

function main() {
  // MDM compliance attests package.json and package-lock.json byte-for-byte.
  // Runtime dependency mutation would create a permanent remediation loop.
  if (isMdmManaged()) {
    log('skip: dependency versions are pinned by MDM expected state')
    return 0
  }
  if (throttled()) return 0
  let lockToken = null
  const removeLockSignalHandlers = installLockSignalHandlers(() => lockToken)
  let outcome = 'ok' // becomes 'failed' on any check/install/test failure -> short backoff
  try {
    lockToken = acquireLock()
    if (!lockToken) {
      log('skip: another update run is active (lock held)')
      return 0
    }
    if (!recoverInterruptedUpdate()) {
      outcome = 'failed'
      return 1
    }
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
    const backups = backupFiles()

    const specs = updates.map((u) => `${u.pkg}@${u.latest}`)
    log(`applying updates: ${specs.join(', ')}`)
    markUpdateInProgress(specs)
    try {
      // --ignore-scripts: never run lifecycle scripts of newly resolved deps;
      // the test gate only catches broken behavior, not malicious install hooks.
      execFileSync('npm', ['install', '--ignore-scripts', ...specs], {
        cwd: SKILL_DIR,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
        timeout: 300000,
      })
    } catch (error) {
      log(`npm install 失敗: ${error?.message ?? error} — rolling back`)
      outcome = 'failed'
      rollback(backups)
      clearUpdateInProgress()
      return 1
    }

    // Verify with the test suite.
    try {
      runTestGate()
    } catch (error) {
      log(`npm test FAIL after update — rolling back. (${error?.message ?? 'tests failed'})`)
      outcome = 'failed'
      rollback(backups)
      clearUpdateInProgress()
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
    clearUpdateInProgress()
    const summary = updates.map((u) => `${u.pkg} ${u.installed}->${u.latest}`).join(', ')
    log(`DONE updated (tests pass): ${summary}`)
    return 0
  } finally {
    // Stamp AFTER a completed run: 24h on a clean run, 1h backoff on failure, so
    // transient npm/network failures retry sooner. Runs skipped by
    // throttle/lock do not own a token and therefore do not reset the timer.
    if (lockToken) {
      log(`run outcome: ${outcome}`)
      try {
        stampOutcome(outcome)
      } catch (error) {
        // The stamp is advisory. Preserve main's original result while still
        // guaranteeing release of the token-bound writer lock.
        log(`outcome stamp failed: ${error?.message ?? error}`)
      } finally {
        if (!releaseLock(lockToken)) {
          log('lock release skipped: lock owner token changed or lock is missing')
        }
      }
    }
    // Keep signal cleanup installed through one event-loop turn so a signal
    // queued during a synchronous release syscall can publish status 128+n.
    setImmediate(removeLockSignalHandlers)
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
    execFileSync('npm', ['ci', '--ignore-scripts'], {
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

if (process.argv[1]
  && realpathSync(resolve(process.argv[1])) === realpathSync(fileURLToPath(import.meta.url))) {
  // Let the event loop deliver a signal queued during a synchronous
  // stamp/release syscall. The installed handler then preserves 128+signal;
  // process.exit(main()) would discard that pending callback immediately.
  process.exitCode = main()
}
