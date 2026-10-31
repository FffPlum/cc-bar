# DeepSeek 账号接入验证

日期：2026-10-31。分支：`feature/deepseek-accounts`。未提交、未发布。

后续架构与最新验证见 [应用与授权重构记录](验证记录-应用与授权重构.md)。本页保留首次接入阶段的证据。

## 实现范围

- 授权中心 → DeepSeek：API Key 与系统浏览器账号授权，多账号名称编辑、重新连接及删除。
- 官方 API 余额、平台充值钱包和赠金；默认显示弹出面板，菜单栏与悬浮窗逐账号开启。金额沿用显示币种偏好，并标明原币。
- 本机私有凭据文件、缓存指纹绑定、防重复刷新、网络失败保留快照、429 十分钟退避、取消与超时后禁止凭据保存、旧请求结果隔离。
- 同步产品需求、技术实现及界面布局。修正既有 `CurrencyTests.swift` 的模块名大小写（`ccbar` → `CCBar`），该错误会阻止整个测试目标编译。

## 自动验证

- `git diff --check` 与工程 plist 检查通过。
- 标准 Debug 构建通过；仅为当前命令设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，不改系统选择或工程签名。
- Debug 测试目标编译通过。标准 `xcodebuild test` 启动阶段遇到本机已有 `IDELaunchErrorDomain / 20`（LaunchServices）错误，不能表述为标准测试启动成功。
- 沿用仓库记录的独立 Xcode `xctest` 运行方式，加载同一 Debug 的 `CCBar.debug.dylib` 与 `CCBarTests.xctest`，设置 `XCTestBundlePath` 隔离 App 启动副作用。Swift Testing 实际报告 **14 tests / 1 suite passed**，包含两组各 7 个参数的测试，共 26 个执行用例，退出码 0。XCTest 的前置输出显示 0 项是因为新增用例使用 Swift Testing；以后续 Swift Testing 的实际计数为准。
- 覆盖：金额精度和科学计数法、多币种隔离、空钱包与失败区分、业务错误及 40003、官方跳转地址限制、取消后禁止重启和保存、回调 state/code 校验、本机文件 0600 权限、元数据无凭据、删除不恢复、429 保留快照及手动退避、替换或删除后的迟到响应、两种认证头与目的地址隔离、错误正文不回显凭据。
- 测试数据为固定假凭据及临时目录；HTTP 由 URLProtocol 拦截，没有使用用户真实 DeepSeek 凭据或发起真实授权。

## 待手动验收

在此工作区的 `ccbar.xcodeproj` 中运行 App：

1. 添加有效 API Key，确认余额、充值、赠金与官方平台一致；无效 Key 有错误提示。
2. 选择账号授权，在系统浏览器完成登录，确认返回 App 后保存并显示余额；取消、关闭弹窗或等到超时后不能新增账号。
3. 编辑名称、替换 Key、重新授权及删除，确认不混用旧余额。
4. 分别开启菜单栏、悬浮窗；关闭其他服务时 DeepSeek 仍可显示，悬浮窗尺寸随新增与删除账号调整。
5. 切换中英文、隐私模式及显示币种，检查名称遮挡、金额和原币标签。

真实账号授权、官方接口兼容性和界面视觉尚未手动验证。平台授权实现参考 DeepSeek Harness 官方源码，平台接口后续变动仍可能需要适配。
