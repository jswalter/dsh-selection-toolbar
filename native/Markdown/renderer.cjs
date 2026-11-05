(function (root) {
  'use strict';
  const factory = typeof module === 'object' && module.exports ? require('./markdown-it.min.cjs') : root.markdownit;
  const parser = factory({ html: false, breaks: true, linkify: true, typographer: false });
  // Model output is display content. Do not load remote images or execute HTML.
  parser.renderer.rules.image = (tokens, index) => {
    const token = tokens[index];
    const alt = parser.renderer.renderInlineAsText(token.children || [], parser.options, {});
    return `<span class="image-alt">[图片：${parser.utils.escapeHtml(alt || '图片')}]</span>`;
  };
  function renderMarkdown(text) { return parser.render(text); }
  if (typeof module === 'object' && module.exports) { module.exports = { renderMarkdown }; return; }

  const content = document.getElementById('content');
  let lastHeight = -1;
  function reportHeight() {
    const height = Math.ceil(content.getBoundingClientRect().height);
    if (height !== lastHeight) {
      lastHeight = height;
      window.webkit?.messageHandlers?.markdownHeight?.postMessage(height);
    }
  }
  root.renderTurns = (turns, scrollToEnd) => {
    const oldY = window.scrollY;
    const atBottom = oldY + innerHeight >= document.documentElement.scrollHeight - 32;
    const newTurn = content.children.length > 0 && turns.length > content.children.length;
    const fragment = document.createDocumentFragment();
    for (const turn of turns) {
      const section = document.createElement('section');
      section.className = turn.role === 'user' ? 'question' : 'answer';
      if (turn.role === 'user') section.textContent = `你：${turn.text}`;
      else section.innerHTML = renderMarkdown(turn.text);
      fragment.appendChild(section);
    }
    content.replaceChildren(fragment);
    reportHeight();
    requestAnimationFrame(() => {
      window.scrollTo(0, newTurn || (scrollToEnd && atBottom) ? document.documentElement.scrollHeight : oldY);
    });
  };
  root.setTheme = dark => { document.documentElement.dataset.theme = dark ? 'dark' : 'light'; };
  new ResizeObserver(reportHeight).observe(content);
  reportHeight();
})(globalThis);
