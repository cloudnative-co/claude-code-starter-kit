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
//   - A lock serializes the apply phase (npm install / test / rollback) with
//     other sessions and with kit setup / update / npm ci. The registry check
//     (`npm view`) runs without it, so a run killed while checking leaves no
//     lock behind.
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
  } catch (error) {
    // The directory is ours because this call created it. Remove only the
    // expected empty/owner-only shape; any foreign addition fails closed.
    try { rmdirSync(lockFile) } catch { /* leave residue for inspection */ }
    throw error
  }
  // The kit's setup recovers an abandoned lock under `<lock>.reclaim`. It
  // re-reads the lock after creating that mutex, so an owner written before
  // the mutex appeared is seen and left alone; one completed after it would
  // not be. This check runs after the owner write, which makes one of the two
  // orderings certain: withdraw the lock when the mutex is there. The
  // reclaimer may already have moved this directory aside, in which case the
  // removals fail and it puts the directory back or keeps it for inspection.
  // Withdraw through the token-checked release: by now the recovery may have
  // finished and another writer may hold the canonical name, and that
  // writer's lock must not be removed.
  // Wait for the reclaimer to finish first. The release checks the owner and
  // then renames; while the reclaimer is active it can move this lock aside
  // between those two steps, and after it releases the mutex another writer
  // can take the canonical name, which the rename would then move. Once the
  // mutex is gone nothing else renames this live, fresh lock. A mutex that
  // outlasts the wait does not prove the reclaimer dead (it may only be
  // stalled), so the same race stays open: leave this lock in place and
  // fail. Its owner names this process, so once it exits the lock is a
  // recognized abandoned lock that the kit's preflight diagnoses or recovers.
  if (reclaimMutexExists(lockFile)) {
    if (!waitForReclaimMutex(lockFile)) return null
    releaseLock(token, lockFile)
    return null
  }
  // A whole recovery can also start and finish between the owner write and
  // the mutex check above: the reclaimer moves this directory aside in a
  // read-to-rename race and then cannot put it back because another writer
  // took the canonical name in the meantime. The mutex is gone again, so only
  // the canonical path tells which writer holds the lock. Succeed only while
  // it still carries this token; otherwise leave everything where the
  // reclaimer left it (it names that path) and report the lock as held.
  const owned = openOwnedLock(token, lockFile)
  const ours = owned !== null && lockOwnerOnly(lockFile)
  closeOwnedLock(owned)
  return ours ? token : null
}

// Same bound as _WCE_RUNTIME_LOCK_WITHDRAW_WAIT_SECONDS in the kit's setup.
const RECLAIM_WITHDRAW_WAIT_MS = 3000

function waitForReclaimMutex(lockFile) {
  const pause = new Int32Array(new SharedArrayBuffer(4))
  const deadline = Date.now() + RECLAIM_WITHDRAW_WAIT_MS
  while (reclaimMutexExists(lockFile) && Date.now() < deadline) {
    Atomics.wait(pause, 0, 0, 50)
  }
  return !reclaimMutexExists(lockFile)
}

function reclaimMutexExists(lockFile) {
  try {
    lstatSync(`${lockFile}.reclaim`)
    return true
  } catch {
    return false
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
  // The marker of an interrupted apply phase bypasses the throttle. A run that
  // found no marker can still stamp 24h after another run's apply phase left
  // one (that run can be killed between this run's marker check and its
  // stamp). Checking the marker first makes the next start recover it anyway.
  const isThrottled = throttled()
  if (isThrottled && !existsSync(IN_PROGRESS_FILE)) return 0
  let lockToken = null
  const removeLockSignalHandlers = installLockSignalHandlers(() => lockToken)
  const dropLock = () => {
    if (!lockToken) return
    if (!releaseLock(lockToken)) {
      log('lock release skipped: lock owner token changed or lock is missing')
    }
    lockToken = null
  }
  let outcome = 'ok' // becomes 'failed' on any check/install/test failure -> short backoff
  // True once this run reached a result of its own. A run that only lost the
  // lock to another writer leaves the timer to that writer.
  let completed = false
  try {
    // An apply phase that died mid-way left its marker. Re-testing (and a
    // possible rollback) mutates the package pair and node_modules, so it
    // runs under the lock, which is dropped again before the registry check.
    if (existsSync(IN_PROGRESS_FILE)) {
      lockToken = acquireLock()
      if (!lockToken) {
        log('skip: another update run is active (lock held)')
        return 0
      }
      completed = true
      if (!recoverInterruptedUpdate()) {
        outcome = 'failed'
        return 1
      }
      dropLock()
      if (isThrottled) {
        // Only the recovery was due; the registry check keeps its timer. A
        // failed recovery above still stamps the short backoff.
        log('done: registry check throttled')
        completed = false
        return 0
      }
    }
    if (isThrottled) return 0

    // The registry check holds no lock. This process is started by an async
    // SessionStart hook and can be killed at any point, and the HUP/INT/TERM
    // handlers cannot run while execFileSync blocks on npm. A lock held across
    // `npm view` stayed behind when the process was killed there, and then
    // blocked every later kit update.
    log('check start')
    const check = checkForUpdates()
    if (check.failed) outcome = 'failed'
    completed = true
    // Another run's apply phase may have been interrupted while this check
    // ran: the installed versions then look current, but they are untested
    // and the marker is still there. Stamping 24h here would hide it from
    // every later run, so such a run goes through the locked path below.
    if (check.updates.length === 0 && !existsSync(IN_PROGRESS_FILE)) {
      log('done: all dependencies up-to-date')
      return 0
    }

    // Only the apply phase needs exclusion from kit setup / update / npm ci.
    lockToken = acquireLock()
    if (!lockToken) {
      log('skip: another update run is active (lock held)')
      completed = false
      return 0
    }
    if (!recoverInterruptedUpdate()) {
      outcome = 'failed'
      return 1
    }
    // The check ran unlocked, so another run may have applied these updates
    // (or a kit update may have replaced node_modules) since. Decide again
    // from what is installed now.
    const updates = []
    for (const candidate of check.updates) {
      const installed = installedVersion(candidate.pkg)
      if (installed && compareVersions(candidate.latest, installed) > 0) {
        updates.push({ ...candidate, installed })
      } else {
        log(`${candidate.pkg} no longer needs ${candidate.latest} (installed: ${installed ?? 'none'})`)
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
    // transient npm/network failures retry sooner. Runs skipped by throttle,
    // or stopped by another writer's lock, do not reset the timer.
    try {
      if (completed) {
        log(`run outcome: ${outcome}`)
        try {
          stampOutcome(outcome)
        } catch (error) {
          // The stamp is advisory. Preserve main's original result while still
          // guaranteeing release of the token-bound writer lock.
          log(`outcome stamp failed: ${error?.message ?? error}`)
        }
      }
    } finally {
      dropLock()
    }
    // Keep signal cleanup installed through one event-loop turn so a signal
    // queued during a synchronous release syscall can publish status 128+n.
    setImmediate(removeLockSignalHandlers)
  }
}

/**
 * Compare installed versions with the registry. Takes no lock: it only reads
 * node_modules and runs `npm view`.
 */
function checkForUpdates() {
  const updates = []
  let failed = false
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
      failed = true // a target could not be checked -> retry sooner
      continue
    }
    if (compareVersions(latest, installed) > 0) {
      log(`${pkg} ${installed} -> ${latest} (update available)`)
      updates.push({ pkg, installed, latest })
    } else {
      log(`${pkg} up-to-date (${installed})`)
    }
  }
  return { updates, failed }
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
