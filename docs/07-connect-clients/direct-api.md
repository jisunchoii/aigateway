---
description: "직접 API 호출 — curl 또는 REST Client로 통합 /openai/v1 경로 호출"
---

# 직접 API 호출

curl, REST Client, 애플리케이션 코드에서 APIM 게이트웨이를 직접 호출합니다. 모든 canonical 모델은 같은 `/openai/v1/chat/completions` 경로와 `api-key` 헤더를 사용하며, 요청 body의 `model`로 배포를 선택합니다.

## 1. 선택 기준

{% hint style="success" %}
**이 경로가 맞는 경우**

- 클라이언트 SDK 없이 HTTP 요청으로 gateway를 호출하고 싶다.
- 특정 모델만 빠르게 호출하고 싶다.
- 앱 코드에서 OpenAI-compatible chat completions 요청을 직접 보낼 수 있다.
{% endhint %}

## 2. 준비값

| 값 | 예시 |
|---|---|
| APIM host | `https://<apim-host>` |
| APIM subscription key | `<APIM subscription key>` |
| Chat Completions 경로 | `/openai/v1/chat/completions` |
| Responses 경로 | `/openai/v1/responses` |
| 인증 헤더 | `api-key` |

## 3. Chat Completions 호출

```bash
curl -s -X POST "https://<apim-host>/openai/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "api-key: <APIM subscription key>" \
  -d '{
    "model": "gpt-5.6-sol",
    "messages": [
      { "role": "user", "content": "Hello, how are you?" }
    ],
    "max_completion_tokens": 200
  }'
```

{% hint style="info" %}
gpt-5 계열 요청에는 `max_tokens` 대신 `max_completion_tokens`를 사용하세요.
{% endhint %}

## 4. Partner/OSS 모델 호출

```bash
curl -s -X POST https://<apim-host>/openai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "api-key: <APIM subscription key>" \
  -d '{
    "model": "grok-4.3",
    "messages": [
      { "role": "user", "content": "Explain quantum entanglement briefly." }
    ],
    "max_tokens": 200
  }'
```

## 5. 모델 전환 헤더 확인

budget switch로 모델 전환이 발생하면 응답 헤더에서 requested/effective model을 확인할 수 있습니다.

```bash
curl -s -i -X POST https://<apim-host>/openai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "api-key: <APIM subscription key>" \
  -d '{ "model": "grok-4.3", "messages": [{"role":"user","content":"Hi"}] }' \
  | grep -E "x-ai-gateway"
```

| 헤더 | 의미 |
|---|---|
| `x-ai-gateway-requested-model` | 클라이언트가 요청한 모델 |
| `x-ai-gateway-effective-model` | 실제 backend로 전달된 모델 |
| `x-ai-gateway-downgrade-level` | 모델 전환 단계 |

## 6. 오류 응답

| HTTP 상태 | 의미 |
|---|---|
| 401 | 인증 실패 |
| 403 | 구독 키가 없거나 유효하지 않음, 또는 모델 미허용 |
| 429 | token rate limit 또는 quota 초과 |
| 500/502 | backend 오류 |
