import Schema from '@deepseek-ai/schemastery'

/**
 * dsh-superphone 配置（Schemastery Schema：harness 在加载期校验，非法值响亮失败；
 * 每个键都能在 cordis.yml 里改，不需要改代码）。
 */
export interface Config {
  /** 网关地址（SuperPhone farm）。默认 https://（网关默认启用 TLS + 自签证书）。
   *  网关以 FARM_TLS=0 启动时填 http:// 亦可 —— 网关层会按协议错配自动切换一次。 */
  gateway: string
  /** 网关 token（FARM_TOKEN；未启用鉴权时留空）。 */
  token: string
  /** 缩略图轮询兜底间隔（毫秒）；事件驱动为主，轮询仅兜底。 */
  thumbPollMs: number
}

export const Config: Schema<Config> = Schema.object({
  // ★ 2026-09-18 默认值由 http:// 改为 https:// —— 网关【设计上默认启用 TLS】（FARM_TLS !== '0'
  //   → https + 自签证书）。原 http 默认值在 https 网关下会被 301 到 https，
  //   而全局 fetch 不信任自签证书 → 面板与所有工具报 502「网关不可达」。
  //   现在 gateway.ts 改用 node:http(s) 直连并信任自签证书，且在协议错配时自动切换一次，
  //   故这里填任一协议都能工作，默认与网关的默认模式对齐。
  gateway: Schema.string().default('https://127.0.0.1:8080').description('SuperPhone 网关地址（默认 https，自签证书已信任）。'),
  token: Schema.string().default('').description('网关 FARM_TOKEN；未启用鉴权时留空。'),
  thumbPollMs: Schema.number().default(15000).description('缩略图兜底轮询间隔（毫秒）。'),
})
