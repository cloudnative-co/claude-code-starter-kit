// Shared Defuddle extraction core for the web-content-extraction skill.
//
// Design notes (verified against defuddle 0.6.x, re-confirmed on 0.18.x; deps auto-update):
// - `defuddle/node` requires a jsdom-class DOM. This skill pins the jsdom major
//   in package.json (currently the jsdom 29 line); defuddle 0.18.x declares no
//   jsdom peerDependency, so compatibility is guarded by the smoke tests rather
//   than a version constraint. linkedom is NOT compatible: Defuddle calls
//   window.getComputedStyle / media-query evaluation which linkedom does not
//   implement, producing degraded extraction.
// - When `defuddle/node` is given an HTML *string* it builds a JSDOM with
//   `resources: 'usable'`, which fetches sub-resources over the network. To keep
//   the standard layer offline-by-default we build the JSDOM *ourselves* WITHOUT
//   `resources: 'usable'` and WITHOUT `runScripts`, then hand the instance in.
// - There is no `useAsync` option in defuddle (absent from dist in 0.6.x–0.18.x).
//   The original intent ("no async external fetch") is enforced here
//   structurally: synchronous core + a DOM that never fetches or runs scripts.

import { JSDOM, VirtualConsole } from 'jsdom'
import { Defuddle } from 'defuddle/node'

const MIN_CONTENT_CHARS = 200 // below this we flag low-confidence extraction

// CJK ranges: Hiragana, Katakana, CJK Unified Ideographs (+Ext A), Hangul,
// CJK symbols/punctuation, fullwidth forms. Used for JP-friendly length metrics.
const CJK_REGEX =
  /[　-〿぀-ゟ゠-ヿ㐀-䶿一-鿿가-힯＀-￯]/g

/**
 * Compute length metrics that are meaningful for Japanese/CJK text, where
 * Defuddle's whitespace-based `wordCount` under-counts heavily.
 * @param {string} text
 * @returns {{charCount: number, cjkCharCount: number}}
 *   charCount: non-whitespace character count.
 *   cjkCharCount: count of CJK characters.
 */
export function countChars(text) {
  const charCount = (text.match(/\S/gu) ?? []).length
  const cjkCharCount = (text.match(CJK_REGEX) ?? []).length
  return { charCount, cjkCharCount }
}

/**
 * Parse an environment value as a positive integer, falling back to `fallback`
 * for missing / non-numeric / zero / negative input. This prevents a bad
 * override from silently disabling a limit: e.g. `Number('unlimited')` is NaN,
 * and `total > NaN` is always false, which would turn a decompression-bomb cap
 * into no cap at all.
 * @param {string|undefined} value
 * @param {number} fallback
 * @returns {number}
 */
export function parsePositiveInt(value, fallback) {
  const n = Number(value)
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback
}

/**
 * Build a JSDOM instance that never fetches sub-resources and never runs scripts.
 * @param {string} html Raw HTML markup.
 * @param {string} url Absolute URL used for relative-link resolution.
 * @returns {JSDOM}
 */
export function buildSafeDom(html, url) {
  const virtualConsole = new VirtualConsole() // swallow page-level console noise
  return new JSDOM(html, {
    url,
    // Deliberately omit `resources: 'usable'` => no sub-resource network fetch.
    // Deliberately omit `runScripts` => page scripts are never executed.
    pretendToBeVisual: true,
    virtualConsole,
  })
}

/**
 * Run an async function with console.* redirected to stderr, so any library
 * logging (Defuddle, pdfjs, ...) can never pollute stdout — which is reserved
 * for the single JSON record.
 *
 * NOTE: this swaps the *global* console for the duration of `fn`, so it is for
 * one-shot CLI use (one extraction per process). Concurrent calls in the same
 * process would race on the shared console and are NOT supported.
 * @template T
 * @param {() => Promise<T>} fn
 * @returns {Promise<T>}
 */
export async function withSilencedStdout(fn) {
  const original = {
    log: console.log,
    info: console.info,
    warn: console.warn,
    error: console.error,
    debug: console.debug,
  }
  const toStderr = (...args) => process.stderr.write(args.map(String).join(' ') + '\n')
  console.log = toStderr
  console.info = toStderr
  console.warn = toStderr
  console.error = toStderr
  console.debug = toStderr
  try {
    return await fn()
  } finally {
    Object.assign(console, original)
  }
}

/**
 * Run Defuddle while keeping stdout pure JSON (see withSilencedStdout).
 * @param {JSDOM} dom
 * @param {string} url
 * @returns {Promise<import('defuddle').DefuddleResponse>}
 */
async function parseWithSilencedStdout(dom, url) {
  // markdown: true => content is converted to Markdown by the node wrapper.
  return withSilencedStdout(() => Defuddle(dom, url, { markdown: true }))
}

/**
 * Extract main content from already-fetched HTML and return a normalized record.
 * @param {object} input
 * @param {string} input.html Raw HTML markup.
 * @param {string} input.url Absolute URL (used for link resolution & metadata).
 * @param {object} [input.extra] Extra fields merged into the output record.
 * @returns {Promise<object>} Normalized extraction record (see fields below).
 */
export async function extractRecord({ html, url, extra = {} }) {
  let result
  let dom
  try {
    dom = buildSafeDom(html, url)
    result = await parseWithSilencedStdout(dom, url)
  } catch (error) {
    return {
      success: false,
      error: `Defuddle抽出失敗: ${error?.message ?? String(error)}`,
      url,
      ...extra,
    }
  } finally {
    // Release JSDOM resources (timers/event loop refs) — important for reuse/tests.
    try {
      dom?.window?.close?.()
    } catch {
      /* best-effort */
    }
  }

  const content = result.content ?? ''
  const wordCount = result.wordCount ?? 0
  const { charCount, cjkCharCount } = countChars(content)
  const warnings = []
  if (content.trim().length === 0) {
    warnings.push('本文が空。Defuddle抽出に失敗した可能性が高い。')
  } else if (charCount < MIN_CONTENT_CHARS) {
    warnings.push(`本文が極端に短い (${charCount} 文字)。抽出不完全の可能性。`)
  }

  return {
    success: content.trim().length > 0,
    ...(warnings.length ? { warnings } : {}),
    url,
    title: result.title ?? '',
    author: result.author ?? '',
    site: result.site ?? '',
    domain: result.domain ?? '',
    published: result.published ?? '',
    description: result.description ?? '',
    favicon: result.favicon ?? '',
    image: result.image ?? '',
    wordCount,
    charCount,
    cjkCharCount,
    extractorType: result.extractorType ?? null,
    content,
    ...extra,
  }
}

/** Print a record as pretty JSON to stdout. */
export function printJson(record) {
  process.stdout.write(JSON.stringify(record, null, 2) + '\n')
}
