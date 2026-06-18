from bff.jobs import JobStarter


class FakeResp:
    def __init__(self, code):
        self.status_code = code


class FakeHttp:
    def __init__(self, code=202):
        self.calls = []
        self._code = code

    def post(self, url, headers=None, timeout=None):
        self.calls.append((url, headers))
        return FakeResp(self._code)


class FakeCred:
    def get_token(self, *scopes):
        class T:
            token = "tok"
        return T()


def test_start_posts_to_arm_job_start_url():
    http = FakeHttp(202)
    js = JobStarter(FakeCred(), http, sub="s", rg="rg", job="job-x")
    assert js.start() is True
    url, headers = http.calls[0]
    assert url.endswith("/providers/Microsoft.App/jobs/job-x/start?api-version=2024-03-01")
    assert "/subscriptions/s/resourceGroups/rg/" in url
    assert headers["Authorization"] == "Bearer tok"


def test_start_accepts_200():
    js = JobStarter(FakeCred(), FakeHttp(200), sub="s", rg="rg", job="job-x")
    assert js.start() is True


def test_start_returns_false_on_error_code():
    js = JobStarter(FakeCred(), FakeHttp(403), sub="s", rg="rg", job="job-x")
    assert js.start() is False


def test_start_noops_when_job_unset():
    http = FakeHttp(202)
    js = JobStarter(FakeCred(), http, sub="s", rg="rg", job="")
    assert js.start() is False
    assert http.calls == []  # never hit ARM


def test_start_swallows_exceptions():
    class BoomHttp:
        def post(self, *a, **k):
            raise RuntimeError("network down")
    js = JobStarter(FakeCred(), BoomHttp(), sub="s", rg="rg", job="job-x")
    assert js.start() is False  # logged, not raised
