---
description: 아키텍트·플랫폼 엔지니어를 위한 페이지 · 선행: 없음
---

# 무엇인가

## 1. 한 문장 요약

***

Azure AI Gateway는 [Azure API Management](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-key-concepts) 위에 구축된 **엔터프라이즈 AI 거버넌스 엔드포인트**입니다. 다수의 LLM 백엔드를 단일 진입점 뒤에 숨기고, 소비자별 권한·속도 제한·예산 제어를 중앙에서 일괄 적용합니다.

## 2. 문제 정의

***

기업 내 여러 팀이 각자 Azure OpenAI나 Azure AI Foundry 모델을 직접 호출하면 다음 문제가 생깁니다.

- **키 관리 분산** — 팀마다 API 키를 별도로 발급·보관하면 키 유출·키 회전이 어렵습니다.
- **비용 통제 불가** — 어느 팀이 얼마나 쓰는지 집계할 중심 지점이 없습니다.
- **모델 거버넌스 없음** — 특정 팀에 특정 모델만 허용하거나 사용량을 제한할 방법이 없습니다.
- **백엔드 교체 영향** — 모델 배포가 바뀌면 모든 클라이언트 설정을 함께 변경해야 합니다.

Azure AI Gateway는 이 모든 문제를 **단일 거버넌스 레이어** 하나로 해결합니다.

## 3. 무엇을 제공하는가

***

| 기능 | 설명 |
|---|---|
| 단일 엔드포인트 | `https://<apim-host>` 하나로 gpt-5.4, gpt-5.4-mini, grok-4.3, DeepSeek-V4-Pro 모두 접근 |
| 소비자별 모델 허용 목록 | 허용되지 않은 모델 요청 → 403 반환 |
| 토큰 속도 제한 | rate-tier별 분당 토큰 상한, 초과 → 429 반환 |
| 예산 기반 모델 전환 | 월 예산 소진 시 고비용 모델을 저비용 모델로 자동 전환 |
| Passwordless 백엔드 | APIM → AIServices 구간은 Managed Identity + RBAC, 키 인증 비활성화 |
| Private Endpoint | APIM → AIServices 구간은 공인 인터넷 미경유 |
| 셀프서비스 Admin UI | React SPA + FastAPI BFF, Entra ID 로그인, 관리자 그룹 게이트 |
| 통합 관찰성 | [Application Insights](https://learn.microsoft.com/ko-kr/azure/azure-monitor/app/app-insights-overview)로 토큰 메트릭·오류율·지연 시간 수집 |

## 4. 아키텍처 개요

***

<figure><img src="../images/architecture.png" alt=""><figcaption><p>아키텍처 개요</p></figcaption></figure>

백엔드는 **Azure AI Foundry(AIServices)** 단일 계정입니다. gpt-5.4 계열은 `azurerm_cognitive_account`(`/openai/v1` 경로)로, grok-4.3·DeepSeek-V4-Pro 등 OSS/파트너 모델은 같은 계정의 Foundry 배포로 제공합니다. 모든 백엔드 호출은 동일한 `/openai/v1/chat/completions` 형식을 사용하며, 클라이언트 쪽 입구 형식(path-route vs body-route)은 APIM 정책이 변환합니다.

## 5. 누구를 위한 것인가

***

- **플랫폼/인프라 팀** — Terraform으로 게이트웨이 스택을 배포·운영합니다.
- **개발팀** — APIM 구독 키 하나로 허용된 모델에 접근합니다. 백엔드 주소나 키를 직접 관리할 필요가 없습니다.
- **아키텍트·보안 담당자** — 모든 AI 트래픽의 중앙 감사·제어 지점을 확보합니다.

## 6. 관련 Azure 서비스 문서

***

- [Azure API Management](https://learn.microsoft.com/ko-kr/azure/api-management/api-management-key-concepts)
- [Azure OpenAI Service](https://learn.microsoft.com/ko-kr/azure/ai-services/openai/overview)
- [Azure AI Foundry](https://learn.microsoft.com/ko-kr/azure/ai-foundry/what-is-azure-ai-foundry)
- [Azure Private Endpoint](https://learn.microsoft.com/ko-kr/azure/private-link/private-endpoint-overview)
