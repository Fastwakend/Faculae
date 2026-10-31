import {chromium} from 'playwright';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const output = path.join(root, 'artifacts/renderer-tests');
await fs.mkdir(output, {recursive: true});
const browser = await chromium.launch({executablePath: process.env.SEEK_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', headless: true});
const page = await browser.newPage({viewport: {width: 393, height: 800}, deviceScaleFactor: 2});
const errors = [], requests = [], cases = [];
page.on('pageerror', error => errors.push(error.message));
page.on('request', request => requests.push({url: request.url(), type: request.resourceType()}));
await page.addInitScript(() => {
  window.testMessages = [];
  window.webkit = {messageHandlers: {renderer: {postMessage: value => window.testMessages.push(value)}}};
});
await page.goto(pathToFileURL(path.join(root, 'SeekAPI/Resources/MarkdownRenderer/index.html')).href);
await page.waitForFunction(() => typeof window.updateTranscript === 'function');
const state = {conversationID: 'conversation-1', order: [], patches: [], fontSize: 16, dark: false, showReasoning: true};
async function update(patches, extra = {}) {
  return await page.evaluate(async payload => {
    // The app uses a separate WKWebView for export. This shared test document
    // must leave that export-only style before testing the live transcript.
    document.documentElement.classList.remove('conversation-export');
    const metrics = await window.updateTranscript(payload);
    await document.fonts.ready;
    return metrics;
  }, {...state, patches, ...extra});
}
async function check(name, run) { await run(); cases.push(name); }
const messages = Array.from({length: 120}, (_, i) => ({id: `message-${i}`, role: i % 2 ? 'assistant' : 'user',
  content: i % 2 ? `## 第 ${i} 条回答\n\n这是一条已完成的历史消息，包含 **强调**、列表和公式 $E=mc^2$。\n\n- 内容一\n- 内容二` : `第 ${i} 次提问`,
  reasoning: i === 119 ? '思考内容 **保留**' : '', status: 'complete', modelTitle: 'Gemini Flash-1017',
  logo: '', attachments: [], error: '', canRegenerate: i === 119}));
state.order = messages.map(x => x.id);
let initialMS, patchMS;
try {
  await check('120 rows render in one document; no eager diagram library load', async () => {
    const start = performance.now();
    await update(messages);
    initialMS = performance.now() - start;
    assert.equal(await page.locator('article.chat-message').count(), 120);
    assert.equal(await page.locator('.katex').count(), 60);
    assert.equal(requests.filter(x => x.type === 'document').length, 1);
    assert.equal(requests.filter(x => /\/mermaid\.js$/.test(x.url)).length, 0);
    assert.equal(await page.evaluate(() => !!window.SeekMermaid), false);
  });
  await check('Scrolling reuses every row and rich-text node without loading or DOM mutation', async () => {
    await page.evaluate(() => {
      window.savedRows = [...document.querySelectorAll('article')];
      window.savedBodies = window.savedRows.map(e => e.querySelector('.message-body').firstChild);
      window.scrollMutations = 0;
      window.scrollObserver = new MutationObserver(changes => { window.scrollMutations += changes.length; });
      window.scrollObserver.observe(document.querySelector('#content'), {subtree: true, childList: true});
      window.scrollTo(0, document.body.scrollHeight);
    });
    const requestCount = requests.length;
    for (const deltaY of [-2800, -2800, 1800, -1600, 2600, 2600]) {
      await page.mouse.wheel(0, deltaY);
      await page.waitForTimeout(80);
    }
    const result = await page.evaluate(() => {
      window.scrollObserver.disconnect();
      return {mutations: window.scrollMutations, identity: window.savedRows.every((row, i) =>
        row === document.querySelectorAll('article')[i] && row.querySelector('.message-body').firstChild === window.savedBodies[i])};
    });
    assert.equal(result.mutations, 0);
    assert.equal(result.identity, true);
    assert.equal(requests.length, requestCount);
  });
  await check('40 streaming patches leave completed history nodes untouched', async () => {
    const start = performance.now();
    for (let i = 0; i < 40; i++) {
      messages[119] = {...messages[119], status: 'streaming', content: `当前回答：${'新增文字。'.repeat(i + 1)}`};
      await update([messages[119]]);
    }
    patchMS = performance.now() - start;
    assert(await page.evaluate(() => window.savedRows.slice(0, 119).every((row, i) =>
      row === document.querySelectorAll('article')[i] && row.querySelector('.message-body').firstChild === window.savedBodies[i])));
    assert.equal(await page.locator('[data-message-id="message-119"] .message-actions').isVisible(), false);
  });
  await check('Reasoning expansion survives reply patches; native copy/share/regenerate bridge receives correct identity', async () => {
    const row = page.locator('[data-message-id="message-119"]');
    await row.locator('summary').click();
    messages[119] = {...messages[119], status: 'complete', content: '完成 **回答**'};
    await update([messages[119]]);
    assert.equal(await row.locator('details').evaluate(e => e.open), true);
    for (const action of ['copy', 'share', 'branch', 'regenerate']) {
      await row.locator(`[data-action="${action}"]`).click();
      const last = await page.evaluate(() => window.testMessages.filter(x => x.type === 'action').at(-1));
      assert.deepEqual(last, {type: 'action', action, id: 'message-119'});
    }
  });
  await check('Diagram module loads once, only changed message renders; stale chart cannot overwrite newer text', async () => {
    messages[119] = {...messages[119], content: '```mermaid\nflowchart LR\nA[提问]-->B[回答]\n```'};
    await update([messages[119]]);
    assert.equal(await page.locator('[data-message-id="message-119"] .diagram svg').count(), 1);
    assert.equal(requests.filter(x => /\/mermaid\.js$/.test(x.url)).length, 1);
    await page.evaluate(async payload => {
      const old = window.updateTranscript({...payload, patches: [{...payload.patches[0], content: '```mermaid\nflowchart LR\nA-->C\n```'}]});
      const next = window.updateTranscript({...payload, patches: [{...payload.patches[0], content: '**最后结果**'}]});
      await Promise.all([old, next]);
    }, {...state, patches: [messages[119]]});
    assert.equal(await page.locator('[data-message-id="message-119"] .message-body strong').textContent(), '最后结果');
  });
  await check('Theme and text-size changes preserve row identity and reasoning state', async () => {
    messages[119] = {...messages[119], content: '## 最后回答\n\n| 模型 | 结果 |\n| --- | --- |\n| Gemini | 正常 |\n\n$\\frac{1}{2}$'};
    await update([messages[119]], {dark: true, fontSize: 20});
    assert.equal(await page.locator('[data-message-id="message-119"] details').evaluate(e => e.open), true);
    assert(await page.evaluate(() => window.savedRows.every((row, i) => row === document.querySelectorAll('article')[i])));
    assert.equal(await page.locator('html').getAttribute('data-theme'), 'dark');
  });
  await check('User text and model metadata stay inert; attachments and errors survive updates', async () => {
    const message = {...messages[0], content: '<script>window.pwned=1</script>', modelTitle: '<img src=x onerror=alert(1)>',
      attachments: [{id:'file-1',kind:'pdf',name:'试卷.pdf',size:'1.4 MB',image:'javascript:alert(1)'}]};
    await update([message]);
    assert.equal(await page.locator('[data-message-id="message-0"] .message-body').textContent(), message.content);
    assert.equal(await page.locator('[data-message-id="message-0"] .attachment-name').textContent(), '试卷.pdf');
    assert.equal(await page.locator('#content script, #content [onerror]').count(), 0);
    assert.equal(await page.evaluate(() => window.pwned), undefined);
    await update([{...messages[119], error:'HTTP 429：配额不足',status:'failed'}]);
    assert.equal(await page.locator('[data-message-id="message-119"] .message-error').textContent(), 'HTTP 429：配额不足');
  });
  await check('Changing conversations removes old rows without another document or script load', async () => {
    const count = requests.filter(x => x.type === 'document').length;
    await update([{...messages[1], id:'new-message'}], {conversationID:'conversation-2',order:['new-message']});
    assert.equal(await page.locator('article').count(), 1);
    assert.equal(await page.locator('[data-message-id="message-119"]').count(), 0);
    assert.equal(requests.filter(x => x.type === 'document').length, count);
    assert.equal(requests.filter(x => /^https?:/.test(x.url)).length, 0);
    assert.deepEqual(errors, []);
  });
  const shortMessages = [
    {...messages[0], id:'new-user', content:'你好'},
    {...messages[1], id:'new-reply', content:'你好！有什么可以帮你？', reasoning:''}
  ];
  const shortOptions = {conversationID:'short-chat', order:shortMessages.map(x => x.id), topInset:120, bottomInset:182, revision:101};
  await check('Short new chat stays below the header and above the composer despite viewport-height document minimum', async () => {
    const metrics = await update(shortMessages, shortOptions);
    assert.equal(metrics.revision, 101);
    assert.equal(metrics.conversationID, 'short-chat');
    await page.evaluate(height => window.scrollTo(0, Math.max(0, height - innerHeight)), metrics.value);
    const positions = await page.evaluate(() => ({first:document.querySelector('article').getBoundingClientRect().top,
      last:document.querySelector('article:last-child').getBoundingClientRect().bottom,
      content:document.querySelector('#content').getBoundingClientRect().height, viewport:innerHeight, offset:scrollY}));
    assert.equal(positions.offset, 0);
    assert(positions.first >= 120);
    assert(positions.last <= positions.viewport - 182);
    assert.equal(metrics.value, Math.ceil(positions.content));
  });
  await check('Awaited append provides the final document height; newest reply clears the overlay in an existing chat', async () => {
    const options = {...shortOptions, conversationID:'append-chat', order:messages.map(x => x.id), revision:102};
    const before = await update(messages, options);
    await page.evaluate(height => window.scrollTo(0, height - innerHeight), before.value);
    const after = await update(shortMessages, {...options, order:[...options.order, ...shortOptions.order], revision:103});
    assert(after.value > before.value);
    await page.evaluate(height => window.scrollTo(0, height - innerHeight), after.value);
    const last = await page.locator('article:last-child').boundingBox();
    assert(last.y >= 120);
    assert(Math.abs(last.y + last.height - (800 - 182 - 24)) <= 1);
  });
  await check('Composer and viewport changes update overlay reservations without replacing message nodes', async () => {
    await page.evaluate(() => { window.lastReply = document.querySelector('article:last-child'); });
    await page.setViewportSize({width:393, height:570});
    const options = {...shortOptions, conversationID:'append-chat', order:[...messages.map(x => x.id), ...shortOptions.order],
      topInset:96, bottomInset:210, revision:104};
    const metrics = await update([], options);
    await page.evaluate(height => window.scrollTo(0, height - innerHeight), metrics.value);
    const last = await page.locator('article:last-child').boundingBox();
    assert.equal(await page.evaluate(() => window.lastReply === document.querySelector('article:last-child')), true);
    assert(Math.abs(last.y + last.height - (570 - 210 - 24)) <= 1);
    await page.setViewportSize({width:393, height:800});
  });
  await check('Same-height conversation changes still return a revision-tagged render acknowledgement', async () => {
    const first = await update(shortMessages, {...shortOptions, revision:105});
    const second = await update(shortMessages, {...shortOptions, conversationID:'same-height-chat', revision:106});
    assert.equal(first.value, second.value);
    assert.equal(second.revision, 106);
    assert.equal(second.conversationID, 'same-height-chat');
    assert.deepEqual(errors, []);
  });
  const photoID = '4C962C1F-9E66-4F54-937F-FB47C3B7464B';
  const imageMessage = {...shortMessages[0], id:'photo-user', attachments:[
    {id:photoID, kind:'image', name:'拍摄照片.jpg', size:'240 KB',
      image:'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7HkAAAAASUVORK5CYII='},
    {id:'pdf-file', kind:'pdf', name:'试卷.pdf', size:'1 MB', image:''}]};
  const imageOptions = {...shortOptions, conversationID:'image-chat',order:['photo-user'],revision:107};
  await check('Sent photo is an accessible preview button and a real tap bridges the exact attachment identity', async () => {
    await update([imageMessage], imageOptions);
    const button = page.getByRole('button', {name:'预览图片：拍摄照片.jpg'});
    assert.equal(await button.count(), 1);
    assert.equal(await page.locator('button.attachment-card').count(), 1);
    await button.click();
    const last = await page.evaluate(() => window.testMessages.filter(x => x.type === 'attachment').at(-1));
    assert.deepEqual(last, {type:'attachment',id:'photo-user',attachmentID:photoID});
  });
  await check('Synthetic clicks and attachment identity tampering cannot request arbitrary local files', async () => {
    const before = await page.evaluate(() => window.testMessages.filter(x => x.type === 'attachment').length);
    await page.locator('button.attachment-card').evaluate(button => button.click());
    await page.locator('button.attachment-card').evaluate(button => { button.dataset.attachmentId = '../not-an-attachment'; });
    await page.locator('button.attachment-card').click();
    const after = await page.evaluate(() => window.testMessages.filter(x => x.type === 'attachment').length);
    assert.equal(after, before);
    assert.deepEqual(errors, []);
  });
  const sourceMessage = {...shortMessages[1], id:'source-reply', sourceCount:5, generationStage:'已检索 5 条资料，正在生成回复…'};
  const sourceOptions = {...shortOptions, conversationID:'source-chat', order:['source-reply'], revision:108};
  await check('Source badge bridges its own reply identity and reserves a native glass button anchor', async () => {
    const metrics = await update([sourceMessage], sourceOptions);
    await page.getByRole('button', {name:'5 个网页 ›'}).click();
    assert.deepEqual(await page.evaluate(() => window.testMessages.filter(x => x.action === 'sources').at(-1)),
      {type:'action',action:'sources',id:'source-reply'});
    assert.equal(metrics.sourceAnchors.length, 1);
    assert.equal(metrics.sourceAnchors[0].id, 'source-reply');
    assert.equal(metrics.sourceAnchors[0].height, 44);
    const native = await update([sourceMessage], {...sourceOptions, revision:109,nativeSourceButtons:true});
    assert.equal(native.sourceAnchors.length, 1);
    assert.equal(await page.locator('.source-preview').evaluate(node => getComputedStyle(node).visibility), 'hidden');
    assert.equal(await page.locator('.source-anchor').evaluate(node => node.getBoundingClientRect().height), 44);
  });
  await check('Native source anchors keep document coordinates during scroll and clear on conversation changes', async () => {
    const order = [...messages.map(x => x.id), sourceMessage.id];
    const before = await update([...messages, sourceMessage], {...sourceOptions,order,revision:110,nativeSourceButtons:true});
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    const after = await update([], {...sourceOptions,order,revision:111,nativeSourceButtons:true});
    assert(Math.abs(before.sourceAnchors[0].y - after.sourceAnchors[0].y) < 1);
    const cleared = await update(shortMessages, {...shortOptions,revision:112});
    assert.deepEqual(cleared.sourceAnchors, []);
    assert.deepEqual(errors, []);
  });
  await check('Native source badge origin aligns with the copy action left edge across viewport widths', async () => {
    for (const width of [320, 393, 430, 900]) {
      await page.setViewportSize({width, height:800});
      const metrics = await update([sourceMessage], {...sourceOptions,revision:120 + width,nativeSourceButtons:true});
      const left = await page.locator('[data-action="copy"]').evaluate(node => node.getBoundingClientRect().left + scrollX);
      assert(Math.abs(metrics.sourceAnchors[0].x - left) <= 0.5);
    }
    await page.setViewportSize({width:393, height:800});
  });
  await check('Native reply export menus keep a stable action anchor and disappear during generation', async () => {
    const native = await update([sourceMessage], {...sourceOptions,revision:150,nativeShareButtons:true});
    assert.equal(native.shareAnchors.length, 1);
    assert.equal(native.shareAnchors[0].id, sourceMessage.id);
    assert.equal(native.shareAnchors[0].width, 40);
    const geometry = await page.evaluate(() => {
      const button = action => document.querySelector(`button[data-action="${action}"]`);
      const size = node => {const r=node.getBoundingClientRect(); return [r.width,r.height];};
      return {copy:size(button('copy')),share:size(button('share')),
        copyIcon:size(button('copy').querySelector('svg')),shareIcon:size(button('share').querySelector('svg')),
        visible:getComputedStyle(button('share')).visibility,
        nativeOwnsEvents:getComputedStyle(button('share')).pointerEvents === 'none' && button('share').tabIndex === -1};
    });
    assert.deepEqual(geometry.copy,geometry.share);
    assert.deepEqual(geometry.copyIcon,geometry.shareIcon);
    assert.equal(geometry.visible,'visible');
    assert.equal(geometry.nativeOwnsEvents,true);
    await page.evaluate(() => scrollTo(0, document.body.scrollHeight));
    const scrolled = await update([], {...sourceOptions,revision:151,nativeShareButtons:true});
    assert(Math.abs(native.shareAnchors[0].y - scrolled.shareAnchors[0].y) < 1);
    const streaming = await update([{...sourceMessage,status:'streaming'}], {...sourceOptions,revision:152,nativeShareButtons:true});
    assert.deepEqual(streaming.shareAnchors, []);
  });
  await check('TXT extraction returns only the requested rendered answer without Markdown markers or reasoning', async () => {
    const reply = {...sourceMessage,content:'## 导出标题\n\n这是 **加粗内容** 和 `代码`。公式 $E=mc^2$。\n\n```python\nprint("saved")\n```',reasoning:'不要导出此思考过程'};
    await update([reply], {...sourceOptions,revision:153});
    const text = await page.evaluate(id => window.replyPlainText(id), reply.id);
    assert(text.includes('导出标题') && text.includes('加粗内容') && text.includes('代码'));
    assert(!text.includes('##') && !text.includes('**') && !text.includes('不要导出此思考过程'));
    assert.equal(text.split('E=mc^2').length-1,1);
    assert(text.includes('print("saved")') && !text.includes('复制代码'));
    assert.equal(await page.evaluate(() => window.replyPlainText('missing')), '');
  });
  await check('Conversation export finishes when an offscreen renderer receives no animation frames', async () => {
    const result = await page.evaluate(async payload => {
      const original = window.requestAnimationFrame;
      window.requestAnimationFrame = () => 0;
      try {
        return await Promise.race([
          window.prepareConversationExport(payload).then(metrics => ({finished:true, height:metrics.value})),
          new Promise(resolve => setTimeout(() => resolve({finished:false}), 1500))
        ]);
      } finally { window.requestAnimationFrame = original; }
    }, {...state,patches:[shortMessages[0],sourceMessage],order:[shortMessages[0].id,sourceMessage.id],
      conversationID:'offscreen-export',revision:154,dark:false});
    assert.equal(result.finished,true,'Export stayed in preparation when animation frames were suspended');
    assert(result.height > 0);
  });
  await check('Conversation image preparation keeps all turns, removes overlay padding and action controls, and supports both themes', async () => {
    const history = await page.evaluate(payload => window.prepareConversationExport(payload),
      {...state,patches:messages,order:messages.map(x=>x.id),conversationID:'whole-history-export',revision:154,dark:false});
    assert.equal(await page.locator('article').count(),120);
    assert(history.value > 800);
    for (const dark of [false,true]) {
      const patches = [shortMessages[0], {...sourceMessage,content:'## 导出回答\n\n公式 $E=mc^2$，以及 **完整对话**。\n\n| 名称 | 结果 |\n| --- | --- |\n| 测试 | 通过 |'}];
      await page.evaluate(payload => window.prepareConversationExport(payload),
        {...state,patches,order:patches.map(x=>x.id),conversationID:'export-preview',revision:155,dark,topInset:100,bottomInset:300,nativeShareButtons:true});
      assert.equal(await page.locator('article').count(),2);
      assert.equal(await page.locator('.message-actions').first().evaluate(node => getComputedStyle(node).display),'none');
      assert.equal(await page.locator('#content').evaluate(node => getComputedStyle(node).paddingTop),'24px');
      assert.equal(await page.locator('body').evaluate(node => getComputedStyle(node).backgroundColor),dark?'rgb(0, 0, 0)':'rgb(255, 255, 255)');
      await page.screenshot({path:path.join(output,dark?'conversation-export-dark.png':'conversation-export-light.png'),fullPage:true});
    }
    assert.deepEqual(errors,[]);
  });
  await check('Generated images render as large previews and tap the exact saved output asset', async () => {
    const outputMessage = {...imageMessage, id:'generated-assistant', role:'assistant', content:'已生成图像。',
      imageGeneration:true,attachments:[imageMessage.attachments[0]],status:'complete'};
    await update([outputMessage], {...shortOptions,conversationID:'generated-preview',order:[outputMessage.id],revision:170});
    const image = page.locator('.image-generation-message .attachment-image');
    assert.equal(await image.count(),1);
    assert((await image.boundingBox()).width > 250);
    await page.locator('.image-generation-message button.attachment-card').click();
    const event = await page.evaluate(() => window.testMessages.filter(x=>x.type==='attachment').at(-1));
    assert.deepEqual(event,{type:'attachment',id:outputMessage.id,attachmentID:photoID});
    await page.screenshot({path:path.join(output,'image-generation-preview.png'),fullPage:true});
  });
  await check('Whole-conversation image export retains generated outputs and image-only responses', async () => {
    const outputMessage = {...imageMessage,id:'image-only-output',role:'assistant',content:'',imageGeneration:true,
      attachments:[imageMessage.attachments[0]],status:'complete'};
    const payload = {...state,conversationID:'generated-export',order:[shortMessages[0].id,outputMessage.id],
      patches:[shortMessages[0],outputMessage],revision:171,dark:false};
    const result = await page.evaluate(payload=>window.prepareConversationExport(payload),payload);
    assert(result.value > 0);
    assert.equal(await page.locator('article').count(),2);
    assert.equal(await page.locator('.image-generation-message .attachment-image').count(),1);
    assert.equal(await page.locator('.image-generation-message .message-body').isVisible(),false);
    assert.deepEqual(errors,[]);
  });
  await check('Branch is between Share and Regenerate at equal size; historical answers retain independent branch actions', async () => {
    const older = {...messages[1],id:'branch-older',content:'older answer',status:'complete',canRegenerate:false};
    const newer = {...messages[3],id:'branch-newer',content:'newer answer',status:'complete',canRegenerate:true};
    await update([older,newer],{conversationID:'branch-actions',order:[older.id,newer.id],revision:180});
    const row = page.locator('[data-message-id="branch-newer"]');
    const geometry = [];
    for (const action of ['share','branch','regenerate']) geometry.push(await row.locator(`[data-action="${action}"]`).boundingBox());
    assert(geometry[0].x < geometry[1].x && geometry[1].x < geometry[2].x);
    assert(geometry.every(box=>box.width===geometry[0].width && box.height===geometry[0].height));
    assert.equal(await page.locator('[data-message-id="branch-older"] [data-action="regenerate"]').isVisible(),false);
    await page.locator('[data-message-id="branch-older"] [data-action="branch"]').click();
    assert.deepEqual(await page.evaluate(()=>window.testMessages.filter(x=>x.type==='action').at(-1)),
      {type:'action',action:'branch',id:older.id});
  });
  await check('Opening and closing reasoning sends user card feedback; programmatic layout changes stay silent', async () => {
    const message={...messages[1],id:'haptic-card',content:'answer',reasoning:'reasoning',status:'complete'};
    await update([message],{conversationID:'haptic-card',order:[message.id],showReasoning:true,revision:181});
    const count=await page.evaluate(()=>window.testMessages.filter(x=>x.type==='haptic').length);
    const summary=page.locator('[data-message-id="haptic-card"] summary');
    await summary.click(); await summary.click();
    const events=await page.evaluate(()=>window.testMessages.filter(x=>x.type==='haptic'));
    assert.equal(events.length,count+2);
    assert.deepEqual(events.at(-1),{type:'haptic',category:'card',id:message.id});
    await page.locator('[data-message-id="haptic-card"] details').evaluate(node=>{node.open=true;});
    assert.equal(await page.evaluate(()=>window.testMessages.filter(x=>x.type==='haptic').length),count+2);
  });
  await check('Image-only replies can branch and streaming placeholders cannot', async () => {
    const output={...imageMessage,id:'branch-image',role:'assistant',content:'',reasoning:'',imageGeneration:true,
      attachments:[imageMessage.attachments[0]],status:'complete'};
    await update([output],{conversationID:'branch-image',order:[output.id],revision:182});
    assert.equal(await page.locator('[data-message-id="branch-image"] [data-action="branch"]').isVisible(),true);
    await update([{...output,status:'streaming'}],{conversationID:'branch-image',order:[output.id],revision:183});
    assert.equal(await page.locator('[data-message-id="branch-image"] [data-action="branch"]').isVisible(),false);
  });
  const report = {engine:'Desktop Edge Chromium (not iOS)', cases, passed:cases.length, failures:0,
    history_rows:120, stream_patches:40, initial_render_ms:Math.round(initialMS), stream_patch_total_ms:Math.round(patchMS),
    document_loads:requests.filter(x => x.type === 'document').length,
    mermaid_script_loads:requests.filter(x => /\/mermaid\.js$/.test(x.url)).length,
    scroll_dom_mutations:0, scroll_reloaded_resources:0, errors};
  await fs.writeFile(path.join(output,'transcript-results.json'),JSON.stringify(report,null,2));
  console.log(`Passed ${cases.length} transcript regression cases; scrolling caused 0 DOM replacements and 0 resource reloads.`);
} finally { await browser.close(); }
