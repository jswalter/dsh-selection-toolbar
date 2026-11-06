// DSH's documented lazy client-bundle format. Kept directly readable: no build step.
window.__ModuleLoader__.load({
  id: 'dsh-selection-toolbar',
  factory: require => {
    const React = require('react');
    const { Switch } = require('@deepseek-ai/dsh-client-ui-primitives');
    const h = React.createElement;
    const namespace = 'selectionToolbar.settings';
    const dictionaries = {
      zh: {
        title: 'AI 划词工具栏',
        enabled: '启用划词',
        description: '开启后，拖选文字即可使用语法修正、翻译和解释。关闭会结束划词程序、关闭浮窗并停止当前请求。',
        hint: '随 DSH 启动和退出。模型可在划词浮窗的“··· → 划词设置”中选择。',
        saving: '正在保存…',
        failed: '未能保存，请重试。',
        readOnly: '当前设置为只读。',
        unavailable: '划词设置暂不可用，请检查插件状态。',
      },
      en: {
        title: 'AI Selection Toolbar',
        enabled: 'Enable text selection',
        description: 'Drag to select text for grammar correction, translation and explanation. Turning this off exits the helper, closes its windows and cancels the current request.',
        hint: 'Starts and stops with DSH. Choose a model from “··· → Selection settings” in the floating toolbar.',
        saving: 'Saving…',
        failed: 'Could not save. Please try again.',
        readOnly: 'These settings are read-only.',
        unavailable: 'Selection settings are unavailable. Check the plugin status.',
      },
    };

    function SelectionSettings({ scope, t }) {
      const subscribe = React.useCallback(listener => scope.subscribe(listener), [scope]);
      const snapshot = React.useCallback(() => scope.getSnapshot(), [scope]);
      const state = React.useSyncExternalStore(subscribe, snapshot, snapshot);
      const [saving, setSaving] = React.useState(false);
      const [failed, setFailed] = React.useState(false);
      const ready = state.status === 'ready';
      async function setEnabled(value) {
        if (saving || !ready || !state.writable) return;
        setSaving(true); setFailed(false);
        try { setFailed(!await scope.set('enabled', value)); }
        catch { setFailed(true); }
        finally { setSaving(false); }
      }
      return h('section', {
        style: { maxWidth: 680, color: 'var(--dsw-alias-label-primary)' },
      },
      h('h2', { style: { margin: '0 0 20px', fontSize: 18, fontWeight: 600 } }, t('title')),
      h('div', { style: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 24 } },
        h('span', { style: { fontSize: 14 } }, t('enabled')),
        h(Switch, {
          label: t('enabled'), checked: ready && state.value?.enabled === true,
          disabled: saving || !ready || !state.writable, onChange: setEnabled,
        })),
      h('p', { style: { fontSize: 13, lineHeight: 1.7, color: 'var(--dsw-alias-label-secondary)' } }, t('description')),
      h('p', { style: { fontSize: 12, lineHeight: 1.7, color: 'var(--dsw-alias-label-tertiary)' } }, t('hint')),
      h('p', { role: failed ? 'alert' : 'status', style: { fontSize: 13, minHeight: 20 } },
        failed ? t('failed') : saving ? t('saving') : !ready ? t('unavailable') : !state.writable ? t('readOnly') : ''));
    }

    function apply(ctx) {
      ctx.effect(() => ctx.locale.register(namespace, dictionaries));
      const t = ctx.locale.bind(namespace);
      const scope = ctx.configForms.get('selection-toolbar');
      ctx.effect(() => ctx.configForms.whileServed(['selection-toolbar'], () =>
        ctx.slots.inject('settings.section', () => ctx.slots.register({
          name: 'settings.section', id: 'selection-toolbar', order: 65,
          label: () => t('title'), locale: namespace, inject: () => ({ scope }),
        }, SelectionSettings))));
    }
    return { inject: ['slots', 'locale', 'configForms'], apply };
  },
});
