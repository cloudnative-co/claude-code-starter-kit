// Unit tests for the SSRF / private-URL guard.
// Run: npm test   (node --test)
// Deterministic only: no real DNS-dependent assertions (avoids CI flakiness).

import { test, mock } from 'node:test'
import assert from 'node:assert/strict'
import dns from 'node:dns/promises'
import { isPrivateIp, assertPublicUrl, createGuardedLookup } from '../scripts/lib/url-guard.mjs'

test('isPrivateIp: IPv4 private/reserved ranges are private', () => {
  for (const ip of [
    '10.0.0.1', '10.255.255.255',
    '172.16.0.1', '172.31.255.255',
    '192.168.0.1', '192.168.1.1',
    '127.0.0.1', '0.0.0.0',
    '169.254.1.1', '100.64.0.1',
    '198.18.0.1', '224.0.0.1', '240.0.0.1',
  ]) {
    assert.equal(isPrivateIp(ip), true, `${ip} should be private`)
  }
})

test('isPrivateIp: public IPv4 are not private', () => {
  for (const ip of ['8.8.8.8', '1.1.1.1', '93.184.216.34', '172.32.0.1', '11.0.0.1']) {
    assert.equal(isPrivateIp(ip), false, `${ip} should be public`)
  }
})

test('isPrivateIp: IPv6 loopback/ULA/link-local are private', () => {
  for (const ip of ['::1', '::', 'fc00::1', 'fd12:3456::1', 'fe80::1']) {
    assert.equal(isPrivateIp(ip), true, `${ip} should be private`)
  }
})

test('isPrivateIp: IPv4-mapped/compatible IPv6 are blocked (default-deny, not global unicast)', () => {
  assert.equal(isPrivateIp('::ffff:192.168.0.1'), true)
  assert.equal(isPrivateIp('::ffff:8.8.8.8'), true) // mapped public still blocked (not 2000::/3)
  assert.equal(isPrivateIp('::ffff:7f00:1'), true) // compressed hex form
  assert.equal(isPrivateIp('::ffff:a9fe:a9fe'), true) // 169.254.169.254 (cloud metadata)
  assert.equal(isPrivateIp('::0.0.0.2'), true) // IPv4-compatible (deprecated)
})

test('isPrivateIp: public global-unicast IPv6 is allowed', () => {
  assert.equal(isPrivateIp('2001:4860:4860::8888'), false) // Google
  assert.equal(isPrivateIp('2606:4700:4700::1111'), false) // Cloudflare
})

test('isPrivateIp: IPv6 special-use ranges (default-deny + sub-range blocks)', () => {
  assert.equal(isPrivateIp('ff02::1'), true) // multicast
  assert.equal(isPrivateIp('ff00::'), true) // multicast
  assert.equal(isPrivateIp('fec0::1'), true) // deprecated site-local
  assert.equal(isPrivateIp('2001::1'), true) // Teredo 2001::/32
  assert.equal(isPrivateIp('2001:db8::1'), true) // documentation
  assert.equal(isPrivateIp('2001:2::1'), true) // benchmarking
  assert.equal(isPrivateIp('2001:10::1'), true) // ORCHID
  // NAT64 64:ff9b::/96 is in 0000::/8 -> blocked by default-deny.
  assert.equal(isPrivateIp('64:ff9b::a9fe:a9fe'), true)
  assert.equal(isPrivateIp('64:ff9b::808:808'), true)
  // 6to4 2002::/16 is global unicast: blocked only when embedded v4 is private.
  assert.equal(isPrivateIp('2002:a9fe:a9fe::1'), true) // wraps 169.254.169.254
  assert.equal(isPrivateIp('2002:808:808::1'), false) // wraps public 8.8.8.8
})

test('assertPublicUrl: rejects NAT64/6to4/multicast SSRF forms', async () => {
  await assert.rejects(assertPublicUrl('http://[64:ff9b::a9fe:a9fe]/'), /プライベート|内部IP/)
  await assert.rejects(assertPublicUrl('http://[2002:a9fe:a9fe::1]/'), /プライベート|内部IP/)
  await assert.rejects(assertPublicUrl('http://[ff02::1]/'), /プライベート|内部IP/)
})

test('assertPublicUrl: rejects non-http(s) protocols', async () => {
  await assert.rejects(assertPublicUrl('file:///etc/passwd'), /プロトコル/)
  await assert.rejects(assertPublicUrl('ftp://example.com/x'), /プロトコル/)
})

test('assertPublicUrl: rejects malformed URLs', async () => {
  await assert.rejects(assertPublicUrl('not a url'), /不正なURL/)
})

test('assertPublicUrl: rejects literal private IPs (no DNS needed)', async () => {
  await assert.rejects(assertPublicUrl('http://192.168.1.1/'), /プライベート|内部IP/)
  await assert.rejects(assertPublicUrl('http://127.0.0.1:8080/admin'), /プライベート|内部IP/)
  await assert.rejects(assertPublicUrl('http://[::1]/'), /プライベート|内部IP/)
})

test('assertPublicUrl: rejects IPv4-mapped IPv6 (compressed hex bypass)', async () => {
  await assert.rejects(assertPublicUrl('http://[::ffff:127.0.0.1]/'), /プライベート|内部IP/)
  await assert.rejects(assertPublicUrl('http://[::ffff:169.254.169.254]/'), /プライベート|内部IP/)
})

test('assertPublicUrl: rejects decimal/octal/hex IPv4 (URL-normalised to dotted)', async () => {
  await assert.rejects(assertPublicUrl('http://0x7f000001/'), /プライベート|内部IP/) // 127.0.0.1
  await assert.rejects(assertPublicUrl('http://2130706433/'), /プライベート|内部IP/) // 127.0.0.1
  await assert.rejects(assertPublicUrl('http://0177.0.0.1/'), /プライベート|内部IP/) // 127.0.0.1
})

test('assertPublicUrl: rejects credentials in URL (userinfo)', async () => {
  await assert.rejects(assertPublicUrl('https://user:pass@example.com/'), /認証情報/)
  await assert.rejects(assertPublicUrl('https://user@example.com/'), /認証情報/)
})

test('createGuardedLookup: blocks resolution to a private IP, allows public (all:true)', async () => {
  const lookup = createGuardedLookup()
  const run = (host) =>
    new Promise((resolve) => lookup(host, { all: true }, (err, addrs) => resolve({ err, addrs })))
  // IP literals resolve to themselves without network access.
  const priv = await run('127.0.0.1')
  assert.ok(priv.err, 'private IP resolution should be refused')
  const pub = await run('8.8.8.8')
  assert.equal(pub.err, null)
  assert.equal(pub.addrs[0].address, '8.8.8.8')
})

test('createGuardedLookup: honours all:false single-address callback shape', async () => {
  const lookup = createGuardedLookup()
  const run = (host) =>
    new Promise((resolve) => lookup(host, { all: false }, (err, address, family) => resolve({ err, address, family })))
  const pub = await run('8.8.8.8')
  assert.equal(pub.err, null)
  assert.equal(pub.address, '8.8.8.8')
  assert.equal(pub.family, 4)
  const priv = await run('127.0.0.1')
  assert.ok(priv.err, 'private IP must be refused even with all:false')
})

test('assertPublicUrl: rejects internal hostnames before DNS', async () => {
  await assert.rejects(assertPublicUrl('http://localhost/'), /内部ホスト名/)
  await assert.rejects(assertPublicUrl('https://service.local/'), /内部ホスト名/)
  await assert.rejects(assertPublicUrl('https://app.internal/'), /内部ホスト名/)
  await assert.rejects(assertPublicUrl('http://intranet/'), /内部ホスト名/) // bare single label
})

test('assertPublicUrl: accepts a public literal IP (no DNS)', async () => {
  const url = await assertPublicUrl('http://8.8.8.8/path')
  assert.equal(url.hostname, '8.8.8.8')
})

test('assertPublicUrl: ALLOW_PRIVATE_URLS=true bypasses guards (no DNS)', async () => {
  const prev = process.env.ALLOW_PRIVATE_URLS
  process.env.ALLOW_PRIVATE_URLS = 'true'
  try {
    const a = await assertPublicUrl('http://localhost:3000/')
    assert.equal(a.hostname, 'localhost')
    const b = await assertPublicUrl('http://192.168.1.1/')
    assert.equal(b.hostname, '192.168.1.1')
  } finally {
    if (prev === undefined) delete process.env.ALLOW_PRIVATE_URLS
    else process.env.ALLOW_PRIVATE_URLS = prev
  }
})

// Guard-time DNS pre-check: a public-looking hostname whose A record points at a
// private IP must be rejected before any connection. dns.lookup is mocked so the
// test stays deterministic and offline.
test('assertPublicUrl: rejects a public hostname resolving to a private IP (mocked DNS)', async () => {
  mock.method(dns, 'lookup', async () => [{ address: '10.0.0.7', family: 4 }])
  try {
    await assert.rejects(assertPublicUrl('http://totally.example.com/'), /プライベートIPに解決/)
  } finally {
    mock.restoreAll()
  }
})

test('assertPublicUrl: allows a public hostname resolving to a public IP (mocked DNS)', async () => {
  mock.method(dns, 'lookup', async () => [{ address: '93.184.216.34', family: 4 }])
  try {
    const url = await assertPublicUrl('http://totally.example.com/')
    assert.equal(url.hostname, 'totally.example.com')
  } finally {
    mock.restoreAll()
  }
})
