import type { Context } from '@deepseek-ai/cordis'
import { ActivityLog } from './activity.js'
import { Config } from './config.js'
import type { Config as ConfigShape } from './config.js'
import { createProxyHandler } from './gateway.js'
import { createSuperphoneTools } from './tools.js'

/**
 * dsh-superphone — SuperPhone 设备群控的 DSH 插件（host 半边）。
 *
 * 职责：
 * - 注册模型可见工具（superphone_devices / _screenshot / _tap / _ocr / _take_control）。
 * - 注册 **同源数据代理** `/superphone/*`：浏览器面板只请求 DSH 自己的源，
 *   由 host 转发到网关 REST（网关不带 CORS 头，跨域与自签证书问题都在这一层消掉）。
 *
 * client 半边（侧边栏按钮 + 浮动控制面板）由 package.json 的 `dsh.client` 声明自动
 * 加载，不在 host 的 apply 里注册 slot。
 */

export const name = 'dsh-superphone'
export const inject = ['tools', 'webServer']

/** 交给 loader 在加载期校验本插件的配置。 */
export { Config }

export function apply(ctx: Context, config: ConfigShape): void {
  // 执行日志：记录每次**工具调用**（AI 步骤流水 + 面板的「AI 控制中」判定）。
  // 记在工具层而非 HTTP 层：取帧类工具也算 AI 的一步，而面板自身的轮询不经工具、不会混入。
  const log = new ActivityLog()

  for (const tool of createSuperphoneTools(config, log)) {
    // register 返回 disposer（注册即 effect）：卸载/热重载时自动撤下工具。
    ctx.tools.register(tool)
  }

  // 面板数据通道：/superphone/devices · /thumb/:id · /config · /log
  ctx.webServer.register({
    kind: 'prefix',
    path: '/superphone',
    handler: createProxyHandler(config, log),
  })

  ctx.logger.info(`dsh-superphone ready (gateway=${config.gateway})`)
}
