// Builds the one chat renderer both surfaces run.
//
// Two outputs from one source tree:
//   • App/ChatRendererResources/  — a classic-script bundle plus the page, the
//     stylesheet and KaTeX, all loaded from inside the app bundle. WKWebView
//     serves this page over file://, where ES module imports are blocked, so
//     the Mac build has to be a self-contained IIFE.
//   • docs-site/website/library/chat-renderer/ — an ES module Web Studio
//     imports. `library-source-images.js` stays external there so the site
//     keeps exactly one runtime copy of the picture-reference parser it shares
//     with the tool executor; the Mac build inlines it.
//
// KaTeX is copied out of the same node_modules into both the app bundle and the
// website's vendor directory, so the two can no longer drift. They already had:
// the Mac was pinned to 0.16.10 on the CDN while the website vendored 0.18.4,
// and the fix for math-mode italics had to be applied to each separately.

import { build } from 'esbuild'
import { copyFile, cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const projectDirectory = dirname(fileURLToPath(import.meta.url))
const appOutput = new URL('../../App/ChatRendererResources/', import.meta.url)
const webOutput = new URL('../../../docs-site/website/library/chat-renderer/', import.meta.url)
const katexVendor = new URL('../../../docs-site/website/library/vendor/katex/', import.meta.url)
const katexDist = join(projectDirectory, 'node_modules', 'katex', 'dist')

// `#source-images` is the canonical picture-reference parser, which lives with
// the website because the browser's tool executor imports it too.
const sourceImages = join(
  projectDirectory, '..', '..', '..', 'docs-site', 'website', 'library', 'library-source-images.js',
)
const externalSourceImages = {
  name: 'external-source-images',
  setup(builder) {
    builder.onResolve({ filter: /^#source-images$/ }, () => ({
      path: '../library-source-images.js',
      external: true,
    }))
  },
}

const shared = {
  bundle: true,
  minify: true,
  format: 'esm',
  platform: 'browser',
  target: 'safari17',
  legalComments: 'eof',
}

await mkdir(appOutput, { recursive: true })
await mkdir(webOutput, { recursive: true })

await build({
  ...shared,
  entryPoints: ['src/mac-host.js'],
  format: 'iife',
  alias: { '#source-images': sourceImages },
  outfile: new URL('chat-render.js', appOutput).pathname,
})

// The whole transcript as one page (`mac-transcript.js`): the same renderer,
// drawing every reply of a chat into one document.
await build({
  ...shared,
  entryPoints: ['src/mac-transcript.js'],
  format: 'iife',
  alias: { '#source-images': sourceImages },
  outfile: new URL('chat-transcript.js', appOutput).pathname,
})

await build({
  ...shared,
  entryPoints: ['src/chat-render.js'],
  plugins: [externalSourceImages],
  outfile: new URL('chat-render.js', webOutput).pathname,
})

for (const output of [appOutput, webOutput]) {
  const bundle = new URL('chat-render.js', output)
  await writeFile(bundle, (await readFile(bundle, 'utf8')).replace(/[ \t]+$/gm, ''), 'utf8')
  await copyFile(new URL('src/chat-render.css', import.meta.url), new URL('chat-render.css', output))
}

await copyFile(
  new URL('chat-render.html', import.meta.url),
  new URL('chat-render.html', appOutput),
)
await copyFile(
  new URL('chat-transcript.html', import.meta.url),
  new URL('chat-transcript.html', appOutput),
)
await copyFile(new URL('src/chat-transcript.css', import.meta.url), new URL('chat-transcript.css', appOutput))
{
  const bundle = new URL('chat-transcript.js', appOutput)
  await writeFile(bundle, (await readFile(bundle, 'utf8')).replace(/[ \t]+$/gm, ''), 'utf8')
}

// KaTeX ships as a plain script that defines a global, which is what both
// surfaces load it as. The app bundle also carries the stylesheet and the woff2
// faces KaTeX's "html" output draws with; its "mathml" output needs neither,
// because the system math font draws the equation.
for (const [name, source] of [
  ['katex.min.js', join(katexDist, 'katex.min.js')],
  ['mhchem.min.js', join(katexDist, 'contrib', 'mhchem.min.js')],
  ['katex.min.css', join(katexDist, 'katex.min.css')],
]) {
  await copyFile(source, new URL(name, appOutput).pathname)
}

const fontOutput = new URL('fonts/', appOutput)
await rm(fontOutput, { recursive: true, force: true })
await mkdir(fontOutput, { recursive: true })
for (const entry of await readdir(join(katexDist, 'fonts'))) {
  // Only woff2: every browser that can run this app reads it, and the .woff
  // and .ttf faces beside it in katex.min.css are never requested.
  if (!entry.endsWith('.woff2')) continue
  await copyFile(join(katexDist, 'fonts', entry), new URL(entry, fontOutput).pathname)
}

for (const [name, source] of [
  ['katex.min.js', join(katexDist, 'katex.min.js')],
  ['mhchem.min.js', join(katexDist, 'contrib', 'mhchem.min.js')],
]) {
  await copyFile(source, new URL(name, katexVendor).pathname)
}
await writeFile(
  new URL('LICENSE', katexVendor),
  `${await readFile(join(projectDirectory, 'node_modules', 'katex', 'LICENSE'), 'utf8')}\n`
  + '---\n\n'
  + "mhchem.min.js (KaTeX's mhchem extension) is derived from mhchem.js and is\n"
  + 'licensed under the Apache License, Version 2.0:\n'
  + 'http://www.apache.org/licenses/LICENSE-2.0\n',
  'utf8',
)

const packageLock = JSON.parse(await readFile(join(projectDirectory, 'package-lock.json'), 'utf8'))
const productionPackages = Object.entries(packageLock.packages)
  .filter(([packagePath, metadata]) => packagePath && !metadata.dev)
  .sort(([left], [right]) => left.localeCompare(right))

const notices = [
  'ForeverLM Chat Renderer — Third-Party Notices',
  '',
  'The chat renderer bundle contains the following open-source packages.',
  '',
]

for (const [packagePath, lockMetadata] of productionPackages) {
  const packageDirectory = join(projectDirectory, packagePath)
  let packageMetadata
  let files
  try {
    packageMetadata = JSON.parse(await readFile(join(packageDirectory, 'package.json'), 'utf8'))
    files = await readdir(packageDirectory)
  } catch {
    continue
  }

  notices.push('='.repeat(80))
  notices.push(`${packageMetadata.name ?? packagePath} ${packageMetadata.version ?? lockMetadata.version ?? ''}`.trim())
  notices.push(`License: ${packageMetadata.license ?? lockMetadata.license ?? 'See package files'}`)
  if (packageMetadata.homepage) notices.push(packageMetadata.homepage)
  notices.push('='.repeat(80), '')

  const licenseFiles = files.filter((file) => /^(licen[sc]e|copying|notice)(\.|-|$)/i.test(file)).sort()
  if (licenseFiles.length === 0) {
    notices.push('No standalone license file was published in this package.', '')
    continue
  }
  for (const licenseFile of licenseFiles) {
    notices.push((await readFile(join(packageDirectory, licenseFile), 'utf8')).replace(/[ \t]+$/gm, ''), '')
  }
}

for (const output of [appOutput, webOutput]) {
  await writeFile(
    new URL('ChatRendererThirdPartyNotices.txt', output),
    `${notices.join('\n').trim()}\n`,
    'utf8',
  )
}
