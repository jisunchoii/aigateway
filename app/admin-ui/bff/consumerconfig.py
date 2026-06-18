"""Cosmos repository for per-consumer gateway config (the `config` container's consumer_config docs).
Stores model permissions (③), token limits (⑤), and budget/ladder (④, storage only — the APIM
policy never reads budget). The `global` doc is owned by the operator/worker and is NOT written
here; it serves as the fallback default the BFF returns when a consumer has no doc yet."""
from typing import Optional

from azure.cosmos.exceptions import CosmosResourceNotFoundError

PERIODS = ("Hourly", "Daily", "Weekly", "Monthly")
TIERS = ("small", "medium", "large")
_POSITIVE_INT_FIELDS = ("tokens_per_minute", "token_quota", "daily_budget")
_POSITIVE_NUMBER_FIELDS = ("daily_budget_usd",)


def _doc_id(consumer: str) -> str:
    return f"consumer:{consumer}"


def validate(fields: dict, *, valid_aliases: Optional[list] = None) -> None:
    """Raise ValueError on any invalid field. Partial dicts are allowed (only-present checked)."""
    if "token_quota_period" in fields and fields["token_quota_period"] not in PERIODS:
        raise ValueError(f"token_quota_period '{fields['token_quota_period']}' must be one of {PERIODS}")
    if "tier" in fields and fields["tier"] not in TIERS:
        raise ValueError(f"tier '{fields['tier']}' must be one of {TIERS}")
    for f in _POSITIVE_INT_FIELDS:
        # bool is a subclass of int in Python — exclude it so True/False can't pass as a count.
        if f in fields and (not isinstance(fields[f], int) or isinstance(fields[f], bool) or fields[f] <= 0):
            raise ValueError(f"{f} must be a positive integer")
    for f in _POSITIVE_NUMBER_FIELDS:
        # daily_budget_usd is a dollar amount (float OK). bool excluded as above.
        if f in fields and (isinstance(fields[f], bool)
                            or not isinstance(fields[f], (int, float)) or fields[f] <= 0):
            raise ValueError(f"{f} must be a positive number")
    if "allowed_models" in fields:
        if not isinstance(fields["allowed_models"], list):
            raise ValueError("allowed_models must be a list of alias strings")
        if valid_aliases is not None:
            for m in fields["allowed_models"]:
                if m not in valid_aliases:
                    raise ValueError(f"allowed_models contains unknown alias '{m}'")


class ConsumerConfigStore:
    def __init__(self, container):
        self._c = container

    def get(self, consumer: str) -> Optional[dict]:
        try:
            return self._c.read_item(item=_doc_id(consumer), partition_key=_doc_id(consumer))
        except CosmosResourceNotFoundError:
            return None

    def list(self) -> list[dict]:
        """consumer_config docs with consumer + active_downgrade projected — used for the consumers listing
        (hasConfig) and the dashboard's active-downgrade panel. Single cross-partition query."""
        return list(self._c.query_items(
            query='SELECT c.consumer, c.active_downgrade FROM c WHERE c.doc_type = "consumer_config"',
            enable_cross_partition_query=True,
        ))

    def put(self, consumer: str, fields: dict, *, valid_aliases: Optional[list] = None) -> dict:
        validate(fields, valid_aliases=valid_aliases)
        # Metadata wins: spread fields first, then force id/doc_type/consumer so a caller can't
        # override the document identity via fields (e.g. fields={"id": "consumer:other"}).
        body = {**fields, "id": _doc_id(consumer), "doc_type": "consumer_config", "consumer": consumer}
        return self._c.upsert_item(body=body)

    def remove(self, consumer: str) -> None:
        """Delete a consumer's config doc. Idempotent — absent doc is a no-op. Only safe to call once
        the consumer has no live keys (else the gateway falls back to global defaults for that key)."""
        try:
            self._c.delete_item(item=_doc_id(consumer), partition_key=_doc_id(consumer))
        except CosmosResourceNotFoundError:
            pass

    def global_defaults(self) -> dict:
        """The operator-owned `global` config doc, used as the fallback the UI shows for a consumer
        with no override. Returns {} if absent."""
        try:
            return self._c.read_item(item="global", partition_key="global")
        except CosmosResourceNotFoundError:
            return {}
