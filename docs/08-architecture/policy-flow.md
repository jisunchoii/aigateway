---
description: 아키텍트·플랫폼 엔지니어를 위한 페이지 · 선행: 배포 개요
---

# APIM 정책 파이프라인 — 정책 흐름

Azure API Management의 인바운드 정책은 클라이언트 요청을 백엔드로 전달하기 전에 일련의 단계를 순서대로 실행한다. 이 페이지는 llm-gateway가 각 요청에 적용하는 정책 파이프라인을 단계별로 설명한다.

---

## 입구 형식 — 두 가지 진입 경로

클라이언트는 두 가지 형식으로 요청을 보낼 수 있다.

| 입구 API | 입구 URL 예시 | model 위치 | 정책 처리 |
|---|---|---|---|
| `/openai` (path-route) | `/openai/deployments/gpt-5.4/chat/completions?api-version=…` | URL 경로 | URL에서 model 추출 → body `"model"` 필드에 주입 |
| `/foundry` (body-route) | `/foundry/chat/completions` | 요청 body | 거의 그대로 통과 |

두 경로 모두 백엔드 URL은 `/openai/v1/chat/completions`로 정규화된다(`?api-version` 파라미터 제거, v1 통일).

---

## 정책 파이프라인 단계

아래 순서는 APIM inbound 정책 실행 순서를 그대로 따른다.

### 1단계 — consumerId 도출

모든 거버넌스 집계의 기준축인 `consumerId`를 결정한다.

| `client_auth_mode` | 인증 수단 | consumerId 도출 방법 |
|---|---|---|
| `subscription-key` (기본값) | APIM 구독 키 | 구독의 **표시명(display name)** |
| `entra-id` | JWT (Entra ID 토큰) | JWT claim 값 (예: `sub`, custom app-role 등) |

`subscription-key` 모드에서는 `Ocp-Apim-Subscription-Key` 헤더를 검증한 뒤 해당 구독의 표시명을 `consumerId`로 사용한다. `entra-id` 모드에서는 `validate-jwt` 정책으로 토큰을 검증하고 지정된 JWT claim을 `consumerId`로 추출한다. ([APIM validate-jwt 정책](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy))

### 2단계 — allowed-models 검사

요청 body의 `"model"` 값을 해당 consumer의 허용 모델 목록(`allowed_models`)과 대조한다. 목록에 없는 모델이면 정책이 즉시 **HTTP 403**을 반환하고 이후 단계는 실행되지 않는다.

허용 모델 목록은 Cosmos DB에서 APIM Named Values로 동기화된 값을 사용한다. config-sync worker가 `*/5 * * * *` 주기로 갱신한다.

### 3단계 — 토큰 기반 속도 제한 (rate limit)

`llm-token-limit` 정책으로 **토큰 소비 속도**를 제어한다.

- 초과 시 **HTTP 429** 반환
- counter key = `consumerId` (소비자별 독립 버킷)
- 제한 값은 `tokens_per_minute` 변수와 `rate_tiers(small/medium/large)` 설정으로 결정된다

([Azure APIM 토큰 한도 정책](https://learn.microsoft.com/en-us/azure/api-management/azure-openai-token-limit-policy))

### 4단계 — 예산 기반 모델 전환

config-sync worker가 일일 사용량 × 단가를 계산하여 `active_downgrade.level`을 Cosmos에 기록하면, APIM 정책은 이 값을 Named Value에서 읽어 body의 `"model"` 필드를 `downgrade_ladder`에 따라 재작성한다.

예: `active_downgrade.level=1`이면 `gpt-5.4` → `gpt-5.4-mini`로 body를 덮어쓴다.

모델 전환은 **항상 동일 백엔드** 내에서 일어난다(v1 통일로 백엔드 URL 변경 없음, body의 `"model"` 값만 교체). 응답 헤더 `x-ai-gateway-requested-model` / `x-ai-gateway-effective-model` / `x-ai-gateway-downgrade-level`이 추가되어 클라이언트가 실제 전환 여부를 확인할 수 있다.

코드 식별자: `downgrade_ladder`, `active_downgrade`, `downgrade_level`.

### 5단계 — 토큰 메트릭 기록

`llm-emit-token-metric` 정책으로 Application Insights에 토큰 소비량을 기록한다. 기록하는 차원(dimension)에 `consumerId`가 포함되어 대시보드에서 소비자별 집계가 가능하다.

([Azure APIM llm-emit-token-metric 정책](https://learn.microsoft.com/en-us/azure/api-management/llm-emit-token-metric-policy))

### 6단계 — 관리 ID 백엔드 인증 (마지막)

`authentication-managed-identity` 정책이 APIM의 시스템 할당 관리 ID로 Entra ID 토큰을 취득하여 `Authorization: Bearer <token>` 헤더를 백엔드 요청에 첨부한다.

{% hint style="info" %}
이 단계가 **파이프라인 마지막**에 위치하는 이유는 앞 단계에서 body rewrite가 완료된 뒤에 인증 토큰을 붙여야 하기 때문이다. 순서를 앞당기면 body 재작성 후 토큰이 재첨부되지 않아 백엔드 인증이 실패할 수 있다.
{% endhint %}

백엔드는 키 인증이 비활성화(`local_auth=false`)되어 있으므로 관리 ID 토큰 없이는 도달할 수 없다.

([APIM authentication-managed-identity 정책](https://learn.microsoft.com/en-us/azure/api-management/authentication-managed-identity-policy))

---

## 파이프라인 요약 다이어그램

```
클라이언트 요청
    │
    ▼
[1] consumerId 도출
    (구독키=표시명 / entra-id=JWT claim)
    │
    ▼
[2] allowed-models 검사 ──── 미허용 ──▶ HTTP 403
    │
    ▼
[3] 토큰 rate limit ─────── 초과 ──────▶ HTTP 429
    │
    ▼
[4] 예산 모델 전환
    (downgrade_ladder 따라 body "model" 재작성)
    │
    ▼
[5] 토큰 메트릭 기록
    (llm-emit-token-metric → App Insights)
    │
    ▼
[6] MI 백엔드 인증
    (authentication-managed-identity)
    │
    ▼
백엔드 /openai/v1/chat/completions
```

---

## 관련 페이지

- [보안 설계](security-design.md) — 관리 ID RBAC 설정 상세
- [Cosmos DB 설정 스키마](cosmos-schema.md) — `downgrade_ladder` / `active_downgrade` 문서 구조
- [모듈 구조](module-structure.md) — APIM 모듈과 정책 파일 위치
- [설정 변경](../06-operate/config-changes.md) — allowed-models·rate-limit 런타임 변경 방법
