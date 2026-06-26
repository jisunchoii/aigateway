---
description: 개발자·운영자를 위한 페이지 · 선행: 07-connect-clients/overview.md
---

# 직접 호출 (curl / REST)

APIM 게이트웨이를 curl이나 REST 클라이언트로 직접 호출합니다. `/foundry` 경로를 사용하며, 요청 body에 `model` 을 포함하고 `Ocp-Apim-Subscription-Key` 헤더로 구독 키를 전달합니다.

---

## 기본 호출 형식

```bash
curl -s -X POST https://<apim-host>/foundry/chat/completions \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: <APIM subscription key>" \
  -d '{
    "model": "gpt-5.4",
    "messages": [
      { "role": "user", "content": "Hello, how are you?" }
    ]
  }'
```

{% hint style="info" %}
`<apim-host>` 는 `terraform output -raw apim_gateway_url` 로 확인합니다. `<APIM subscription key>` 는 Admin UI의 Consumers 탭에서 발급합니다.
{% endhint %}

---

## OSS/파트너 모델 호출

`model` 필드에 Foundry에 배포된 모델명을 그대로 넣으면 됩니다.

```bash
curl -s -X POST https://<apim-host>/foundry/chat/completions \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: <APIM subscription key>" \
  -d '{
    "model": "grok-4.3",
    "messages": [
      { "role": "user", "content": "Explain quantum entanglement briefly." }
    ],
    "max_completion_tokens": 200
  }'
```

---

## 응답 확인

정상 응답은 HTTP 200이며, OpenAI chat completions 형식의 JSON이 반환됩니다.

모델 전환이 발생한 경우 응답 헤더에서 확인할 수 있습니다.

```bash
curl -s -i -X POST https://<apim-host>/foundry/chat/completions \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: <APIM subscription key>" \
  -d '{ "model": "gpt-5.4", "messages": [{"role":"user","content":"Hi"}] }' \
  | grep -E "x-ai-gateway"
```

| 헤더 | 설명 |
|---|---|
| `x-ai-gateway-requested-model` | 요청한 모델 |
| `x-ai-gateway-effective-model` | 실제 사용된 모델 |
| `x-ai-gateway-downgrade-level` | 모델 전환 단계 (0=없음, 1=80%, 2=100%) |

---

## 오류 응답 의미

| HTTP 상태 | 의미 |
|---|---|
| 403 Forbidden | 구독 키가 없거나 유효하지 않음, 또는 해당 모델이 소비자 허용 목록에 없음 |
| 429 Too Many Requests | 토큰 레이트 리밋 또는 일별 쿼터 초과 |
| 401 Unauthorized | 인증 실패 |
| 500 / 502 | 백엔드 오류 |

{% hint style="info" %}
403은 구독 키 문제이거나 해당 소비자에게 모델 사용 권한이 없는 경우이고, 429는 레이트 리밋 또는 일별 쿼터 초과입니다. 상세 원인과 해결 방법은 [10-reference/gotchas.md](../10-reference/gotchas.md)를 참조하십시오.
{% endhint %}

---

## 스모크 테스트 스크립트

여러 모델을 한꺼번에 확인하려면 제공된 스모크 테스트 스크립트를 사용합니다.

```bash
./scripts/smoke-v1-gateway.sh <apim-host> <subscription-key>
```

이 스크립트는 gpt-5.4(`/openai` 경로), grok-4.3, DeepSeek-V4-Pro(`/foundry` 경로)에 각각 HTTP 200 응답을 확인합니다. 상세는 [05-verify/smoke-test.md](../05-verify/smoke-test.md)를 참조하십시오.

---

## 참고 링크

- [Azure API Management — 게이트웨이 요청 처리](https://learn.microsoft.com/en-us/azure/api-management/api-management-key-concepts)
- [Azure API Management — 구독 키](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)
