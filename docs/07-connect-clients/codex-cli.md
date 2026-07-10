---
description: "Codex CLI — Responses API provider로 APIM 게이트웨이(/responses) 연결"
---

# Codex CLI

OpenAI Codex CLI를 custom model provider로 설정해 APIM 게이트웨이를 통과하도록 구성합니다. Codex CLI는 **Responses API 전용**(`wire_api = "responses"`)입니다. 게이트웨이의 `/responses` 경로는 Codex proxy sidecar가 payload를 정규화한 뒤 같은 AIServices `codexproj` project의 `/openai/v1/responses`로 전달합니다.

{% hint style="warning" %}
**이 가이드는 `gpt-5.6-sol` 전용입니다.** Codex CLI는 OpenAI 자사 모델(gpt/o-series)에 최적화돼 있어, grok·DeepSeek 같은 비gpt reasoning 모델은 native Responses를 지원하더라도 Codex에서 간헐적 mid-session 스트리밍 실패가 발생합니다(Codex의 알려진 한계 — [openai/codex#28742](https://github.com/openai/codex/issues/28742), [#16397](https://github.com/openai/codex/issues/16397) 등, 게이트웨이·backend 문제 아님). **grok·DeepSeek을 코딩 에이전트로 쓰려면 [OpenCode](opencode.md)**(Chat Completions 기반, `/foundry` 경로)**를 사용하세요.**
{% endhint %}

{% hint style="info" %}
`/responses`는 `/foundry`·`/openai`와 같은 APIM API로, 동일한 거버넌스 정책과 관리 ID(Managed Identity) 인증을 사용합니다. 차이는 `/responses`만 Codex proxy sidecar를 거쳐 Responses payload를 정규화한다는 점입니다.
{% endhint %}

## 1. 선택 기준

{% hint style="success" %}
**이 경로가 맞는 경우**

* OpenAI Codex CLI를 **gpt-5.6-sol**로 사용한다.
* `codex` 명령을 실행하고 `~/.codex/config.toml`을 편집할 수 있다.
* Responses API 기반 에이전트 워크플로가 필요하다.

**맞지 않는 경우**: grok·DeepSeek 등 비gpt 모델을 쓰려면 [OpenCode](opencode.md)를 사용하세요.
{% endhint %}

## 2. 준비값

| 값                     | 예시                        |
| --------------------- | ------------------------- |
| APIM host             | `https://<apim-host>`     |
| APIM subscription key | `<APIM subscription key>` |
| APIM 경로               | `/responses`              |
| 인증 헤더                 | `Ocp-Apim-Subscription-Key` |

APIM subscription key는 환경 변수로 둡니다.

```bash
export GATEWAY_KEY="<APIM subscription key>"
```

{% hint style="warning" %}
APIM subscription key를 `config.toml`, dotfiles, Git 저장소에 평문으로 커밋하지 마세요. 아래 `env_http_headers`는 **환경 변수 이름**만 담고, 실제 키는 환경 변수로 주입합니다.
{% endhint %}

## 3. 설정 파일

Codex global config는 `~/.codex/config.toml`에 둡니다.

```toml
model = "gpt-5.6-sol"
model_provider = "aigateway"

[model_providers.aigateway]
name = "AI Gateway (Responses)"
base_url = "https://<apim-host>/responses"
wire_api = "responses"

# APIM은 subscription key를 Ocp-Apim-Subscription-Key 헤더로 받습니다. http_headers 값은 리터럴
# 문자열이라 ${VAR} 치환이 안 되므로, 환경 변수는 반드시 env_http_headers로 전달합니다.
# env_http_headers는 "헤더 이름 -> 환경 변수 이름" 매핑입니다(값이 아니라 변수 이름).
[model_providers.aigateway.env_http_headers]
"Ocp-Apim-Subscription-Key" = "GATEWAY_KEY"
```

{% hint style="info" %}
`wire_api`는 `"responses"`가 유일한 값입니다(Codex CLI는 chat completions wire 포맷을 더 이상 지원하지 않습니다). gpt 계열은 native Responses를 완전 지원하며 Codex와 안정적으로 동작합니다.
{% endhint %}

{% hint style="warning" %}
`http_headers`(리터럴)와 `env_http_headers`(환경 변수 이름 매핑)는 다릅니다. `http_headers`에 `"${GATEWAY_KEY}"`처럼 적으면 치환되지 않고 문자열 그대로 전송되어 401이 납니다. 환경 변수로 주입하려면 위처럼 `env_http_headers`를 사용하세요.
{% endhint %}

## 4. 동작 방식

| 항목       | 값                                                      |
| -------- | ------------------------------------------------------ |
| base URL | `/responses` (APIM → Codex proxy → AIServices project) |
| 요청 경로    | Codex가 `base_url` + `/responses` 호출 → APIM이 Codex proxy로 전달 → proxy가 `/openai/v1/responses` 호출 |
| APIM 인증  | `Ocp-Apim-Subscription-Key` 헤더                         |
| backend 인증 | APIM 관리 ID(Entra ID) → AIServices 계정 (키 없음)          |
| 라우팅      | 요청 body `model` 필드로 backend deployment 선택              |

Codex가 보내는 요청은 항상 Responses 포맷이며, gpt 계열 backend가 native Responses를 지원하므로 hosted tool(`web_search`)과 function tool을 포함해 그대로 전달됩니다.

## 5. 모델별 지원 매트릭스

| 모델              | Codex 지원 | 비고                                        |
| --------------- | --------- | ----------------------------------------- |
| `gpt-5.6-sol`  | ✅ 권장     | native Responses + sidecar normalization, Codex와 안정적 동작 |
| `grok-4.3`      | ❌ 비권장   | 간헐적 mid-session 실패 → [OpenCode](opencode.md) 사용 |
| `DeepSeek-V4-Pro` | ❌ 비권장 | 간헐적 mid-session 실패 → [OpenCode](opencode.md) 사용 |

{% hint style="warning" %}
grok·DeepSeek은 AIServices 계정에서 native Responses를 지원하고 게이트웨이·backend 관점에선 정상 동작합니다(curl 반복 호출 100% 완주 확인). 그러나 **Codex CLI 클라이언트가 비gpt reasoning 모델과 상성이 나빠** 간헐적으로 스트림이 중단됩니다(`stream disconnected before completion`). 이는 Codex의 알려진 한계이며([openai/codex#28742](https://github.com/openai/codex/issues/28742) 등 다수 open 이슈), 게이트웨이에서 해결할 수 없습니다. 이 모델들은 Chat Completions 기반 클라이언트인 **[OpenCode](opencode.md)** 로 쓰세요.
{% endhint %}

{% hint style="info" %}
Fireworks 서빙 등 **partner/community 카테고리 OSS 모델**(예: GLM)은 배포 capability상 Chat Completions만 노출하지만, Foundry **project 경로**(`/api/projects/<project>/openai/v1/responses`)로는 native Responses가 동작할 수 있습니다. 다만 Codex가 보내는 payload를 backend가 받는 형태로 변환해야 하며, 현재 정식 게이트웨이 경로는 `gpt-5.6-sol`만 지원합니다. 실험용 로컬 프록시는 [부록: GLM/DeepSeek 로컬 실험 경로](#부록-glmdeepseek-로컬-실험-경로)를 참고하세요.
{% endhint %}

## 6. 검증

gpt 계열 모델로 실행해 응답을 확인합니다.

```bash
codex -m gpt-5.6-sol "Reply with the single word: pong"
```

Codex TUI 안에서는 `/model` 슬래시 명령으로도 `gpt-5.6-sol`을 선택할 수 있습니다. Admin UI에서 해당 consumer의 allowed models에 선택한 모델이 포함되어 있어야 합니다.

<figure><img src="../.gitbook/assets/codex-cli-responses.png" alt="Codex CLI에서 APIM /responses 경유로 gpt-5.6-sol 응답을 받는 터미널 화면"><figcaption><p>Codex CLI 실행 결과 — APIM <code>/responses</code> + Codex proxy 경유 응답 (실제 터미널 스크린샷으로 교체하세요)</p></figcaption></figure>

APIM을 실제로 거쳤는지는 Application Insights 요청 로그로 확인합니다.

```bash
az monitor app-insights query -g <rg> -a <appinsights-name> \
  --analytics-query "requests | where timestamp > ago(10m) | where name contains 'responses' | project timestamp, name, resultCode | order by timestamp desc" \
  -o table
```

<figure><img src="../.gitbook/assets/codex-cli-appinsights.png" alt="Application Insights에서 POST /responses/responses 요청이 200으로 기록된 화면"><figcaption><p>Application Insights — <code>POST /responses/responses</code> 200 기록 (실제 스크린샷으로 교체하세요)</p></figcaption></figure>

오류가 발생하면 아래를 확인합니다.

* `base_url`이 `/responses`로 끝나는지
* `GATEWAY_KEY` 환경 변수가 올바른 APIM subscription key인지 (현재 셸 세션에 설정돼 있어야 함)
* `env_http_headers`로 `Ocp-Apim-Subscription-Key`를 전달하는지 (`http_headers` 리터럴 아님)
* 선택한 모델(`gpt-5.6-sol`)이 consumer allowed models에 포함되어 있는지

| HTTP 상태 | 의미 |
|---|---|
| 401 | 인증 실패 (subscription key 헤더 누락/오설정) |
| 403 | 구독 키 무효 또는 모델 미허용 |
| 404 | `/responses` 경로 미배포 (APIM 배포 확인) |
| 429 | token rate limit 또는 quota 초과 |

## 7. 참고 링크

* [Codex CLI — Config reference](https://developers.openai.com/codex/config-reference)
* [Foundry Models sold by Azure — GPT-5.6](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure#gpt-56)
* [Responses API supported models](https://learn.microsoft.com/azure/foundry/openai/how-to/responses#supported-models)
* [Authenticate with managed identity](https://learn.microsoft.com/azure/api-management/api-management-authenticate-authorize-ai-apis#authenticate-with-managed-identity)
* [Azure API Management — Subscriptions](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)

## 부록: GLM/DeepSeek 로컬 실험 경로

{% hint style="danger" %}
**실험적 · 로컬 전용 · APIM 거버넌스 우회.** 아래 프록시는 정식 온보딩 경로가 아닙니다. Codex를 Fireworks 서빙 모델(GLM·DeepSeek)로 구동하려는 개발 검증용이며, consumerId·allowed-models·rate limit·budget downgrade 등 게이트웨이 거버넌스가 **적용되지 않습니다**. 프로덕션·다중 사용자 용도가 아닙니다.
{% endhint %}

Codex는 Responses 전용이면서 OpenAI 고유의 툴 shape(`local_shell`, `custom`=apply_patch, `namespace`=multi_agent_v1)와 필드(`text.verbosity`, `include: reasoning.encrypted_content`)를 보냅니다. Foundry의 OpenAI 호환 계층은 이를 거부하므로, 로컬 번역 프록시가 backend가 받는 형태로 변환합니다. 스크립트: `app/codex-proxy/foundry_codex_proxy.py` (stdlib만, 의존성 없음).

### 프록시가 수행하는 변환

| 항목 | 처리 | 이유 |
|---|---|---|
| `local_shell` / `custom` 툴 | 표준 `function` 툴로 변환 | backend가 이 타입 거부 (400) |
| `namespace`(multi_agent_v1) 툴 | nested 툴을 top-level로 flatten + 응답에서 `namespace` 복원 | namespace 타입은 backend 5xx(`server_error` mid-stream) 유발. 이름만 flatten하면 Codex가 `unsupported call`. |
| `input`의 `reasoning`·`web_search_call` 아이템 | 히스토리에서 제거 | backend가 거부 — [openai/codex#24612](https://github.com/openai/codex/issues/24612) (웹서치 후 다음 턴 400의 원인) |
| `text.verbosity` | `medium`으로 치환 | backend가 `medium`만 허용 |
| `include: reasoning.encrypted_content` | 제거 | gpt o-series 전용 메타데이터, backend 400 |
| `reasoning.effort` | GLM은 유지, DeepSeek은 제거 | 모델별 허용 형태가 다름 |
| Entra 토큰 | 프록시가 `az account get-access-token`으로 자동 주입·갱신(401 시 강제 재시도) | 세션 중 만료 방지 |

### 사용법

```powershell
# 1) 프록시 실행 (별도 터미널). az login 되어 있어야 하고, 대상 Foundry 계정에 Cognitive Services 데이터플레인 역할 필요.
python app/codex-proxy/foundry_codex_proxy.py   # 127.0.0.1:8789

# 2) Codex 설정: model_providers.foundryproxy (base_url = http://127.0.0.1:8789/v1, wire_api = responses)
#    프로필 glm/deepseek.config.toml — model, model_provider="foundryproxy",
#    model_supports_reasoning_summaries=true (미지 slug fallback을 뚫고 reasoning object 전송)

# 3) 실행 (workspace-write 필수 — 없으면 파일 쓰기 거부)
$env:FOUNDRY_TOKEN = "placeholder"   # 프록시가 실제 토큰 주입, codex는 env_key만 요구
codex --profile deepseek --sandbox workspace-write "..."
```

`ROUTES`에 모델→Foundry 엔드포인트 매핑이 있습니다. body의 `model`은 변경하지 않으므로, 이 프록시를 향후 APIM `/responses` 뒤에 두면 body-`model` 기반 거버넌스가 그대로 동작합니다(사이드카 승격 시).

### 한계

* **거버넌스 없음** (위 danger 참고).
* Codex↔비gpt reasoning 모델의 간헐적 mid-session 스트림 중단은 프록시로 해결되지 않습니다(Codex 클라이언트 한계).
* `codex-rs` 버전에 따라 툴 shape이 바뀔 수 있습니다(검증 기준: `rust-v0.143.0`).
