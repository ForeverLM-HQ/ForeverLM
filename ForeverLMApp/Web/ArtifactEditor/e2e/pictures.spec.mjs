// Pictures on a line of their own: the bar a selected picture shows (where it
// stands, its width, Caption, Move up/down, Delete), the side handles that drag
// its width, and the block-property comment that keeps both in the page text.
import { test, expect } from '@playwright/test'
import { openEditor, load, settle, stored, blocks } from './editor-page.mjs'

// A 400×200 picture, drawn in the page so the test needs no file.
async function pictureURL(page) {
  return page.evaluate(() => {
    const canvas = document.createElement('canvas')
    canvas.width = 400
    canvas.height = 200
    const context = canvas.getContext('2d')
    context.fillStyle = '#3b82f6'
    context.fillRect(0, 0, 400, 200)
    return canvas.toDataURL('image/png')
  })
}

async function pageWithPicture(page, comment = '') {
  const errors = await openEditor(page, 'Before.')
  const url = await pictureURL(page)
  await load(page, `Before.\n\n![A blue box](${url})\n${comment ? `\n${comment}\n` : ''}\nAfter the picture.`, 'pictures')
  await page.locator('.artifact-picture img').waitFor()
  await settle(page, 150)
  return errors
}

const picture = (page) => page.locator('.artifact-picture')
const bar = (page) => page.locator('.artifact-picture-bar')

test('width and placement are read from the page and written back', async ({ page }) => {
  const errors = await pageWithPicture(page, '<!--fl {"width":"50","align":"wrap-left"}-->')
  await expect(picture(page)).toHaveAttribute('data-width', '50')
  await expect(picture(page)).toHaveAttribute('data-align', 'wrap-left')
  expect(await stored(page)).toContain('<!--fl {"width":"50","align":"wrap-left"}-->')
  const column = await page.evaluate(() => {
    const view = window.__editorTest.view()
    const style = getComputedStyle(view.dom)
    return view.dom.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)
  })
  const box = await picture(page).boundingBox()
  expect(Math.abs(box.width - column / 2)).toBeLessThan(3)
  expect(await page.evaluate(() => getComputedStyle(document.querySelector('.artifact-picture')).float)).toBe('left')
  expect(errors).toEqual([])
})

test('a click shows the bar; a size and a placement are kept in the page', async ({ page }) => {
  const errors = await pageWithPicture(page)
  await expect(bar(page)).toBeHidden()
  expect(await stored(page)).not.toContain('<!--fl')
  await picture(page).locator('img').click()
  await expect(bar(page)).toBeVisible()
  await bar(page).getByRole('button', { name: 'Medium' }).click()
  await settle(page)
  await bar(page).getByRole('button', { name: 'Right', exact: true }).click()
  await settle(page)
  expect(await stored(page)).toContain('<!--fl {"width":"50","align":"right"}-->')
  await expect(bar(page)).toBeVisible()
  await expect(bar(page).getByRole('button', { name: 'Medium' })).toHaveAttribute('aria-pressed', 'true')
  // Back to its own size in the middle: no comment at all.
  await bar(page).getByRole('button', { name: 'Its own size' }).click()
  await bar(page).getByRole('button', { name: 'Centre' }).click()
  await settle(page)
  expect(await stored(page)).not.toContain('<!--fl')
  expect(errors).toEqual([])
})

test('dragging a side handle sets the width in steps of five', async ({ page }) => {
  const errors = await pageWithPicture(page, '<!--fl {"width":"50","align":"left"}-->')
  await picture(page).locator('img').click()
  const handle = picture(page).locator('.artifact-picture-handle[data-side="right"]')
  const box = await handle.boundingBox()
  const column = await page.evaluate(() => {
    const view = window.__editorTest.view()
    const style = getComputedStyle(view.dom)
    return view.dom.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)
  })
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.down()
  await page.mouse.move(box.x + box.width / 2 + column * 0.25, box.y + box.height / 2, { steps: 6 })
  await expect(picture(page).locator('.artifact-picture-size')).toHaveText('75%')
  await page.mouse.up()
  await settle(page)
  expect(await stored(page)).toContain('<!--fl {"width":"75","align":"left"}-->')
  expect(errors).toEqual([])
})

test('Move up and Move down carry the picture past its neighbours', async ({ page }) => {
  const errors = await pageWithPicture(page)
  expect(await blocks(page)).toEqual(['paragraph', 'image-block', 'paragraph'])
  await picture(page).locator('img').click()
  await bar(page).getByRole('button', { name: 'Move down' }).click()
  await settle(page)
  expect((await blocks(page)).slice(0, 3)).toEqual(['paragraph', 'paragraph', 'image-block'])
  await bar(page).getByRole('button', { name: 'Move up' }).click()
  await bar(page).getByRole('button', { name: 'Move up' }).click()
  await settle(page)
  expect((await blocks(page)).slice(0, 3)).toEqual(['image-block', 'paragraph', 'paragraph'])
  await expect(bar(page).getByRole('button', { name: 'Move up' })).toBeDisabled()
  expect(errors).toEqual([])
})

test('a caption is written, and Delete takes the picture away', async ({ page }) => {
  const errors = await pageWithPicture(page)
  await picture(page).locator('img').click()
  await bar(page).getByRole('button', { name: 'Caption' }).click()
  await page.keyboard.type('Two steps')
  await page.keyboard.press('Enter')
  await settle(page, 300)
  expect(await stored(page)).toContain('"Two steps")')
  // A second click on the same spot within half a second is a double-click.
  await page.waitForTimeout(600)
  await picture(page).locator('img').click()
  await bar(page).getByRole('button', { name: 'Delete' }).click()
  await settle(page)
  expect(await blocks(page)).not.toContain('image-block')
  expect(errors).toEqual([])
})

test('a picture the host inserts on an empty line is a picture block', async ({ page }) => {
  const errors = await openEditor(page, 'Words.')
  const url = await pictureURL(page)
  await page.locator('.milkdown .editor p').first().click()
  await page.keyboard.press('End')
  await page.keyboard.press('Enter')
  await page.evaluate((dataURL) => window.foreverLMArtifactEditor.insertAttachment({ token: 'picture-1', dataURL, altText: 'A box' }), url)
  await settle(page)
  expect(await blocks(page)).toContain('image-block')
  await expect(picture(page)).toHaveCount(1)
  expect(errors).toEqual([])
})

test('the published copy keeps width and placement, not the controls', async ({ page }) => {
  await pageWithPicture(page, '<!--fl {"width":"50","align":"wrap-right"}-->')
  const html = await page.evaluate(() => window.foreverLMArtifactEditor.publicationHTML?.('Pictures') ?? '')
  test.skip(!html, 'this editor build does not expose publicationHTML')
  expect(html).toContain('class="picture picture-wrap-right picture-w-50"')
  expect(html).not.toContain('artifact-picture-bar')
})
