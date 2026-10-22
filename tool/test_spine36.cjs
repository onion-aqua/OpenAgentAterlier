// Run with Playwright available in NODE_PATH, a local model directory, and an
// output directory. Uses the SAME HTML/JS as the Android platform view.
const { chromium } = require('playwright');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

async function main() {
  const model = path.resolve(process.argv[2]);
  const output = path.resolve(process.argv[3]);
  fs.mkdirSync(output, { recursive: true });
  const runtime = path.resolve(__dirname, '../android/app/src/main/assets/spine36');
  const files = new Map([
    ['/index.html', ['text/html', fs.readFileSync(path.join(runtime, 'index.html'))]],
    ...['player.js', 'spine-webgl.js'].map(f => ['/' + f, ['application/javascript', fs.readFileSync(path.join(runtime, f))]]),
    ['/model/model.json', ['application/json', fs.readFileSync(path.join(model, 'data.json'))]],
    ['/model/model.atlas', ['text/plain', fs.readFileSync(path.join(model, 'data.atlas'), 'utf8').replace(/^\s*[^\r\n]+\.png/m, 'texture.png')]],
    ['/model/texture.png', ['image/png', fs.readFileSync(path.join(model, 'data.png'))]],
  ]);
  const server = http.createServer((req, res) => {
    const file = files.get(req.url);
    if (!file) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': file[0] }); res.end(file[1]);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({
    executablePath: process.env.SPINE_TEST_BROWSER || undefined,
    headless: true,
    args: ['--enable-webgl', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  try {
    const page = await browser.newPage({ viewport: { width: 480, height: 760 }, deviceScaleFactor: 1 });
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));
    await page.addInitScript(() => {
      window.runtimeEvents = [];
      window.addEventListener('spine36', e => window.runtimeEvents.push(e.detail));
    });
    const url = `http://127.0.0.1:${server.address().port}/index.html`;
    await page.goto(url);
    await page.waitForFunction(() => window.runtimeEvents.some(e => e.type === 'ready' || e.type === 'error'));
    const event = await page.evaluate(() => window.runtimeEvents[0]);
    assert.equal(event.type, 'ready', JSON.stringify(event));
    assert.equal(event.value.length, 62);
    const idle = { idle: 'wait', paused: false, speaking: false, actionNonce: 0 };
    const update = async command => page.evaluate(p => window.spine36.update(p), command);
    await update(idle);
    await page.waitForTimeout(1100);
    const inspect = () => page.evaluate(() => window.spine36.inspect());
    const running = await inspect();
    assert.ok(running.time > 0.5, JSON.stringify(running));
    await page.screenshot({ path: path.join(output, 'spine36-mano-idle.png'), omitBackground: true });
    await update({ ...idle, paused: true });
    const paused = await inspect();
    await page.waitForTimeout(200);
    assert.equal((await inspect()).time, paused.time);
    await update({ ...idle, face: 'face_smile', action: 'yes', actionNonce: 1, speaking: true, mouth: 'lip_smile', energy: 0.7 });
    await page.waitForTimeout(250);
    const speaking = await inspect();
    assert.equal(speaking.tracks[11], 'face_smile');
    assert.equal(speaking.tracks[13], 'lip_smile');
    assert.ok(speaking.mouthTime > 0);
    await page.screenshot({ path: path.join(output, 'spine36-mano-smile.png'), omitBackground: true });
    for (const [index, animation] of event.value.entries()) {
      await update({ ...idle, action: animation, actionNonce: index + 2 });
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      assert.equal((await inspect()).failed, false, animation);
    }
    assert.deepEqual(errors, []);
    await page.reload();
    await page.waitForFunction(() => window.runtimeEvents.some(e => e.type === 'ready'));
    await update(idle);
    await page.waitForTimeout(150);
    assert.equal((await inspect()).loaded, true);
    await page.route('**/model/model.json', route => route.fulfill({
      contentType: 'application/json', body: '{"skeleton":{"spine":"3.6.53"},"bones":[{}]}',
    }));
    await page.reload();
    await page.waitForFunction(() => window.runtimeEvents.some(e => e.type === 'error'));
    assert.ok(!(await page.evaluate(() => window.runtimeEvents.some(e => e.type === 'ready'))));
    const report = { animations: event.value.length, idleTime: running.time, pause: 'passed',
      expression: speaking.tracks[11], mouth: speaking.tracks[13], allAnimations: 'passed',
      reload: 'passed', corruptModel: 'rejected', pageErrors: errors };
    fs.writeFileSync(path.join(output, 'spine36-render-check.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report, null, 2));
  } finally { await browser.close(); server.close(); }
}
main().catch(e => { console.error(e); process.exitCode = 1; });
