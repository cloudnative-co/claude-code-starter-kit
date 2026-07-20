import { spawn, spawnSync } from 'node:child_process'
import { once } from 'node:events'
import {
  existsSync,
  copyFileSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
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
