// Unit tests for the JP-friendly length metrics (countChars).
// Run: npm test   (node --test)

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { countChars } from '../scripts/lib/defuddle-core.mjs'

test('countChars: ASCII words counted as non-whitespace chars', () => {
  const { charCount, cjkCharCount } = countChars('hello world')
  assert.equal(charCount, 10) // whitespace excluded
  assert.equal(cjkCharCount, 0)
})

test('countChars: Japanese text counts CJK characters', () => {
  const { charCount, cjkCharCount } = countChars('ゼロトラスト概論')
  assert.equal(charCount, 8)
  assert.equal(cjkCharCount, 8)
})

test('countChars: mixed JP/ASCII separates cjk subset', () => {
  const { charCount, cjkCharCount } = countChars('SASE を 導入')
  // non-whitespace: S A S E を 導 入 = 7
  assert.equal(charCount, 7)
  // CJK: を 導 入 = 3
  assert.equal(cjkCharCount, 3)
})

test('countChars: whitespace and newlines excluded from charCount', () => {
  const { charCount } = countChars('a\n b\t c')
  assert.equal(charCount, 3)
})

test('countChars: empty string yields zeros', () => {
  assert.deepEqual(countChars(''), { charCount: 0, cjkCharCount: 0 })
})
