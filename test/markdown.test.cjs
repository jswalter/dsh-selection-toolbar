'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { renderMarkdown } = require('../native/Markdown/renderer.cjs');

test('renders headings at their declared levels', () => {
  assert.equal(renderMarkdown('# Title\n\n### Detail'), '<h1>Title</h1>\n<h3>Detail</h3>\n');
});

test('renders bold, italic, and strikethrough', () => {
  assert.equal(renderMarkdown('**bold** *italic* ~~deleted~~'),
    '<p><strong>bold</strong> <em>italic</em> <s>deleted</s></p>\n');
});

test('renders nested unordered and ordered lists', () => {
  assert.equal(renderMarkdown('- outer\n  - nested\n\n1. first\n2. second'),
    '<ul>\n<li>outer\n<ul>\n<li>nested</li>\n</ul>\n</li>\n</ul>\n' +
    '<ol>\n<li>first</li>\n<li>second</li>\n</ol>\n');
});

test('renders blockquotes with inline formatting', () => {
  assert.equal(renderMarkdown('> quoted **text**'),
    '<blockquote>\n<p>quoted <strong>text</strong></p>\n</blockquote>\n');
});

test('renders explicit links and linkifies plain URLs', () => {
  assert.equal(renderMarkdown('[Example](https://example.com) https://example.org'),
    '<p><a href="https://example.com">Example</a> <a href="https://example.org">https://example.org</a></p>\n');
});

test('fenced code preserves multiple lines, escapes HTML, and carries its language', () => {
  const source = '```js\nconst x = "<&>";\nconsole.log(x);\n```';
  assert.equal(renderMarkdown(source),
    '<pre><code class="language-js">const x = &quot;&lt;&amp;&gt;&quot;;\nconsole.log(x);\n</code></pre>\n');
});

test('renders table headers and cells', () => {
  assert.equal(renderMarkdown('| Name | Value |\n| --- | --- |\n| alpha | **one** |'),
    '<table>\n<thead>\n<tr>\n<th>Name</th>\n<th>Value</th>\n</tr>\n</thead>\n' +
    '<tbody>\n<tr>\n<td>alpha</td>\n<td><strong>one</strong></td>\n</tr>\n</tbody>\n</table>\n');
});

test('preserves Unicode text and emoji', () => {
  assert.equal(renderMarkdown('汉字 繁體 café e\u0301 👩🏽‍💻 🚀'),
    '<p>汉字 繁體 café e\u0301 👩🏽‍💻 🚀</p>\n');
});

test('renders soft newlines as line breaks', () => {
  assert.equal(renderMarkdown('hello\nworld'), '<p>hello<br>\nworld</p>\n');
});

test('leaves typographic punctuation unchanged', () => {
  assert.equal(renderMarkdown('"quoted" -- ... (c)'), '<p>&quot;quoted&quot; -- ... (c)</p>\n');
});

test('incomplete streaming emphasis becomes formatted when the closing delimiter arrives', () => {
  assert.equal(renderMarkdown('**bold'), '<p>**bold</p>\n');
  assert.equal(renderMarkdown('**bold**'), '<p><strong>bold</strong></p>\n');
});

test('incomplete streaming fences recover when the full response arrives', () => {
  assert.equal(renderMarkdown('```js\nconst answer = 42;'),
    '<pre><code class="language-js">const answer = 42;</code></pre>\n');
  assert.equal(renderMarkdown('```js\nconst answer = 42;\n```\n\n**Done**'),
    '<pre><code class="language-js">const answer = 42;\n</code></pre>\n<p><strong>Done</strong></p>\n');
});

test('an unclosed code fence does not affect a subsequent render call', () => {
  renderMarkdown('```html\n<div>unfinished');
  assert.equal(renderMarkdown('# Next turn\n\n**Normal**'),
    '<h1>Next turn</h1>\n<p><strong>Normal</strong></p>\n');
});

test('raw script and HTML remain escaped text rather than elements', () => {
  const result = renderMarkdown('<script>alert("x")</script>\n<div onclick="evil()">text</div>');
  assert.doesNotMatch(result, /<(?:script|div)\b/i);
  assert.match(result, /&lt;script&gt;alert\(&quot;x&quot;\)&lt;\/script&gt;/);
  assert.match(result, /&lt;div onclick=&quot;evil\(\)&quot;&gt;text&lt;\/div&gt;/);
});

for (const destination of ['javascript:alert%281%29', 'file:///tmp/test', 'data:text/html,hello']) {
  test(`unsafe link destination stays non-clickable: ${destination}`, () => {
    const result = renderMarkdown(`[unsafe](${destination})\n${destination}`);
    assert.doesNotMatch(result, /<a\b/i);
    assert.match(result, /unsafe/);
  });
}

test('images render escaped alternative text without loading image resources', () => {
  const result = renderMarkdown('![<script>alert("x")</script> & sample](https://example.com/a.png)');
  assert.equal(result,
    '<p><span class="image-alt">[图片：&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; sample]</span></p>\n');
  assert.doesNotMatch(result, /<(?:img|script)\b|\bsrc\s*=|https:\/\/example\.com/i);
});

test('rendering preserves the exact original input string', () => {
  const source = '\uFEFF# 汉字\r\n\r\n**text**  \n```js\n<&>\n```\n\t尾部 \n';
  const originalBytes = Buffer.from(source, 'utf8');
  const originalCodeUnits = Array.from({ length: source.length }, (_, index) => source.charCodeAt(index));
  renderMarkdown(source);
  assert.deepEqual(Buffer.from(source, 'utf8'), originalBytes);
  assert.deepEqual(Array.from({ length: source.length }, (_, index) => source.charCodeAt(index)), originalCodeUnits);
});
