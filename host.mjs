import z from '@deepseek-ai/schemastery';
import { settingsSchema } from './config.mjs';
export { name, inject, apply } from './index.mjs';
export const Config = settingsSchema(z);
