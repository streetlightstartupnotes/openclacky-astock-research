#!/usr/bin/env python3
"""Offline contract tests for the TradingAgents data bridge."""

from pathlib import Path
import importlib.util
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime" / "vendor"))
SPEC = importlib.util.spec_from_file_location("astock_data", ROOT / "runtime" / "astock_data.py")
astock_data = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = astock_data
SPEC.loader.exec_module(astock_data)


class RecordingAPI:
    def __init__(self):
        self.calls = []

    def __getattr__(self, name):
        def record(*args):
            self.calls.append((name, args))
            return f"ok:{name}"
        return record


class DataBridgeTest(unittest.TestCase):
    def bundle_calls(self, role):
        api = RecordingAPI()
        output = astock_data.run_bundle(api, role, "600519", "2026-07-15", 30)
        self.assertIn(f"- 角色：{role}", output)
        return api.calls

    def test_every_role_bundle_can_run_offline(self):
        for role in ("market", "social", "news", "fundamentals", "policy", "hot_money", "lockup"):
            with self.subTest(role=role):
                self.assertTrue(self.bundle_calls(role))

    def test_upstream_function_signatures_are_mapped_correctly(self):
        fundamentals = dict(self.bundle_calls("fundamentals"))
        self.assertEqual(fundamentals["get_balance_sheet"], ("600519", "quarterly", "2026-07-15"))
        self.assertEqual(fundamentals["get_cashflow"], ("600519", "quarterly", "2026-07-15"))
        self.assertEqual(fundamentals["get_income_statement"], ("600519", "quarterly", "2026-07-15"))

        for role in ("news", "lockup"):
            calls = dict(self.bundle_calls(role))
            self.assertEqual(calls["get_insider_transactions"], ("600519",))

    def test_one_vendor_failure_does_not_abort_bundle(self):
        class PartlyBrokenAPI(RecordingAPI):
            def get_news(self, *_args):
                raise RuntimeError("vendor unavailable")

        output = astock_data.run_bundle(PartlyBrokenAPI(), "news", "600519", "2026-07-15", 30)
        self.assertIn("[数据缺失: 公司新闻]", output)
        self.assertIn("ok:get_global_news", output)
        self.assertIn("ok:get_insider_transactions", output)

    def test_mootdx_dict_f10_response_is_supported(self):
        from tradingagents.dataflows import a_stock

        class DictF10Client:
            def F10(self, **_kwargs):
                return {"最新提示": "股东人数减少 4.98%"}

        original = a_stock._get_mootdx_client
        a_stock._get_mootdx_client = lambda: DictF10Client()
        try:
            output = a_stock.get_insider_transactions("600519")
        finally:
            a_stock._get_mootdx_client = original
        self.assertIn("股东人数减少 4.98%", output)
        self.assertIn("# F10 category: 最新提示", output)

    def test_current_sina_financial_report_shape_is_supported(self):
        from tradingagents.dataflows import a_stock

        payload = {
            "result": {"data": {
                "report_date": [
                    {"date_value": "20251231", "date_type": 4},
                    {"date_value": "20250930", "date_type": 3},
                ],
                "report_list": {
                    "20251231": {"rType": "合并期末", "rCurrency": "CNY", "is_audit": "审计", "data": [
                        {"item_title": "货币资金", "item_value": "100"},
                    ]},
                    "20250930": {"rType": "合并期末", "rCurrency": "CNY", "is_audit": "未审计", "data": [
                        {"item_title": "货币资金", "item_value": "90"},
                    ]},
                },
            }}
        }

        class Response:
            def json(self):
                return payload

        original = a_stock._requests.get
        a_stock._requests.get = lambda *_args, **_kwargs: Response()
        try:
            quarterly = a_stock._get_financial_report_sina("600519", "资产负债表", "quarterly", "2025-12-31")
            annual = a_stock._get_financial_report_sina("600519", "资产负债表", "annual", "2025-12-31")
        finally:
            a_stock._requests.get = original

        self.assertEqual(list(quarterly["报告日"].dt.strftime("%Y-%m-%d")), ["2025-12-31", "2025-09-30"])
        self.assertEqual(list(quarterly["货币资金"]), ["100", "90"])
        self.assertEqual(list(annual["报告日"].dt.strftime("%Y-%m-%d")), ["2025-12-31"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
