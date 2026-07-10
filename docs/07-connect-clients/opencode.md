---
description: OpenCode — opencode.json으로 APIM OpenAI-compatible endpoint 연결
---

# OpenCode

OpenCode에서 APIM 게이트웨이를 통해 `gpt-5.6-sol`과 partner/OSS 모델(`FW-GLM-5.2`, `DeepSeek-V4-Pro`, `grok-4.3`)을 사용하도록 설정합니다. APIM 경유 시에는 OpenCode의 **OpenAI-compatible custom provider**를 사용합니다.

## 1. 선택 기준

{% hint style="success" %}
**이 경로가 맞는 경우**

* OpenCode에서 `opencode.json` provider 설정을 사용할 수 있다.
* APIM subscription key를 환경 변수나 별도 파일로 관리할 수 있다.
* gpt 계열은 `/openai/deployments/<model>`, partner/OSS 모델은 `/foundry` 경로로 호출한다.
{% endhint %}

## 2. 준비값

| 값                         | 예시                                               |
| ------------------------- | ------------------------------------------------ |
| APIM host                 | `https://<apim-host>`                            |
| APIM subscription key     | `<APIM subscription key>`                        |
| API version               | `2025-01-01-preview`                             |
| gpt 계열 APIM base URL      | `https://<apim-host>/openai/deployments/gpt-5.6-sol` |
| partner/OSS APIM base URL | `https://<apim-host>/foundry`                    |

APIM subscription key는 환경 변수로 둘 수 있습니다.

```bash
export AI_GATEWAY_API_KEY="<APIM subscription key>"
```

{% hint style="warning" %}
APIM subscription key를 `opencode.json`, dotfiles, Git 저장소에 평문으로 커밋하지 마세요. 아래 예시는 OpenCode의 `{env:...}` 치환을 사용합니다. 별도 파일을 쓰는 경우 `{file:/path/to/key}`로 바꿀 수 있습니다.
{% endhint %}

## 3. 설정 파일

OpenCode global config는 Linux 기준 `~/.config/opencode/opencode.json`에 둡니다.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "aigateway-openai/gpt-5.6-sol",
  "small_model": "aigateway-openai/gpt-5.6-sol",
  "provider": {
    "aigateway-openai": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "AI Gateway APIM OpenAI",
      "options": {
        "baseURL": "https://<apim-host>/openai/deployments/gpt-5.6-sol",
        "queryParams": {
          "api-version": "2025-01-01-preview"
        },
        "headers": {
          "api-key": "{env:AI_GATEWAY_API_KEY}"
        }
      },
      "models": {
        "gpt-5.6-sol": {
          "name": "GPT-5.6 Sol via APIM",
          "tool_call": true
        }
      }
    },
    "aigateway": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "AI Gateway APIM",
      "options": {
        "baseURL": "https://<apim-host>/foundry",
        "headers": {
          "Ocp-Apim-Subscription-Key": "{env:AI_GATEWAY_API_KEY}"
        }
      },
      "models": {
        "FW-GLM-5.2": {
          "name": "GLM 5.2 via APIM",
          "tool_call": true
        },
        "DeepSeek-V4-Pro": {
          "name": "DeepSeek V4 Pro via APIM",
          "tool_call": true
        },
        "grok-4.3": {
          "name": "Grok 4.3 via APIM",
          "tool_call": true
        }
      }
    }
  }
}
```

{% hint style="info" %}
OpenCode의 OpenAI-compatible provider는 `baseURL` 뒤에 `/chat/completions`를 붙입니다. 그래서 gpt 계열은 `/openai`까지만 쓰지 않고 `/openai/deployments/<model>`까지 base URL에 포함합니다.
{% endhint %}

## 4. 동작 방식

| 항목                | gpt 계열                                                         | partner/OSS 모델                                    |
| ----------------- | -------------------------------------------------------------- | ------------------------------------------------- |
| OpenCode model ID | `aigateway-openai/gpt-5.6-sol`                                 | `aigateway/FW-GLM-5.2`, `aigateway/DeepSeek-V4-Pro`, `aigateway/grok-4.3` |
| APIM base URL     | `/openai/deployments/<model>`                                  | `/foundry`                                        |
| 실제 요청 경로          | `/openai/deployments/<model>/chat/completions?api-version=...` | `/foundry/chat/completions`                       |
| APIM 인증           | `api-key`                                                      | `Ocp-Apim-Subscription-Key`                       |
| 모델 위치             | URL의 deployment segment                                        | body `model`                                      |

OpenCode는 gpt 요청에도 `max_tokens`를 보낼 수 있습니다. `/openai` policy는 이를 gpt-5 계열이 요구하는 `max_completion_tokens`로 변환합니다.

## 5. Azure provider와 Azure Cognitive Services provider

| OpenCode provider        | 기본 endpoint 전제                                          | 환경 변수                                                                        | APIM 경유 권장  |
| ------------------------ | ------------------------------------------------------- | ---------------------------------------------------------------------------- | ----------- |
| Azure                    | `https://<resource>.openai.azure.com/openai/...`        | `AZURE_RESOURCE_NAME`, `AZURE_API_KEY`                                       | 기본 권장 아님    |
| Azure Cognitive Services | `https://<resource>.cognitiveservices.azure.com/...` 계열 | `AZURE_COGNITIVE_SERVICES_RESOURCE_NAME`, `AZURE_COGNITIVE_SERVICES_API_KEY` | 기본 권장 아님    |
| custom OpenAI-compatible | 사용자가 지정한 `baseURL`                                      | 사용자 정의                                                                       | APIM 경유 기본값 |

OpenCode에서 **Azure Cognitive Services**가 보이는 것은 정상입니다. 다만 APIM gateway는 원본 Azure resource endpoint가 아니며, `/openai`와 `/foundry` facade별로 header와 path가 다릅니다. APIM 경유 기본값은 custom OpenAI-compatible provider입니다.

## 6. 모델 변경

처음 실행할 때 `--model`로 지정할 수 있습니다.

```bash
opencode --model aigateway-openai/gpt-5.6-sol
```

OpenCode TUI 안에서는 `/model` 명령으로도 전환할 수 있습니다. 모델 목록에서 `aigateway-openai/gpt-5.6-sol`, `aigateway/FW-GLM-5.2`, `aigateway/DeepSeek-V4-Pro`, `aigateway/grok-4.3` 중 하나를 선택합니다.

<figure><img src="../.gitbook/assets/opencode-model-picker.png" alt="OpenCode TUI에서 /model 명령으로 APIM provider 모델을 선택하는 화면"><figcaption><p>OpenCode `/model` 모델 선택 — APIM 경유 provider 확인</p></figcaption></figure>

CLI에서 바로 partner/OSS 모델로 시작할 수도 있습니다.

```bash
opencode --model aigateway/DeepSeek-V4-Pro
opencode --model aigateway/FW-GLM-5.2
opencode --model aigateway/grok-4.3
```

Admin UI에서 해당 consumer의 allowed models에 선택한 모델이 포함되어 있어야 합니다.

## 7. 검증

단순 `pong` 테스트보다, OpenCode의 멀티에이전트 동작과 서브에이전트 호출을 각각 확인하는 시나리오를 권장합니다.

```bash
opencode --model aigateway-openai/gpt-5.6-sol
```

OpenCode TUI에서 아래 프롬프트를 입력합니다.

```
멀티에이전트 방식으로 검증해줘.
Agent 1은 docs/07-connect-clients/opencode.md를 읽고 APIM path/header 설정이 맞는지 확인해.
Agent 2는 README.md, docs/07-connect-clients.md, docs/SUMMARY.md를 읽고 OpenCode 링크와 목차가 맞는지 확인해.
파일은 수정하지 말고, 각 agent의 확인 결과와 최종 결론만 한국어로 짧게 정리해줘.
```

partner/OSS 경로도 스크린샷에 포함하려면 `/model`로 `aigateway/FW-GLM-5.2`, `aigateway/DeepSeek-V4-Pro`, `aigateway/grok-4.3` 중 하나로 전환한 뒤 같은 프롬프트를 한 번 더 실행합니다.

| 멀티에이전트 검증                                                                                     | 서브에이전트 검증                                                                                   |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| ![OpenCode TUI에서 APIM 경유 모델로 멀티에이전트 검증을 수행하는 화면](../.gitbook/assets/opencode-multi-agent.png) | ![OpenCode TUI에서 APIM 경유 모델로 서브에이전트 검증을 수행하는 화면](../.gitbook/assets/opencode-sub-agent.png) |

## 8. 참고 링크

* [OpenCode — Providers](https://opencode.ai/docs/providers/)
* [OpenCode — Config](https://opencode.ai/docs/config/)
* [AI SDK — OpenAI Compatible Providers](https://ai-sdk.dev/providers/openai-compatible-providers)
* [Azure API Management — Subscriptions](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)
