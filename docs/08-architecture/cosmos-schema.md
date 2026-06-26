---
description: 플랫폼 엔지니어·운영 담당자를 위한 페이지 · 선행: 모듈 구조
---

# Cosmos DB 설정 스키마

llm-gateway는 Azure Cosmos DB를 **설정 저장소**로 사용한다. APIM 정책에 필요한 모든 거버넌스 설정(허용 모델, 토큰 한도, 예산, 가격)이 여기 저장되며, config-sync worker가 주기적으로 읽어 APIM Named Values로 동기화한다.

{% hint style="info" %}
Cosmos DB 계정은 Private Endpoint로 격리되고 키 인증이 비활성화된다. 모든 접근은 관리 ID + RBAC 데이터 롤로만 가능하다.
{% endhint %}

---

## 컨테이너 구조

| 컨테이너 | 파티션 키 | 주요 문서 |
|---|---|---|
| `config` | `/id` | `global` (전역 기본값), 소비자별 문서 |
| `pricing` | `/id` | `pricing` (모델별 토큰 단가) |

---

## 1. `global` 문서 (id = "global")

전체 소비자에게 적용되는 기본값을 정의한다. 소비자별 문서가 없으면 이 값이 적용된다.

```json
{
  "id": "global",
  "allowed_models": ["gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"],
  "token_limits": {
    "tokens_per_minute": 1000,
    "token_quota": 50000,
    "token_quota_period": "Daily"
  }
}
```

| 필드 | 설명 |
|---|---|
| `allowed_models` | 게이트웨이 전체에서 허용되는 기본 모델 목록 |
| `token_limits.tokens_per_minute` | 분당 토큰 속도 제한 기본값 |
| `token_limits.token_quota` | 기간당 토큰 할당량 기본값 |
| `token_limits.token_quota_period` | 할당량 초기화 주기 (`Daily` / `Monthly`) |

---

## 2. `pricing` 문서 (id = "pricing")

config-sync worker가 일일 예산 계산 시 사용하는 모델별 토큰 단가다. `seed-pricing-jumpbox.sh`로 초기화한다.

```json
{
  "id": "pricing",
  "per_1k_tokens": {
    "gpt-5.4": 0.015,
    "gpt-5.4-mini": 0.003,
    "grok-4.3": 0.009,
    "DeepSeek-V4-Pro": 0.005
  }
}
```

`per_1k_tokens` 값은 1,000 토큰당 USD 단가다. 이 값과 일일 토큰 사용량을 곱해 예산 소진율을 계산한다.

---

## 3. 소비자별 문서 (id = `<consumerId>`)

특정 소비자에 대해 전역 기본값을 덮어쓴다.

```json
{
  "id": "team-a",
  "allowed_models": ["gpt-5.4", "gpt-5.4-mini"],
  "tier": "medium",
  "daily_budget_usd": 50.0,
  "downgrade_ladder": [
    { "level": 0, "model": "gpt-5.4" },
    { "level": 1, "model": "gpt-5.4-mini" }
  ],
  "active_downgrade": {
    "level": 0,
    "updated_at": "2026-06-26T00:00:00Z"
  }
}
```

| 필드 | 설명 |
|---|---|
| `allowed_models` | 이 소비자에게만 허용되는 모델 (전역 기본값 override) |
| `tier` | rate tier (`small` / `medium` / `large`) |
| `daily_budget_usd` | 일일 USD 예산 한도 |
| `downgrade_ladder` | 레벨별 모델 전환 매핑 (level 0 = 원래 모델, 1+ = 예산 초과 시 전환) |
| `active_downgrade.level` | **현재 적용 중인 전환 레벨**. config-sync worker가 매 동기화 사이클에 갱신 |
| `active_downgrade.updated_at` | 레벨이 마지막으로 변경된 시각 (ISO 8601) |

`downgrade_ladder`의 `level` 값이 높을수록 저비용 모델로 전환된다. APIM 정책은 `active_downgrade.level`에 해당하는 `model` 값을 body에 주입한다.

---

## config-sync worker의 동기화 흐름

```
Cosmos DB (config 컨테이너)
    │
    │  1) 전역·소비자 문서 읽기
    ▼
config-sync worker (Container App Job)
    │
    │  2) 일일 사용량(App Insights) × pricing 단가 계산
    │     → active_downgrade.level 업데이트 (Cosmos 쓰기)
    │
    │  3) allowed_models, token limits, downgrade level
    │     → APIM Named Values 동기화
    ▼
APIM Named Values (정책 런타임에 참조)
```

동기화 주기: `config_sync_cron` 변수 (기본 `*/5 * * * *`, 5분마다).

---

## Seed 스크립트

초기 문서 삽입은 아래 스크립트로 수행한다. 두 스크립트 모두 jumpbox의 관리 ID를 이용한 passwordless 접근이다.

```bash
# global 설정 문서 초기화
./scripts/seed-cosmos-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/

# pricing 문서 초기화
./scripts/seed-pricing-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
```

자세한 실행 방법은 [Seed 및 최종 설정](../03-deploy/seed-and-finalize.md)을 참고한다.

---

## 관련 페이지

- [정책 흐름](policy-flow.md) — APIM이 Named Values에서 `active_downgrade.level`을 읽어 모델 전환하는 방법
- [보안 설계](security-design.md) — Cosmos DB RBAC 접근 구조
- [설정 변경](../06-operate/config-changes.md) — 런타임 중 소비자 문서 수정 방법
- [Seed 및 최종 설정](../03-deploy/seed-and-finalize.md) — seed 스크립트 실행 상세
