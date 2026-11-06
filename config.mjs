// Kept separate so tests can use the schema shipped with the installed host.
export function settingsSchema(z) {
  const language = () => z.union(['zh-Hans', 'zh-Hant', 'en', 'ja'].map(value => z.const(value)));
  return z.object({
    helperPath: z.string(),
    llmModule: z.string(),
    dataDir: z.string(),
    // An absent value or null means the native preferences have not been imported yet.
    preferences: z.union([z.const(null), z.object({
      paused: z.boolean().default(false),
      route: z.union([z.const(null), z.object({ provider: z.string().min(1).max(256), model: z.string().min(1).max(512) })]).default(null),
      sourceLanguage: z.union([z.const('auto'), language()]).default('auto'),
      targetLanguage: language().default('zh-Hans'),
    })]).default(null).volatile(),
  });
}
