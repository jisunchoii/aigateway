---
description: 보안 담당자·플랫폼 엔지니어를 위한 페이지 · 선행: 모듈 구조
---

# 보안 설계 — Passwordless 전 구간

llm-gateway는 API 키·연결 문자열·비밀번호를 어디에도 저장하지 않는다. 모든 서비스 간 인증은 [Azure 관리 ID(Managed Identity)](https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/overview)와 [Azure RBAC](https://learn.microsoft.com/en-us/azure/role-based-access-control/overview)으로 처리하며, 네트워크 경계는 Private Endpoint로 격리한다.

---

## 1. 백엔드 격리 — Private Endpoint + 로컬 인증 비활성화

| 리소스 | Private Endpoint | local_auth |
|---|---|---|
| Azure AI Foundry (AIServices) | 게이트웨이 VNet 내 PE 생성 | `disableLocalAuth=true` |
| Azure OpenAI (greenfield) | 게이트웨이 VNet 내 PE 생성 | `disableLocalAuth=true` |

{% hint style="success" %}
`disableLocalAuth=true`이면 API 키로는 호출 자체가 불가능하다. APIM의 관리 ID가 Entra ID 토큰을 제시해야만 백엔드에 도달할 수 있다.
{% endhint %}

Brownfield(reuse) 모드에서는 배포 전 `az` 명령으로 기존 계정에도 동일한 설정을 적용하고, Terraform precondition이 이를 검증한다. ([계정 잠금 준비](../04-reuse-foundry/prepare-account.md))

---

## 2. APIM → 백엔드 인증 (관리 ID + RBAC)

APIM 인스턴스는 시스템 할당 관리 ID를 가진다. 이 ID에 아래 두 가지 Azure 내장 역할이 부여된다.

| 역할 | 대상 리소스 | 목적 |
|---|---|---|
| `Cognitive Services OpenAI User` | AIServices / Azure OpenAI 계정 | 채팅·완성 API 호출 |
| `Cognitive Services User` | AIServices / Azure OpenAI 계정 | 계정 메타데이터 읽기 (선택) |

역할 부여는 `modules/identity`에서 `azurerm_role_assignment`로 처리한다. 수동 작업이 없으며, Terraform이 APIM 관리 ID를 참조하여 배포 시 자동으로 할당한다.

([Azure RBAC for Cognitive Services](https://learn.microsoft.com/en-us/azure/ai-services/role-based-access-control))

---

## 3. 컨트롤 플레인 인증 (worker·Admin UI)

| 컴포넌트 | 인증 방식 | 부여 역할 |
|---|---|---|
| config-sync worker (Container App Job) | 시스템 할당 관리 ID | Cosmos DB: `Cosmos DB Built-in Data Contributor` (데이터 롤) |
| config-sync worker | 동일 관리 ID | Log Analytics Reader (모니터링 메트릭 읽기) |
| Admin UI BFF (FastAPI) | 시스템 할당 관리 ID | Cosmos DB 데이터 롤 |
| Admin UI SPA | Entra ID PKCE (사용자 로그인) | admin 보안 그룹 멤버십으로 접근 제어 |

{% hint style="info" %}
Cosmos DB 데이터 평면 롤 (`Cosmos DB Built-in Data Contributor`)은 컨트롤 플레인이 설정 문서를 읽고 쓸 수 있도록 한다. 연결 문자열이나 마스터 키를 사용하지 않는다.
{% endhint %}

([Azure Cosmos DB RBAC](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-setup-rbac))

---

## 4. 시크릿 관리 — Key Vault

Key Vault는 `modules/keyvault`가 생성하며, Private Endpoint와 RBAC 접근으로 보호된다.

| 저장 항목 | 저장소 |
|---|---|
| 인증서, 비밀 값 등 진짜 시크릿 | Azure Key Vault |
| allowed_models, token limits 등 비시크릿 설정 | Cosmos DB + APIM Named Values |
| API 키·연결 문자열 | **저장하지 않음** |

APIM Named Values는 Key Vault 참조 형식으로 시크릿을 간접 참조할 수 있다. config-sync worker가 Cosmos에서 읽은 값을 APIM Named Values로 동기화한다.

([Azure Key Vault 개요](https://learn.microsoft.com/en-us/azure/key-vault/general/overview)) · ([APIM Key Vault 참조](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties#key-vault-secrets))

---

## 5. 네트워크 격리

모든 백엔드(AIServices, Cosmos DB, ACR, Key Vault)는 퍼블릭 네트워크 접근이 비활성화되거나 VNet 서브넷으로만 접근이 허용된다. APIM은 `apim_public=true`일 때만 인터넷에 노출되며, 백엔드는 항상 Private Endpoint 경유로만 통신한다.

([Azure Private Link 개요](https://learn.microsoft.com/en-us/azure/private-link/private-link-overview))

---

## 보안 원칙 요약

{% hint style="info" %}
- **키 없음**: API 키, 연결 문자열, SAS 토큰이 코드·설정·git 히스토리 어디에도 없음
- **최소 권한**: 각 컴포넌트는 자신의 업무에 필요한 역할만 보유
- **네트워크 경계**: 백엔드는 Private Endpoint + 퍼블릭 네트워크 차단
- **감사 추적**: 모든 Entra ID 토큰 발급·RBAC 변경은 Azure 감사 로그에 기록
{% endhint %}

---

## 관련 페이지

- [정책 흐름](policy-flow.md) — 런타임 MI 인증이 정책 파이프라인 마지막 단계에서 실행되는 이유
- [Cosmos DB 설정 스키마](cosmos-schema.md) — config-sync worker의 Cosmos 접근 구조
- [C — Entra ID 클라이언트 인증](../09-future/extension-c-entra-client-auth.md) — 클라이언트 측 키 없는 인증 확장
