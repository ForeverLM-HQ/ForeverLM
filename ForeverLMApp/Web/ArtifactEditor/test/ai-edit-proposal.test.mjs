// Edit with AI: the stand-ins the model reads for the page's addresses, and
// the word changes a proposal is marked with. Run with `npm test` here.

import assert from 'node:assert/strict'
import test from 'node:test'
import { aliasedAddresses, isAddressStandIn, newAddressAliases, restoredAddresses, reviewWordMarks, wordChanges } from '../src/ai-edit-proposal.js'

const quoteSource = 'foreverlm://grounding/src_8fcdf69cde54199827fc0d9c0487955011b277304017b849b034c0528b2c8616'

test('a source address the model reads once per line is one short stand-in', () => {
  const aliases = newAddressAliases()
  const passage = `[first line](${quoteSource})\\\n[second line](${quoteSource})`
  const read = aliasedAddresses(passage, aliases)
  assert.equal(read, '[first line](foreverlm://grounding/1)\\\n[second line](foreverlm://grounding/1)')
  assert.equal(aliases.byAlias.get('foreverlm://grounding/1'), quoteSource)
})

test('stand-ins are numbered across the passage, its context and every kind', () => {
  const aliases = newAddressAliases()
  aliasedAddresses('See [a page](foreverlm://doc/7F1C-AA) and ![a picture](foreverlm://attachment/9f8e7d)', aliases)
  const after = aliasedAddresses(`[cited](foreverlm://grounding/src_a,book:b12) [again](foreverlm://doc/7F1C-AA)`, aliases)
  assert.equal(after, '[cited](foreverlm://grounding/3) [again](foreverlm://doc/1)')
})

test('the answer gets the real addresses back, pictures and titles included', () => {
  const aliases = newAddressAliases()
  aliasedAddresses(`[a](${quoteSource}) ![chart](foreverlm://attachment/abc123)`, aliases)
  const answer = '[a joined line](foreverlm://grounding/1 "Zara Holt") and ![chart](foreverlm://attachment/2)'
  assert.equal(
    restoredAddresses(answer, aliases),
    `[a joined line](${quoteSource} "Zara Holt") and ![chart](foreverlm://attachment/abc123)`
  )
})

test('a stand-in the model was never given stays, and reads as made up', () => {
  const aliases = newAddressAliases()
  aliasedAddresses(`[a](${quoteSource})`, aliases)
  const restored = restoredAddresses('[a](foreverlm://grounding/1) [b](foreverlm://grounding/5)', aliases)
  assert.equal(restored, `[a](${quoteSource}) [b](foreverlm://grounding/5)`)
  assert.ok(isAddressStandIn('foreverlm://grounding/5'))
  assert.ok(isAddressStandIn('https://foreverlm.invalid/doc/12'))
  assert.ok(!isAddressStandIn(quoteSource))
  assert.ok(!isAddressStandIn('https://example.org/2'))
})

test('words a passage keeps are kept; joined lines change no word', () => {
  const before = 'To judge from all the efforts'.split(' ')
  const { kept, removed } = wordChanges(before, [...before])
  assert.ok(kept.every(Boolean))
  assert.equal(removed.size, 0)
})

test('a changed word reads as one taken out and one put in, where it stood', () => {
  const { kept, removed } = wordChanges('the big grey cell'.split(' '), 'the small grey cell'.split(' '))
  assert.deepEqual(kept, [true, false, true, true])
  assert.deepEqual([...removed], [[1, ['big']]])
})

test('words taken out at the end stand after the last word', () => {
  const { kept, removed } = wordChanges('one two three four'.split(' '), 'one two'.split(' '))
  assert.deepEqual(kept, [true, true])
  assert.deepEqual([...removed], [[2, ['three', 'four']]])
})

test('a middle too long to align reads as replaced whole', () => {
  const before = Array.from({ length: 600 }, (_, index) => `old${index}`)
  const after = ['start', ...Array.from({ length: 600 }, (_, index) => `new${index}`)]
  const { kept, removed } = wordChanges(['start', ...before], after, { limit: 1000 })
  assert.equal(kept.filter(Boolean).length, 1)
  assert.equal(removed.get(1).length, 600)
})

test('a written edit that keeps most words marks only the new ones, and what it took out where it stood', () => {
  const marks = reviewWordMarks('the big grey cell divides'.split(' '), 'the small grey cell divides'.split(' '))
  assert.equal(marks.wordLevel, true)
  assert.deepEqual(marks.added, [1])
  assert.deepEqual([...marks.removed], [[1, ['big']]])
})

test('a rewrite, new writing, or an emptied passage is marked whole', () => {
  assert.equal(reviewWordMarks('one two three four five'.split(' '), 'entirely different words here'.split(' ')).wordLevel, false)
  assert.equal(reviewWordMarks([], 'new words'.split(' ')).wordLevel, false)
  assert.equal(reviewWordMarks('old words'.split(' '), []).wordLevel, false)
})
