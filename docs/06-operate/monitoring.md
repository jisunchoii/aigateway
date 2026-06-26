---
description: 게이트웨이 운영자를 위한 페이지 · 선행: 06-operate/config-changes.md
---

# 모니터링

Admin UI의 **Monitoring** 페이지와 Azure Application Insights를 통해 게이트웨이의 요청 현황, 차단 이벤트, 모델 전환 이벤트를 실시간으로 파악할 수 있습니다.

---

## 1. Admin UI Monitoring 페이지

***

Monitoring 페이지에는 세 가지 테이블이 제공됩니다.

| 테이블 | 내용 |
|---|---|
| **최근 요청(Recent Requests)** | 소비자별 API 호출 목록 (타임스탬프, 소비자 ID, 모델, 상태 코드, 사용 토큰) |
| **차단 이벤트(Blocked Events)** | 403·429 응답 목록 (차단 사유: 모델 비허용·레이트 리밋 초과) |
| **모델 전환 이벤트(Model Downgrade Events)** | 예산 기반 모델 전환이 발생한 요청 목록 |

{% hint style="info" %}
UI 상의 한국어 용어는 **"모델 전환"** 입니다. 코드 식별자(`downgrade_ladder`, `active_downgrade`, `downgrade_level`)는 원문 그대로 사용됩니다.
{% endhint %}

---

## 2. 모델 전환 이벤트 추적

***

모델 전환이 발생한 요청은 응답 헤더에 다음 세 가지 값이 포함됩니다.

| 헤더 | 설명 |
|---|---|
| `x-ai-gateway-requested-model` | 클라이언트가 요청한 원래 모델 |
| `x-ai-gateway-effective-model` | 실제로 호출된 모델 (전환 후 모델) |
| `x-ai-gateway-downgrade-level` | 전환 단계 (0=전환 없음, 1=80% 임계, 2=100% 임계) |

모델 전환 이벤트 테이블에서 이 세 헤더 값을 함께 확인할 수 있습니다. 예산 설정 및 전환 사다리 상세는 [cost-management.md](cost-management.md)를 참조하십시오.

---

## 3. Application Insights 토큰 메트릭

***

게이트웨이는 APIM 정책에서 처리된 토큰 수를 Application Insights로 내보냅니다. 다음 두 가지 차원으로 집계됩니다.

- **consumerId**: 소비자 단위 토큰 사용량
- **model**: 모델 단위 토큰 사용량

### 주요 커스텀 메트릭

| 메트릭 이름 | 설명 |
|---|---|
| `llm_total_tokens` | 소비자+모델 차원의 전체 토큰 수 |
| `llm_prompt_tokens` | 입력(프롬프트) 토큰 수 |
| `llm_completion_tokens` | 출력(컴플리션) 토큰 수 |

Application Insights에서 쿼리 예시:

```kusto
customMetrics
| where name == "llm_total_tokens"
| summarize sum(value) by tostring(customDimensions.consumerId), bin(timestamp, 1h)
| order by timestamp desc
```

{% hint style="info" %}
Application Insights 리소스는 Terraform이 자동으로 생성하며, Workspace 기반(Log Analytics) 모드로 구성됩니다.
{% endhint %}

---

## 4. 알림 설정

***

Application Insights에서 임계값 기반 알림을 구성하면 레이트 리밋 초과나 오류율 급증 시 이메일·Teams 알림을 받을 수 있습니다.

- [Azure Monitor 경고 규칙](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview)
- [Application Insights — 커스텀 메트릭](https://learn.microsoft.com/en-us/azure/azure-monitor/app/api-custom-events-metrics)
- [Azure API Management — 분석 및 모니터링](https://learn.microsoft.com/en-us/azure/api-management/howto-use-analytics)
