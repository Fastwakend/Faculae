import {createRichRenderer} from './rich-renderer.js';

const bridge = message => window.webkit?.messageHandlers?.renderer?.postMessage(message);
const icons = {
  copy: '<svg viewBox="0 0 24 24"><path d="M8 8h11v13H8zM16 8V3H3v13h5"/></svg>',
  share: '<svg viewBox="0 0 24 24"><path d="M8 9H5v12h14V9h-3M12 15V2m-4 4 4-4 4 4"/></svg>',
  branch: '<svg viewBox="0 0 24 24"><path d="M7 21V3M7 14c0-5 10-3 10-9M14 5h3V2"/></svg>',
  regenerate: '<svg viewBox="0 0 24 24"><path d="M20 9a8 8 0 1 0 0 7M20 3v6h-6"/></svg>',
  file: '<svg viewBox="0 0 24 24"><path d="M5 2h9l5 5v15H5zM14 2v6h5M8 12h8M8 16h8"/></svg>'
};
function node(tag, className = '', text) {
  const result = document.createElement(tag);
  result.className = className;
  if (text !== undefined) result.textContent = text;
  return result;
}
function safeImage(url) {
  return /^(?:seek-local:\/\/(?:model|icon|attachment)\/[^?#]+|data:image\/(?:png|jpeg|gif|webp);base64,[a-z0-9+/=]+)$/i.test(url || '') ? url : '';
}

export function createTranscript(root, onLayout) {
  let conversation, appearance;
  const rows = new Map();
  root.addEventListener('click', event => {
    const attachment = event.target.closest('button[data-attachment-id]');
    if (event.isTrusted && attachment && root.contains(attachment)) {
      const id = attachment.closest('[data-message-id]')?.dataset.messageId;
      const attachmentID = attachment.dataset.attachmentId;
      if (rows.get(id)?.snapshot?.attachments?.some(item => item.id === attachmentID && item.kind === 'image')) {
        bridge({type:'attachment', id, attachmentID});
      }
      return;
    }
    const button = event.target.closest('button[data-action]');
    if (!event.isTrusted || !button || !root.contains(button)) return;
    const id = button.closest('[data-message-id]')?.dataset.messageId;
    if (!id || !rows.has(id)) return;
    if (button.dataset.action === 'sources' && !rows.get(id)?.snapshot?.sourceCount) return;
    bridge({type: 'action', action: button.dataset.action, id});
    if (button.dataset.action === 'copy') {
      button.setAttribute('aria-label', '已复制');
      setTimeout(() => { if (button.isConnected) button.setAttribute('aria-label', '复制回答'); }, 1500);
    }
  });

  function makeRow(message) {
    const article = node('article', `chat-message ${message.role === 'user' ? 'user-message' : 'assistant-message'}`);
    article.dataset.messageId = message.id;
    const header = node('header', 'message-header');
    const logo = node('img', 'message-logo');
    logo.width = 24; logo.height = 24; logo.alt = '';
    const title = node('span', 'model-title');
    const spinner = node('span', 'stream-spinner');
    spinner.setAttribute('role', 'status'); spinner.setAttribute('aria-label', '正在生成');
    header.append(logo, title, spinner);
    const attachments = node('div', 'message-attachments');
    const details = node('details', 'message-reasoning');
    const summary = node('summary', '', '思考过程');
    const reasoning = node('div', 'reasoning-body');
    details.append(summary, reasoning);
    const body = node('div', 'message-body');
    const status = node('div', 'message-status');
    const sourceAnchor = node('div', 'source-anchor');
    const sourceButton = node('button', 'source-preview');
    sourceButton.type = 'button'; sourceButton.dataset.action = 'sources';
    sourceAnchor.append(sourceButton);
    const error = node('div', 'message-error');
    const actions = node('div', 'message-actions');
    for (const [action, label] of [['copy','复制回答'], ['share','分享回答'], ['branch','分支到新对话'], ['regenerate','重新生成']]) {
      const button = node('button', 'message-action');
      button.type = 'button'; button.dataset.action = action;
      button.setAttribute('aria-label', label); button.innerHTML = icons[action];
      actions.append(button);
    }
    article.append(header, attachments, details, body, sourceAnchor, status, error, actions);
    const row = {article, header, logo, title, spinner, attachments, details, summary, reasoning, body, sourceAnchor, sourceButton, status, error, actions,
      rich: createRichRenderer(body, onLayout), thought: createRichRenderer(reasoning, onLayout)};
    summary.addEventListener('click', event => {
      if (event.isTrusted && row.snapshot?.reasoning) bridge({type:'haptic',category:'card',id:article.dataset.messageId});
    });
    details.addEventListener('toggle', () => {
      if (details.open && row.reasoningDirty) {
        row.reasoningDirty = false;
        row.thought.render({text: row.snapshot.reasoning, dark: row.dark}).then(onLayout);
      }
      onLayout();
    });
    return row;
  }

  async function patch(row, message, options, restyle) {
    const prior = row.snapshot;
    const tasks = [];
    const user = message.role === 'user';
    row.article.classList.toggle('image-generation-message', !user && !!message.imageGeneration);
    row.header.hidden = user;
    if (row.title.textContent !== message.modelTitle) row.title.textContent = message.modelTitle || '助手';
    const logoURL = safeImage(message.logo);
    if (row.logo.getAttribute('src') !== logoURL) {
      if (logoURL) row.logo.src = logoURL;
      else row.logo.removeAttribute('src');
    }
    row.logo.hidden = !logoURL;
    row.spinner.hidden = message.status !== 'streaming';
    const attachmentKey = JSON.stringify(message.attachments || []);
    if (attachmentKey !== row.attachmentKey) {
      row.attachments.replaceChildren();
      for (const item of message.attachments || []) {
        const previewable = item.kind === 'image';
        const card = node(previewable ? 'button' : 'div', 'attachment-card');
        if (previewable) {
          card.type = 'button'; card.dataset.attachmentId = item.id;
          card.setAttribute('aria-label', `预览图片：${item.name}`);
        }
        const imageURL = safeImage(item.image);
        if (imageURL) {
          const image = node('img', 'attachment-image');
          image.src = imageURL; image.alt = ''; image.width = 42; image.height = 42;
          card.append(image);
        } else {
          const glyph = node('span', 'attachment-glyph'); glyph.innerHTML = icons.file; card.append(glyph);
        }
        const label = node('div', 'attachment-label');
        label.append(node('span', 'attachment-name', item.name), node('span', 'attachment-size', item.size));
        card.append(label); row.attachments.append(card);
      }
      row.attachmentKey = attachmentKey;
    }
    row.attachments.hidden = !(message.attachments || []).length;
    row.body.hidden = !message.content;
    if (!prior || prior.content !== message.content || restyle) {
      if (user) row.body.textContent = message.content;
      else tasks.push(row.rich.render({text: message.content, dark: options.dark}));
    }
    row.details.hidden = user || !options.showReasoning || !message.reasoning;
    const summary = message.status === 'streaming' && !message.content ? '思考中…' : '思考过程';
    if (row.summary.textContent !== summary) row.summary.textContent = summary;
    row.dark = options.dark;
    if (!prior || prior.reasoning !== message.reasoning || restyle) row.reasoningDirty = true;
    if (row.details.open && row.reasoningDirty) {
      row.reasoningDirty = false;
      tasks.push(row.thought.render({text: message.reasoning, dark: options.dark}));
    }
    row.sourceAnchor.hidden = !message.sourceCount || user;
    row.sourceAnchor.dataset.sourceMessage = message.id;
    row.sourceButton.textContent = `${message.sourceCount || 0} 个网页 ›`;
    row.sourceButton.style.visibility = options.nativeSourceButtons ? 'hidden' : '';
    const stopped = message.status === 'streaming' ? (message.generationStage || '') : (message.status === 'stopped' ? '已停止生成' : '');
    if (row.status.textContent !== stopped) row.status.textContent = stopped;
    row.status.hidden = !stopped;
    if (row.error.textContent !== message.error) row.error.textContent = message.error || '';
    row.error.hidden = !message.error;
    row.actions.hidden = user || message.status === 'streaming';
    for (const button of row.actions.children) {
      const hasPayload = !!(message.content || message.reasoning || message.attachments?.length);
      button.hidden = button.dataset.action === 'regenerate' ? !message.canRegenerate :
        (button.dataset.action === 'copy' ? !message.content : !hasPayload);
      if (button.dataset.action === 'share') {
        // Keep the same SVG, padding and 40pt action frame as Copy. A clear
        // native button above it owns the system menu and accessibility.
        button.style.pointerEvents = options.nativeShareButtons ? 'none' : '';
        button.tabIndex = options.nativeShareButtons ? -1 : 0;
        if (options.nativeShareButtons) button.setAttribute('aria-hidden','true');
        else button.removeAttribute('aria-hidden');
      }
    }
    row.snapshot = message;
    await Promise.all(tasks);
  }

  return {async update(options) {
    root.classList.add('transcript');
    if (conversation !== options.conversationID) {
      for (const row of rows.values()) { row.rich.dispose(); row.thought.dispose(); }
      rows.clear(); root.replaceChildren(); conversation = options.conversationID;
    }
    const nextAppearance = JSON.stringify([options.dark, options.fontSize, options.showReasoning]);
    const restyle = appearance !== nextAppearance;
    const keep = new Set(options.order);
    for (const [id, row] of rows) {
      if (!keep.has(id)) { row.rich.dispose(); row.thought.dispose(); row.article.remove(); rows.delete(id); }
    }
    const patches = new Map(options.patches.map(message => [message.id, message]));
    const tasks = [];
    for (const id of options.order) {
      const message = patches.get(id) || rows.get(id)?.snapshot;
      if (!message) continue;
      let row = rows.get(id);
      if (!row) { row = makeRow(message); rows.set(id, row); }
      if (patches.has(id) || restyle) tasks.push(patch(row, message, options, restyle));
    }
    let cursor = root.firstChild;
    for (const id of options.order) {
      const row = rows.get(id);
      if (!row) continue;
      if (row.article !== cursor) root.insertBefore(row.article, cursor);
      cursor = row.article.nextSibling;
    }
    appearance = nextAppearance;
    onLayout();
    await Promise.all(tasks);
    onLayout();
  }};
}
