import { build, context } from 'esbuild'

/**
 * client 半边构建：src/client/index.tsx → lib/client/index.js
 *
 * DSH 的浏览器半边走的是宿主模块加载器（不是普通 ESM）：
 *   window.__ModuleLoader__.load({ id, factory: (require) => { … ; return module.exports } })
 * 因此这里用 esbuild 打成 **cjs**，再用 banner/footer 包进 factory；react 与
 * @deepseek-ai/* 一律 external，由宿主通过 factory 的 require 提供。
 *
 * 用法：node scripts/build-client.mjs [--watch]
 */
const watch = process.argv.includes('--watch')

/** @type {import('esbuild').BuildOptions} */
const options = {
  entryPoints: ['src/client/index.tsx'],
  bundle: true,
  format: 'cjs',
  platform: 'browser',
  target: 'es2022',
  jsx: 'automatic',
  external: ['react', 'react-dom', 'react/jsx-runtime', '@deepseek-ai/*'],
  outfile: 'lib/client/index.js',
  banner: {
    js: 'window.__ModuleLoader__.load({id:"@zseven-w/dsh-superphone",factory:(require)=>{var module={exports:{}};var exports=module.exports;',
  },
  footer: { js: 'return module.exports;}});' },
  sourcemap: false,
  logLevel: 'info',
}

if (watch) {
  const ctx = await context(options)
  await ctx.watch()
  console.log('[dsh-superphone] client watch 模式已启动（保存即重建）')
} else {
  await build(options)
  console.log('[dsh-superphone] client 构建完成 → lib/client/index.js')
}
