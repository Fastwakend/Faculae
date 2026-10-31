import {createRichRenderer, setAppearance} from './rich-renderer.js';
import {createTranscript} from './transcript.js';
const content = document.querySelector('#content');
let mode = 'standalone', frame, lastMeasurement = '', revision = 0, conversationID;
function metrics() {
  const sourceAnchors = [...content.querySelectorAll('.source-anchor:not([hidden])')].map(node => {
    const rect = node.getBoundingClientRect();
    return {id: node.dataset.sourceMessage, x: rect.left + window.scrollX, y: rect.top + window.scrollY,
      width: Math.min(210, rect.width), height: rect.height};
  });
  const shareAnchors = [...content.querySelectorAll('.assistant-message .message-actions:not([hidden]) button[data-action="share"]:not([hidden])')].map(node => {
    const rect = node.getBoundingClientRect();
    return {id: node.closest('[data-message-id]').dataset.messageId, x: rect.left + scrollX, y: rect.top + scrollY,
      width: rect.width, height: rect.height};
  });
  return {value: Math.ceil(content.getBoundingClientRect().height), revision, conversationID, sourceAnchors, shareAnchors};
}
function reportLayout() {
  cancelAnimationFrame(frame);
  frame = requestAnimationFrame(() => {
    const measurement = metrics(), signature = JSON.stringify(measurement);
    if (signature === lastMeasurement) return;
    lastMeasurement = signature;
    window.webkit?.messageHandlers?.renderer?.postMessage({type: mode === 'transcript' ? 'layout' : 'height', ...measurement});
  });
}
new ResizeObserver(reportLayout).observe(content);
document.fonts.ready.then(reportLayout);
document.addEventListener('load', reportLayout, true);
const standalone = createRichRenderer(content, reportLayout);
const transcript = createTranscript(content, reportLayout);
window.renderMarkdown = async payload => {
  mode = 'standalone'; setAppearance(payload);
  return standalone.render(payload);
};
window.updateTranscript = async payload => {
  mode = 'transcript'; setAppearance(payload);
  revision = payload.revision ?? 0; conversationID = payload.conversationID;
  // Reserve overlay space in the document, not UIScrollView.contentInset. WebKit
  // has a viewport-height minimum contentSize even when the conversation is short.
  const inset = value => Number.isFinite(value) ? Math.max(0, value) : 0;
  content.style.setProperty('--transcript-top', `${inset(payload.topInset)}px`);
  content.style.setProperty('--transcript-bottom', `${inset(payload.bottomInset)}px`);
  await transcript.update(payload);
  // A detached export WKWebView may never receive an animation frame. DOM
  // measurement forces layout without depending on a display refresh.
  if (!payload.exportMode) await new Promise(resolve => requestAnimationFrame(resolve));
  reportLayout();
  return metrics();
};
window.replyPlainText = id => {
  const answer = [...content.querySelectorAll('.assistant-message')]
    .find(node => node.dataset.messageId === id)?.querySelector('.message-body');
  if (!answer) return '';
  const copy = answer.cloneNode(true);
  // KaTeX contains both visual and accessibility trees. Export the original
  // formula once, and omit UI labels such as code-block copy buttons.
  copy.querySelectorAll('.katex').forEach(node => node.replaceWith(document.createTextNode(
    node.querySelector('annotation[encoding="application/x-tex"]')?.textContent || node.textContent)));
  copy.querySelectorAll('.code-header,button').forEach(node => node.remove());
  copy.querySelectorAll('img').forEach(node => node.replaceWith(document.createTextNode(node.alt || '')));
  copy.querySelectorAll('br').forEach(node => node.replaceWith(document.createTextNode('\n')));
  copy.querySelectorAll('td,th').forEach(node => node.append('\t'));
  copy.querySelectorAll('p,h1,h2,h3,h4,h5,h6,li,pre,blockquote,tr').forEach(node => node.append('\n'));
  return copy.textContent.replace(/\t+\n/g,'\n').replace(/\n{3,}/g,'\n\n').trim();
};
window.prepareConversationExport = async payload => {
  document.documentElement.classList.add('conversation-export');
  await window.updateTranscript({...payload, exportMode:true, topInset:0, bottomInset:0, nativeSourceButtons:false, nativeShareButtons:false});
  // Start lazy images and font layout explicitly in the offscreen document.
  const images = [...content.querySelectorAll('img')];
  for (const image of images) image.loading = 'eager';
  content.getBoundingClientRect();
  let deadline;
  try {
    await Promise.race([
      Promise.all([document.fonts.ready, ...images.map(image => image.decode().catch(() => {}))]),
      new Promise(resolve => { deadline = setTimeout(resolve, 8000); })
    ]);
  } finally { clearTimeout(deadline); }
  return metrics();
};
window.webkit?.messageHandlers?.renderer?.postMessage({type: 'ready'});
