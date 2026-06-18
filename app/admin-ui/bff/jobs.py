"""Starts the config-sync Container Apps Job via the ARM REST API using the BFF's managed-identity
token (no azure-mgmt-appcontainers dependency — httpx is already a dep). Used to re-evaluate
budgets immediately on a budget change instead of waiting for the cron."""
import logging

log = logging.getLogger("bff.jobs")
_ARM = "https://management.azure.com"
_SCOPE = "https://management.azure.com/.default"
_API = "2024-03-01"


class JobStarter:
    def __init__(self, credential, http, *, sub: str, rg: str, job: str):
        self._cred = credential
        self._http = http
        self._sub = sub
        self._rg = rg
        self._job = job

    def start(self) -> bool:
        """Best-effort: returns True on a 200/202 ARM start, False otherwise (unset job name,
        error status, or transport failure). Never raises — callers don't fail their request on it."""
        if not self._job:
            return False
        url = (f"{_ARM}/subscriptions/{self._sub}/resourceGroups/{self._rg}"
               f"/providers/Microsoft.App/jobs/{self._job}/start?api-version={_API}")
        try:
            token = self._cred.get_token(_SCOPE).token
            resp = self._http.post(url, headers={"Authorization": f"Bearer {token}",
                                                 "Content-Length": "0"}, timeout=30)
        except Exception:
            log.exception("failed to start config-sync job %s", self._job)
            return False
        if resp.status_code in (200, 202):
            log.info("started config-sync job %s (%s)", self._job, resp.status_code)
            return True
        log.warning("config-sync job start returned %s", resp.status_code)
        return False
