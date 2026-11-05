# Markdown parser

Vendored `markdown-it` 14.1.0 browser distribution, under the MIT license
in `LICENSE.markdown-it`. The distribution is unmodified, renamed to `.cjs`
so the same file can run in WebKit and the Node test runner.

Source: https://github.com/markdown-it/markdown-it/tree/14.1.0
Download: https://cdn.jsdelivr.net/npm/markdown-it@14.1.0/dist/markdown-it.min.js
SHA-256: `38c70a1e7ca91ab40e2d9e6e60129851a717ed1c7d4acbbdd41bf9503791cf68`

The renderer disables raw HTML and external image loading. Script, style,
and parser resources are bundled locally; rendering does not need a network
connection. The configuration follows the upstream security guidance:
https://github.com/markdown-it/markdown-it/blob/14.1.0/docs/security.md
