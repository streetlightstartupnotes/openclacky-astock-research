#!/usr/bin/env python3
"""Small CLI bridge around TradingAgents-Astock's reusable A-share data layer."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent
DATA_ROOT = Path(os.environ.get(
    "ASTOCK_DATA_DIR", Path.home() / ".clacky" / "ext" / "data" / "astock-research"
)).expanduser()
CACHE_VENV = DATA_ROOT / "venv"
CACHE_PYTHON = CACHE_VENV / "bin" / "python"
if CACHE_PYTHON.exists() and Path(sys.prefix).resolve() != CACHE_VENV.resolve():
    os.execv(str(CACHE_PYTHON), [str(CACHE_PYTHON), *sys.argv])
os.environ.setdefault("TRADINGAGENTS_CACHE_DIR", str(DATA_ROOT / "cache"))
os.environ.setdefault("TRADINGAGENTS_RESULTS_DIR", str(DATA_ROOT / "results"))
sys.path.insert(0, str(ROOT / "vendor"))


def _vendor():
    try:
        from tradingagents.dataflows import a_stock
        return a_stock
    except ModuleNotFoundError as exc:
        missing = exc.name or "Python dependency"
        raise SystemExit(
            f"缺少依赖 {missing}。请执行：{sys.executable} -m pip install -r "
            f"{ROOT / 'requirements.txt'}"
        ) from exc


def _date(value: str) -> str:
    try:
        return datetime.strptime(value, "%Y-%m-%d").strftime("%Y-%m-%d")
    except ValueError as exc:
        raise argparse.ArgumentTypeError("日期必须为 YYYY-MM-DD") from exc


def _safe_call(title, fn, *args, **kwargs):
    try:
        result = fn(*args, **kwargs)
        return f"## {title}\n\n{result}\n"
    except Exception as exc:  # Data vendors should degrade independently.
        return f"## {title}\n\n[数据缺失: {title}]\n\n错误：{type(exc).__name__}: {exc}\n"


def _range(date: str, days: int):
    end = datetime.strptime(date, "%Y-%m-%d")
    return (end - timedelta(days=days)).strftime("%Y-%m-%d"), date


def run_bundle(api, role: str, ticker: str, date: str, days: int) -> str:
    start, end = _range(date, days)
    calls = {
        "market": [
            ("K线行情", api.get_stock_data, ticker, start, end),
            *[(f"技术指标 {name}", api.get_indicators, ticker, name, date, 30)
              for name in ("rsi", "macd", "macdh", "boll", "boll_ub", "boll_lb", "atr", "close_50_sma")],
        ],
        "social": [("公司新闻与舆情代理数据", api.get_news, ticker, start, end)],
        "news": [
            ("公司新闻", api.get_news, ticker, start, end),
            ("全球与宏观快讯", api.get_global_news, date, min(days, 30), 30),
            ("股东与内幕信息", api.get_insider_transactions, ticker),
        ],
        "fundamentals": [
            ("公司基本面", api.get_fundamentals, ticker, date),
            ("资产负债表", api.get_balance_sheet, ticker, "quarterly", date),
            ("现金流量表", api.get_cashflow, ticker, "quarterly", date),
            ("利润表", api.get_income_statement, ticker, "quarterly", date),
            ("盈利预测", api.get_profit_forecast, ticker, date),
            ("行业横向比较", api.get_industry_comparison, ticker, date, 20),
        ],
        "policy": [
            ("公司与行业政策新闻", api.get_news, ticker, start, end),
            ("宏观与政策快讯", api.get_global_news, date, min(days, 30), 40),
        ],
        "hot_money": [
            ("近期行情", api.get_stock_data, ticker, start, end),
            ("热门股票与题材归因", api.get_hot_stocks, date),
            ("北向资金", api.get_northbound_flow, date, True),
            ("概念与行业板块", api.get_concept_blocks, ticker),
            ("个股资金流", api.get_fund_flow, ticker, date, True),
            ("龙虎榜", api.get_dragon_tiger_board, ticker, date, 30),
            ("行业横向比较", api.get_industry_comparison, ticker, date, 20),
        ],
        "lockup": [
            ("解禁日历", api.get_lockup_expiry, ticker, date, 90),
            ("股东与内幕信息", api.get_insider_transactions, ticker),
            ("公司新闻", api.get_news, ticker, start, end),
            ("公司基本面", api.get_fundamentals, ticker, date),
        ],
    }
    if role not in calls:
        raise SystemExit(f"不支持的 role：{role}；可选：{', '.join(calls)}")
    sections = [
        f"# A股原始数据包 · {ticker}",
        "",
        f"- 研究截止日：{date}",
        f"- 角色：{role}",
        f"- 生成时间：{datetime.now().isoformat(timespec='seconds')}",
        "- 数据层：TradingAgents-Astock v0.2.18（Apache-2.0）",
        "",
    ]
    for title, fn, *args in calls[role]:
        sections.append(_safe_call(title, fn, *args))
    return "\n".join(sections)


def build_parser():
    parser = argparse.ArgumentParser(description="TradingAgents-Astock 数据层的 OpenClacky CLI 桥")
    parser.add_argument("--version", action="version", version="astock-data 0.2.6 / upstream 0.2.18")
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="检查运行依赖")
    check.set_defaults(handler="check")

    bundle = sub.add_parser("bundle", help="按分析师角色采集一组数据")
    bundle.add_argument("--role", required=True, choices=["market", "social", "news", "fundamentals", "policy", "hot_money", "lockup"])
    bundle.add_argument("--ticker", required=True)
    bundle.add_argument("--date", required=True, type=_date)
    bundle.add_argument("--days", type=int, default=180)
    bundle.add_argument("--save", help="把结果保存到当前委员工作目录")
    bundle.set_defaults(handler="bundle")

    call = sub.add_parser("call", help="调用单个上游数据函数")
    call.add_argument("method", choices=[
        "get_stock_data", "get_indicators", "get_fundamentals", "get_balance_sheet",
        "get_cashflow", "get_income_statement", "get_news", "get_global_news",
        "get_insider_transactions", "get_profit_forecast", "get_hot_stocks",
        "get_northbound_flow", "get_concept_blocks", "get_fund_flow",
        "get_dragon_tiger_board", "get_lockup_expiry", "get_industry_comparison",
    ])
    call.add_argument("args", nargs="*", help="按上游函数签名传递位置参数")
    call.set_defaults(handler="call")
    return parser


def main():
    args = build_parser().parse_args()
    api = _vendor()
    if args.handler == "check":
        print("OK: TradingAgents-Astock 数据层可导入")
        return
    if args.handler == "bundle":
        result = run_bundle(api, args.role, args.ticker, args.date, max(1, args.days))
        if args.save:
            target = Path(args.save).expanduser().resolve()
            cwd = Path.cwd().resolve()
            if cwd != target.parent and cwd not in target.parents:
                raise SystemExit("--save 只能写入当前工作目录或其子目录")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(result, encoding="utf-8")
            print(target)
        else:
            print(result)
        return
    fn = getattr(api, args.method)
    int_positions = {
        "get_indicators": {3}, "get_global_news": {1, 2},
        "get_dragon_tiger_board": {2}, "get_lockup_expiry": {2},
        "get_industry_comparison": {2},
    }.get(args.method, set())
    bool_positions = {
        "get_northbound_flow": {1}, "get_fund_flow": {2},
    }.get(args.method, set())
    values = []
    for index, value in enumerate(args.args):
        if index in int_positions:
            values.append(int(value))
        elif index in bool_positions:
            values.append(value.lower() in {"1", "true", "yes", "y"})
        else:
            values.append(value)
    print(fn(*values))


if __name__ == "__main__":
    main()
