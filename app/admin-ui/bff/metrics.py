"""Read-only Log Analytics queries for the Dashboard ① / Monitoring ⑦ pages.

Runs a FIXED set of KQL via azure-monitor-query LogsQueryClient (auth = the BFF's managed
identity, granted Log Analytics Reader). Callers choose only a time RANGE — they never send KQL,
so the workspace can't be arbitrarily queried. The range is passed as the SDK `timespan`
(a timedelta), so no time expression is interpolated into the query text either.

Schema (verified live): AppMetrics rows with Name=='Total Tokens' carry Properties JSON with
`consumer` and `deployment`; AppRequests has Name/ResultCode/DurationMs.
"""
import re
from datetime import timedelta

RANGES = {"1h": timedelta(hours=1), "24h": timedelta(days=1), "7d": timedelta(days=7)}

# A consumer name is interpolated into the per-consumer usage KQL (admin-only endpoint, but guard
# anyway). Consumer names are simple identifiers; reject anything with quotes or KQL metacharacters.
_CONSUMER_SAFE = re.compile(r"^[A-Za-z0-9 _.:-]{1,128}$")

# Fixed KQL. timespan is supplied via the SDK (not ago()), so these have no time literal.
_Q_TOTAL = 'AppMetrics | where Name == "Total Tokens" | summarize total=sum(Sum)'
_Q_BY_CONSUMER = ('AppMetrics | where Name == "Total Tokens" | extend p=parse_json(Properties) '
              '| summarize tokens=sum(Sum) by consumer=tostring(p.consumer) | order by tokens desc')
_Q_BY_MODEL = ('AppMetrics | where Name == "Total Tokens" | extend p=parse_json(Properties) '
               '| summarize tokens=sum(Sum) by deployment=tostring(p.deployment) | order by tokens desc')
_Q_ERRORS = 'AppRequests | summarize total=count(), errors=countif(toint(ResultCode) >= 400)'
_Q_BLOCKED = ('AppRequests | summarize blocked_403=countif(toint(ResultCode) == 403), '
              'blocked_429=countif(toint(ResultCode) == 429)')
_Q_REQ_BY_MODEL = ('AppMetrics | where Name == "Total Tokens" | extend p=parse_json(Properties) '
                   '| summarize requests=count() by deployment=tostring(p.deployment) | order by requests desc')
# Monitoring (logs) page: recent gateway requests, blocked events, and downgrade traces.
_Q_RECENT_REQUESTS = ('AppRequests | top 50 by TimeGenerated desc '
                      '| project TimeGenerated, Name, ResultCode, DurationMs')
_Q_BLOCKED_EVENTS = ('AppRequests | where toint(ResultCode) in (403, 429) | top 50 by TimeGenerated desc '
                     '| project TimeGenerated, Name, ResultCode')
_Q_DOWNGRADE_EVENTS = (
    "AppTraces | where Message has 'model routed' | top 50 by TimeGenerated desc "
    "| extend p=parse_json(Properties) "
    "| project TimeGenerated, Message, consumer=tostring(p.consumer), "
    "requestedModel=tostring(p.requestedModel), effectiveModel=tostring(p.effectiveModel), "
    "downgradeLevel=tostring(p.downgradeLevel)"
)


def _rows(result) -> list:
    """LogsQueryResult/partial -> list[dict] from the first table (column-name keyed)."""
    tables = getattr(result, "tables", None)
    if not tables:
        tables = getattr(result, "partial_data", None) or []
    if not tables:
        return []
    t = tables[0]
    cols = [str(c) for c in t.columns]
    return [dict(zip(cols, row)) for row in t.rows]


def _scalar(result, key, default=0):
    rows = _rows(result)
    if not rows:
        return default
    v = rows[0].get(key, default)
    return v if v is not None else default


class MetricsQuery:
    def __init__(self, client, workspace_id: str):
        self._c = client
        self._ws = workspace_id

    def _q(self, kql: str, span: timedelta):
        return self._c.query_workspace(workspace_id=self._ws, query=kql, timespan=span)

    def consumer_usage(self, consumer: str, span: timedelta) -> dict:
        """{model: {"prompt","completion"}} of one consumer's tokens SINCE UTC midnight, for live
        budget cost display. The `>= startofday(now())` filter matches the worker's daily budget
        window exactly (the budget resets at UTC midnight), so the UI percentage agrees with the
        enforced level instead of trailing a rolling 24h. `span` only bounds the data scanned (a day
        always covers since-midnight). model = effectiveModel (served after any downgrade), falling
        back to the requested deployment. Returns {} for an unsafe/empty consumer name. NOTE: the
        kind column is tok_kind — 'kind' is a reserved KQL keyword and fails to parse."""
        if not _CONSUMER_SAFE.match(consumer or ""):
            return {}
        kql = (
            'AppMetrics | where Name in ("Prompt Tokens", "Completion Tokens") '
            'and TimeGenerated >= startofday(now()) '
            f"| extend p=parse_json(Properties) | where tostring(p.consumer) == '{consumer}' "
            '| extend tok_kind = iff(Name == "Prompt Tokens", "prompt", "completion") '
            '| summarize tokens=sum(Sum) by model=tostring(coalesce(p.effectiveModel, p.deployment)), tok_kind'
        )
        out: dict = {}
        for r in _rows(self._q(kql, span)):
            model = r.get("model")
            tk = r.get("tok_kind")
            if not model or tk not in ("prompt", "completion"):
                continue
            out.setdefault(model, {"prompt": 0, "completion": 0})[tk] = int(r.get("tokens") or 0)
        return out

    def dashboard(self, span: timedelta) -> dict:
        total = _scalar(self._q(_Q_TOTAL, span), "total", 0)
        by_consumer = _rows(self._q(_Q_BY_CONSUMER, span))
        by_model = _rows(self._q(_Q_BY_MODEL, span))
        err = _rows(self._q(_Q_ERRORS, span))
        total_req = err[0].get("total", 0) if err else 0
        errors = err[0].get("errors", 0) if err else 0
        rate = round(errors / total_req, 4) if total_req else 0.0
        blocked = _rows(self._q(_Q_BLOCKED, span))
        req_by_model = _rows(self._q(_Q_REQ_BY_MODEL, span))
        return {
            "total_tokens": total,
            "by_consumer": [{"consumer": r.get("consumer"), "tokens": r.get("tokens")} for r in by_consumer],
            "by_model": [{"deployment": r.get("deployment"), "tokens": r.get("tokens")} for r in by_model],
            "requests_by_model": [{"deployment": r.get("deployment"), "requests": r.get("requests")} for r in req_by_model],
            "total_requests": total_req,
            "error_rate": rate,
            "blocked_403": blocked[0].get("blocked_403", 0) if blocked else 0,
            "blocked_429": blocked[0].get("blocked_429", 0) if blocked else 0,
        }

    def monitoring(self, span: timedelta) -> dict:
        """Recent request log + 403/429 blocked-event + downgrade trace log for Monitoring.
        Ingestion lags a few minutes (AppRequests/AppTraces are APIM logs in Log Analytics)."""
        return {
            "recent": _rows(self._q(_Q_RECENT_REQUESTS, span)),
            "blocked": _rows(self._q(_Q_BLOCKED_EVENTS, span)),
            "downgrades": _rows(self._q(_Q_DOWNGRADE_EVENTS, span)),
        }
