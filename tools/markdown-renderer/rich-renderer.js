import { Marked } from 'marked';
import katex from 'katex';
import DOMPurify from 'dompurify';
import hljs from 'highlight.js/lib/common';

const escape = text => String(text).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const bridge = message => window.webkit?.messageHandlers?.renderer?.postMessage(message);

function math(source, displayMode) {
  try {
    return katex.renderToString(source, {displayMode, throwOnError: false, trust: false,
      strict: 'ignore', maxExpand: 1000, maxSize: 20, output: 'htmlAndMathml'});
  } catch {
    return `<code class="math-error">${escape(source)}</code>`;
  }
}

function safeURL(value, image = false) {
  if (image && /^data:image\/(?:png|jpeg|gif|webp);base64,/i.test(value)) return value;
  try {
    const url = new URL(value);
    if (url.protocol === 'https:' || (!image && ['http:', 'mailto:'].includes(url.protocol))) return url.href;
  } catch { /* Invalid and relative URLs stay plain text. */ }
  return '';
}

function parser(codes, diagrams) {
  let nextCode = 0;
  return new Marked({gfm: true, breaks: true, renderer: {
    html({text}) { return escape(text); },
    link({href, title, tokens}) {
      const label = this.parser.parseInline(tokens);
      const url = safeURL(href);
      return url ? `<a href="${escape(url)}"${title ? ` title="${escape(title)}"` : ''} rel="noreferrer noopener">${label}</a>` : label;
    },
    image({href, title, text}) {
      const url = safeURL(href, true);
      return url ? `<img src="${escape(url)}" alt="${escape(text)}"${title ? ` title="${escape(title)}"` : ''} referrerpolicy="no-referrer" loading="lazy">` : escape(text);
    },
    code({text, lang = ''}) {
      const language = lang.trim().split(/\s+/)[0].toLowerCase();
      const id = String(nextCode++);
      codes.set(id, text);
      if (language === 'mermaid') {
        diagrams.push({id, text});
        return `<div class="diagram" data-diagram="${id}" role="img" aria-label="图表"><pre>${escape(text)}</pre></div>`;
      }
      let highlighted = escape(text);
      if (hljs.getLanguage(language) && text.length < 100000) {
        try { highlighted = hljs.highlight(text, {language, ignoreIllegals: true}).value; } catch { /* Keep readable code. */ }
      }
      return `<section class="code-block"><div class="code-header"><span>${escape(language || '代码')}</span><button type="button" data-copy="${id}" aria-label="复制代码">复制</button></div><pre><code class="hljs">${highlighted}</code></pre></section>`;
    },
    table(token) {
      const original = this.constructor.prototype.table.call(this, token);
      return `<div class="table-scroll" role="region" aria-label="表格，可横向滚动" tabindex="0">${original}</div>`;
    }
  }, extensions: [{
    name: 'displayMath', level: 'block',
    start: src => src.search(/\$\$|\\\[/),
    tokenizer(src) {
      const match = /^(?:\$\$([\s\S]*?)\$\$|\\\[([\s\S]*?)\\\])(?:[ \t]*\n|[ \t]*$)/.exec(src);
      if (match) return {type: 'displayMath', raw: match[0], source: match[1] ?? match[2]};
    },
    renderer: token => `<div class="math-display">${math(token.source, true)}</div>`
  }, {
    name: 'inlineMath', level: 'inline',
    start: src => src.search(/\$(?!\$)|\\\(/),
    tokenizer(src) {
      const match = /^(?:\\\(([\s\S]*?)\\\)|\$(?!\$)([^\s$](?:[^$\n]*?[^\s$])?)\$(?![\d$]))/.exec(src);
      if (match) return {type: 'inlineMath', raw: match[0], source: match[1] ?? match[2]};
    },
    renderer: token => math(token.source, false)
  }]});
}

let mermaidLoader;
let diagramQueue = Promise.resolve();
function loadMermaid() {
  if (!mermaidLoader) mermaidLoader = new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = 'mermaid.js';
    script.onload = () => resolve(window.SeekMermaid);
    script.onerror = reject;
    document.head.append(script);
  });
  return mermaidLoader;
}
async function renderDiagram(id, text, dark) {
  const mermaid = await loadMermaid();
  const task = diagramQueue.then(async () => {
    mermaid.initialize({startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
      theme: dark ? 'dark' : 'default', htmlLabels: false, flowchart: {htmlLabels: false},
      maxTextSize: 50000, maxEdges: 500, fontFamily: '-apple-system, sans-serif'});
    return await mermaid.render(id, text);
  });
  diagramQueue = task.catch(() => {});
  return task;
}
let nextRenderer = 0;
export function createRichRenderer(content, reportHeight = () => {}) {
  let revision = 0;
  let copiedCode = new Map();
  const rendererID = ++nextRenderer;

const onCopy = event => {
  const button = event.target.closest('button[data-copy]');
  if (!event.isTrusted || !button || !content.contains(button)) return;
  const text = copiedCode.get(button.dataset.copy);
  if (text === undefined) return;
  bridge({type: 'copy', text});
  button.textContent = '已复制';
  setTimeout(() => { if (button.isConnected) button.textContent = '复制'; }, 1500);
};
content.addEventListener('click', onCopy);

async function render({text, dark = false}) {
  const current = ++revision;
  const codes = new Map(), diagrams = [];
  const html = parser(codes, diagrams).parse(String(text));
  content.innerHTML = DOMPurify.sanitize(html, {
    USE_PROFILES: {html: true, mathMl: true},
    ADD_TAGS: ['annotation', 'semantics'],
    FORBID_TAGS: ['style', 'iframe', 'object', 'embed', 'form'],
    FORBID_ATTR: ['srcset']
  });
  copiedCode = codes;
  reportHeight();
  for (const diagram of diagrams) {
    if (current !== revision) return;
    const target = content.querySelector(`[data-diagram="${diagram.id}"]`);
    if (!target) continue;
    try {
      const {svg} = await renderDiagram(`diagram-${rendererID}-${current}-${diagram.id}`, diagram.text, dark);
      if (current !== revision) return;
      target.innerHTML = DOMPurify.sanitize(svg, {
        USE_PROFILES: {svg: true, svgFilters: true},
        FORBID_TAGS: ['foreignObject', 'script', 'a', 'image'],
        FORBID_ATTR: ['href', 'xlink:href']
      });
    } catch {
      if (current !== revision) return;
      target.setAttribute('aria-label', '图表源代码（格式尚不完整）');
    }
    reportHeight();
  }
}
return {render, dispose() { ++revision; copiedCode.clear(); content.removeEventListener('click', onCopy); }};
}
export function setAppearance({dark = false, fontSize = 16}) {
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  document.documentElement.style.fontSize = `${Math.max(10, Math.min(64, fontSize))}px`;
}

