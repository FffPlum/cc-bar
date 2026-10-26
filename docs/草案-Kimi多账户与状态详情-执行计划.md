# Kimi 多账户、Moonshot 余额与展示改进执行计划

日期：2026-10-26。状态：实现与审阅修正已完成，Debug 构建及测试目标编译通过，最新完整 XCTest 共 676 项、674 项通过、2 项按环境条件跳过、0 失败；官方登录及真实 UI 待手动验收。代码保留本地，PR #12 保持关闭，提交、推送、重开 PR 和发版均不在本轮范围内。

## 1. 已确认需求与边界

1. Kimi 账户显示 `nickname · user_level_name`；缺字段时只显示已有字段，均缺失时显示「已登录」。隐私模式隐藏昵称，不能通过 hover、辅助功能或通知泄露身份。
2. 支持多个 Kimi Code 订阅账户；通过应用内官方设备授权登录添加，可选择国内 `.com` 或海外 `.ai`。保留自动识别的 CLI 账户，新增账户不切换或覆盖 CLI 当前登录。
3. API Key 单独填写，只用于 Moonshot 按量 API 服务追踪。本轮追踪官方可用余额、现金及代金券余额，国内人民币、海外美元；不将充值余额变化称为实际消费，不推算 Token 或每账户本机用量。用户未要求把订阅 API Key 作为另一种新增入口。
4. 相关模型提示和 Kimi 官方状态详情使用约 150ms 的本地 hover 延迟，不改 macOS 全局 tooltip 设置。状态详情列出 Kimi Code 分组及全部子服务的当前状态、获取时间和陈旧提示。
5. 界面模型名去掉精确的 `kimi-code/` 前缀；仅修改展示，原始模型身份、定价映射、周期归属、历史记录和去重规则保持不变。

## 2. 现状与依据

- 改动前 `Core/AppState.swift` 仅有一个 CLI `kimiAccount`；现已增加 App 管理账户列表、独立请求状态和凭据存储，昵称由 `GET /coding/v1/me` 返回并用于展示。
- `Core/Quota/ServiceStatusClient.swift` 限定官方 Kimi Code 分组，取分组与子项最严重状态；现已保留全部组件明细并标记陈旧快照。
- `Core/Credentials/ImportedCodexStore.swift` 和 `Settings/ImportedCodexAccountsView.swift` 是现有多账户持久化及界面参考，复用其原生布局和 Keychain 模式，不做全局账户架构重构。
- Kimi Code 官方端点：国内 `https://api.kimi.com/coding/v1`、海外 `https://api.kimi.ai/coding/v1`；OAuth 为对应 `auth.kimi.com` / `auth.kimi.ai`。
- 已核对本机 Kimi CLI 的设备授权实现：`POST /api/oauth/device_authorization` 与 `POST /api/oauth/token`，后者的 `grant_type` 为 `urn:ietf:params:oauth:grant-type:device_code`。公共 client ID 与已有续期实现一致。实现前再次阅读 CLI 源码中完整的字段校验、轮询间隔和错误处理。
- Moonshot 国内余额：`GET https://api.moonshot.cn/v1/users/me/balance`；海外为 `https://api.moonshot.ai/v1/users/me/balance`。读取 `data.available_balance`、`cash_balance`、`voucher_balance`，检查 HTTP 和业务错误，币种由明确选定的地区确定。负现金余额是有效欠费信息，缺失和无效数值不能当零。

参考：

- [Kimi Code 官方平台与地区说明](https://www.kimi.com/code/docs/en/)
- [Moonshot 国内余额接口](https://platform.kimi.com/docs/api/balance)
- [Moonshot 海外余额接口](https://platform.kimi.ai/docs/api/balance)
- 本机 CLI 源码：`/Users/meitounao/.nvm/versions/node/v22.23.2/lib/node_modules/@moonshot-ai/kimi-code/dist/main.mjs`（仅阅读程序代码，不读取真实密钥）

## 3. 分阶段实施

### A. 昵称、模型展示、状态详情

- 保存并展示 `nickname`，接入 Popover 和设置账户副标题；保留现有 email 元数据但不继续用作默认 Kimi 账户名称。
- 增加共享的模型展示格式化函数，仅移除字符串开头的 `kimi-code/`，覆盖统计、对话、图例、筛选及相关 hover；不能据此合并不同模型或改写缓存。
- `ServiceStatus` 增加有默认空值的组件明细，保证原三家构造点兼容；Kimi 保存已验证分组及子项的 ID、名称和状态。
- 状态圆点沿用现有尺寸和颜色。hover 内容逐项列出状态，可区分运行正常、性能下降、部分故障、严重故障、维护和未知；旧快照获取失败后，标题和子项必须明确是旧数据，不能暗示「当前正常」。
- 可取消的约 150ms hover 任务，鼠标移出、视图消失时取消，避免面板闪烁或迟到弹出；提供点击或辅助功能入口，复用原生 popover 风格。
- 更新相关常驻文档和解析／展示用例。

### B. Kimi Code 订阅多账户与应用内登录

- 明确地区枚举（国内 / 海外）与账户类型；账户元数据与敏感凭据分离，元数据原子落盘，OAuth token 放 App 自己的 Keychain，不写进偏好、日志或文档。
- 保留原来的自动识别 CLI 账户；应用内新增账户独立管理，不写 CLI 根目录。CLI 来源继续使用现有锁与凭据回写策略，App 管理的账户使用独立的续期及 Keychain 回写路径。
- 设置增加账户列表、地区选择、官方登录、取消、重新登录、删除及显示开关。设备授权在开始登录后自动打开完整官方授权页，不展示验证码，按官方间隔轮询，处理 pending、slow_down、拒绝、过期、取消、网络及 429；等待期间取消保留可见的取消结果。
- 账户身份至少包含地区与官方用户身份，避免国内／海外串号；同一身份重复登录更新凭据，不复制显示同一订阅额度。
- 按账户隔离额度、资料、错误、退避、in-flight、请求代次和缓存。删除／重新登录／切号后，迟到响应不得复活旧账户或覆盖其他账户。
- Popover 在 Kimi 服务下按账户展示，菜单栏和悬浮窗复用现有多账户显示选择方式。Free 账户的 HTTP 200 `{}` 作为成功空额度处理，保留昵称与等级，显示「暂无额度数据」，不报解析失败或伪造剩余比例。周期／时间线仅记录对应订阅账户的真实额度采样；不将共用的本机扫描用量复制给每个账户，不伪造账户级周期用满预估。
- 兼容旧版单账户缓存与未配置账户列表的用户，保留旧历史。服务关闭后停止相关请求；失败保留快照，手动刷新遵守退避。

### C. Moonshot 按量 API 余额账户

- 新增入口明确标为「Moonshot API · 按量计费」，可配置多个账户，填写名称、地区和 API Key，Key 存 Keychain；不得把 Moonshot Key 发往 Kimi Code 订阅接口或自动跨地区试探。
- 展示官方余额及币种、现金／代金券明细、获取时间与错误状态；余额没有百分比分母，不绘制伪造的额度百分比和重置时间。
- 复用原生账号列表与紧凑 Popover 展示；菜单栏／悬浮窗展示金额时保留币种，不把金额混入额度百分比聚合。不把人民币、美元余额相加。
- 每账户独立缓存及刷新；429、失败保留、删除账户后迟到响应隔离与订阅账户一致。
- 不把余额当作 Token 或真实消费统计，不把按量账户放入订阅额度周期及订阅告警。已有本机模型用量仍按现有来源统计。

### D. 验证与文档收尾

- 本地 Kimi 完成初版和工程／文档收尾；Codex 完成审阅修正及最终自动验证。修正覆盖登录／续期竞态、持久化失败回滚、换 Key 缓存失效、服务开关、只使用 App 账户的状态入口和模型 hover 去前缀。
- 优先写与风险相匹配的确定性用例：地区与主机绑定、设备轮询/取消/slow_down、Keychain 可注入存储、续期与凭据轮换、同身份去重、账户删除后迟到响应隔离、每账户 429 与缓存、余额错误和小数、模型显示不改身份、状态组件明细及旧数据提示。
- 测试使用临时根目录和假网络，不发起真实登录、不访问或改写真实凭据；执行代理不能调用 CLI login 改变用户本机登录。
- 本地 Kimi 先实施与静态审阅，汇报每阶段文件和剩余事项。由 Codex 在最终代码上统一执行已授权的 Debug 构建、测试目标编译和完整测试；沿用当前环境中已验证的 Xcode 与独立 XCTest 运行方式，记录最终数量，不把启动失败当作通过。
- 更新 `产品需求.md`、`技术实现.md`、`界面布局.md`、`设计风格.md`、本计划及文档索引。通过才标记自动验证完成，实际 UI / 官方登录需要手动验收，不能预先写成已验收。

## 4. 验收清单

- [ ] Kimi 副标题为昵称与订阅等级，缺字段及隐私模式正确。
- [ ] 国内和海外订阅均有应用内登录入口，多个账户独立显示和刷新，不覆盖 CLI 当前账户。
- [ ] 多个 Moonshot API Key 可添加，地区、币种、余额、现金和代金券信息正确，失败不丢快照。
- [ ] Kimi 状态 hover 在约 150ms 后显示分组及所有子项，离开或关闭后不迟到弹出；失败后的明细明确为旧快照。
- [ ] 所有相关界面模型名不显示 `kimi-code/` 前缀，存储和计价身份保持原值。
- [ ] 缓存迁移、账号隔离和自动验证通过；实际登录及 UI 验收状态如实记录。
- [x] 未提交、未推送、未重开 PR、未发版，保留 `dist-official/`。


## 5. 最终自动验证（2026-10-26）

- Debug：`BUILD SUCCEEDED`；测试目标：`TEST BUILD SUCCEEDED`。
- 完整 XCTest：659 项，657 项通过、2 项跳过、0 失败；进程退出码 0。其中 `KimiManagedAccountTests` 19 项、`MoonshotBalanceTests` 6 项通过，模型展示新增用例及原官方状态用例通过。
- 跳过项：缺少 Command Code 本机凭据、未配置真实用量对照文件。没有以跳过代替新功能的确定性测试。
- 当前机器仍无工程指定的开发证书：Debug 构建仅通过命令参数关闭签名，测试目标使用命令参数选择临时 ad-hoc 签名；工程团队和签名设置未变。沿用仓库已记录的独立 XCTest 方式，加载本次 Debug 的 `CCBar.debug.dylib` 与测试 bundle，并设置 `XCTestBundlePath`。没有将标准 `xcodebuild test` 启动器流程描述为通过。
- 工程 plist 解析、`git diff --check` 通过；既有项目警告未在本轮做无关清理。
- 新用例覆盖地区绑定、设备轮询减速／取消、取消后的资料晚到、重复登录、身份不符、Keychain／元数据事务回滚、续期不覆盖新凭据或复活删除项、账户级 429、删除后的额度／余额晚到、同地区更换 Key、跨重启缓存、隐私模式、极小余额和 App-only 状态明细。
- 尚未进行：真实国内／海外账号的浏览器授权、真实 Moonshot Key 联调和真实 Popover／菜单栏／悬浮窗交互验收。上方 UI 清单维持未勾选，避免把代码与单测通过当作人工验收。

## 6. Free 空额度回归修复（2026-10-26）

- 实际读取截图所示国内 Free 账户：`GET /coding/v1/me` 为 HTTP 200，包含昵称、`user_level_name: Free` 与正常账户状态；`GET /coding/v1/usages` 为 HTTP 200，正文为 `{}`。未在文档或日志记录访问令牌、用户 ID 或昵称。
- 原因是成功的空额度被 `KimiQuotaClient` 当作 `missing usage windows`，并非用户资料查询失败。此前新增的旧版 `usage/limits` 计数解析不覆盖 `{}`。本机官方 CLI 的 `parseManagedUsagePayload` 将其归为成功的空额度，展示 `No usage data available.`。
- 明确空响应及既有成功包装现保存为无窗口快照，清除刷新错误、继续限频更新昵称和等级，并在下一次跳过资料请求时保留套餐名称。Popover 与设置显示「暂无额度数据」，悬浮窗显示破折号；不伪造 0%、100%、无限额度、周期或低额度提醒。未知结构、错误包装、损坏窗口与网络失败继续保留旧快照并报错。
- Debug `build` 与 `build-for-testing` 均通过；独立 XCTest 完整套件共 676 项，674 项通过、2 项跳过、0 失败，退出码 0。新增回归覆盖真实 `{}`、空 `usages`、成功包装与错误结构区分、完整请求／资料／账户更新、错误清除、缓存恢复及资料限频后的套餐保留。运行方式和环境边界同上节，未声称标准 `xcodebuild test` 启动流程通过。
- 已用 `scripts/build.sh` 重新构建包含本次修复的 v1.1.30 arm64 Release 包，覆盖 `dist/CCBar.dmg` 与 `dist/CCBar.app.zip`；脚本签名验证、DMG 校验和与 ZIP 完整性检查均通过。
- 本轮未提交或推送。真实界面交互仍需用新构建验收。
