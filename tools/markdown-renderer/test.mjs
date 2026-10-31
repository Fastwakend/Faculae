import {chromium} from 'playwright';
import path from 'node:path';
import fs from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const output = path.join(root, 'artifacts/renderer-tests');
await fs.mkdir(output, {recursive: true});
const browser = await chromium.launch({executablePath: process.env.SEEK_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', headless: true});
const page = await browser.newPage({viewport: {width: 350, height: 1000}, deviceScaleFactor: 2});
const errors = [], externalRequests = [], cases = [];
page.on('pageerror', error => errors.push(error.message));
page.on('request', request => { if (/^https?:/.test(request.url())) externalRequests.push(request.url()); });
await page.addInitScript(() => {
  window.testMessages = [];
  window.webkit = {messageHandlers: {renderer: {postMessage: value => window.testMessages.push(value)}}};
});
await page.goto(pathToFileURL(path.join(root, 'SeekAPI/Resources/MarkdownRenderer/index.html')).href);
await page.waitForFunction(() => typeof window.renderMarkdown === 'function');
async function render(text, options = {}) {
  await page.evaluate(async payload => { await window.renderMarkdown(payload); await document.fonts.ready; }, {text, ...options});
}
async function check(name, run) { await run(); cases.push(name); }
try {
  await check('GFM table, bold, strikethrough and narrow horizontal scrolling', async () => {
    await render('| 模型 | 状态 | 显示名称 | 延迟 | 速度 | 备注 |\n| :--- | :---: | ---: | --- | --- | --- |\n| **Gemini** | ~~旧版~~ | Flash-1017-long-name | 1s | 100 | 正常 |');
    assert.equal(await page.locator('table tbody tr').count(), 1);
    assert.equal(await page.locator('th').count(), 6);
    assert.equal(await page.locator('td strong').textContent(), 'Gemini');
    assert.equal(await page.locator('td del').textContent(), '旧版');
    assert(await page.locator('.table-scroll').evaluate(e => e.scrollWidth > e.clientWidth));
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  });
  await check('Inline/block LaTeX, Greek symbols, matrices, all four delimiters and bundled fonts', async () => {
    await render(String.raw`内联 $E=mc^2$ 与 \(\alpha+\beta\)。

$$
\int_0^1 x^2\,dx=\frac{1}{3}
$$

\[
\begin{pmatrix}1&2\\3&4\end{pmatrix}
\]`);
    assert.equal(await page.locator('.katex').count(), 4);
    assert.equal(await page.locator('.katex-error').count(), 0);
    assert.equal(await page.locator('math').count(), 4);
    assert(await page.evaluate(() => document.fonts.check('16px KaTeX_Main')));
  });
  await check('Code highlighting and actual user-click copy; formulas stay literal in code', async () => {
    const source = 'const formula = "$x^2$";\nconsole.log(formula);';
    await render('```javascript\n' + source + '\n```');
    assert.equal(await page.locator('pre code').textContent(), source);
    assert.equal(await page.locator('.katex').count(), 0);
    assert(await page.locator('.hljs-keyword').count() > 0);
    await page.locator('button[data-copy]').click();
    assert.equal(await page.evaluate(() => window.testMessages.filter(x => x.type === 'copy').at(-1).text), source);
  });
  await check('Nested lists, blockquotes, task lists and safe Markdown links', async () => {
    await render('1. 第一项\n   - 子项目\n   - 第二项\n2. 第三项\n\n> **引用**\n\n- [x] 完成\n- [ ] 待做\n\n[文档](https://example.com/docs)');
    assert.equal(await page.locator('ol > li > ul').count(), 1);
    assert.equal(await page.locator('blockquote strong').textContent(), '引用');
    assert.equal(await page.locator('input[type=checkbox]').count(), 2);
    assert.equal(await page.locator('a').getAttribute('href'), 'https://example.com/docs');
  });
  await check('Offline Mermaid chart rendered to SVG', async () => {
    await render('```mermaid\nflowchart LR\n  A[用户] --> B[模型]\n  B --> C[回答]\n```');
    assert.equal(await page.locator('.diagram svg').count(), 1);
    assert((await page.locator('.diagram').textContent()).includes('用户'));
  });
  await check('Raw HTML, scripts, JavaScript links, SVG events and KaTeX commands remain inert', async () => {
    await render('<script>window.pwned=1</script>\n<img src=x onerror="window.pwned=2">\n\n[危险](javascript:alert(1))\n\n![图标](data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=)\n\n$\\href{javascript:alert(1)}{x}$\n\n```html\n<script>window.pwned=3</script>\n```');
    assert.equal(await page.evaluate(() => window.pwned), undefined);
    assert.equal(await page.locator('#content script, #content iframe, #content [onerror], #content a[href^="javascript:"], #content img').count(), 0);
  });
  await check('Broken/streaming Markdown and math recover on the next update', async () => {
    await render('```mermaid\nflowchart LR\nA[');
    assert.equal(await page.locator('.diagram pre').count(), 1);
    await render('尚未完成 $\\frac{1');
    await render('已经完成 $\\frac{1}{2}$');
    assert.equal(await page.locator('.katex').count(), 1);
    await page.evaluate(async () => {
      const old = window.renderMarkdown({text:'```mermaid\nflowchart LR\nA-->B\n```'});
      const next = window.renderMarkdown({text:'最终回答 **保留**'});
      await Promise.all([old, next]);
    });
    assert.equal(await page.locator('#content strong').textContent(), '保留');
    assert.equal(await page.locator('.diagram').count(), 0);
  });
  const sample = String.raw`## 结果对比

| 模型 | 推理等级 | 状态 |
| --- | --- | --- |
| **Gemini Flash-1017** | High | 已完成 |
| Claude | Max | 已完成 |

爱因斯坦公式 $E=mc^2$，积分为：

$$\int_0^1 x^2\,dx=\frac{1}{3}$$

> 支持 **Markdown**、数学符号、表格与图表。

~~~mermaid
flowchart LR
  A[提问] --> B[推理] --> C[回答]
~~~

~~~swift
let answer = "你好，世界"
print(answer)
~~~`;
  await check('Dark/light appearance, larger text, height bridge and offline loading', async () => {
    for (const dark of [false, true]) {
      await render(sample, {dark});
      await page.screenshot({path: path.join(output, dark ? 'dark.png' : 'light.png'), fullPage: true});
    }
    const normal = await page.locator('#content').evaluate(e => e.getBoundingClientRect().height);
    await render(sample, {fontSize: 22});
    const large = await page.locator('#content').evaluate(e => e.getBoundingClientRect().height);
    assert(large > normal);
    await page.waitForFunction(() => window.testMessages.some(x => x.type === 'height' && x.value > 100));
    assert.equal(externalRequests.length, 0);
    assert.deepEqual(errors, []);
  });
  await fs.writeFile(path.join(output, 'results.json'), JSON.stringify({engine: 'Desktop Edge Chromium (not iOS WebKit)', cases, passed: cases.length, failures: 0, externalRequests, errors}, null, 2));
  console.log(`Passed ${cases.length} renderer regression cases.`);
} finally { await browser.close(); }
