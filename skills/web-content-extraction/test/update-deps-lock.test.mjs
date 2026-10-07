import { spawn, spawnSync } from 'node:child_process'
import { once } from 'node:events'
import fs from 'node:fs'
import { syncBuiltinESMExports } from 'node:module'
import {
  existsSync,
  copyFileSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  acquireLock,
  releaseLock,
} from '../scripts/update-deps.mjs'

const updaterUrl = new URL('../scripts/update-deps.mjs', import.meta.url)

test('dependency lock never reclaims an existing stale inode', (t) => {
  const root = mkdtempSync(join(tmpdir(), 'wce-update-lock-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const lockFile = join(root, 'logs', '.update.lock')

  mkdirSync(join(root, 'logs'))
  mkdirSync(lockFile)
  writeFileSync(join(lockFile, 'owner'), 'foreign-owner\n')
  const old = new Date('2000-01-01T00:00:00Z')
  utimesSync(lockFile, old, old)
  assert.equal(acquireLock(lockFile), null)
  assert.equal(readFileSync(join(lockFile, 'owner'), 'utf8'), 'foreign-owner\n')

  rmSync(lockFile, { recursive: true })
  const token = acquireLock(lockFile)
  assert.equal(typeof token, 'string')
  assert.equal(acquireLock(lockFile), null)
  assert.equal(releaseLock('not-the-owner', lockFile), false)
  assert.equal(readFileSync(join(lockFile, 'owner'), 'utf8'), `${token}\n`)
  assert.equal(releaseLock(token, lockFile), true)
  assert.equal(existsSync(lockFile), false)
})

test('dependency lock backs off while the kit reclaim mutex exists', (t) => {
  // setup.sh recovers an abandoned lock under `<lock>.reclaim` and re-reads
  // the lock only after creating that mutex. An acquisition completed after
  // the mutex appeared would go unseen, so acquireLock checks for the mutex
  // after writing its owner and fails when it is there. A mutex that outlasts
  // the withdrawal wait (here one left by a killed reclaimer) does not prove
  // the reclaimer dead, so the lock is left in place rather than renamed.
  const root = mkdtempSync(join(tmpdir(), 'wce-update-lock-mutex-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const logs = join(root, 'logs')
  const lockFile = join(logs, '.update.lock')
  const mutex = `${lockFile}.reclaim`
  mkdirSync(logs)
  mkdirSync(mutex)

  assert.equal(acquireLock(lockFile), null)
  assert.match(readFileSync(join(lockFile, 'owner'), 'utf8'), /^\d+:[0-9a-f-]{36}\n$/)
  assert.equal(lstatSync(mutex).isDirectory(), true)
  assert.equal(acquireLock(lockFile), null)

  rmSync(mutex, { recursive: true })
  rmSync(lockFile, { recursive: true })
  const token = acquireLock(lockFile)
  assert.equal(typeof token, 'string')
  assert.equal(releaseLock(token, lockFile), true)
})

test('dependency lock fails when a recovery displaced it before the mutex check', (t) => {
  // A whole kit recovery can run between the owner write and the mutex
  // check: it moves this directory aside (read-to-rename race), cannot put it
  // back because writer B took the canonical name, and releases the mutex.
  // The mutex check then passes, so acquisition must verify the canonical
  // owner or both writers would proceed.
  const root = mkdtempSync(join(tmpdir(), 'wce-update-lock-displaced-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const lockFile = join(root, 'logs', '.update.lock')
  const quarantine = `${lockFile}.stale-test`
  const writeFile = fs.writeFileSync
  t.after(() => {
    fs.writeFileSync = writeFile
    syncBuiltinESMExports()
  })
  let displaced = false
  fs.writeFileSync = function (path, ...rest) {
    const result = writeFile.call(this, path, ...rest)
    if (!displaced && path === join(lockFile, 'owner')) {
      displaced = true
      fs.renameSync(lockFile, quarantine)
      fs.mkdirSync(lockFile)
      writeFile(join(lockFile, 'owner'), 'writer-b\n')
    }
    return result
  }
  syncBuiltinESMExports()

  assert.equal(acquireLock(lockFile), null)
  fs.writeFileSync = writeFile
  syncBuiltinESMExports()
  assert.equal(displaced, true)
  assert.equal(readFileSync(join(lockFile, 'owner'), 'utf8'), 'writer-b\n')
  // The displaced directory stays where the reclaimer left it.
  assert.match(readFileSync(join(quarantine, 'owner'), 'utf8'), /^\d+:[0-9a-f-]{36}\n$/)
})

test('dependency lock withdrawal never removes another writer\'s lock', (t) => {
  // The mutex check sees the recovery, but before the withdrawal runs the
  // recovery moves this directory aside and writer B takes the canonical
  // name. Withdrawing must check the token and leave B's lock in place.
  const root = mkdtempSync(join(tmpdir(), 'wce-update-lock-withdraw-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const lockFile = join(root, 'logs', '.update.lock')
  const quarantine = `${lockFile}.stale-test`
  const writeFile = fs.writeFileSync
  t.after(() => {
    fs.writeFileSync = writeFile
    syncBuiltinESMExports()
  })
  let displaced = false
  fs.writeFileSync = function (path, ...rest) {
    const result = writeFile.call(this, path, ...rest)
    if (!displaced && path === join(lockFile, 'owner')) {
      displaced = true
      fs.mkdirSync(`${lockFile}.reclaim`)
      fs.renameSync(lockFile, quarantine)
      fs.mkdirSync(lockFile)
      writeFile(join(lockFile, 'owner'), 'writer-b\n')
    }
    return result
  }
  syncBuiltinESMExports()

  assert.equal(acquireLock(lockFile), null)
  fs.writeFileSync = writeFile
  syncBuiltinESMExports()
  assert.equal(displaced, true)
  assert.equal(readFileSync(join(lockFile, 'owner'), 'utf8'), 'writer-b\n')
  assert.deepEqual(readdirSync(lockFile), ['owner'])
  assert.match(readFileSync(join(quarantine, 'owner'), 'utf8'), /^\d+:[0-9a-f-]{36}\n$/)
})

test('dependency lock withdrawal waits for the reclaimer before renaming', (t) => {
  // The reclaimer is active when the mutex check runs. If the withdrawal
  // checked its owner and renamed while the reclaimer still worked, the
  // reclaimer could move this lock aside between the two steps, writer B
  // could take the canonical name after the mutex is released, and the
  // rename would move B's lock (writer C then takes the free name). Waiting
  // for the mutex first leaves the withdrawal nothing to rename.
  const root = mkdtempSync(join(tmpdir(), 'wce-update-lock-withdraw-wait-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const lockFile = join(root, 'logs', '.update.lock')
  const mutex = `${lockFile}.reclaim`
  const quarantine = `${lockFile}.stale-test`
  const writeFile = fs.writeFileSync
  const lstat = fs.lstatSync
  const rename = fs.renameSync
  const restore = () => {
    fs.writeFileSync = writeFile
    fs.lstatSync = lstat
    fs.renameSync = rename
    syncBuiltinESMExports()
  }
  t.after(restore)
  let mutexLooks = 0
  let recovered = false
  // The reclaimer moves this lock aside and finishes; writer B acquires.
  const finishRecoveryThenB = () => {
    if (recovered) return
    recovered = true
    rename(lockFile, quarantine)
    fs.rmdirSync(mutex)
    fs.mkdirSync(lockFile)
    writeFile(join(lockFile, 'owner'), 'writer-b\n')
  }
  fs.writeFileSync = function (path, ...rest) {
    const result = writeFile.call(this, path, ...rest)
    if (path === join(lockFile, 'owner') && !existsSync(mutex)) {
      fs.mkdirSync(mutex)
    }
    return result
  }
  fs.lstatSync = function (path, ...rest) {
    // The first look is the mutex check; later looks happen while waiting.
    if (path === mutex && ++mutexLooks > 1) finishRecoveryThenB()
    return lstat.call(this, path, ...rest)
  }
  fs.renameSync = function (from, to) {
    if (from === lockFile && String(to).startsWith(`${lockFile}.release-`)) {
      finishRecoveryThenB()
    } else if (to === lockFile && !existsSync(lockFile)) {
      fs.mkdirSync(lockFile)
      writeFile(join(lockFile, 'owner'), 'writer-c\n')
    }
    return rename.call(this, from, to)
  }
  syncBuiltinESMExports()

  assert.equal(acquireLock(lockFile), null)
  restore()
  assert.equal(recovered, true)
  assert.equal(readFileSync(join(lockFile, 'owner'), 'utf8'), 'writer-b\n')
  assert.deepEqual(readdirSync(lockFile), ['owner'])
  assert.match(readFileSync(join(quarantine, 'owner'), 'utf8'), /^\d+:[0-9a-f-]{36}\n$/)
  assert.deepEqual(readdirSync(join(root, 'logs')).sort(),
    ['.update.lock', '.update.lock.stale-test'])
})

test('dependency lock fails without renaming when the mutex outlasts the wait', (t) => {
  // A mutex still there after the wait does not prove the reclaimer dead: it
  // may be stalled between its own read and rename, and the token-checked
  // release is not atomic. Withdrawing now could move a successor's lock, so
  // the acquisition must fail and leave its lock and the mutex in place.
  const root = mkdtempSync(join(tmpdir(), 'wce-update-lock-withdraw-stalled-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const lockFile = join(root, 'logs', '.update.lock')
  const mutex = `${lockFile}.reclaim`
  const writeFile = fs.writeFileSync
  const rename = fs.renameSync
  const restore = () => {
    fs.writeFileSync = writeFile
    fs.renameSync = rename
    syncBuiltinESMExports()
  }
  t.after(restore)
  const renames = []
  fs.writeFileSync = function (path, ...rest) {
    const result = writeFile.call(this, path, ...rest)
    if (path === join(lockFile, 'owner') && !existsSync(mutex)) {
      fs.mkdirSync(mutex)
    }
    return result
  }
  fs.renameSync = function (from, to) {
    renames.push([from, to])
    return rename.call(this, from, to)
  }
  syncBuiltinESMExports()

  assert.equal(acquireLock(lockFile), null)
  restore()
  assert.deepEqual(renames, [])
  assert.equal(existsSync(mutex), true)
  assert.match(readFileSync(join(lockFile, 'owner'), 'utf8'), /^\d+:[0-9a-f-]{36}\n$/)
  assert.deepEqual(readdirSync(join(root, 'logs')).sort(),
    ['.update.lock', '.update.lock.reclaim'])
})

test('dependency lock rejects non-directories and exact-owner violations', {
  skip: process.platform === 'win32',
}, (t) => {
  const root = mkdtempSync(join(tmpdir(), 'wce-update-lock-shapes-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const logs = join(root, 'logs')
  const lockFile = join(logs, '.update.lock')
  mkdirSync(logs)

  writeFileSync(lockFile, 'regular-file\n')
  assert.equal(acquireLock(lockFile), null)
  assert.equal(readFileSync(lockFile, 'utf8'), 'regular-file\n')
  rmSync(lockFile)

  const target = join(root, 'foreign-target')
  writeFileSync(target, 'keep\n')
  symlinkSync(target, lockFile)
  assert.equal(acquireLock(lockFile), null)
  assert.equal(lstatSync(lockFile).isSymbolicLink(), true)
  rmSync(lockFile)

  const fifo = spawnSync('mkfifo', [lockFile])
  assert.equal(fifo.status, 0, fifo.stderr?.toString())
  assert.equal(acquireLock(lockFile), null)
  assert.equal(lstatSync(lockFile).isFIFO(), true)
  rmSync(lockFile)

  const token = acquireLock(lockFile)
  writeFileSync(join(lockFile, 'owner'), `${token}\nsecond-line\n`)
  assert.equal(releaseLock(token, lockFile), false)
  assert.equal(existsSync(lockFile), true)
  writeFileSync(join(lockFile, 'owner'), Buffer.concat([
    Buffer.from(`${token}\n`),
    Buffer.from([0]),
  ]))
  assert.equal(releaseLock(token, lockFile), false)
  assert.equal(existsSync(lockFile), true)
  writeFileSync(join(lockFile, 'owner'), `${token}\n`)
  writeFileSync(join(lockFile, 'foreign'), 'keep\n')
  assert.equal(releaseLock(token, lockFile), false)
  assert.equal(readFileSync(join(lockFile, 'foreign'), 'utf8'), 'keep\n')
})

test('dependency release retains a foreign hand-off winner', (t) => {
  const root = mkdtempSync(join(tmpdir(), 'wce-update-lock-handoff-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const lockFile = join(root, 'logs', '.update.lock')
  const token = acquireLock(lockFile)
  const quarantine = `${lockFile}.release-${token.replaceAll(':', '-')}`
  rmSync(lockFile, { recursive: true })
  mkdirSync(quarantine)
  writeFileSync(join(quarantine, 'owner'), 'foreign-owner\n')

  assert.equal(releaseLock(token, lockFile), false)
  assert.equal(readFileSync(join(quarantine, 'owner'), 'utf8'), 'foreign-owner\n')
  assert.equal(existsSync(lockFile), false)
})

test('dependency lock is released on TERM with signal status', {
  skip: process.platform === 'win32',
}, async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'wce-update-signal-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const lockFile = join(root, 'logs', '.update.lock')
  const childFile = join(root, 'lock-owner.mjs')
  writeFileSync(childFile, `
    import {
      acquireLock,
      installLockSignalHandlers,
    } from ${JSON.stringify(updaterUrl.href)}
    const lockFile = ${JSON.stringify(lockFile)}
    const token = acquireLock(lockFile)
    if (!token) process.exit(75)
    installLockSignalHandlers(token, lockFile)
    process.stdout.write('ready\\n')
    setInterval(() => {}, 1000)
  `)

  const child = spawn(process.execPath, [childFile], {
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  t.after(() => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
  })
  let output = ''
  await new Promise((resolve, reject) => {
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk) => {
      output += chunk
      if (output.includes('ready\n')) resolve()
    })
    child.once('error', reject)
    child.once('exit', (code, signal) => {
      if (!output.includes('ready\n')) {
        reject(new Error(`lock owner exited before ready: ${code}/${signal}`))
      }
    })
  })
  assert.equal(existsSync(lockFile), true)
  child.kill('SIGTERM')
  const [code, signal] = await once(child, 'exit')
  assert.equal(code, 143)
  assert.equal(signal, null)
  assert.equal(existsSync(lockFile), false)
})

test('a TERM queued beside synchronous release still wins with status 143', {
  skip: process.platform === 'win32',
}, async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'wce-update-release-signal-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const lockFile = join(root, 'logs', '.update.lock')
  const childFile = join(root, 'release-owner.mjs')
  writeFileSync(childFile, `
    import {
      acquireLock,
      installLockSignalHandlers,
      releaseLock,
    } from ${JSON.stringify(updaterUrl.href)}
    const lockFile = ${JSON.stringify(lockFile)}
    const token = acquireLock(lockFile)
    if (!token) process.exit(75)
    installLockSignalHandlers(token, lockFile)
    process.kill(process.pid, 'SIGTERM')
    releaseLock(token, lockFile)
    setImmediate(() => process.exit(99))
  `)

  const child = spawn(process.execPath, [childFile], {
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const [code, signal] = await once(child, 'exit')
  assert.equal(code, 143)
  assert.equal(signal, null)
  assert.equal(existsSync(lockFile), false)
})

function copyUpdaterFixture(root) {
  const scripts = join(root, 'skill', 'scripts')
  mkdirSync(scripts, { recursive: true })
  const updater = join(scripts, 'update-deps.mjs')
  copyFileSync(fileURLToPath(updaterUrl), updater)
  return { skill: join(root, 'skill'), updater }
}

test('stamp failure preserves the run result and still releases the lock', (t) => {
  const root = mkdtempSync(join(tmpdir(), 'wce-update-stamp-failure-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const { skill, updater } = copyUpdaterFixture(root)
  mkdirSync(join(skill, 'logs', '.last-update-check'), { recursive: true })

  const result = spawnSync(process.execPath, [updater, '--force'], {
    encoding: 'utf8',
    timeout: 10000,
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(existsSync(join(skill, 'logs', '.update.lock')), false)
  assert.match(readFileSync(join(skill, 'logs', 'update.log'), 'utf8'),
    /outcome stamp failed:/)
})

test('a symlinked updater entrypoint still executes main', {
  skip: process.platform === 'win32',
}, (t) => {
  const root = mkdtempSync(join(tmpdir(), 'wce-update-symlink-main-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const { skill, updater } = copyUpdaterFixture(root)
  const entrypoint = join(root, 'update-deps-link.mjs')
  symlinkSync(updater, entrypoint)

  const result = spawnSync(process.execPath, [entrypoint, '--force'], {
    encoding: 'utf8',
    timeout: 10000,
  })
  assert.equal(result.status, 0, result.stderr)
  assert.match(readFileSync(join(skill, 'logs', 'update.log'), 'utf8'),
    /check start/)
  assert.equal(existsSync(join(skill, 'logs', '.update.lock')), false)
})
