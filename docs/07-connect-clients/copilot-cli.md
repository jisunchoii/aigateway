> 읽는 사람: 개발자 (GitHub Copilot CLI 사용자) · 선행: 07-connect-clients/overview.md

# GitHub Copilot CLI (GHCP CLI) 연동

GHCP CLI를 Azure provider 모드로 설정하여 게이트웨이를 통해 모델을 호출합니다. 환경 변수 `COPILOT_PROVIDER_*` 블록으로 구성하며, `/openai` 경로를 사용합니다.

---

## 사전 준비

- GitHub Copilot CLI 최신 버전 설치
- Admin UI에서 발급한 APIM 구독 키 (`<APIM subscription key>`)
- `terraform output -raw apim_gateway_url` 로 확인한 APIM 호스트 (`<apim-host>`)

---

## 환경 변수 설정

터미널에서 다음 환경 변수를 설정합니다.

```bash
export COPILOT_PROVIDER_TYPE=azure
export COPILOT_PROVIDER_BASE_URL=https://<apim-host>
export COPILOT_PROVIDER_API_KEY="<APIM subscription key>"
export COPILOT_PROVIDER_AZURE_API_VERSION=2025-01-01-preview
export COPILOT_PROVIDER_WIRE_API=completions
export COPILOT_PROVIDER_MODEL_ID=gpt-5.4
export COPILOT_PROVIDER_WIRE_MODEL=gpt-5.4
```

> **중요:** `COPILOT_PROVIDER_BASE_URL` 에 `/openai` 를 포함하지 마십시오. CLI가 azure provider 모드에서 경로를 자동으로 구성합니다. 예를 들어 `https://<apim-host>/openai` 로 설정하면 경로가 중복되어 요청이 실패합니다.

---

## 동작 방식

- CLI가 azure provider 모드일 때 내부적으로 `<COPILOT_PROVIDER_BASE_URL>/openai/deployments/<model>/chat/completions?api-version=<version>` 형태로 URL을 조립합니다.
- APIM은 `/openai` 경로에서 URL 내 모델명을 추출하여 요청 body의 `model` 필드에 주입한 뒤 백엔드로 전달합니다.
- `COPILOT_PROVIDER_API_KEY` 는 APIM의 `Ocp-Apim-Subscription-Key` 헤더로 전달됩니다.

---

## 모델 변경

다른 모델을 사용하려면 `COPILOT_PROVIDER_MODEL_ID` 와 `COPILOT_PROVIDER_WIRE_MODEL` 을 함께 변경합니다.

```bash
export COPILOT_PROVIDER_MODEL_ID=gpt-5.4-mini
export COPILOT_PROVIDER_WIRE_MODEL=gpt-5.4-mini
```

Admin UI에서 해당 소비자의 허용 모델 목록에 변경할 모델이 포함되어 있는지 확인하십시오.

---

## 연결 확인

환경 변수 설정 후 GHCP CLI를 사용하여 간단한 쿼리를 실행합니다.

```bash
gh copilot explain "git rebase"
```

오류가 발생하는 경우:

1. `COPILOT_PROVIDER_BASE_URL` 에 `/openai` 가 포함되어 있지 않은지 확인합니다.
2. 구독 키가 유효한지 Admin UI에서 재확인합니다.
3. 오류 코드 의미는 [10-reference/gotchas.md](../10-reference/gotchas.md)를 참조하십시오.

---

## 참고 링크

- [GitHub Copilot CLI — About Copilot CLI](https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli)
- [Azure API Management — 구독 키](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)
