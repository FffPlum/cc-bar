# Codex 契约审查 · 第一轮

以下是对已落盘 window.ts 的实际审查，需在 Swift 接线前修正，并同步前端契约。不是新增产品范围。

1. **重置次数 DTO 错误**：原 `CodexResetCreditsClient.Fetched` / `CodexResetCreditsDetailView` 是 availableCount 和 credits `{id,title,status,grantedAt,expiresAt}`。不能以额度比例/金额 DTO 替代，需忠实映射当前页面。
2. **v1 兼容**：usage/settings 已分到 window.*，但新 `WindowAPI.quotaRefresh` 仍调用旧 `quota.refresh` 而要求不同 DTO。改成 `window.quota.refresh` 或其他明确独立方法，保留旧 HostAPI 行为和测试。
3. **代理真实枚举**：当前设置只支持 system/manual 与 http/socks5，不得凭空加入 off/https 使前端提供无实现的选项。
4. **副作用与原子设置**：launchAtLogin 的系统注册和通知权限请求会失败，不能在写入普通 patch 一半后才失败。系统动作应独立明确方法，普通 settings patch 先完整校验后一次执行；可复用现有 platform.setLaunchAtLogin。通知偏好保存与请求权限的结果需清楚区分，保持原有授权状态展示。
5. **安装图标**：当前 ApplicationSummary/Bootstrap 缺可消费的宿主图标，React 仅复制 favicon 无法响应“跟随已安装 App 图标”。增加必要的品牌资源 DTO（安全 data:image/png;base64 或打包资源 URI），复用既有 InstalledAppIconResolver，不暴露任意文件读取。设置变化/事件后前端实际刷新图标。品牌色也须立即更新。
6. **展示金额完整性**：PricingModel.price 只有原币数值，ConversationCosts 也只有 total 展示金额，CycleSummary 用满费用只有 USD。需要宿主格式化相应展示字段，复用 CurrencyFormatter（含缺汇率回退、JPY/KRW精度），否则前端不得自行汇率换算或把 USD 标目标币符号。不可用价格和空值不能伪造为0。
7. **跨平台类型边界**：bootstrap platform 不应硬编码类型 macos，允许 windows / 合理的平台字符串；macOS 实现仍只回 macos。能力和页面平台无关。
8. **系统操作可达**：对话 ID 复制在自定义 WK scheme 下不要依赖不保证存在的 navigator.clipboard；增加安全 platform 操作或基于会话 ID 的具体复制动作，隐私开启时拒绝原值复制。Finder 同理隐私禁用、项目路径在宿主校验。打开厂商/Pi说明等外链保留系统浏览器行为。
9. **SDK 验证收尾**：不要保留未用 schema + void 抑制；dictionary 的键也按 UsageService/币种等真实集合校验，时间/金额字段至少保证能可靠显示。请求中省略 undefined 字段，避免 WK消息序列化不一致。

10. **每服务 KPI**：UsageOverview 缺各服务 current/previous totals 或独立 KPI DTO，无法保留 Codex/Kimi 等卡片的环比。不能由前端聚合图表样本来补。
11. **账号来源语义**：QuotaAccount 需原有数据来源说明和 sourceOwned/sourceApplication 信息，DeepSeek 删除确认和执行必须区分原应用副本与 CCBar 自建授权。QuotaAccountsResult 需额外 Gemini/Grok 登录项及状态、应用配置跳转，不能纳入不存在的额度 Provider。
12. **系统状态**：NotificationState 缺 sound/alerts/statusText，需显示系统声音未允许等情况，原生 allowed 到 authorized 显式映射；UpdateState 需 hasUpdate/isWorking 保留“查看更新”按钮状态。
13. **长任务超时**：HostAPI 默认15秒，PAT导入/诊断导出/重算可能超时但后台已成功。为长任务使用 start+操作状态/ID或明确更长定向超时，不得让超时变成“未保存，请重试”导致重复写入。
14. **隐私稳定 ID**：ProjectIdentity.key、ConversationSummary.id 不能直接返回路径拼接原文；sourcePaths 当前 UI 不需要，应移除。使用稳定 opaque ID 在宿主解析查询；导入预览 ID/账号在隐私模式脱敏。测试断言整个 JSON 不含原始路径/身份/秘密，不只检查可见标题。

不能仅凭方法名齐全认为完成，需与原生每个控件行为对照。
