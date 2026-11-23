import { execFileSync } from 'node:child_process'

// Playwright entrega o mouse ao Chromium. O aplicativo também lê o cursor da tela do Mac.
// Ambos precisam representar a mesma entrada para a pílula permanecer sob o ponteiro.
export async function alinharCursor(app, page, locator) {
  const box = await locator.boundingBox()
  if (!box || box.width <= 0 || box.height <= 0) throw Error('O alvo do cursor está invisível.')
  const x = Math.round(box.x + box.width / 2)
  const y = Math.round(box.y + box.height / 2)
  const origem = await app.evaluate(({ BrowserWindow }, url) => {
    const janela = BrowserWindow.getAllWindows().find(w => w.webContents.getURL() === url)
    if (!janela) throw Error('Janela do ensaio indisponível.')
    return janela.getContentBounds()
  }, page.url())
  const telaX = origem.x + x, telaY = origem.y + y
  execFileSync(process.env.GZEROOS_CURSOR_ENSAIO, [String(telaX), String(telaY)])
  const cursor = await app.evaluate(({ screen }) => screen.getCursorScreenPoint())
  if (Math.abs(cursor.x - telaX) > 1 || Math.abs(cursor.y - telaY) > 1)
    throw Error('O cursor físico não chegou ao alvo no Mac de ensaio.')
  await page.mouse.move(x, y)
}
