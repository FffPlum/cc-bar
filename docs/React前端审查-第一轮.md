# Codex 前端审查 · 第一轮

针对已落盘前端代码，请持续对照更新后的 host-api/window.ts：

1. HostProvider 目前只订阅 settings，没有响应 navigation/applications/bootstrap 所需事件；原生 ⌘1、⌘,、菜单入口无法切换 React 路由。根据最新 domains 刷新 bootstrap，并处理语言/隐私/图标/外观变化。
2. navigate 的 finally 只有 generation 相等才清 routePending；若途中 refreshBootstrap 增加 generation，pending 永久 true。请求过期控制与导航 pending 生命周期要分别管理，卸载也安全清理。防止更旧原生导航响应覆盖新导航。
3. ApplicationsPage useHostResource domains=[]，后台应用变化不刷新。各页面用准确事件域，不能永久依赖空数组。Mutation setData 与进行中的旧 loader 也有覆盖竞态，需要统一 generation 或 mutation 后失效重读。
4. 应用图标现在只有首字母，品牌色传 dark=false，无法保留 favicon/安装图标、深色品牌色。B 正新增宿主品牌资源 DTO，前端接入，首字母只作为图片失败兜底。
5. 默认 shadcn scaffold 的 Geist 字体不是当前布局基准；继续使用系统字体与13px密度。保持供应商目录/表单的真实厂商链接、Pi说明链接、对话复制、项目Finder，不以纯文本或省略代替；B 将补具体平台动作。避免直接 navigator.clipboard 在自定义 scheme 上失败。
6. B 正按 docs/React契约审查-第一轮.md 修复数据契约：resetCredits 必须次数/状态/到期时间；quota刷新改独立window方法；proxy去掉虚构off/https；金额展示字段由宿主给；每服务KPI/额外Gemini-Grok登录/账号来源/通知声音/更新状态均在补齐。请及时读取最新类型和接口文档，不基于旧类型继续丢功能。
7. 用户错误提示不要显示 React、native bridge、内部方法名/版本/type path 等实现细节；HostError 已脱敏但仍需转换为用户可理解的本地化提示，开发日志与产品信息分开。服务超时不等于保存未发生，避免鼓励无条件重复写入。
8. 添加必要的可执行前端行为验证（使用隔离 fake transport，严禁真实桥接写入）：至少路由事件、导航竞态、表单校验/错误保留/成功刷新、隐私搜索、空态和过期响应。可以增加项目测试依赖与脚本，但构建/测试仍由 Codex 统一执行。

最终正式入口不能包含演示自动回退、假数据或不可用占位操作。未实现能力写 HOST_GAPS 并交回后端补齐，之后真正接上。
