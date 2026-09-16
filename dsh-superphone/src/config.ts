import Schema from '@deepseek-ai/schemastery'

/**
 * dsh-superphone 配置（Schemastery Schema：harness 在加载期校验，非法值响亮失败；
 * 每个键都能在 cordis.yml 里改，不需要改代码）。
 */
export interface Config {
  /** 网关地址（SuperPhone farm，HTTP；默认本机 8080）。 */
  gateway: string
  /** 网关 token（FARM_TOKEN；未启用鉴权时留空）。 */
  token: string
  /** 缩略图轮询兜底间隔（毫秒）；事件驱动为主，轮询仅兜底。 */
  thumbPollMs: number
}

export const Config: Schema<Config> = Schema.object({
  gateway: Schema.string().default('http://127.0.0.1:8080').description('SuperPhone 网关地址（HTTP）。'),
  token: Schema.string().default('').description('网关 FARM_TOKEN；未启用鉴权时留空。'),
  thumbPollMs: Schema.number().default(15000).description('缩略图兜底轮询间隔（毫秒）。'),
})
