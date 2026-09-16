import { chromium } from 'playwright'
const OUT = '/tmp/shots'
import { mkdirSync } from 'node:fs'
mkdirSync(OUT, { recursive: true })

const browser = await chromium.launch({ channel: 'chromium', executablePath: '/opt/pw-browsers/chromium' })
const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: 2 })
const page = await ctx.newPage()
const errors = []
page.on('console', m => { if (m.type() === 'error') errors.push(m.text()) })
page.on('pageerror', e => errors.push(String(e)))

await page.goto('http://localhost:5173/', { waitUntil: 'networkidle' })
await page.screenshot({ path: `${OUT}/1-login.png` })

// Sign in as the class teacher
await page.getByRole('button', { name: /Elena/ }).click()
await page.waitForTimeout(1200)
await page.screenshot({ path: `${OUT}/2-today.png`, fullPage: true })

// Class view with the heatmap
await page.getByRole('link', { name: 'Classes' }).click()
await page.waitForTimeout(600)
await page.locator('select').selectOption({ index: 1 })
await page.waitForTimeout(1200)
await page.screenshot({ path: `${OUT}/3-class.png`, fullPage: true })

// A student profile
await page.locator('a[href^="/students/"]').first().click()
await page.waitForTimeout(1200)
await page.screenshot({ path: `${OUT}/4-student.png`, fullPage: true })

console.log('CONSOLE ERRORS:', errors.length ? errors.slice(0,8).join('\n  ') : 'none')
await browser.close()
