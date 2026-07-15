# A股投研委员会 · OpenClacky 扩展

> **公开测试版（Beta）** · 当前版本 `0.2.5`
> 作者与维护者：**路灯同学创业笔记**  
> 本项目仍在快速迭代，欢迎提交 Issue 反馈真实使用问题。

## 项目介绍

这是一个运行在 OpenClacky 里的 A 股多 Agent 投研助手。用户只需要新建一个“A股投研助手”会话，在右侧面板填写股票代码，系统就会自动创建投研委员会、收集公开数据、按依赖推进研究流程，并生成结构化研究报告。

它不是一个只会同时询问多个模型的聊天模板。当前会话会直接成为投研总控，后台 16 个专项角色分别承担技术面、舆情、新闻、基本面、政策、资金流、股东行为、数据质量、多空辩论、交易方案与风险审查，并在前序材料完成后自动启动下一阶段。

把 OpenClacky 的原生多 Agent 会话编排，与
[TradingAgents-Astock](https://github.com/simonlin1212/TradingAgents-astock) 的 A 股角色设计和免费数据层结合成一个扩展。

> 仅供学习研究与技术演示，不构成任何投资建议。数据源可能延迟、缺失或失效，实际投资决策应咨询持牌机构。

## 核心功能

- 7 类可选分析师：技术面、舆情、新闻、基本面、政策、游资资金流、解禁股东行为。
- 7 阶段流水线：多维研报 → 数据质量 → 多空辩论 → 研究裁决 → 交易方案 → 三方风控 → 组合决策。
- 当前“A股投研助手”会话就是项目总控；后台按所选流水线创建最多 16 个专项研究会话。
- 会话标题统一为“角色｜股票代码/任务”，例如 `市场技术分析师｜600519/01 技术面与量价分析`。
- 支持 OpenClacky 原生模型选择、会话恢复、错误重试、消息和任务日志。
- 默认最多同时运行 3 个 Agent，可在创建时选择 2 / 3 / 5；后端强制限制，避免模型误派造成卡顿。
- 任务显示运行中但 Worker 已空闲时会自动续跑，连续失败 3 次后暂停并提示人工处理。
- 双模型设计：快速模型负责分析/辩论/交易/风控，深度模型负责研究经理和组合经理。
- 内置 TradingAgents-Astock v0.2.18 数据层，免费直连 mootdx、腾讯、东方财富、新浪、同花顺、财联社和百度股市通。
- 自动生成团队工作目录、原始数据、委员报告和最终 `FINAL_REPORT.md`。

## 已验证案例

公开测试版已使用科大讯飞 `002230` 完成真实端到端验证：

- 1 个当前总控会话和 16 个委员全部正确关联；
- 01–07 第一阶段任务自动并行启动并全部生成 `REPORT.md` 与 `raw_data.md`；
- 第一阶段完成后自动启动 08 数据质量门控；
- 连续运行期间项目保持 `running`，总控等待委员时显示 `idle` 但不会停止项目；
- 未出现重复任务、并发上限或 UTF-8 消息中断。

详细测试证据见 [TEST_REPORT.md](TEST_REPORT.md)。

## 架构

```text
New Session → A股投研助手（当前会话 = 总控）
   └─ A股投研 Panel → Ruby API / session registry / recovery / persistence
        ├─ 7 Analysts (parallel)
        ├─ Data Quality Gate
        ├─ Bull ↔ Bear
        ├─ Research Manager (deep model)
        ├─ A-share Trader
        ├─ Aggressive / Neutral / Conservative Risk
        └─ Portfolio Manager (deep model) → FINAL_REPORT.md

Each analyst
   └─ runtime/astock_data.py
        └─ vendored TradingAgents-Astock dataflows/a_stock.py
```

OpenClacky 负责模型与 Agent 会话，上游 LangGraph/Streamlit/LLM client 不重复引入；上游最有价值的数据访问代码、A 股制度知识、角色职责和阶段设计被直接复用。

## 安装

需要 OpenClacky，以及 Python 3.9+（推荐 3.10+）。本地开发安装：

```bash
./scripts/install_local.sh
```

脚本会：

1. 复制扩展到 `~/.clacky/ext/local/astock-research`；
2. 在 `~/.clacky/ext/data/astock-research/venv` 创建隔离 Python 环境；
3. 安装 A 股数据层的最小依赖并执行 `openclacky ext verify`。

如有多个 Python，可指定：

```bash
ASTOCK_PYTHON=python3.11 ./scripts/install_local.sh
```

刷新 OpenClacky WebUI 后：

1. 点击“新建会话”，选择“A股投研助手”；
2. 进入这个会话后，在右侧“A股投研”面板填写股票代码、日期和模型；
3. 进入会话后右侧会默认打开“A股投研”面板；点击“创建并启动”。当前会话继续担任总控，后台研究角色自动创建和协作。

公开的 Agent 只有“A股投研助手”一个。主席和委员是项目内部身份，不会再作为容易选错的独立 Agent 出现在“新建会话”里。

测试版安装包可从 [GitHub Releases](https://github.com/streetlightstartupnotes/openclacky-astock-research/releases) 下载。安装或更新后请重新加载 OpenClacky 页面。

## 开发验证

```bash
ruby -c api/handler.rb
find api/lib -name '*.rb' -exec ruby -c {} \;
find panels -name '*.js' -exec node --check {} \;
python3 -m py_compile runtime/astock_data.py runtime/vendor/tradingagents/dataflows/*.py
python3 runtime/astock_data.py check
ruby test/api_integration_test.rb
python3 test/data_bridge_test.py
test/http_smoke.sh
openclacky ext verify
```

单独验证数据：

```bash
python3 runtime/astock_data.py bundle \
  --role market --ticker 600519 --date 2026-07-15 --days 180 \
  --save raw_data.md
```

## 数据与隐私

- 投研元数据保存在 `~/.clacky/ext/data/astock-research/orchestrations.json`，重装扩展不会覆盖历史。
- Python 依赖环境保存在 `~/.clacky/ext/data/astock-research/venv`，不会打进扩展包。
- 每次投研建立独立团队目录；当前会话切换到该目录担任总控，后台角色只能向各自目录写文件。
- 删除投研项目时保留用户创建的总控会话，并恢复它原来的工作目录；只删除扩展创建的后台会话。
- 东方财富请求沿用上游串行限流与随机抖动。批量运行可设置 `EM_MIN_INTERVAL=1.5` 或更高。

## 复用与许可证

- OpenClacky 会话编排、持久化、恢复与面板结构改自本机 `orchestrator` 扩展 1.0.1。
- A 股数据层与角色/流水线设计来自 TradingAgents-Astock 0.2.18，固定到提交 `e6b32a4f8223dc8c24cbf94fc7343caf6723738a`。
- 上游数据代码以 Apache License 2.0 分发；详见 `LICENSE`、`NOTICE` 和 `THIRD_PARTY_NOTICES.md`。

## 作者

本 OpenClacky 扩展由 **路灯同学创业笔记** 重新设计、开发与维护。项目尽可能复用了 OpenClacky Orchestrator 和 TradingAgents-Astock 的成熟代码与设计，并完整保留上游署名、许可证和第三方说明。

- GitHub：[@streetlightstartupnotes](https://github.com/streetlightstartupnotes)
- 问题反馈：[Issues](https://github.com/streetlightstartupnotes/openclacky-astock-research/issues)
