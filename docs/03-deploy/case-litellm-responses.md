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

## 4. 이미지 빌드

LiteLLM 공식 이미지 위에 `app/litellm/config.yaml`을 구워 넣은 이미지를 ACR로 빌드합니다(ACR은 APIM 배포 단계에서 준비되어 있어야 합니다). config가 이미지에 포함되므로 Container App은 볼륨 마운트가 필요 없습니다.

```bash
reg=$(terraform output -raw registry_name)
az acr build --registry "$reg" --image litellm:main-stable ../app/litellm
```

{% hint style="info" %}
`app/litellm/Dockerfile`은 `FROM ghcr.io/berriai/litellm:main-stable`에 `config.yaml`만 COPY합니다. 업스트림 버전을 올리려면 Dockerfile의 태그를 바꾼 뒤 다시 빌드하세요.
{% endhint %}

## 5. LiteLLM config

LiteLLM 설정은 이미지에 함께 빌드되는 `app/litellm/config.yaml`에 있습니다. backend 인증은 **관리 ID 기반**(`use_azure_ad: true`)이고 API 키를 넣지 않습니다. backend 엔드포인트는 Container App이 환경 변수(`AOAI_API_BASE`, `FOUNDRY_API_BASE`)로 주입하므로 config에는 `os.environ/...`로만 참조합니다.

```yaml
model_list:
  - model_name: gpt-5.4                 # native Responses passthrough
    litellm_params:
      model: azure/gpt-5.4
      api_base: os.environ/AOAI_API_BASE
      api_version: "2025-04-01-preview"
      use_azure_ad: true
  - model_name: grok-4.3                # Responses→Chat 브리지
    litellm_params:
      model: azure_ai/grok-4.3
      api_base: os.environ/FOUNDRY_API_BASE
      use_azure_ad: true
      use_chat_completions_api: true
  - model_name: DeepSeek-V4-Pro         # Responses→Chat 브리지
    litellm_params:
      model: azure_ai/DeepSeek-V4-Pro
      api_base: os.environ/FOUNDRY_API_BASE
      use_azure_ad: true
      use_chat_completions_api: true

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY   # APIM<->LiteLLM 홉 인증
```

{% hint style="info" %}
새 partner/OSS 모델을 추가하면 `app/litellm/config.yaml`에 `use_chat_completions_api: true` 항목으로 추가한 뒤 이미지를 다시 import/build하세요. gpt 계열은 `use_azure_ad: true`만으로 native passthrough입니다.
{% endhint %}

## 6. 배포 (tfvars 한 줄)

이미지·관리 ID·backend RBAC·APIM `/responses` route·master key는 모두 Terraform이 자동 생성합니다. `litellm_image`만 설정하면 활성화됩니다(빈 문자열이면 전체 비활성).

```hcl
# infra/terraform.tfvars
litellm_image = "<registry_login_server>/litellm:main-stable"
```

```bash
cd infra
terraform apply
```

Terraform이 자동으로 처리하는 것:

| 항목 | 리소스 |
|---|---|
| LiteLLM 관리 ID | `id-litellm-<suffix>` (identity 모듈) |
| backend RBAC | `litellm_to_openai`(OpenAI User) + `litellm_to_foundry`(Cognitive Services User) |
| Container App | `ca-litellm-<suffix>` (control_plane 모듈, 내부 ingress :4000) |
| APIM route | `/responses` API + 와일드카드 POST + 정책 |
| 홉 인증 | `random_password` → LiteLLM `master_key` + APIM named value(secret) |

{% hint style="info" %}
backend RBAC는 APIM 관리 ID에 부여한 것과 동일한 역할입니다(OpenAI User + Cognitive Services User). LiteLLM이 backend를 직접 호출하므로 자신의 관리 ID에도 같은 역할이 필요하며, Terraform이 함께 생성합니다.
{% endhint %}

## 7. 라우팅 동작

APIM `/responses` API는 `foundry` API와 같은 **와일드카드 프록시 + 정책** 패턴을 따르되, 백엔드가 Azure가 아니라 LiteLLM Container App입니다.

* Codex `base_url = https://<apim-host>/responses`, `wire_api = "responses"` → Codex는 `{base_url}/responses`로 POST
* APIM이 `responses` path prefix를 제거, 와일드카드 오퍼레이션이 나머지 `/responses`를 매치, `service_url`(`.../v1`)로 backend 경로는 `.../v1/responses` = LiteLLM canonical route
* 정책은 foundry 거버넌스(consumerId, allowed-models 403, downgrade ladder, token-limit, metric)를 그대로 재사용하되 **백엔드 auth만** cognitiveservices MI 토큰 대신 LiteLLM master key(`Authorization: Bearer {{litellm-master-key}}`)를 주입

{% hint style="warning" %}
`litellm_image`를 비운 채 두면 `/responses` API 자체가 생성되지 않아 Codex가 404를 받습니다. 브리지 전체가 `litellm_image` 하나로 on/off됩니다.
{% endhint %}

## 8. 검증

`terraform output -raw responses_endpoint`가 Codex `base_url`입니다. Codex는 `{base_url}/responses`로 POST하므로, 스모크 테스트도 실제 경로(`/responses/responses`)를 그대로 호출합니다.

```bash
base=$(terraform output -raw responses_endpoint)   # https://<apim-host>/responses
key="<APIM subscription key>"

# native (gpt-5.4)
curl -s -X POST "$base/responses" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: $key" \
  -d '{ "model": "gpt-5.4", "input": "Reply with the single word: pong" }'

# bridge (grok-4.3) — LiteLLM이 Chat으로 변환
curl -s -X POST "$base/responses" \
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
