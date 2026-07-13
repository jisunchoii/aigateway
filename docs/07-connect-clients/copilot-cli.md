---
description: GitHub Copilot CLI — Azure provider로 통합 /openai/v1 게이트웨이 연결
---

# GitHub Copilot CLI

GitHub Copilot CLI 1.0.70을 Azure provider 모드로 설정해 APIM 게이트웨이를 통과하도록 구성합니다. `COPILOT_PROVIDER_AZURE_API_VERSION`을 설정하지 않으면 CLI가 통합 `/openai/v1/chat/completions` 경로를 사용합니다.

## 1. 선택 기준

{% hint style="success" %}
**이 경로가 맞는 경우**

* GitHub Copilot CLI를 사용한다.
* standalone `copilot` 명령을 실행할 수 있다.
* CLI의 Azure provider 환경 변수를 설정할 수 있다.
* 기본 모델을 하나 정해 CLI 세션에서 사용한다.
{% endhint %}

## 2. 준비값

| 값                     | 예시                        |
| --------------------- | ------------------------- |
| APIM host             | `https://<apim-host>`     |
| APIM subscription key | `<APIM subscription key>` |
| API version           | 설정하지 않음                  |
| APIM 경로               | `/openai/v1/chat/completions` |

`copilot --help`가 실행되는지 먼저 확인합니다. `COPILOT_PROVIDER_BASE_URL`을 설정하는 BYOK 모드에서는 custom provider 모델을 명시해 실행합니다.

## 3. 환경 변수 설정

```bash
export COPILOT_PROVIDER_TYPE=azure
export COPILOT_PROVIDER_BASE_URL=https://<apim-host>
export COPILOT_PROVIDER_API_KEY="<APIM subscription key>"
unset COPILOT_PROVIDER_AZURE_API_VERSION
export COPILOT_PROVIDER_WIRE_API=completions
export COPILOT_PROVIDER_MODEL_ID=FW-GLM-5.2
export COPILOT_PROVIDER_WIRE_MODEL=FW-GLM-5.2
```

{% hint style="warning" %}
`COPILOT_PROVIDER_BASE_URL`에는 APIM host만 넣고 `COPILOT_PROVIDER_AZURE_API_VERSION`은 반드시 unset 상태로 유지하세요. API version을 설정하면 CLI가 구형 Azure deployment 경로를 조립해 현재 통합 API와 맞지 않습니다.
{% endhint %}

{% hint style="info" %}
APIM 미경유로 Foundry 엔드포인트를 직접 테스트할 때는 `COPILOT_PROVIDER_TYPE=openai`, base URL `https://<리소스이름>.services.ai.azure.com/openai/v1`로 두고, API key 대신 Entra ID bearer token을 쓸 수 있습니다. bearer token은 API key보다 우선 적용되며 만료가 짧아 새 터미널마다 재발급해야 합니다. 두 값을 동시에 설정하지 마세요(`unset COPILOT_PROVIDER_API_KEY`).

```bash
export COPILOT_PROVIDER_BEARER_TOKEN=$(az account get-access-token \
  --scope https://ai.azure.com/.default --query accessToken -o tsv)
export COPILOT_PROVIDER_TYPE=openai
export COPILOT_PROVIDER_BASE_URL=https://<리소스이름>.services.ai.azure.com/openai/v1
export COPILOT_MODEL=<배포이름>
```
{% endhint %}

## 4. 동작 방식

| 항목       | 값 |
| -------- | --- |
| base URL | APIM host만 입력 |
| 요청 경로    | `/openai/v1/chat/completions` |
| APIM 인증  | `api-key` 헤더 |
| 모델 선택  | `COPILOT_PROVIDER_MODEL_ID`와 `COPILOT_PROVIDER_WIRE_MODEL` |

Copilot CLI가 보내는 API key는 APIM subscription key입니다. APIM 정책은 요청 body의 `model`을 기준으로 허용 모델, rate limit, budget switch를 적용합니다.

## 5. 모델 변경

검증된 네 canonical 모델 중 하나를 선택하고 두 환경 변수 값을 함께 맞춥니다.

```bash
export COPILOT_PROVIDER_MODEL_ID=FW-GLM-5.2
export COPILOT_PROVIDER_WIRE_MODEL=FW-GLM-5.2
```

Admin UI에서 해당 consumer의 allowed models에 선택한 모델이 포함되어 있어야 합니다.

{% hint style="info" %}
BYOK 모델은 GitHub 호스팅 카탈로그에 등록되지 않으므로 `/model` 목록에 안 보일 수 있습니다. `COPILOT_MODEL=<배포이름>`(또는 실행 시 `--model <배포이름>`)으로 직접 지정하세요. 호스팅 모델은 세션 중 `/model`로 전환하지만 BYOK는 환경 변수로 지정하는 것이 명확합니다.
{% endhint %}

## 6. 검증

```bash
copilot --model FW-GLM-5.2 --secret-env-vars=COPILOT_PROVIDER_API_KEY
```

오류가 발생하면 아래를 확인합니다.

* `COPILOT_PROVIDER_BASE_URL`이 APIM host로만 구성됐는지
* `COPILOT_PROVIDER_AZURE_API_VERSION`이 unset 상태인지
* `COPILOT_PROVIDER_API_KEY`가 올바른 APIM subscription key인지
* `COPILOT_PROVIDER_MODEL_ID`와 `COPILOT_PROVIDER_WIRE_MODEL`이 같은 모델인지
* 해당 모델이 consumer allowed models에 포함되어 있는지
* `copilot --help`가 실행되는지

## 7. 참고 링크

* [GitHub Copilot CLI](https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli)
* [Azure API Management — Subscriptions](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)
* [Microsoft Foundry Models endpoints and keyless authentication](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/endpoints#keyless-authentication)
