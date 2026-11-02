# SQLite 用量明细缓存

日期：2026-11-02。分支：`feature/react-main-window`。状态：已实现，32 项定向测试与指定 Xcode Debug 构建通过。

用户要求以 SQLite 保存用量明细，并明确忽略旧 JSON 明细，首次直接建立 SQLite 索引。6.1 Terra 报告执行额度不足后，用户授权由主代理接手实现和验证。

## 范围与流程

- 替换 `UsageRequestIndexStore` 的明细持久化；继续使用系统 SQLite3，不新增依赖。
- 文件位于 Application Support 的 `CCBar/usage-history/request-index.sqlite3`。主历史 `current.json`、`previous.json`、Cursor 远端日桶和 React 查询缓存保持各自职责。
- 无数据库时，`loadResult` 返回待重建，已有后台链按已接纳日志偏移及 Kimi 等扫描状态准备请求记录，再创建数据库。旧 `request-index-v1.json` 从不读取、迁移或删除。
- 有效数据库启动时后台恢复，请求页面继续先返回已有快照；来源指纹变化时更新该来源，请求时间仍由宿主与权威日桶核验，不能补造缺失日志。

## 数据模型与提交

`sources` 以应用为主键，保存可空指纹及不完整状态。`requests` 以 `(app,id)` 为主键，保存会话摘要、模型、速度、日期、时间戳、各项 Token、请求数、费用与计时。费用为精确十进制 TEXT；计数为 INTEGER64；时间为 Date 对应 REAL；计时小对象保留 JSON。建立 `(app,timestamp)` 和 `(app,model,timestamp)` 索引。

读取在一笔事务内完成，写入在 `BEGIN IMMEDIATE` 内比较磁盘指纹、替换变化来源请求行并更新状态，来源移除也同笔删除。相同非空指纹仅更新元数据，未知指纹仍需替换；任何语句失败回滚整笔事务。首建使用私有临时数据库，提交、关闭后原子发布。

数据库与文件锁权限 0600；新库显式使用 DELETE journal 与 FULL 同步，SQLite 创建的回滚日志继承数据库权限。各操作的连接和 prepared statement 局部创建/释放，不跨并发任务传递指针。保留 UsageService 的后台执行、版本检查与串行写入链。

## 故障边界

- 缺失或确认损坏：重建派生缓存；确认损坏的旧库隔离留存。有 journal/WAL/SHM 时不主动改名，避免干扰活跃连接。
- BUSY/LOCKED、权限、I/O、磁盘满：保留旧库；加载不可用时至少 30 秒后随请求或正常扫描重试，不当作空索引发布。
- 未来 `user_version` 或错误 `application_id`：不覆盖，暂不使用；没有旧 JSON 回退路径。
- 读取校验行数、字段长度、枚举、数值、唯一请求身份和来源关系；非法缓存不会修改权威历史。

本次改善的是明细持久化与来源局部更新。启动仍恢复内存索引，前端分页及宿主聚合查询仍走现有内存接口，没有改写为 SQL 查询。

## 验证

使用临时目录中的真实 SQLite，验证精度与空值、计时、私有权限、忽略旧 JSON、未来版本保护、锁占用、损坏恢复、来源局部更新及事务回滚。原索引测试继续验证重启复用、Kimi 与扫描期间缓存可展示。结果记录见 [React 主窗口验证记录](验证记录-React主窗口.md)。

事务与 journal 行为参考 [SQLite transactions](https://www.sqlite.org/transactional.html) 和 [SQLite PRAGMA](https://www.sqlite.org/pragma.html)。
