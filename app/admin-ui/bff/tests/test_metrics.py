from datetime import timedelta

from bff.metrics import MetricsQuery, RANGES


# --- a fake LogsQueryClient + result mirroring azure-monitor-query's shape ---
class FakeTable:
    def __init__(self, columns, rows):
        self.columns = columns
        self.rows = rows


class FakeResult:
    def __init__(self, tables):
        self.status = "Success"
        self.tables = tables


class FakeLogsClient:
    """Returns canned tables keyed by a substring of the query."""
    def __init__(self, mapping):
        self._mapping = mapping
        self.calls = []

    def query_workspace(self, workspace_id, query, timespan):
        self.calls.append((workspace_id, query, timespan))
        for key, table in self._mapping.items():
            if key in query:
                return FakeResult([table])
        return FakeResult([FakeTable([], [])])


def test_ranges_map_to_timedeltas():
    assert RANGES["1h"] == timedelta(hours=1)
    assert RANGES["24h"] == timedelta(days=1)
    assert RANGES["7d"] == timedelta(days=7)


def test_dashboard_parses_tables():
    # Keys are substrings unique to each fixed query (no overlap between _Q_ERRORS/_Q_BLOCKED's
    # 'countif' or _Q_BY_MODEL/_Q_REQ_BY_MODEL's 'by deployment').
    client = FakeLogsClient({
        'total=sum(Sum)': FakeTable(["total"], [[12345]]),
        'by consumer': FakeTable(["consumer", "tokens"], [["smoke", 1000], ["payments", 500]]),
        'tokens=sum(Sum) by deployment': FakeTable(["deployment", "tokens"], [["FW-GLM-5.2", 800], ["gpt-5.6-sol", 700]]),
        'requests=count() by deployment': FakeTable(["deployment", "requests"], [["FW-GLM-5.2", 12], ["gpt-5.6-sol", 5]]),
        'total=count(), errors=countif': FakeTable(["total", "errors"], [[20, 3]]),
        'blocked_403': FakeTable(["blocked_403", "blocked_429"], [[2, 4]]),
    })
    mq = MetricsQuery(client, "ws-guid")
    d = mq.dashboard(timedelta(days=1))
    assert d["total_tokens"] == 12345
    assert d["by_consumer"] == [{"consumer": "smoke", "tokens": 1000}, {"consumer": "payments", "tokens": 500}]
    assert d["by_model"] == [{"deployment": "FW-GLM-5.2", "tokens": 800}, {"deployment": "gpt-5.6-sol", "tokens": 700}]
    assert d["requests_by_model"] == [{"deployment": "FW-GLM-5.2", "requests": 12}, {"deployment": "gpt-5.6-sol", "requests": 5}]
    assert d["total_requests"] == 20
    assert d["error_rate"] == 0.15  # 3/20
    assert d["blocked_403"] == 2
    assert d["blocked_429"] == 4


def test_error_rate_zero_when_no_requests():
    client = FakeLogsClient({"countif": FakeTable(["total", "errors"], [[0, 0]])})
    mq = MetricsQuery(client, "ws-guid")
    d = mq.dashboard(timedelta(days=1))
    assert d["error_rate"] == 0.0


def test_consumer_usage_groups_by_model_and_kind():
    client = FakeLogsClient({
        'by model': FakeTable(["model", "tok_kind", "tokens"],
            [["gpt-5.6-sol", "prompt", 1000], ["gpt-5.6-sol", "completion", 200], ["grok-4.3", "prompt", 50]]),
    })
    mq = MetricsQuery(client, "ws-guid")
    out = mq.consumer_usage("smoke", timedelta(days=1))
    assert out["gpt-5.6-sol"] == {"prompt": 1000, "completion": 200}
    assert out["grok-4.3"] == {"prompt": 50, "completion": 0}


def test_consumer_usage_rejects_unsafe_consumer_name():
    # consumer is interpolated into KQL; a name with a quote/odd char returns {} (no query).
    mq = MetricsQuery(FakeLogsClient({}), "ws-guid")
    assert mq.consumer_usage("bad'name", timedelta(days=1)) == {}
    assert mq.consumer_usage("", timedelta(days=1)) == {}


def test_consumer_usage_window_is_utc_midnight_not_rolling():
    # REGRESSION: the live budget display must align with the worker's daily reset (UTC midnight),
    # not a rolling 24h — otherwise the UI percentage trails the enforced level just after midnight.
    captured = {}

    class CapturingClient:
        def query_workspace(self, workspace_id, query, timespan):
            captured["query"] = query
            return FakeResult([FakeTable([], [])])

    MetricsQuery(CapturingClient(), "ws").consumer_usage("infra", timedelta(days=1))
    assert "startofday(now())" in captured["query"]


def test_monitoring_includes_downgrade_events():
    client = FakeLogsClient({
        'top 50 by TimeGenerated desc | project TimeGenerated, Name, ResultCode, DurationMs':
            FakeTable(["TimeGenerated", "Name", "ResultCode", "DurationMs"], [["t1", "POST /openai", "200", 12]]),
        'where toint(ResultCode) in (403, 429)':
            FakeTable(["TimeGenerated", "Name", "ResultCode"], [["t2", "POST /openai", "429"]]),
        "Message has 'model routed'":
            FakeTable(["TimeGenerated", "Message", "consumer", "requestedModel", "effectiveModel", "downgradeLevel"],
                      [["t3", "model routed from gpt-5.6-sol to grok-4.3", "ghcp", "gpt-5.6-sol", "grok-4.3", "2"]]),
    })
    out = MetricsQuery(client, "ws").monitoring(timedelta(hours=1))
    assert out["downgrades"] == [{
        "TimeGenerated": "t3",
        "Message": "model routed from gpt-5.6-sol to grok-4.3",
        "consumer": "ghcp",
        "requestedModel": "gpt-5.6-sol",
        "effectiveModel": "grok-4.3",
        "downgradeLevel": "2",
    }]
