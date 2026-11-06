/* Browser entry loaded by DSH's public client module loader; no build tool needed. */
window.__ModuleLoader__.load({
  id: 'dsh-selection-toolbar',
  factory: require => {
    const React = require('react');
    const h = React.createElement;
    function apply(ctx) {
      const form = ctx.configForms.get('selection-toolbar');
      function Settings() {
        const snapshot = React.useSyncExternalStore(fn => form.subscribe(fn), () => form.getSnapshot());
        const [draft, setDraft] = React.useState(null);
        const [revision, setRevision] = React.useState(undefined);
        const [catalog, setCatalog] = React.useState(null);
        const [loading, setLoading] = React.useState(false);
        const [saving, setSaving] = React.useState(false);
        const [message, setMessage] = React.useState('');
        const [catalogError, setCatalogError] = React.useState('');
        const live = React.useRef(true);
        const refresh = async () => {
          setLoading(true); setCatalogError('');
          try {
            const response = await ctx.remote.session.modelCatalog();
            if (!response.ok) throw new Error('catalog unavailable');
            if (live.current) setCatalog(response.value);
          } catch { if (live.current) setCatalogError('模型目录读取失败，请刷新重试。'); }
          finally { if (live.current) setLoading(false); }
        };
        React.useEffect(() => { live.current = true; void refresh(); return () => { live.current = false; }; }, []);
        const value = draft ?? { paused: false, route: null, sourceLanguage: 'auto', targetLanguage: 'zh-Hans', ...snapshot.value?.preferences, enabled: snapshot.value?.enabled ?? true };
        const disabled = saving || !snapshot.writable || snapshot.status !== 'ready';
        function edit(key, next) {
          if (disabled) return;
          if (!draft) setRevision(snapshot.revision);
          setDraft({ ...value, [key]: next }); setMessage('');
        }
        async function save(event) {
          event.preventDefault(); if (disabled || !draft) return; setSaving(true); setMessage('');
          try {
            const { enabled, ...preferences } = draft;
            const ok = await form.mutate([{ op: 'set', path: ['enabled'], value: enabled }, { op: 'set', path: ['preferences'], value: preferences }], revision);
            if (!live.current) return;
            if (ok) { setDraft(null); setMessage('已保存。模型和翻译语言在下次划词时生效。'); }
            else setMessage('保存未成功，设置可能已在其他窗口更改。请重新载入后再试。');
          } catch { if (live.current) setMessage('保存失败，请检查 DSH 连接后重试。'); }
          finally { if (live.current) setSaving(false); }
        }
        const control = { padding: '8px 10px', border: '1px solid var(--dsw-alias-border-l2, #8886)', borderRadius: 8, background: 'var(--dsw-alias-bg-base, transparent)', color: 'inherit', font: 'inherit', maxWidth: '100%' };
        const button = (text, onClick, extra = {}) => h('button', { type: 'button', onClick, style: { ...control, cursor: 'pointer' }, ...extra }, text);
        const field = (label, child) => h('label', { style: { display: 'grid', gap: 8 } }, h('span', null, label), child);
        const routeKey = route => route ? JSON.stringify([route.provider, route.model]) : '';
        const models = (catalog?.groups ?? []).flatMap(group => group.models.map(model => ({ provider: group.id, model: model.id, name: `${group.name ?? group.id} · ${model.name ?? model.id}` })));
        const current = routeKey(value.route);
        const languages = [['zh-Hans', '简体中文'], ['zh-Hant', '繁體中文'], ['en', '英语'], ['ja', '日本語']];
        const languageSelect = (key, options) => h('select', { value: value[key], disabled, style: control, onChange: e => edit(key, e.target.value) }, options.map(([code, title]) => h('option', { key: code, value: code }, title)));
        return h('form', { onSubmit: save, style: { display: 'grid', gap: 20, padding: '24px 0', maxWidth: 620, color: 'var(--dsw-alias-label-primary, inherit)' } },
          h('h3', { style: { margin: 0, fontSize: 18 } }, '划词设置'),
          h('label', { style: { display: 'flex', alignItems: 'center', gap: 10 } }, h('input', { type: 'checkbox', checked: value.enabled && !value.paused, disabled, onChange: e => { if (disabled) return; if (!draft) setRevision(snapshot.revision); setDraft({ ...value, enabled: e.target.checked, paused: false }); setMessage(''); } }), '启用全局划词'),
          field('划词使用的模型', h('select', { style: control, disabled, value: current, onChange: e => { const route = e.target.value ? JSON.parse(e.target.value) : null; edit('route', route && { provider: route[0], model: route[1] }); } },
            h('option', { value: '' }, `跟随 DSH 默认模型${catalog?.default?.model ? `（${catalog.default.model}）` : ''}`),
            current && !models.some(model => routeKey(model) === current) ? h('option', { value: current }, `当前选择（目录暂不可用）：${value.route.model}`) : null,
            models.map(model => h('option', { key: routeKey(model), value: routeKey(model) }, model.name)))),
          h('div', { style: { display: 'flex', alignItems: 'center', gap: 12 } }, button(loading ? '读取中…' : '刷新模型列表', refresh, { disabled: loading }), h('span', { style: { opacity: 0.65, fontSize: 13 } }, `已读取 ${models.length} 个模型`)),
          catalogError || catalog?.failures?.length ? h('p', { role: 'status', style: { margin: 0 } }, catalogError || `部分服务商暂不可用：${catalog.failures.map(item => item.name ?? item.id).join('、')}`) : null,
          field('翻译默认原始语言', languageSelect('sourceLanguage', [['auto', '自动检测'], ...languages])),
          field('翻译默认目标语言', languageSelect('targetLanguage', languages)),
          h('p', { style: { margin: 0, fontSize: 13, opacity: 0.7, lineHeight: 1.7 } }, '关闭划词会停止辅助程序和当前请求，仍可在此重新启用。自动检测时保留中英互译。模型和语言的修改用于下次划词；当前对话不会重新发送。辅助功能权限请在 macOS 系统设置 → 隐私与安全性 → 辅助功能中管理。'),
          h('div', { style: { display: 'flex', gap: 12 } }, button(saving ? '保存中…' : '保存设置', undefined, { type: 'submit', disabled: disabled || !draft }), button('重新载入', () => { setDraft(null); setMessage('已载入最新设置。'); }, { disabled: saving })),
          h('p', { role: 'status', style: { margin: 0, fontSize: 13 } }, snapshot.status !== 'ready' ? '划词设置暂不可用，请检查插件状态。' : !snapshot.writable ? '当前设置只读。' : message));
      }
      ctx.effect(() => ctx.slots.inject('plugins.bundle.config', () => ctx.slots.register({ name: 'plugins.bundle.config', key: 'dsh-selection-toolbar' }, Settings)));
      ctx.effect(() => ctx.slots.inject('plugins.row.config', () => ctx.slots.register({ name: 'plugins.row.config', key: 'dsh-selection-toolbar#selection-toolbar' }, Settings)));
    }
    return { apply, inject: ['slots', 'configForms', 'remote', 'remote.session'] };
  },
});
