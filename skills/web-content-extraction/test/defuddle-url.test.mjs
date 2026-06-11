// E2E tests for defuddle-url.mjs.
//
// defuddle-url.mjs has no importable API (`main()` runs on import), so we drive
// it as a subprocess and assert on its EXIT CODE contract. This covers what
// url-guard.test.mjs cannot reach: the SSRF block -> exit-code mapping and the
// manual-redirect / body-size-cap orchestration in fetchGuarded/readCappedBody.
//
// Network: a local loopback HTTP server only — no external traffic. The guard
// normally blocks loopback, so the redirect/size/success cases run with
// ALLOW_PRIVATE_URLS=true to exercise the fetch pipeline itself; the block
// cases run WITHOUT it to assert real SSRF rejection.
//
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import http from 'node:http'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const SCRIPT = fileURLToPath(new URL('../scripts/defuddle-url.mjs', import.meta.url))
const SKILL_DIR = resolve(dirname(SCRIPT), '..')

const HTML_FIXTURE = `<!doctype html><html><head>
<title>Smoke Title</title><meta name="author" content="Smoke Author">
</head><body>
<article><h1>Smoke Title</h1>
<p>This is a sufficiently long paragraph of genuine body content used to verify that the fetch pipeline returns exit 0 on a real successful extraction over the loopback server.</p>
<ul><li>alpha</li><li>beta</li></ul></article>
</body></html>`

/** Run `node defuddle-url.mjs <url>`; resolve with the numeric exit code. */
function runUrl(url, env = {}) {
  return new Promise((resolvePromise) => {
    execFile(
      process.execPath,
      [SCRIPT, url],
      { cwd: SKILL_DIR, env: { ...process.env, ...env }, timeout: 30000 },
      (error) => {
        if (!error) return resolvePromise(0)
        if (typeof error.code === 'number') return resolvePromise(error.code)
        // spawn failure / timeout: surface the error so the assertion fails loudly.
        return resolvePromise(error)
      },
    )
  })
}

// --- exit 4: SSRF / blocked URLs (deterministic, no server, no real DNS) ---

test('exit 4: disallowed protocols (file/ftp)', async () => {
  assert.equal(await runUrl('file:///etc/passwd'), 4)
  assert.equal(await runUrl('ftp://example.com/x'), 4)
})

test('exit 4: credentials embedded in URL', async () => {
  assert.equal(await runUrl('http://user:pass@example.com/'), 4)
})

test('exit 4: literal private / loopback / link-local IPs', async () => {
  assert.equal(await runUrl('http://127.0.0.1/'), 4)
  assert.equal(await runUrl('http://192.168.1.1/'), 4)
  assert.equal(await runUrl('http://[::1]/'), 4)
  assert.equal(await runUrl('http://169.254.169.254/latest/meta-data/'), 4)
})

test('exit 4: octal/hex/decimal IPv4 normalised to loopback', async () => {
  assert.equal(await runUrl('http://0x7f000001/'), 4)
  assert.equal(await runUrl('http://2130706433/'), 4)
})

test('exit 4: internal hostname (localhost)', async () => {
  assert.equal(await runUrl('http://localhost/'), 4)
})

test('exit 4: malformed URL', async () => {
  assert.equal(await runUrl('not a url'), 4)
})

test('exit 64: usage error (no URL argument)', async () => {
  assert.equal(await runUrl(''), 64)
})

// --- exit 0 / 3: fetch pipeline over a local loopback server ---

let server
let baseUrl
const PRIV = { ALLOW_PRIVATE_URLS: 'true' }

before(async () => {
  server = http.createServer((req, res) => {
    const path = req.url ?? '/'
    if (path === '/ok') {
      res.writeHead(200, { 'content-type': 'text/html' })
      res.end(HTML_FIXTURE)
    } else if (path.startsWith('/redirect')) {
      // Infinite self-redirect to exercise the MAX_REDIRECTS guard.
      const n = Number(new URL(path, baseUrl).searchParams.get('n') ?? '0')
      res.writeHead(302, { location: `/redirect?n=${n + 1}` })
      res.end()
    } else if (path === '/stream') {
      // No Content-Length (chunked) -> exercises the streamed size cap in
      // readCappedBody, not the Content-Length pre-check.
      res.writeHead(200, { 'content-type': 'text/html' })
      res.write('a'.repeat(5000))
      res.end()
    } else if (path === '/404') {
      res.writeHead(404)
      res.end('nope')
    } else {
      res.writeHead(200, { 'content-type': 'text/html' })
      res.end(HTML_FIXTURE)
    }
  })
  await new Promise((r) => server.listen(0, '127.0.0.1', r))
  baseUrl = `http://127.0.0.1:${server.address().port}`
})

after(async () => {
  await new Promise((r) => server.close(r))
})

test('exit 0: successful HTML extraction over loopback', async () => {
  assert.equal(await runUrl(`${baseUrl}/ok`, PRIV), 0)
})

test('exit 3: too many redirects', async () => {
  assert.equal(await runUrl(`${baseUrl}/redirect?n=0`, { ...PRIV, DEFUDDLE_MAX_REDIRECTS: '2' }), 3)
})

test('exit 3: invalid DEFUDDLE_MAX_REDIRECTS falls back to default instead of breaking all fetches', async () => {
  assert.equal(await runUrl(`${baseUrl}/ok`, { ...PRIV, DEFUDDLE_MAX_REDIRECTS: 'unlimited' }), 0)
})

test('exit 3: streamed body exceeds size cap (truncated)', async () => {
  assert.equal(await runUrl(`${baseUrl}/stream`, { ...PRIV, DEFUDDLE_MAX_BYTES: '100' }), 3)
})

test('exit 3: upstream HTTP error status', async () => {
  assert.equal(await runUrl(`${baseUrl}/404`, PRIV), 3)
})
