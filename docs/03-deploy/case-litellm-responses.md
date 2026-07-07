---
description: "Responses 브리지(LiteLLM) 배포 — /responses 경로로 Codex CLI 지원, Responses↔Chat 변환"
---

# Responses 브리지(LiteLLM) 배포

이 페이지는 APIM 게이트웨이가 이미 배포된 상태에서 **Responses API 브리지(LiteLLM)** 를 추가하는 경로를 설명합니다. Codex CLI처럼 **Responses API 전용** 클라이언트를 붙이려면 게이트웨이가 `/responses` 엔드포인트를 노출해야 하는데, partner/OSS 모델(Grok·DeepSeek 등)은 Responses를 네이티브 지원하지 않으므로 LiteLLM이 Responses 요청을 Chat Completions로 변환합니다.

## 1. 선택 기준

{% hint style="success" %}
**이 경로가 맞는 경우**

* APIM 게이트웨이와 ACR이 이미 준비되어 있다.
* Codex CLI 등 Responses API 전용 클라이언트를 온보딩하고 싶다.
* gpt 계열과 partner/OSS 모델을 **하나의 Responses 엔드포인트**로 통일하고 싶다.
* partner/OSS 모델(Responses 미지원)을 Codex에서 쓰려면 브리지가 필요하다.
{% endhint %}

{% hint style="info" %}
gpt 계열만 Codex로 쓰면 되고 partner/OSS 모델이 필요 없다면, 이 브리지 없이 APIM `/openai` 경로를 Responses용으로 확장하는 것도 가능합니다. 하지만 두 부류를 한 provider로 통일하고 partner/OSS까지 지원하려면 LiteLLM 브리지가 가장 단순합니다.
{% endhint %}

## 2. 아키텍처

```
Codex CLI ──/responses──▶ APIM ──▶ LiteLLM ──┬─(native)──▶ Azure OpenAI /responses   (gpt-5.4)
        (wire_api=responses)   (거버넌스)      └─(bridge)──▶ Foundry /chat/completions (grok-4.3, DeepSeek-V4-Pro)
```

* **APIM을 앞단에 유지**: subscription key, rate/quota 정책, budget switch 헤더 같은 거버넌스가 모두 APIM에 있습니다. Codex를 LiteLLM에 직결하면 이 거버넌스를 우회하므로, 반드시 APIM `/responses` route를 거쳐 LiteLLM으로 보냅니다.
* **LiteLLM을 단일 Responses 표면으로**: 모델별 native/bridge 분기는 LiteLLM config가 흡수하고, Codex는 `wire_api = "responses"` 하나로 모든 모델을 씁니다.
* **인증은 Entra ID**: LiteLLM → Azure OpenAI/Foundry backend 호출은 API 키가 아니라 LiteLLM 컨테이너의 관리 ID(Managed Identity)로 인증합니다.

## 3. 모델별 라우팅

| 모델              | backend Responses 네이티브 | LiteLLM 처리                    |
| --------------- | ----------------------- | ----------------------------- |
| `gpt-5.4`       | ✅ 지원                    | passthrough (native responses) |
| `grok-4.3`      | ❌ 미지원                   | Responses→Chat 브리지            |
| `DeepSeek-V4-Pro` | ❌ 미지원                 | Responses→Chat 브리지            |

{% hint style="info" %}
Azure OpenAI Responses API는 gpt 계열만 네이티브 지원합니다. 새 partner/OSS 모델은 기본적으로 브리지 대상이며, LiteLLM config에서 `use_chat_completions_api: true`로 브리지를 강제합니다.
{% endhint %}

## 4. 이미지 준비

LiteLLM은 공식 이미지를 ACR로 미러링해 사용합니다(ACR은 APIM 배포 단계에서 준비되어 있어야 합니다).

```bash
reg=$(terraform output -raw registry_name)
az acr import --name "$reg" \
  --source ghcr.io/berriai/litellm:main-stable \
  --image litellm:main-stable
```

## 5. LiteLLM config

LiteLLM 설정은 `config.yaml`로 주입합니다. backend 인증은 **관리 ID 기반**(`azure_ad_token` 또는 `use_azure_ad`)으로 두고, API 키를 넣지 않습니다.

```yaml
model_list:
  # gpt 계열 — Responses 네이티브 passthrough
  - model_name: gpt-5.4
    litellm_params:
      model: azure/gpt-5.4
      api_base: https://<aoai-resource>.openai.azure.com
      api_version: "2025-04-01-preview"
      use_azure_ad: true          # Entra ID (Managed Identity) — 키 미사용

  # partner/OSS — Responses→Chat 브리지
  - model_name: grok-4.3
    litellm_params:
      model: azure_ai/grok-4.3
      api_base: https://<ais-resource>.services.ai.azure.com/openai/v1
      use_azure_ad: true
      use_chat_completions_api: true   # /responses 요청을 /chat/completions로 변환

  - model_name: DeepSeek-V4-Pro
    litellm_params:
      model: azure_ai/DeepSeek-V4-Pro
      api_base: https://<ais-resource>.services.ai.azure.com/openai/v1
      use_azure_ad: true
      use_chat_completions_api: true
```

{% hint style="warning" %}
`config.yaml`과 backend 엔드포인트에 API 키를 넣지 마세요. LiteLLM 컨테이너의 관리 ID에 backend RBAC(아래 §6)를 부여하면 키 없이 토큰으로 인증됩니다.
{% endhint %}

## 6. 배포 (Container App + 관리 ID + RBAC)

LiteLLM은 기존 control-plane과 동일하게 **Azure Container Apps**로 배포하고, **user-assigned 관리 ID**로 backend를 호출합니다. `infra/`에 아래 값을 넣고 apply합니다(모듈 변수명은 실제 구현에 맞춰 조정).

```hcl
litellm_image = "<registry_login_server>/litellm:main-stable"
```

관리 ID에 backend 데이터플레인 역할을 부여합니다(전역 인증 규칙: 키 아님).

```bash
# LiteLLM 관리 ID의 principalId
mi=$(terraform output -raw litellm_identity_principal_id)

# Azure OpenAI backend (gpt 계열)
az role assignment create --assignee-object-id "$mi" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" \
  --scope "$(terraform output -raw openai_account_id)"

# Foundry(AIServices) backend (partner/OSS 모델)
az role assignment create --assignee-object-id "$mi" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" \
  --scope "$(terraform output -raw foundry_account_id)"
```

{% hint style="info" %}
이 RBAC는 APIM 관리 ID에 부여한 것과 동일한 역할입니다(`apim_to_openai` = OpenAI User, `apim_to_foundry` = Cognitive Services User). LiteLLM은 backend를 직접 호출하므로 자신의 관리 ID에도 같은 역할이 필요합니다.
{% endhint %}

## 7. APIM `/responses` route 추가

APIM에 `/responses` API를 추가해 LiteLLM Container App으로 보냅니다. `foundry` API와 같은 **와일드카드 프록시 + 정책** 패턴을 따릅니다.

* `path = "responses"`, `service_url = "https://<litellm-app-fqdn>"`
* 와일드카드 POST 오퍼레이션(`url_template = "/*"`)
* 구독 키 헤더 `Ocp-Apim-Subscription-Key`
* 기존 foundry 정책 XML을 재사용해 teamId 카운터, allowed-models 검사, rate/quota를 동일하게 적용

{% hint style="warning" %}
`/responses` route를 추가하지 않으면 Codex는 404를 받습니다. LiteLLM만 배포하고 APIM route를 빠뜨리는 것이 가장 흔한 실수입니다.
{% endhint %}

## 8. 검증

```bash
apim=$(terraform output -raw apim_gateway_url)
key="<APIM subscription key>"

# native (gpt-5.4)
curl -s -X POST "$apim/responses" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: $key" \
  -d '{ "model": "gpt-5.4", "input": "Reply with the single word: pong" }'

# bridge (grok-4.3) — LiteLLM이 Chat으로 변환
curl -s -X POST "$apim/responses" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: $key" \
  -d '{ "model": "grok-4.3", "input": "Reply with the single word: pong" }'
```

| 확인 항목 | 기대 결과 |
|---|---|
| native 모델 응답 | `gpt-5.4`가 Responses 포맷으로 응답 |
| bridge 모델 응답 | `grok-4.3`·`DeepSeek-V4-Pro`가 브리지 경유로 응답 (400 없음) |
| backend 인증 | LiteLLM 로그에 키 미사용, 관리 ID 토큰으로 호출 |
| 거버넌스 | allowed models 밖 모델은 403, rate limit 초과 시 429 |

## 9. 다음 단계

| 목적 | 이동 |
|---|---|
| Codex CLI 연결 | [Codex CLI](../07-connect-clients/codex-cli.md) |
| 클라이언트 온보딩 허브 | [클라이언트 온보딩](../07-connect-clients.md) |
| 오류 코드 확인 | [문제 해결](../10-reference.md#4-문제-해결) |
