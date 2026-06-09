#!/usr/bin/env node
// defuddle-file.mjs <path-to-html-file>
//
// Extracts main content from a LOCAL HTML file using Defuddle and prints a
// normalized JSON record to stdout. Intended for offline/private HTML.
//
// Security: performs NO network communication whatsoever. The DOM is built
// without sub-resource fetching and without script execution. This makes it
// safe for internal/customer/confidential HTML that must not leave the machine.
//
// Exit codes:
//   0  success (record emitted; check `success`/`warnings` in the JSON)
//   2  Defuddle extraction failed
//   3  file read error
//  64  usage error (bad arguments)

import { readFile } from 'node:fs/promises'
import { resolve, basename } from 'node:path'
import { pathToFileURL } from 'node:url'
import { extractRecord, printJson } from './lib/defuddle-core.mjs'

function fail(exitCode, record) {
  printJson(record)
  process.exit(exitCode)
}

async function main() {
  const inputPath = process.argv[2]
  if (!inputPath) {
    fail(64, { success: false, error: '使い方: node defuddle-file.mjs <path-to-html-file>' })
  }

  const parsedAt = new Date().toISOString()
  const absPath = resolve(inputPath)

  let buf
  try {
    buf = await readFile(absPath)
  } catch (error) {
    fail(3, { success: false, error: `ファイル読み取り失敗: ${error?.message ?? String(error)}`, sourcePath: absPath, parsedAt })
  }

  // Reject PDFs explicitly: this script is HTML-only. A PDF read as UTF-8 would
  // produce garbage rather than an obvious error. (Use defuddle-url.mjs for PDF
  // URLs; local PDF extraction is intentionally out of scope.)
  if (/\.pdf$/i.test(absPath) || /^%PDF-/.test(buf.subarray(0, 5).toString('latin1'))) {
    fail(64, {
      success: false,
      error: 'ローカルPDFは未対応です（このスクリプトはHTML専用）。PDFのURLなら defuddle-url.mjs を使用してください。',
      sourcePath: absPath,
      parsedAt,
    })
  }

  const html = buf.toString('utf8')

  // Use a file:// URL only for relative-link resolution; nothing is fetched.
  const fileUrl = pathToFileURL(absPath).href

  const record = await extractRecord({
    html,
    url: fileUrl,
    extra: {
      sourcePath: absPath,
      sourceName: basename(absPath),
      parsedAt,
      offline: true,
    },
  })

  if (record.success === false && record.error) {
    fail(2, record)
  }

  printJson(record)
  process.exit(0)
}

main().catch((error) => {
  fail(2, { success: false, error: `予期しないエラー: ${error?.message ?? String(error)}` })
})
