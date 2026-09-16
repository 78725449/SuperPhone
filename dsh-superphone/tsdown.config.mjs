import { defineConfig } from 'tsdown'

// host 半边：src/index.ts → lib/index.js（ESM）。
// 注意 clean:false —— lib/ 同时存放 client 产物（scripts/build-client.mjs），
// clean 会把 client 目录删掉。
export default defineConfig({
  entry: { index: 'src/index.ts' },
  format: ['esm'],
  platform: 'node',
  target: 'node22',
  dts: false,
  clean: false,
  sourcemap: false,
  outDir: 'lib',
  external: [/^@deepseek-ai\//],
})
