// Copies the Map's page into App/KnowledgeMapResources/, which the Mac's
// WKWebView loads over file://. The renderer is a plain classic script with no
// dependencies, so there is nothing to bundle. The Map is the Mac's alone
// (product owner, 2026-10-05: "we don't need web and iphone for now").
import { copyFile, mkdir } from 'node:fs/promises'

const outputs = [
  new URL('../../App/KnowledgeMapResources/', import.meta.url),
]
const files = [
  ['knowledge-map.html', 'knowledge-map.html'],
  ['src/knowledge-map.js', 'knowledge-map.js'],
  ['src/knowledge-map.css', 'knowledge-map.css'],
  ['src/mac-host.js', 'mac-host.js'],
]

for (const output of outputs) {
  await mkdir(output, { recursive: true })
  for (const [from, to] of files) {
    await copyFile(new URL(from, import.meta.url), new URL(to, output))
  }
}
