// Builds the published-page renderer the Mac app runs.
//
// foreverlm.com draws a published Doc with `docs-site/website/publishing/`
// (page.ts and markdown.ts). The Mac's Page view used to ask the site to draw
// the doc's current text over `POST /api/publish/preview` on every open and
// every save, and waited on the round trip — the TLS handshake, the identity
// check behind the route, the render — before it could show anything. This
// bundle is the same renderer, compiled into a classic script the app evaluates
// in JavaScriptCore (`PublishedPageRenderer`), so the page is drawn on the Mac
// in milliseconds from the same code the site runs, and the preview route is
// only the fallback when the bundle cannot run.
//
// The bundle carries one polyfill, the web platform's URL parser (url-polyfill.js),
// because JavaScriptCore has none and the renderer reads a link's host.
//
// The manifest beside the bundle records what it was built from. A website
// test (`published-page-bundle.test.ts`) recomputes those digests, so a change
// to the renderer that is not rebuilt into the app fails the site's check
// rather than shipping two renderers that disagree.

import { build } from 'esbuild'
import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

const outputDirectory = new URL('../../App/PublishedPageResources/', import.meta.url)
const publishing = new URL('../../../docs-site/website/publishing/', import.meta.url)
const sources = ['page.ts', 'markdown.ts']

await mkdir(outputDirectory, { recursive: true })
await build({
  entryPoints: [fileURLToPath(new URL('page.ts', publishing))],
  // The web platform's URL parser, which JavaScriptCore does not have; see
  // url-polyfill.js.
  inject: [fileURLToPath(new URL('url-polyfill.js', import.meta.url))],
  bundle: true,
  minify: true,
  format: 'iife',
  globalName: 'ForeverLMPublishedPage',
  platform: 'neutral',
  target: 'safari17',
  legalComments: 'none',
  outfile: fileURLToPath(new URL('published-page.js', outputDirectory)),
})

const bundleURL = new URL('published-page.js', outputDirectory)
const bundle = await readFile(bundleURL, 'utf8')
await writeFile(bundleURL, bundle.replace(/[ \t]+$/gm, ''), 'utf8')

const pageSource = await readFile(new URL('page.ts', publishing), 'utf8')
const rendererVersion = Number(/export const RENDERER_VERSION = (\d+);/.exec(pageSource)?.[1])
if (!Number.isInteger(rendererVersion)) throw new Error('page.ts no longer declares RENDERER_VERSION')

const digests = {}
for (const source of sources) {
  const text = await readFile(new URL(source, publishing), 'utf8')
  digests[`docs-site/website/publishing/${source}`] = createHash('sha256').update(text).digest('hex')
}
// The bundle carries core-js's URL polyfill; its notice ships beside it, as
// the artifact editor's third-party notices do.
const coreJS = JSON.parse(await readFile(new URL('node_modules/core-js/package.json', import.meta.url), 'utf8'))
const coreJSLicense = await readFile(new URL('node_modules/core-js/LICENSE', import.meta.url), 'utf8')
await writeFile(
  new URL('PublishedPageThirdPartyNotices.txt', outputDirectory),
  [
    'ForeverLM Published Page Renderer — Third-Party Notices',
    '',
    'The renderer bundle contains the following open-source package.',
    '',
    '='.repeat(80),
    `core-js ${coreJS.version}`,
    `License: ${coreJS.license}`,
    coreJS.homepage ?? '',
    '='.repeat(80),
    '',
    coreJSLicense.replace(/[ \t]+$/gm, '').trim(),
    '',
  ].join('\n'),
  'utf8'
)

await writeFile(
  new URL('published-page.manifest.json', outputDirectory),
  `${JSON.stringify({ renderer_version: rendererVersion, sources: digests }, null, 2)}\n`,
  'utf8'
)
