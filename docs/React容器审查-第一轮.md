# Codex 容器审查 · 第一轮

针对已落盘代码：

1. WebInterfaceBundle 的 URLResponse expectedContentLength 目前用原 data.count，随后插 CSP 得到不同长度 payload。先确定最终 payload 再用 payload.count，HEAD 与 GET 的表示一致。
2. ReactWindowRecoveryView 是产品流程，不显示 React、packages/interface、build output 等实现细节。使用“应用窗口暂时无法加载，请重试”等准确用户文案；开发排错原因可以写安全日志。不要声称重试一定解决缺资源。
3. WKNavigationDelegate 当前允许整个可信资源目录成为主页面，并会将所有 http(s) 导航直接打开系统浏览器。主框架导航只允许 index.html（可含前端 hash），拒绝其他资源当文档；外链只针对用户主动点击主页面链接/明确 target=_blank 手势，避免 iframe/自动重定向触发外部浏览器。资源子请求仍由 scheme handler 服务，不需要放开主文档导航。
4. 为资源 URL resolver 提供可注入 bundle/root 供测试，覆盖 ../、编码 ..、编码 slash/backslash、兄弟同前缀目录、符号链接逃逸、根不存在、未知 MIME 和 HEAD。不用真实 app bundle 模拟这些错误。
5. showRecovery 隐藏 WebView 后应卸载 bridge/取消订阅；retry 再 install，避免失败页仍持有活跃通道。关闭的 dispose 应幂等、不可继续 load；内容进程终止再重试能重建。
6. 保留当前 env opt-in 直到后续验收，最终用户功能需要默认入口切换；此阶段不要因前端开发依赖缺失生成占位页面。
