> 읽는 사람: 개발자 (opencode 사용자) · 선행: 07-connect-clients/overview.md

# opencode 연동

opencode는 `@ai-sdk/openai-compatible` 어댑터를 사용하며, `/foundry` 경로로 게이트웨이에 연결합니다. `opencode.json` 의 provider 블록에 APIM 호스트와 구독 키를 설정합니다.

---

## 사전 준비

- opencode 최신 버전 설치
- Admin UI에서 발급한 APIM 구독 키
- `terraform output -raw apim_gateway_url` 로 확인한 APIM 호스트 (`<apim-host>`)
- 환경 변수 `APIM_KEY` 에 구독 키 설정

```bash
export APIM_KEY="<APIM subscription key>"
```

---

## opencode.json 설정

프로젝트 루트 또는 홈 디렉터리의 `opencode.json` 에 다음 provider 블록을 추가합니다.

```json
{ "provider": { "apim": {
  "npm": "@ai-sdk/openai-compatible",
  "options": { "baseURL": "https://<apim-host>/foundry", "apiKey": "{env:APIM_KEY}" },
  "models": { "grok-4.3": { "name": "Grok 4.3" } }
}}}
```

> `<apim-host>` 를 실제 APIM 호스트명으로 교체하십시오. `apiKey` 는 `{env:APIM_KEY}` 형식으로 환경 변수를 참조하므로, 구독 키를 설정 파일에 직접 기입하지 않아도 됩니다.

---

## 동작 방식

- opencode는 `@ai-sdk/openai-compatible` 어댑터를 통해 OpenAI chat completions 형식의 요청을 보냅니다.
- `baseURL` 이 `/foundry` 로 끝나므로 실제 요청은 `POST https://<apim-host>/foundry/chat/completions` 형태가 됩니다.
- APIM의 `/foundry` 입구는 body에 포함된 `model` 필드를 그대로 사용합니다 (body-route).
- `apiKey` 는 `Ocp-Apim-Subscription-Key` 헤더로 전달됩니다.

---

## 모델 추가

`models` 객체에 다른 모델 엔트리를 추가하면 opencode UI에서 선택할 수 있습니다.

```json
"models": {
  "grok-4.3": { "name": "Grok 4.3" },
  "DeepSeek-V4-Pro": { "name": "DeepSeek V4 Pro" },
  "gpt-5.4": { "name": "GPT-5.4" },
  "gpt-5.4-mini": { "name": "GPT-5.4 Mini" }
}
```

Admin UI에서 해당 소비자의 허용 모델 목록에 추가할 모델이 포함되어 있는지 확인하십시오.

---

## 연결 확인

opencode를 실행하고 provider 목록에서 `apim` 이 표시되는지 확인합니다. 오류가 발생하는 경우:

1. `APIM_KEY` 환경 변수가 설정되어 있는지 확인합니다.
2. `baseURL` 에 `/foundry` 가 포함되어 있는지 확인합니다.
3. 오류 코드 의미는 [10-reference/gotchas.md](../10-reference/gotchas.md)를 참조하십시오.

---

## 참고 링크

- [opencode — Providers 문서](https://opencode.ai/docs/providers/)
- [Azure API Management — 구독 키](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)
