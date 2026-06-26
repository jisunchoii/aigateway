---
description: 아키텍트·플랫폼 엔지니어를 위한 페이지 · 선행: 배포 개요
---

# APIM 정책 파이프라인 — 정책 흐름

{% hint style="info" %}
**6단계 파이프라인 요약**
① **consumerId** 도출 → ② **allowed_models** 검사(미허용 → 403) → ③ 토큰 rate limit(초과 → 429) → ④ **downgrade_ladder**로 예산 모델 전환(**active_downgrade** 적용) → ⑤ 토큰 메트릭 기록 → ⑥ 관리 ID 백엔드 인증
{% endhint %}

Azure API Management의 인바운드 정책은 클라이언트 요청을 백엔드로 전달하기 전에 일련의 단계를 순서대로 실행합니다. 이 페이지는 llm-gateway가 각 요청에 적용하는 정책 파이프라인을 단계별로 설명합니다.

<!-- diagram: policy-pipeline -->
<div style="display:flex; flex-direction:column; gap:6px; font-family:'Segoe UI','Noto Sans KR',sans-serif; margin:16px 0; max-width:480px;">
  <div style="background:#EEF6FC; border-left:4px solid #0078D4; border-radius:4px; padding:10px 14px;">
    <span style="font-size:11px; color:#0078D4; font-weight:700; letter-spacing:1px;">CLIENT</span>
    <div style="font-size:13px; color:#0a2540; font-weight:600; margin-top:2px;">클라이언트 요청</div>
  </div>
  <div style="text-align:center; color:#0078D4; font-size:13px; font-weight:700;">▼</div>
  <div style="background:#0a2540; border-radius:4px; padding:10px 14px; color:#fff;">
    <span style="font-size:11px; color:#5AC8FA; font-weight:700; letter-spacing:1px;">① IDENTITY</span>
    <div style="font-size:13px; font-weight:600; margin-top:2px;">consumerId 도출</div>
    <div style="font-size:11.5px; color:#dce6f0; margin-top:4px;">구독키=표시명 / Entra ID=JWT claim</div>
  </div>
  <div style="text-align:center; color:#0078D4; font-size:13px; font-weight:700;">▼</div>
  <div style="background:#0a2540; border-radius:4px; padding:10px 14px; color:#fff; display:flex; justify-content:space-between; align-items:center;">
    <div>
      <span style="font-size:11px; color:#5AC8FA; font-weight:700; letter-spacing:1px;">② AUTHZ</span>
      <div style="font-size:13px; font-weight:600; margin-top:2px;">allowed_models 검사</div>
    </div>
    <div style="background:#FFB454; color:#0a2540; font-weight:700; font-size:12px; border-radius:4px; padding:4px 10px;">미허용 → 403</div>
  </div>
  <div style="text-align:center; color:#0078D4; font-size:13px; font-weight:700;">▼</div>
  <div style="background:#0a2540; border-radius:4px; padding:10px 14px; color:#fff; display:flex; justify-content:space-between; align-items:center;">
    <div>
      <span style="font-size:11px; color:#5AC8FA; font-weight:700; letter-spacing:1px;">③ RATE LIMIT</span>
      <div style="font-size:13px; font-weight:600; margin-top:2px;">토큰 속도 제한</div>
    </div>
    <div style="background:#FFB454; color:#0a2540; font-weight:700; font-size:12px; border-radius:4px; padding:4px 10px;">초과 → 429</div>
  </div>
  <div style="text-align:center; color:#0078D4; font-size:13px; font-weight:700;">▼</div>
  <div style="background:#0a2540; border-radius:4px; padding:10px 14px; color:#fff;">
    <span style="font-size:11px; color:#5AC8FA; font-weight:700; letter-spacing:1px;">④ DOWNGRADE</span>
    <div style="font-size:13px; font-weight:600; margin-top:2px;">예산 모델 전환</div>
    <div style="font-size:11.5px; color:#dce6f0; margin-top:4px;">downgrade_ladder → body "model" 재작성</div>
  </div>
  <div style="text-align:center; color:#0078D4; font-size:13px; font-weight:700;">▼</div>
  <div style="background:#0a2540; border-radius:4px; padding:10px 14px; color:#fff;">
    <span style="font-size:11px; color:#5AC8FA; font-weight:700; letter-spacing:1px;">⑤ METRICS</span>
    <div style="font-size:13px; font-weight:600; margin-top:2px;">토큰 메트릭 기록</div>
    <div style="font-size:11.5px; color:#dce6f0; margin-top:4px;">llm-emit-token-metric → App Insights</div>
  </div>
  <div style="text-align:center; color:#0078D4; font-size:13px; font-weight:700;">▼</div>
  <div style="background:#EEF7F0; border-left:4px solid #107C41; border-radius:4px; padding:10px 14px;">
    <span style="font-size:11px; color:#107C41; font-weight:700; letter-spacing:1px;">⑥ AUTH</span>
    <div style="font-size:13px; color:#0a2540; font-weight:600; margin-top:2px;">관리 ID 백엔드 인증</div>
    <div style="font-size:11.5px; color:#1a1a2e; margin-top:4px;">authentication-managed-identity</div>
  </div>
  <div style="text-align:center; color:#107C41; font-size:13px; font-weight:700;">▼</div>
  <div style="background:#EEF7F0; border-left:4px solid #107C41; border-radius:4px; padding:10px 14px;">
    <span style="font-size:11px; color:#107C41; font-weight:700; letter-spacing:1px;">BACKEND</span>
    <div style="font-size:13px; color:#0a2540; font-weight:600; margin-top:2px;">백엔드 /openai/v1/chat/completions</div>
  </div>
</div>
<!-- /diagram -->

---

## 1. 입구 형식 — 두 가지 진입 경로

***

클라이언트는 두 가지 형식으로 요청을 보낼 수 있습니다.

| 입구 API | 입구 URL 예시 | model 위치 | 정책 처리 |
|---|---|---|---|
| `/openai` (path-route) | `/openai/deployments/gpt-5.4/chat/completions?api-version=…` | URL 경로 | URL에서 model 추출 → body `"model"` 필드에 주입 |
| `/foundry` (body-route) | `/foundry/chat/completions` | 요청 body | 거의 그대로 통과 |

두 경로 모두 백엔드 URL은 `/openai/v1/chat/completions`로 정규화됩니다(`?api-version` 파라미터 제거, v1 통일).

---

## 2. 정책 파이프라인 단계

***

아래 순서는 APIM inbound 정책 실행 순서를 그대로 따릅니다.

### 1단계 — consumerId 도출

모든 거버넌스 집계의 기준축인 **`consumerId`**를 결정합니다.

| `client_auth_mode` | 인증 수단 | consumerId 도출 방법 |
|---|---|---|
| `subscription-key` (기본값) | APIM 구독 키 | 구독의 **표시명(display name)** |
| `entra-id` | JWT (Entra ID 토큰) | JWT claim 값 (예: `sub`, custom app-role 등) |

`subscription-key` 모드에서는 `Ocp-Apim-Subscription-Key` 헤더를 검증한 뒤 해당 구독의 표시명을 `consumerId`로 사용합니다. `entra-id` 모드에서는 `validate-jwt` 정책으로 토큰을 검증하고 지정된 JWT claim을 `consumerId`로 추출합니다. ([APIM validate-jwt 정책](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy))

### 2단계 — allowed-models 검사

요청 body의 `"model"` 값을 해당 consumer의 허용 모델 목록(**`allowed_models`**)과 대조합니다. 목록에 없는 모델이면 정책이 즉시 **HTTP 403**을 반환하고 이후 단계는 실행되지 않습니다.

허용 모델 목록은 Cosmos DB에서 APIM Named Values로 동기화된 값을 사용합니다. config-sync worker가 `*/5 * * * *` 주기로 갱신합니다.

### 3단계 — 토큰 기반 속도 제한 (rate limit)

`llm-token-limit` 정책으로 **토큰 소비 속도**를 제어합니다.

- 초과 시 **HTTP 429** 반환
- counter key = `consumerId` (소비자별 독립 버킷)
- 제한 값은 `tokens_per_minute` 변수와 `rate_tiers(small/medium/large)` 설정으로 결정됩니다

([Azure APIM 토큰 한도 정책](https://learn.microsoft.com/en-us/azure/api-management/azure-openai-token-limit-policy))

### 4단계 — 예산 기반 모델 전환

config-sync worker가 일일 사용량 × 단가를 계산하여 **`active_downgrade`**.level을 Cosmos에 기록하면, APIM 정책은 이 값을 Named Value에서 읽어 body의 `"model"` 필드를 **`downgrade_ladder`**에 따라 재작성합니다.

예: `active_downgrade.level=1`이면 `gpt-5.4` → `gpt-5.4-mini`로 body를 덮어씁니다.

모델 전환은 **항상 동일 백엔드** 내에서 일어납니다(v1 통일로 백엔드 URL 변경 없음, body의 `"model"` 값만 교체). 응답 헤더 `x-ai-gateway-requested-model` / `x-ai-gateway-effective-model` / `x-ai-gateway-downgrade-level`이 추가되어 클라이언트가 실제 전환 여부를 확인할 수 있습니다.

코드 식별자: `downgrade_ladder`, `active_downgrade`, `downgrade_level`.

### 5단계 — 토큰 메트릭 기록

`llm-emit-token-metric` 정책으로 Application Insights에 토큰 소비량을 기록합니다. 기록하는 차원(dimension)에 `consumerId`가 포함되어 대시보드에서 소비자별 집계가 가능합니다.

([Azure APIM llm-emit-token-metric 정책](https://learn.microsoft.com/en-us/azure/api-management/llm-emit-token-metric-policy))

### 6단계 — 관리 ID 백엔드 인증 (마지막)

`authentication-managed-identity` 정책이 APIM의 시스템 할당 관리 ID로 Entra ID 토큰을 취득하여 `Authorization: Bearer <token>` 헤더를 백엔드 요청에 첨부합니다.

{% hint style="info" %}
이 단계가 **파이프라인 마지막**에 위치하는 이유는 앞 단계에서 body rewrite가 완료된 뒤에 인증 토큰을 붙여야 하기 때문입니다. 순서를 앞당기면 body 재작성 후 토큰이 재첨부되지 않아 백엔드 인증이 실패할 수 있습니다.
{% endhint %}

백엔드는 키 인증이 비활성화(`local_auth=false`)되어 있으므로 관리 ID 토큰 없이는 도달할 수 없습니다.

([APIM authentication-managed-identity 정책](https://learn.microsoft.com/en-us/azure/api-management/authentication-managed-identity-policy))

---

## 3. 파이프라인 요약 다이어그램

***

파이프라인 다이어그램은 이 페이지 상단(페이지 도입부 바로 아래)을 참고하세요.

---

## 4. 관련 페이지

***

- [보안 설계](security-design.md) — 관리 ID RBAC 설정 상세
- [Cosmos DB 설정 스키마](cosmos-schema.md) — `downgrade_ladder` / `active_downgrade` 문서 구조
- [모듈 구조](module-structure.md) — APIM 모듈과 정책 파일 위치
- [설정 변경](../06-operate/config-changes.md) — allowed-models·rate-limit 런타임 변경 방법
