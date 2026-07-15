# 实现与交接说明

## 复用边界

| 层 | 复用来源 | 处理方式 |
|---|---|---|
| OpenClacky 宿主集成 | 本机 orchestrator 1.0.1 | 保留 Ruby API、Session Registry、模型热切换、恢复/重建、错误分类、工作目录隔离与轮询设计；更换命名空间和领域模型 |
| 投研流水线 | TradingAgents-Astock 0.2.18 | 保留 7 Analyst、质量门控、多空、研究经理、Trader、三方风险、Portfolio Manager 的阶段和依赖 |
| A 股角色知识 | TradingAgents-Astock agents | 将上游 prompt 中的 A 股制度、政策/游资/解禁框架、质量规则压缩为 OpenClacky Agent Profile 与角色职责 |
| A 股数据 | TradingAgents-Astock `a_stock.py` | Apache-2.0 原码 vendoring；增加轻量 CLI bridge、角色数据包、独立失败降级和隔离 venv；兼容 mootdx F10 字典返回及新浪 FinanceReport2022 新旧 JSON 结构 |
| 面板交互 | orchestrator panel | 保留 mount、动态模块、轮询、宿主设计变量和会话跳转；重做为投研创建页与 7 阶段流水线视图 |

## 有意不复用的部分

- LangGraph、LangChain LLM clients、Streamlit 和 CLI 交互层没有带入。OpenClacky 已经提供模型、会话、工具调用和 UI，重复引入会造成两套会话状态与两次模型配置。
- 上游 memory/reflection/backtest 暂未接入 MVP；当前版本聚焦单次结构化投研和可审计产物。
- 像素办公室没有复制到新扩展。它与证券研究主流程无关，保留会增加包体与维护面。

## 运行数据流

1. 用户从“新建会话”选择唯一公开 Agent `astock-research`，这个会话就是项目总控入口。
2. 面板 `POST /researches` 创建研究元数据与依赖任务，`entry_session_id` 绑定当前会话。
3. 启动时 Ruby API 创建团队目录，复制只读数据 runtime，写入 `research.json`、`PIPELINE.md` 和带身份边界的 `.clackyrules`；当前会话切换到团队根目录。
4. API 创建后台专项角色会话，总控按依赖把任务标记为 running 并派活。
5. 分析师通过 `astock_data.py bundle` 获取自己的数据包，写 `raw_data.md` 与 `REPORT.md`。
6. 委员回报中的“任务已完成”触发后端幂等完成标记，总控继续下一阶段。
7. 投资组合经理产出最终结论，总控在团队根目录汇总 `FINAL_REPORT.md`。

## 已验证

- Ruby 2.6：handler 与全部 lib `ruby -c` 通过。
- Node 22：全部 Panel ES module `node --check` 通过。
- Python 3.9：7 类数据包的上游函数签名、单源失败降级和 CLI 导入测试通过。
- Ruby 2.6 集成测试：19 条扩展路由、参数校验、当前会话绑定、后台角色生命周期、消息/决策/进度、停止和删除均通过。
- HTTP 实机冒烟：研究 CRUD、会话过滤、Worker 增删改/重建，以及删除项目后保留总控会话并恢复原目录均通过。
- OpenClacky 1.4.0：`ext verify` 的 panel/API/唯一公开 agent 均为 `[OK]`。
- 浏览器：从“新建会话”只能看到“A股投研助手”；会话、面板和首轮提示按当前会话总控模式运行。

## 已知限制

- 免费财经接口可能改变参数或触发风控；每个数据调用独立降级并保留错误，不能保证所有字段持续可用。
- macOS 系统 Python 使用 LibreSSL，因此隔离环境固定 `urllib3` 1.26 兼容线；扩展不会改动系统 Python 包。
- 百度股市通概念接口在本次测试中返回 403；其他来源仍可继续，报告应标注该字段缺失。
- 完整启动共使用最多 17 个会话（用户当前总控会话 + 最多 16 个后台角色），模型成本取决于所选模型。可少选第一阶段分析师降低成本，但固定裁决/风控阶段仍保留。
- 本版本没有执行真实交易，也没有券商接口；这是刻意的安全边界。

## 推荐后续迭代

1. 增加研究模板（短线事件驱动 / 中线基本面 / 财报专项），按模板裁剪固定委员会角色。
2. 把数据源健康状态做成面板卡片，并支持按源重试。
3. 增加同一标的多日期对比、历史研究复盘与命中率统计。
4. 在不触碰真实交易的前提下加入纸面组合和回测报告。
