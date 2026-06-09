#!/usr/bin/env node
// defuddle-url.mjs <url>
//
// Standard web-fetch layer for Claude Code. Fetches a public URL, extracts the
// main content with Defuddle (or pdfjs for PDFs), and prints a normalized JSON
// record to stdout.
//
// Security:
//   - Private/internal URLs are rejected by default (lib/url-guard.mjs).
//   - Connections are pinned to validated IPs via a guarded undici dispatcher,
//     closing the DNS-rebinding / TOCTOU window.
//   - Redirects are followed MANUALLY, re-validating every hop before the
//     request is sent (so a 30x to 169.254.169.254 / 127.0.0.1 is blocked
//     BEFORE any packet reaches the internal target).
//   - The response body is read as a size-capped stream (Content-Length is also
//     pre-checked) to prevent memory-exhaustion DoS.
//   - The DOM is built without sub-resource fetching and without script
//     execution (lib/defuddle-core.mjs). No external fallback is used.
//
// Exit codes:
//   0  success (record emitted; check `success`/`warnings` in the JSON)
//   2  Defuddle/PDF extraction failed
//   3  fetch / HTTP error (incl. too-large, too-many-redirects, timeout)
//   4  blocked URL (private/internal/disallowed protocol/credentials)
//  64  usage error (bad arguments)

// Use undici's own fetch (not Node's global fetch): a dispatcher created from
// this undici instance is only compatible with this instance's fetch. Mixing
// with Node's built-in undici throws "invalid onRequestStart method".
import { Agent, fetch as undiciFetch } from 'undici'
import { assertPublicUrl, createGuardedLookup } from './lib/url-guard.mjs'
import { extractRecord, printJson } from './lib/defuddle-core.mjs'
import { extractPdfRecord } from './lib/pdf-extract.mjs'

const USER_AGENT =
  process.env.DEFUDDLE_USER_AGENT ??
  'Claude-Code-Defuddle/1.0 (+https://github.com/kepano/defuddle; web-content-extraction skill)'
const TIMEOUT_MS = Number(process.env.DEFUDDLE_TIMEOUT_MS ?? 20000)
const MAX_BYTES = Number(process.env.DEFUDDLE_MAX_BYTES ?? 10 * 1024 * 1024) // 10 MB
const MAX_REDIRECTS = Number(process.env.DEFUDDLE_MAX_REDIRECTS ?? 5)
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308])

function fail(exitCode, record) {
  printJson(record)
  process.exit(exitCode)
}

/**
 * Follow redirects manually, validating every hop BEFORE the request is sent.
 * @returns {Promise<{response: Response, finalUrl: string}>}
 */
async function fetchGuarded(startUrl, { dispatcher, signal, headers }) {
  const startSecure = new URL(startUrl).protocol === 'https:'
  let currentUrl = startUrl
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    await assertPublicUrl(currentUrl) // throws -> caller maps to exit 4
    const response = await undiciFetch(currentUrl, { redirect: 'manual', dispatcher, signal, headers })
    if (REDIRECT_STATUSES.has(response.status)) {
      const location = response.headers.get('location')
      if (!location) return { response, finalUrl: currentUrl }
      await response.body?.cancel?.()
      const next = new URL(location, currentUrl)
      // Refuse HTTPS -> HTTP downgrade (content could be tampered in transit).
      if (startSecure && next.protocol === 'http:') {
        throw new Error('HTTPSからHTTPへのリダイレクト(プロトコルダウングレード)は拒否')
      }
      currentUrl = next.href
      continue
    }
    return { response, finalUrl: currentUrl }
  }
  const err = new Error(`リダイレクトが多すぎる (>${MAX_REDIRECTS})`)
  err.code = 'TOO_MANY_REDIRECTS'
  throw err
}

/** Read a response body into a Buffer, capped at MAX_BYTES (streamed). */
async function readCappedBody(response, controller) {
  const chunks = []
  let total = 0
  let truncated = false
  if (response.body) {
    for await (const chunk of response.body) {
      total += chunk.length
      if (total > MAX_BYTES) {
        const room = MAX_BYTES - (total - chunk.length)
        if (room > 0) chunks.push(Buffer.from(chunk.subarray(0, room)))
        truncated = true
        break
      }
      chunks.push(Buffer.from(chunk))
    }
    if (truncated) controller.abort() // stop the download promptly
  }
  return { buf: Buffer.concat(chunks), truncated }
}

async function main() {
  const rawUrl = process.argv[2]
  if (!rawUrl) {
    fail(64, { success: false, error: '使い方: node defuddle-url.mjs <url>' })
  }

  const fetchedAt = new Date().toISOString()

  // 1. SSRF / private-URL guard (pattern + DNS pre-check).
  try {
    await assertPublicUrl(rawUrl)
  } catch (error) {
    fail(4, { success: false, error: error.message, url: rawUrl, fetchedAt })
  }

  // 2. Fetch with a guarded dispatcher + manual redirect validation.
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)
  const dispatcher = new Agent({ connect: { lookup: createGuardedLookup() } })
  const headers = {
    'User-Agent': USER_AGENT,
    Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,application/pdf;q=0.9,*/*;q=0.8',
    'Accept-Language': 'ja,en;q=0.8',
  }

  let response
  let finalUrl
  let buf
  const warnings = []
  try {
    ;({ response, finalUrl } = await fetchGuarded(rawUrl, { dispatcher, signal: controller.signal, headers }))

    if (!response.ok) {
      fail(3, {
        success: false,
        error: `HTTPエラー: ${response.status} ${response.statusText}`,
        url: rawUrl,
        finalUrl,
        status: response.status,
        fetchedAt,
      })
    }

    // Pre-reject oversized responses by Content-Length before streaming.
    const declaredLen = Number(response.headers.get('content-length') ?? 0)
    if (declaredLen && declaredLen > MAX_BYTES) {
      fail(3, {
        success: false,
        error: `本文が大きすぎる: Content-Length ${declaredLen} > 上限 ${MAX_BYTES}`,
        url: rawUrl,
        finalUrl,
        fetchedAt,
      })
    }

    const read = await readCappedBody(response, controller)
    buf = read.buf
    // Truncated content must NOT be treated as a successful extraction: a
    // partial HTML/PDF can mislead downstream analysis. Reject instead.
    if (read.truncated) {
      fail(3, {
        success: false,
        error: `本文がサイズ上限 ${MAX_BYTES} バイトを超過(truncated)。信頼できないため中断。`,
        url: rawUrl,
        finalUrl,
        fetchedAt,
      })
    }
  } catch (error) {
    const aborted = error?.name === 'AbortError'
    const code =
      error?.message?.includes('プロトコル') ||
      error?.message?.includes('IP') ||
      error?.message?.includes('ホスト名') ||
      error?.message?.includes('認証情報') ||
      error?.message?.includes('不正なURL')
        ? 4
        : 3
    fail(code, {
      success: false,
      error: aborted ? `取得タイムアウト (${TIMEOUT_MS}ms)` : `fetch失敗: ${error?.message ?? String(error)}`,
      url: rawUrl,
      finalUrl: finalUrl ?? null,
      fetchedAt,
    })
  } finally {
    clearTimeout(timer)
    // Release undici connections (the body has already been fully read by here).
    try {
      await dispatcher.close()
    } catch {
      /* best-effort */
    }
  }

  const contentType = response.headers.get('content-type') ?? ''

  // 3. PDF fallback: detect by content-type, magic number, or .pdf path.
  const isPdf =
    /application\/pdf/i.test(contentType) ||
    /%PDF-/.test(buf.subarray(0, 8).toString('latin1')) ||
    /\.pdf(?:[?#]|$)/i.test(new URL(finalUrl).pathname)

  const sharedExtra = {
    requestedUrl: rawUrl,
    finalUrl,
    fetchedAt,
    contentType,
    ...(warnings.length ? { fetchWarnings: warnings } : {}),
  }

  let record
  if (isPdf) {
    record = await extractPdfRecord({ data: new Uint8Array(buf), url: finalUrl, extra: sharedExtra })
  } else {
    if (!/(text\/html|application\/xhtml|text\/xml|application\/xml)/i.test(contentType)) {
      warnings.push(`Content-Typeが非HTML (${contentType || '不明'})。HTMLとして解析を試行。`)
      sharedExtra.fetchWarnings = warnings
    }
    record = await extractRecord({ html: buf.toString('utf8'), url: finalUrl, extra: sharedExtra })
  }

  if (record.success === false && record.error) {
    fail(2, record)
  }
  // Truncated PDF text must not be treated as a complete extraction (parity with
  // the HTTP body size cap, which also rejects truncated content).
  if (record.textTruncated) {
    fail(3, {
      ...record,
      success: false,
      error: 'PDF抽出テキストが上限を超過(truncated)。信頼できないため中断。',
    })
  }

  printJson(record)
  process.exit(0)
}

main().catch((error) => {
  fail(2, { success: false, error: `予期しないエラー: ${error?.message ?? String(error)}` })
})
