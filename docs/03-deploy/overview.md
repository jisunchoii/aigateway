> 읽는 사람: 운영자·DevOps 엔지니어 · 선행: [Greenfield vs Brownfield 결정](../02-prerequisites/decide-greenfield-vs-brownfield.md)

# 배포 개요

이 챕터는 llm-gateway를 Azure에 처음 배포하는 전체 흐름을 안내합니다. 배포는 크게 두 경로로 나뉩니다.

## 배포 경로 선택

| 경로 | 설명 | 언제 선택? |
|---|---|---|
| **Greenfield** | Azure OpenAI 계정과 모델 배포를 Terraform이 새로 생성 | 신규 구독 또는 기존 AIServices 계정 재사용 불필요 |
| **Brownfield** | 기존 AIServices(Foundry) 계정을 `data`로 읽어 재사용, PE·RBAC만 신규 생성 | 이미 운영 중인 Azure OpenAI/Foundry 계정이 있는 경우 |

Brownfield 경로를 선택했다면 이 챕터의 절차를 따른 뒤 [기존 Foundry 재사용](../04-reuse-foundry/overview.md) 챕터의 추가 준비 단계를 반드시 먼저 완료하십시오.

## 전체 배포 단계

1. **상태 백엔드 부트스트랩** — 구독당 1회, Terraform 원격 state 저장소 생성 ([→ 상세](bootstrap-state.md))
2. **tfvars 구성** — 배포 대상 구독·위치·비용 센터 등 핵심 변수 설정 ([→ 상세](configure-tfvars.md))
3. **첫 번째 `terraform apply`** — 코어 인프라(APIM, VNet, Cosmos, ACR, Jumpbox) 배포, 약 45분 ([→ 상세](first-apply.md))
4. **이미지 빌드·푸시** — ACR remote build로 worker/admin-ui 컨테이너 이미지 빌드 ([→ 상세](build-push-images.md))
5. **앱 등록 및 두 번째 apply** — Entra ID 앱 등록 후 나머지 컨테이너 앱 배포 ([→ 상세](app-registration-second-apply.md))
6. **Seed 및 최종 설정** — Cosmos DB 초기 데이터 주입, config-sync 트리거 ([→ 상세](seed-and-finalize.md))

## 전제 조건 확인

배포를 시작하기 전에 다음이 준비되어 있어야 합니다.

- `az login` 완료 및 대상 구독 활성화
- Terraform ≥ 1.7 설치 (Docker 불필요 — ACR remote build 사용)
- Azure CLI 최신 버전
- [사전 준비 챕터](../02-prerequisites/azure-requirements.md)의 모든 항목 완료

> **Brownfield 경로:** `reuse_foundry = true`를 설정하기 전에 [기존 Foundry 재사용 — 계정 잠금 준비](../04-reuse-foundry/prepare-account.md)를 먼저 완료하십시오.
