// Builds the page editor for the browser tests (e2e/*.spec.mjs): the same
// source as build.mjs, unminified, with one hook the tests read the document
// through (`window.__editorTest.view()`). Written to e2e/.build/, never shipped.
// Playwright runs it once before the tests (playwright.config.mjs).
import { build } from 'esbuild'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { milkdownPatches } from '../build-patches.mjs'

const source = new URL('../src/', import.meta.url)
const output = new URL('./.build/editor.js', import.meta.url)

export default async function buildForTests() {
  const editor = await readFile(new URL('artifact-editor.js', source), 'utf8')
  await build({
    stdin: {
      contents: `${editor}\nwindow.__editorTest = { view: () => activeEditorView() }\n`,
      resolveDir: fileURLToPath(source),
      sourcefile: 'artifact-editor.e2e.js',
      loader: 'js',
    },
    bundle: true,
    minify: false,
    format: 'iife',
    platform: 'browser',
    target: 'safari17',
    loader: { '.png': 'dataurl', '.woff2': 'file', '.woff': 'empty', '.ttf': 'empty' },
    assetNames: 'fonts/[name]-[hash]',
    outfile: fileURLToPath(output),
    plugins: [milkdownPatches()],
    logLevel: 'error',
  })
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await buildForTests()
