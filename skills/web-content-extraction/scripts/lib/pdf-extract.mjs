// PDF text extraction for the web-content-extraction skill.
//
// Uses the pdfjs-dist *legacy* build (Node-friendly) directly. Correct CJK
// (Japanese/Chinese/Korean) extraction needs packed CMap data to map CIDs to
// Unicode. pdfjs's default Node data factory reads the .bcmap and standard-font
// files straight from disk using the absolute cMapUrl / standardFontDataUrl we
// pass below (paths inside the local pdfjs-dist install), so no network access
// is performed.
//
// Verified: without the CMap data, Japanese PDFs extract as garbage
// ("ٗ׃צע..."); with it, text is correct ("ゼロトラスト幻想を断つ...").

import { fileURLToPath } from 'node:url'
import {
  MIN_CONTENT_CHARS,
  countChars,
  parsePositiveInt,
  withSilencedStdout,
} from './defuddle-core.mjs'

const CMAP_DIR = fileURLToPath(new URL('../../node_modules/pdfjs-dist/cmaps/', import.meta.url))
const STANDARD_FONTS_DIR = fileURLToPath(new URL('../../node_modules/pdfjs-dist/standard_fonts/', import.meta.url))
// Read at call-time (not import-time) so callers/tests can override via env.
// parsePositiveInt rejects non-numeric / zero / negative values so a bad
// override cannot silently disable the page/char caps.
const maxPdfPages = () => parsePositiveInt(process.env.DEFUDDLE_MAX_PDF_PAGES, 2000)
// Bound total extracted text so a small compressed PDF cannot expand into a
// huge in-memory string (decompression-bomb style DoS).
const maxPdfTextChars = () => parsePositiveInt(process.env.DEFUDDLE_MAX_PDF_TEXT_CHARS, 5_000_000)

/** Parse a PDF date string ("D:20260409120000+09'00'") to ISO, best-effort. */
function parsePdfDate(value) {
  if (typeof value !== 'string') return ''
  const m = value.match(/^D:(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?/)
  if (!m) return ''
  const [, y, mo = '01', d = '01', h = '00', mi = '00', s = '00'] = m
  const iso = `${y}-${mo}-${d}T${h}:${mi}:${s}Z`
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? '' : date.toISOString()
}

/**
 * Extract plain text + metadata from PDF bytes.
 * @param {Uint8Array} data
 * @returns {Promise<{text: string, pageCount: number, processedPages: number, info: object}>}
 */
export async function extractPdfText(data) {
  // pdfjs can write deprecation/info notices to stdout on some code paths;
  // wrap the whole parse so stdout stays pure JSON (parity with defuddle-core).
  return withSilencedStdout(async () => {
    // Imported lazily so HTML-only runs never load the (heavy) pdfjs bundle.
    const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs')
    const loadingTask = pdfjs.getDocument({
      data,
      // Absolute file paths under the local pdfjs-dist install. The default Node
      // data factory reads .bcmap / standard-font files from these dirs via
      // fs.readFile, so CJK CMaps load without any network access.
      cMapUrl: CMAP_DIR,
      cMapPacked: true,
      standardFontDataUrl: STANDARD_FONTS_DIR,
      isEvalSupported: false,
      useSystemFonts: false,
    })
    // try/finally wraps loadingTask itself so destroy() runs even if .promise rejects.
    try {
      const doc = await loadingTask.promise
      const pageCount = doc.numPages
      const maxPages = maxPdfPages()
      const maxChars = maxPdfTextChars()
      let processedPages = Math.min(pageCount, maxPages) // bound parsing-DoS

      const parts = []
      let totalChars = 0
      let textTruncated = false
      for (let i = 1; i <= processedPages; i++) {
        const page = await doc.getPage(i)
        const tc = await page.getTextContent()
        // Join text items; insert newlines where pdfjs marks an end-of-line.
        let line = ''
        for (const item of tc.items) {
          line += item.str
          if (item.hasEOL) line += '\n'
        }
        page.cleanup()
        totalChars += line.length
        if (totalChars > maxChars) {
          const room = maxChars - (totalChars - line.length)
          if (room > 0) parts.push(line.slice(0, room).trim())
          textTruncated = true
          processedPages = i
          break
        }
        parts.push(line.trim())
      }

      let info = {}
      try {
        const meta = await doc.getMetadata()
        info = meta?.info ?? {}
      } catch {
        info = {}
      }

      return { text: parts.join('\n\n').trim(), pageCount, processedPages, textTruncated, info }
    } finally {
      try {
        await loadingTask.destroy()
      } catch {
        /* destroy best-effort */
      }
    }
  })
}

/**
 * Build a normalized record (same shape family as defuddle-core's extractRecord)
 * from PDF bytes. On failure returns { success:false, error, ... }.
 * @param {object} input
 * @param {Uint8Array} input.data
 * @param {string} input.url
 * @param {object} [input.extra]
 * @returns {Promise<object>}
 */
export async function extractPdfRecord({ data, url, extra = {} }) {
  let result
  try {
    result = await extractPdfText(data)
  } catch (error) {
    return {
      success: false,
      error: `PDF抽出失敗: ${error?.message ?? String(error)}`,
      url,
      extractorEngine: 'pdf',
      ...extra,
    }
  }

  const content = result.text
  const { charCount, cjkCharCount } = countChars(content)
  const warnings = []
  if (charCount === 0) {
    warnings.push('PDFからテキストを抽出できなかった（スキャン画像PDFの可能性）。OCRが必要。')
  } else if (charCount < MIN_CONTENT_CHARS) {
    warnings.push(`抽出テキストが極端に短い (${charCount} 文字)。抽出不完全の可能性。`)
  }
  if (result.textTruncated) {
    warnings.push(`抽出テキストが上限 ${maxPdfTextChars()} 文字を超過。先頭のみ保持(truncated)。本文は不完全。`)
  } else if (result.processedPages < result.pageCount) {
    warnings.push(`ページ数が上限 ${maxPdfPages()} を超過。先頭 ${result.processedPages}/${result.pageCount} ページのみ解析。`)
  }

  return {
    success: charCount > 0,
    ...(warnings.length ? { warnings } : {}),
    url,
    title: result.info?.Title ?? '',
    author: result.info?.Author ?? '',
    site: '',
    domain: '',
    published: parsePdfDate(result.info?.CreationDate),
    description: result.info?.Subject ?? '',
    favicon: '',
    image: '',
    wordCount: (content.match(/\S+/gu) ?? []).length,
    charCount,
    cjkCharCount,
    pageCount: result.pageCount,
    processedPages: result.processedPages,
    textTruncated: result.textTruncated,
    extractorEngine: 'pdf',
    content,
    ...extra,
  }
}
