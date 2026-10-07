// End-to-end runs of update-deps.mjs against an offline npm stand-in.
//
// The lock serializes the phase that mutates package.json / package-lock.json
// / node_modules. The registry check (`npm view`) must run without it: the
// updater is started from an async SessionStart hook and can be killed at any
// point, and a kill during a lock-holding `npm view` used to leave the lock
// behind forever.
import { spawn, spawnSync } from 'node:child_process'
import { once } from 'node:events'
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { delimiter, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import assert from 'node:assert/strict'
import { test } from 'node:test'

const updaterPath = fileURLToPath(new URL('../scripts/update-deps.mjs', import.meta.url))
const TARGETS = ['defuddle', 'jsdom', 'pdfjs-dist', 'undici']

// The npm stand-in is a POSIX shell script executed from the temp directory.
// This suite is also the updater's own test gate on user machines, so where
// that cannot work (Windows, a noexec temp mount) the tests are skipped
// instead of failing the gate.
function standInUnavailable() {
  if (process.platform === 'win32') return 'needs a POSIX shell'
  const dir = mkdtempSync(join(tmpdir(), 'wce-update-probe-'))
  try {
    const probe = join(dir, 'probe')
    writeFileSync(probe, '#!/bin/sh\nexit 0\n')
    chmodSync(probe, 0o755)
    const result = spawnSync(probe, [], { timeout: 10000 })
    return result.status === 0 ? false : 'cannot execute scripts from the temp directory'
  } catch {
    return 'cannot execute scripts from the temp directory'
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}
const skip = standInUnavailable()

// Records "<subcommand> <locked|unlocked>" for every call, so each test can
// assert whether the lock directory existed while npm was running.
const FAKE_NPM = `#!/bin/sh
skill="$FAKE_NPM_SKILL"
if [ -d "$skill/logs/.update.lock" ]; then state=locked; else state=unlocked; fi
printf '%s %s\\n' "$1" "$state" >> "$FAKE_NPM_TRACE"
case "$1" in
  view)
    if [ -n "\${FAKE_NPM_VIEW_BLOCK:-}" ]; then exec sleep 60; fi
    if [ -n "\${FAKE_NPM_BUMP_ON_VIEW:-}" ]; then
      printf '{"version":"%s"}\\n' "$FAKE_NPM_LATEST" \\
        > "$skill/node_modules/$2/package.json"
    fi
    if [ -n "\${FAKE_NPM_MARK_ON_VIEW:-}" ]; then
      # Another run's apply phase was interrupted while this check ran.
      mkdir -p "$skill/logs"
      printf '{"pid":1,"specs":[]}' > "$skill/logs/.update-in-progress"
    fi
    printf '%s\\n' "$FAKE_NPM_LATEST"
    ;;
  test)
    exit "\${FAKE_NPM_TEST_RC:-0}"
    ;;
esac
exit 0
`

function makeFixture(t, { installed = '1.0.0' } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'wce-update-run-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  // Mirror ~/.claude/skills/<skill>/ so the updater's manifest lookup
  // (two levels above the skill) stays inside the fixture.
  const skill = join(root, 'claude', 'skills', 'web-content-extraction')
  const scripts = join(skill, 'scripts')
  const bin = join(root, 'bin')
  mkdirSync(scripts, { recursive: true })
  mkdirSync(bin)
  const updater = join(scripts, 'update-deps.mjs')
  copyFileSync(updaterPath, updater)
  for (const pkg of TARGETS) {
    const dir = join(skill, 'node_modules', pkg)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'package.json'), `${JSON.stringify({ version: installed })}\n`)
  }
  writeFileSync(join(skill, 'package.json'), '{"name":"fixture"}\n')
  writeFileSync(join(skill, 'package-lock.json'), '{"lockfileVersion":3}\n')
  const npm = join(bin, 'npm')
  writeFileSync(npm, FAKE_NPM)
  chmodSync(npm, 0o755)
  const trace = join(root, 'npm.trace')
  const logs = join(skill, 'logs')
  return {
    skill,
    updater,
    trace,
    logs,
    lock: join(logs, '.update.lock'),
    stamp: join(logs, '.last-update-check'),
    marker: join(logs, '.update-in-progress'),
    env(extra = {}) {
      return {
        ...process.env,
        PATH: [bin, dirname(process.execPath), process.env.PATH].join(delimiter),
        FAKE_NPM_SKILL: skill,
        FAKE_NPM_TRACE: trace,
        FAKE_NPM_LATEST: '1.0.0',
        ...extra,
      }
    },
    traceLines() {
      return existsSync(trace)
        ? readFileSync(trace, 'utf8').split('\n').filter(Boolean)
        : []
    },
    log() {
      return readFileSync(join(logs, 'update.log'), 'utf8')
    },
  }
}

// Each run finishes in well under a second when the machine is idle. The
// timeout only guards against a hang: when it fires, the updater's SIGTERM
// handler exits 143 and the test fails, and on a user machine that failure
// rolls back a dependency update that was fine. So it stays far above what a
// heavily loaded host needs, inside the updater's 300s gate for `npm test`.
const RUN_TIMEOUT_MS = 120000

function run(fixture, extraEnv) {
  return spawnSync(process.execPath, [fixture.updater, '--force'], {
    encoding: 'utf8',
    env: fixture.env(extraEnv),
    timeout: RUN_TIMEOUT_MS,
  })
}

test('an up-to-date check never creates the lock', { skip }, (t) => {
  const fixture = makeFixture(t)
  const result = run(fixture)
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(fixture.traceLines(), TARGETS.map(() => 'view unlocked'))
  assert.match(fixture.log(), /done: all dependencies up-to-date/)
  assert.equal(existsSync(fixture.stamp), true)
  assert.equal(existsSync(fixture.lock), false)
})

test('SIGKILL during the registry check leaves no lock behind', { skip }, async (t) => {
  const fixture = makeFixture(t)
  // Own process group, so the blocked npm stand-in dies with the updater.
  const child = spawn(process.execPath, [fixture.updater, '--force'], {
    env: fixture.env({ FAKE_NPM_VIEW_BLOCK: '1' }),
    stdio: 'ignore',
    detached: true,
  })
  const exited = once(child, 'exit')
  const killGroup = () => {
    try { process.kill(-child.pid, 'SIGKILL') } catch { /* already gone */ }
  }
  t.after(killGroup)
  const deadline = Date.now() + RUN_TIMEOUT_MS
  while (fixture.traceLines().length === 0) {
    assert.ok(Date.now() < deadline, 'npm view was never started')
    assert.equal(child.exitCode, null, 'updater exited before npm view')
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  killGroup()
  const [code, signal] = await exited
  assert.equal(code, null)
  assert.equal(signal, 'SIGKILL')
  assert.deepEqual(fixture.traceLines(), ['view unlocked'])
  assert.equal(existsSync(fixture.lock), false)
})

test('the lock covers install and the test gate, and is released', { skip }, (t) => {
  const fixture = makeFixture(t)
  const result = run(fixture, { FAKE_NPM_LATEST: '2.0.0' })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(fixture.traceLines(), [
    ...TARGETS.map(() => 'view unlocked'),
    'install locked',
    'test locked',
  ])
  assert.match(fixture.log(), /DONE updated \(tests pass\)/)
  assert.equal(existsSync(fixture.stamp), true)
  assert.equal(existsSync(fixture.marker), false)
  assert.equal(existsSync(fixture.lock), false)
})

test('a held lock still blocks the apply phase and is never taken over', { skip }, (t) => {
  const fixture = makeFixture(t)
  mkdirSync(fixture.lock, { recursive: true })
  writeFileSync(join(fixture.lock, 'owner'), 'foreign-owner\n')
  const result = run(fixture, { FAKE_NPM_LATEST: '2.0.0' })
  assert.equal(result.status, 0, result.stderr)
  assert.match(fixture.log(), /skip: another update run is active \(lock held\)/)
  assert.equal(fixture.traceLines().some((line) => !line.startsWith('view ')), false)
  assert.equal(readFileSync(join(fixture.lock, 'owner'), 'utf8'), 'foreign-owner\n')
  // The run that owns the lock stamps the outcome; a skipped one must not.
  assert.equal(existsSync(fixture.stamp), false)
})

test('updates applied by another run while checking are not re-applied', { skip }, (t) => {
  const fixture = makeFixture(t)
  const result = run(fixture, { FAKE_NPM_LATEST: '2.0.0', FAKE_NPM_BUMP_ON_VIEW: '1' })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(fixture.traceLines(), TARGETS.map(() => 'view unlocked'))
  assert.match(fixture.log(), /done: all dependencies up-to-date/)
  assert.equal(existsSync(fixture.stamp), true)
  assert.equal(existsSync(fixture.lock), false)
})

test('an interrupted update is re-tested under the lock before checking', { skip }, (t) => {
  const fixture = makeFixture(t)
  mkdirSync(fixture.logs, { recursive: true })
  writeFileSync(fixture.marker, '{"pid":1,"specs":[]}')
  const result = run(fixture)
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(fixture.traceLines(), [
    'test locked',
    ...TARGETS.map(() => 'view unlocked'),
  ])
  assert.match(fixture.log(), /interrupted update accepted: tests pass/)
  assert.equal(existsSync(fixture.marker), false)
  assert.equal(existsSync(fixture.lock), false)
})

test('an update interrupted during the check is re-tested before stamping', { skip }, (t) => {
  const fixture = makeFixture(t)
  // No marker when the run starts; another run's apply phase leaves one
  // (installed versions already current) while `npm view` is running.
  const result = run(fixture, { FAKE_NPM_BUMP_ON_VIEW: '1', FAKE_NPM_MARK_ON_VIEW: '1' })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(fixture.traceLines(), [
    ...TARGETS.map(() => 'view unlocked'),
    'test locked',
  ])
  assert.match(fixture.log(), /interrupted update accepted: tests pass/)
  assert.equal(existsSync(fixture.marker), false)
  assert.equal(existsSync(fixture.lock), false)
  assert.equal(existsSync(fixture.stamp), true)
})

test('an update interrupted during the check is not stamped while its lock is held', { skip }, (t) => {
  const fixture = makeFixture(t)
  mkdirSync(fixture.lock, { recursive: true })
  writeFileSync(join(fixture.lock, 'owner'), 'foreign-owner\n')
  const result = run(fixture, { FAKE_NPM_MARK_ON_VIEW: '1' })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(fixture.traceLines().length, TARGETS.length)
  assert.equal(fixture.traceLines().some((line) => !line.startsWith('view ')), false)
  assert.match(fixture.log(), /skip: another update run is active \(lock held\)/)
  // The untested state belongs to the lock holder; a 24h stamp here would
  // hide the marker from every later run.
  assert.equal(existsSync(fixture.stamp), false)
  assert.equal(existsSync(fixture.marker), true)
  assert.equal(readFileSync(join(fixture.lock, 'owner'), 'utf8'), 'foreign-owner\n')
})

test('a failed test gate rolls back under the lock and releases it', { skip }, (t) => {
  const fixture = makeFixture(t)
  const result = run(fixture, { FAKE_NPM_LATEST: '2.0.0', FAKE_NPM_TEST_RC: '1' })
  assert.equal(result.status, 1, result.stderr)
  assert.deepEqual(fixture.traceLines(), [
    ...TARGETS.map(() => 'view unlocked'),
    'install locked',
    'test locked',
    'ci locked',
  ])
  assert.match(fixture.log(), /npm test FAIL after update/)
  assert.equal(existsSync(fixture.marker), false)
  assert.equal(existsSync(fixture.lock), false)
})

test('an interrupted update bypasses the 24h throttle on the next start', { skip }, (t) => {
  // A run that saw no marker can stamp 24h just after another run's apply
  // phase left one and was killed. The next (throttled) start must still
  // re-test it, without running the throttled registry check.
  const fixture = makeFixture(t)
  mkdirSync(fixture.logs, { recursive: true })
  const nextAllowed = String(Date.now() + 24 * 60 * 60 * 1000)
  writeFileSync(fixture.stamp, nextAllowed)
  writeFileSync(fixture.marker, '{"pid":1,"specs":[]}')
  const result = spawnSync(process.execPath, [fixture.updater], {
    encoding: 'utf8',
    env: fixture.env(),
    timeout: RUN_TIMEOUT_MS,
  })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(fixture.traceLines(), ['test locked'])
  assert.match(fixture.log(), /interrupted update accepted: tests pass/)
  assert.equal(existsSync(fixture.marker), false)
  assert.equal(existsSync(fixture.lock), false)
  assert.equal(readFileSync(fixture.stamp, 'utf8'), nextAllowed)
})

test('a throttled start without a marker does nothing', { skip }, (t) => {
  const fixture = makeFixture(t)
  mkdirSync(fixture.logs, { recursive: true })
  writeFileSync(fixture.stamp, String(Date.now() + 24 * 60 * 60 * 1000))
  const result = spawnSync(process.execPath, [fixture.updater], {
    encoding: 'utf8',
    env: fixture.env(),
    timeout: RUN_TIMEOUT_MS,
  })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(fixture.traceLines(), [])
  assert.equal(existsSync(fixture.lock), false)
})
