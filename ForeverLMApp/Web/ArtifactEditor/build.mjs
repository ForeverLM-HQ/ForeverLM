import { build } from 'esbuild'
import { milkdownPatches } from './build-patches.mjs'
import { copyFile, cp, mkdir, readFile, readdir, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const outputDirectory = new URL('../../App/ArtifactEditorResources/', import.meta.url)
const projectDirectory = dirname(fileURLToPath(import.meta.url))

await mkdir(outputDirectory, { recursive: true })
await build({
  entryPoints: ['src/artifact-editor.js'],
  bundle: true,
  minify: true,
  format: 'iife',
  platform: 'browser',
  target: 'safari17',
  legalComments: 'eof',
  loader: {
    '.png': 'dataurl',
    '.woff2': 'file',
    '.woff': 'empty',
    '.ttf': 'empty',
  },
  assetNames: 'fonts/[name]-[hash]',
  outfile: new URL('artifact-editor.js', outputDirectory).pathname,
  plugins: [milkdownPatches()],
})
const editorBundleURL = new URL('artifact-editor.js', outputDirectory)
const editorBundle = await readFile(editorBundleURL, 'utf8')
await writeFile(editorBundleURL, editorBundle.replace(/[ \t]+$/gm, ''), 'utf8')
await copyFile(
  new URL('artifact-editor.html', import.meta.url),
  new URL('artifact-editor.html', outputDirectory)
)

const packageLock = JSON.parse(await readFile(join(projectDirectory, 'package-lock.json'), 'utf8'))
const productionPackages = Object.entries(packageLock.packages)
  .filter(([packagePath, metadata]) => packagePath && !metadata.dev)
  .sort(([left], [right]) => left.localeCompare(right))

const notices = [
  'ForeverLM Artifact Editor — Third-Party Notices',
  '',
  'The editor bundle contains the following open-source packages.',
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

  const licenseFiles = files
    .filter((file) => /^(licen[sc]e|copying|notice)(\.|-|$)/i.test(file))
    .sort()
  if (licenseFiles.length === 0) {
    notices.push('No standalone license file was published in this package.', '')
    continue
  }

  for (const licenseFile of licenseFiles) {
    const licenseText = await readFile(join(packageDirectory, licenseFile), 'utf8')
    notices.push(licenseText.replace(/[ \t]+$/gm, ''), '')
  }
}

await writeFile(
  new URL('ArtifactEditorThirdPartyNotices.txt', outputDirectory),
  `${notices.join('\n').trim()}\n`,
  'utf8'
)

// Web Studio embeds the exact same editor bundle. Sharing the renderer is what
// keeps Markdown, source links, image nodes, selection formatting, comments,
// and AI gestures from becoming two subtly incompatible products.
const webOutputDirectory = new URL(
  '../../../docs-site/website/library/artifact-editor/',
  import.meta.url
)
await mkdir(webOutputDirectory, { recursive: true })
await cp(outputDirectory, webOutputDirectory, { recursive: true, force: true })
