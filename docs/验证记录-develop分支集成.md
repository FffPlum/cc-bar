# develop 分支集成与全量验证

日期：2026-10-31。

## 分支核对

- 同步 `origin` 全部分支并核对本地分支的提交祖先关系。原远端拉取配置只覆盖部分分支，本次显式拉取所有分支，未修改长期拉取配置。
- 待集成分支只有 `feature/provider-quota-management`（`73a106e`）和 `feature/menu-bar-tracking`（`20e63db`）。其余本地及 origin 功能分支的提交已包含在 develop 中。
- 两条分支依次使用普通 merge 合入 develop，保留功能历史；合并提交为 `c90f015`、`44c6491`。没有修改 main、版本号或发布标签。
- 主工作区仍在使用菜单栏功能分支，保留其未提交的 Xcode 启动参数，不纳入本次集成。

## 合并与修复

1. 菜单栏改用原生状态栏菜单和按钮图像时，保留新供应商功能中的登录账号筛选、DeepSeek 余额及 Codex 导入账号参数。
2. 架构文档保留 Swift Package 目录结构，合并 AppKit 窗口管理说明，并保留新的应用 / 额度管理 / 用量统计 / 设置导航。
3. 首轮 Debug 构建通过；全量测试暴露 21 个失败断言。修复原因如下：
   - Swift Package 未打包两份 JSONL 测试数据；在测试 target 声明资源，并用统一的 `TestResources.bundle` 兼容 Swift Package 和 Xcode。
   - 品牌目录新增 DeepSeek、Grok、Gemini，补齐默认颜色与资源映射断言，继续核对完整目录数量。
   - Kimi 缺价测试沿用旧美元格式；非占位结果改为验证统一金额格式，保留 Kimi 专属缺价提示和非零金额断言。
   - 图标样本用命名颜色向 Device RGB 位图写像素时，在独立测试进程中得到未知颜色空间并写成透明像素；样本改为显式 Device RGB 颜色。裁切实现及预期 60 × 60 主体边界未改。
4. 未更改上述测试覆盖的业务实现，未删除或跳过失败测试。

## 最终验证

- Xcode Debug build：通过，日志 `/tmp/ccbar-develop-merged-build.log`。
- Swift Package 全量测试：761 项 XCTest（3 项跳过）及 39 项 Swift Testing，合计 797 项通过、3 项跳过、0 失败。日志 `/tmp/ccbar-develop-verified-tests.log`。
- Xcode App 宿主全量测试：相同 800 项用例，797 项通过、3 项跳过、0 失败，包含 `TEST SUCCEEDED`。日志 `/tmp/ccbar-develop-xcode-tests.log`。
- 三项跳过均为可选本机验证：无 Command Code 凭据、未启用 Kimi 真实日志计时审计、未配置真实用量 golden 对照。
- 工程 plist、差异空白及未合并分支检查通过。既有 Swift 6 并发警告仍需后续专门处理，不影响本次 Swift 5 语言模式下构建和测试。
- 本轮未重新验证全屏 / 自动隐藏菜单栏的手动交互，也未新增真实账号登录。自动测试通过不替代这些界面验收。

## ub-mode 自查

复用统一测试资源入口，保留现有核心功能；针对首轮失败修复原因并重新运行全量测试，未引入测试专用业务分支。当前环境没有 crapper / dryer / mutator 工具，本轮采用差异审阅和行为测试，不提供这些工具的评分。
