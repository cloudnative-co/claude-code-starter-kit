// Real extraction smoke tests. These make the auto-update gate meaningful:
// they actually exercise defuddle+jsdom (HTML) and pdfjs-dist (PDF) so that a
// dependency upgrade which breaks extraction will fail `npm test` and trigger a
// rollback. Fully deterministic and offline (inline fixtures, no network).

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { extractRecord } from '../scripts/lib/defuddle-core.mjs'
import { extractPdfRecord } from '../scripts/lib/pdf-extract.mjs'

const HTML_FIXTURE = `<!doctype html><html><head>
<title>Smoke Title</title><meta name="author" content="Smoke Author">
</head><body>
<nav>NAVIGATION_JUNK_TOKEN</nav>
<article><h1>Smoke Title</h1>
<p>This is a sufficiently long paragraph of genuine body content used to verify that Defuddle still extracts the main article correctly after any dependency upgrade.</p>
<ul><li>alpha</li><li>beta</li></ul></article>
<footer>FOOTER_JUNK_TOKEN</footer>
</body></html>`

test('HTML extraction (defuddle+jsdom) still works', async () => {
  const r = await extractRecord({ html: HTML_FIXTURE, url: 'https://example.com/smoke' })
  assert.equal(r.success, true, 'extraction should succeed')
  assert.equal(r.title, 'Smoke Title')
  assert.ok(r.charCount > 50, `charCount should be substantial, got ${r.charCount}`)
  assert.match(r.content, /- alpha/, 'list should be converted to Markdown')
  assert.doesNotMatch(r.content, /NAVIGATION_JUNK_TOKEN/, 'nav junk should be stripped')
  assert.doesNotMatch(r.content, /FOOTER_JUNK_TOKEN/, 'footer junk should be stripped')
})

// Minimal valid-enough PDF (ASCII only) with the text "Hello PDF Smoke".
// pdfjs reconstructs the xref, so a hand-written body is sufficient.
const MIN_PDF = `%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
4 0 obj<</Length 44>>stream
BT /F1 24 Tf 20 100 Td (Hello PDF Smoke) Tj ET
endstream
endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
trailer<</Root 1 0 R>>
%%EOF`

test('PDF extraction (pdfjs-dist) still works', async () => {
  const data = new Uint8Array(Buffer.from(MIN_PDF, 'latin1'))
  const r = await extractPdfRecord({ data, url: 'file:///smoke.pdf' })
  assert.equal(r.success, true, 'PDF extraction should succeed')
  assert.equal(r.pageCount, 1)
  assert.equal(r.extractorEngine, 'pdf')
  assert.match(r.content, /Hello PDF Smoke/, 'PDF text should be extracted')
  assert.notEqual(r.textTruncated, true, 'should not be truncated at default cap')
})

test('PDF text cap flags textTruncated (decompression-bomb guard)', async () => {
  const prev = process.env.DEFUDDLE_MAX_PDF_TEXT_CHARS
  process.env.DEFUDDLE_MAX_PDF_TEXT_CHARS = '5' // tiny cap -> "Hello PDF Smoke" exceeds it
  try {
    const data = new Uint8Array(Buffer.from(MIN_PDF, 'latin1'))
    const r = await extractPdfRecord({ data, url: 'file:///smoke.pdf' })
    assert.equal(r.textTruncated, true, 'should be flagged truncated')
    assert.ok(r.content.length <= 5, `content should be capped, got ${r.content.length}`)
    assert.ok(r.warnings?.some((w) => /truncated/.test(w)), 'should warn about truncation')
  } finally {
    if (prev === undefined) delete process.env.DEFUDDLE_MAX_PDF_TEXT_CHARS
    else process.env.DEFUDDLE_MAX_PDF_TEXT_CHARS = prev
  }
})
