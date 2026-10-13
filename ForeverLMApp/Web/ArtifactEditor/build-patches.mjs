// Corrections to Milkdown's own code, made as the bundle is built (build.mjs,
// e2e/build-e2e.mjs). Each must find the text it corrects, or the build
// stops: an upgrade that changes the code has to be looked at again, never
// shipped without the correction by accident.
import { readFile } from 'node:fs/promises'

export const patches = [
  {
    // Typing straight after Return in a list scrambled the new item's first
    // letters ("three" became "hreet"): the list item's view, mounting the new
    // item, took the caret as it stood then and put it back a frame later,
    // over whatever had been typed in between. On a long page that frame comes
    // late. The caret it restores is now the one the page has when the frame
    // comes, which is what the restore is for (the moved DOM lost the browser's
    // selection). e2e/writing.spec.mjs types into a new list item to hold it.
    file: /@milkdown[\\/]components[\\/]lib[\\/]list-item-block[\\/]index\.js$/,
    find: /const anchorPos = state\.doc\.resolve\(anchor\);(\s*)const headPos = state\.doc\.resolve\(head\);/,
    replace: 'const anchorPos = state.selection.$anchor;$1const headPos = state.selection.$head;',
  },
]

export function milkdownPatches() {
  return {
    name: 'foreverlm-milkdown-patches',
    setup(build) {
      for (const patch of patches) {
        build.onLoad({ filter: patch.file }, async (args) => {
          const source = await readFile(args.path, 'utf8')
          if (!patch.find.test(source)) {
            throw new Error(`build-patches.mjs: the correction for ${args.path} no longer finds its text; look at it again`)
          }
          return { contents: source.replace(patch.find, patch.replace), loader: 'js' }
        })
      }
    },
  }
}
