---
description: "배포 — 배포 방식 선택, 공통 순서, 시나리오별 runbook 안내"
---

# 배포

이 장은 **어떤 방식으로 배포할지 선택하는 허브**입니다. 실제 명령과 세부 절차는 각 하위 runbook에서 다룹니다.

APIM 정책은 backend URL, 모델 배포 이름, allowed model 목록을 포함해 생성됩니다. 따라서 APIM을 먼저 띄우고 나중에 모델을 붙이는 흐름이 아니라, **모델 백엔드 방식을 먼저 결정한 뒤 APIM 게이트웨이를 배포**해야 합니다.

## 배포 전에 결정할 것

| 결정 | 선택지 | 기준 |
|---|---|---|
| APIM 공개 여부 | `apim_public=true/false` | VS Code, GitHub Copilot CLI 같은 외부 개발 도구가 붙으면 public |
| 모델 백엔드 | 신규 생성 / 기존 계정 재사용 | 신규 환경이면 새로 생성, 고객 운영 계정이 있으면 재사용 |
| Admin UI | 함께 배포 / 나중에 추가 | 셀프서비스 consumer·key·정책 관리가 필요하면 배포 |
| 배포 순서 | 단계적 / All-in-one | 운영 검증은 단계적, 데모·랩은 All-in-one |
| Entra 객체 | 새로 생성 / 기존 그룹 재사용 | 고객 조직에 admin 보안 그룹이 이미 있으면 재사용 |

{% hint style="warning" %}
`apim_public`과 모델 백엔드 방식(`reuse_foundry`, `openai_deployments`, `foundry_deployments`)은 첫 APIM 배포 전에 확정하세요. 나중에 바꾸면 APIM 정책, Private Endpoint, RBAC, 모델 라우팅을 다시 적용해야 합니다.
{% endhint %}

## 추천 배포 경로

| 상황 | 읽을 runbook |
|---|---|
| 새 Azure OpenAI/Foundry 모델까지 Terraform으로 만들고 싶다 | [모델 백엔드 신규 생성](03-deploy/case-foundry-greenfield.md) |
| 이미 운영 중인 Foundry/AIServices 계정과 모델이 있다 | [모델 백엔드 기존 계정 재사용](04-reuse-foundry.md) |
| 모델 백엔드 결정 후 APIM 게이트웨이만 먼저 검증하고 싶다 | [APIM 게이트웨이 배포](03-deploy/case-apim-core-first.md) |
| APIM 게이트웨이 배포 후 Admin UI를 배포하고 싶다 | [Admin UI 배포](03-deploy/case-admin-ui.md) |
| Codex CLI 등 Responses API 전용 클라이언트를 지원하고 싶다 | [Responses 브리지(LiteLLM) 배포](03-deploy/case-litellm-responses.md) |
| 신규 데모/랩 환경에 전체 스택을 한 번에 올리고 싶다 | [All-in-one 배포](03-deploy/case-all-in-one.md) |

## 공통 배포 순서

세부 명령은 각 runbook에서 다루지만, 모든 배포는 같은 큰 흐름을 따릅니다.

| 단계 | 목적 | 결과 |
|---|---|---|
| 모델 백엔드 결정 | 신규 생성 또는 기존 계정 재사용 선택 | `reuse_foundry`, 모델 배포 이름, quota/capacity 기준 확정 |
| State backend bootstrap | Terraform state 저장소 생성 | `infra/providers.tf` backend block 갱신 |
| tfvars 작성 | 리전, APIM 공개 여부, 모델/쿼터, 이미지 변수 결정 | APIM이 참조할 backend 설정까지 포함한 `infra/terraform.tfvars` 준비 |
| 게이트웨이 apply | 네트워크, APIM, 선택한 모델 백엔드 연결, Cosmos, ACR 생성 | APIM gateway와 backend private 연결 준비 |
| Image build | worker/Admin UI 이미지를 ACR에 push | `config-sync-worker`, `admin-ui` 이미지 준비 |
| App apply | Admin UI와 config-sync worker 활성화 | Admin UI FQDN, config-sync job 생성 |
| Seed & sync | Cosmos 초기 문서 생성 및 APIM named value 동기화 | 동적 consumer 정책 활성화 |
| Verify | APIM 경유 모델 호출 검증 | `/openai`, `/vscode/models`, `/foundry` 정상 확인 |

## 단계적 배포 모델

운영 환경에서는 한 번에 모든 기능을 켜기보다 단계적으로 검증하는 방식을 권장합니다.

| Stage | 켜지는 것 | 비고 |
|---|---|---|
| Stage 0 — 모델 백엔드 결정 | 신규 생성 또는 기존 계정 재사용, brownfield 직접 호출 경로 차단 | APIM 배포 전에 완료 |
| Stage 1 — APIM 게이트웨이 | APIM, 정책, 선택한 모델 백엔드 연결, Cosmos, ACR | `worker_image=""`, `admin_ui_image=""` |
| Stage 2 — Admin UI | 셀프서비스 consumer/key/policy 관리 | Entra app registration 필요 |
| Stage 3 — config-sync worker | 소비자별 동적 설정, budget switch | Cosmos seed 후 즉시 sync 권장 |

Stage 1만으로도 APIM subscription key를 수동 발급하면 모델 호출은 가능합니다. 다만 Stage 1은 **모델 백엔드가 이미 tfvars에 결정된 상태**를 전제로 합니다. consumer별 동적 정책과 예산 기반 모델 전환은 Stage 3 이후 완전해집니다.

## tfvars에서 가장 먼저 보는 값

모든 배포 runbook의 `tfvars` 예시는 `infra/` 디렉터리의 `terraform.tfvars` 파일에서 수정합니다.

| 변수 | 의미 |
|---|---|
| `location` | 배포 리전 |
| `apim_public` | APIM을 인터넷에서 호출 가능하게 할지 |
| `admin_ui_public` | Admin UI를 public FQDN으로 노출할지 |
| `reuse_foundry` | 기존 AIServices 계정을 재사용할지 |
| `openai_deployments` | gpt 계열 deployment와 capacity |
| `foundry_deployments` | Foundry partner/OSS deployment와 capacity |
| `allowed_models` | gateway 전체 허용 모델 목록 |
| `rate_tiers` | consumer별 rate tier 정의 |
| `worker_image` | config-sync worker 활성화 여부 |
| `admin_ui_image` | Admin UI 활성화 여부 |

전체 변수 목록은 [부록: 변수·출력·문제 해결](10-reference.md)을 참고하세요.

## Admin UI와 Entra 객체

Admin UI를 배포하려면 Entra 값 3개가 필요합니다. 새 Admin 그룹을 만들지, 기존 그룹을 재사용할지는 Admin UI 배포 전에 먼저 결정합니다.

| 객체 | tfvars |
|---|---|
| Admin security group | `admin_group_object_id` |
| BFF API app registration | `bff_api_audience` |
| SPA public-client app registration | `spa_client_id` |

결정 기준과 준비 절차는 [사전 준비](02-prerequisites.md)와 [Admin UI 배포](03-deploy/case-admin-ui.md)를 참고하세요.

## 모델 백엔드 선택

| 방식 | Terraform이 모델 계정을 만드나? | 권장 상황 |
|---|---:|---|
| 모델 백엔드 신규 생성 | 예 | 데모, 신규 환경, 모델 quota를 gateway 기준으로 새로 잡는 경우 |
| 모델 백엔드 기존 계정 재사용 | 아니오 | 고객이 이미 운영 중인 AIServices/Foundry 계정을 가진 경우 |

기존 계정을 재사용하는 경우 Terraform은 계정과 모델을 삭제하거나 수정하지 않습니다. 대신 gateway VNet에서 기존 계정으로 Private Endpoint를 만들고, APIM managed identity에 backend 호출 권한만 부여합니다.

APIM 정책은 이 선택 결과를 기준으로 생성됩니다. 모델 배포 이름이나 reuse 여부가 바뀌면 `infra/` 디렉터리의 `terraform.tfvars` 파일을 수정합니다.

## 배포 후 확인할 출력

| 출력 | 용도 |
|---|---|
| `apim_gateway_url` | Copilot CLI base URL, direct API base |
| `vscode_base_url` | VS Code BYOK URL prefix |
| `admin_ui_fqdn` | Admin UI 접속 URL |
| `config_sync_job_name` | config-sync 즉시 실행 |
| `registry_name` / `registry_login_server` | ACR remote build |
| `config_store_endpoint` | seed script 입력값 |

## 다음 단계

| 목적 | 이동 |
|---|---|
| 신규 모델 백엔드 준비 | [모델 백엔드 신규 생성](03-deploy/case-foundry-greenfield.md) |
| 기존 모델 백엔드 연결 준비 | [모델 백엔드 기존 계정 재사용](04-reuse-foundry.md) |
| APIM 게이트웨이 배포 | [APIM 게이트웨이 배포](03-deploy/case-apim-core-first.md) |
| 호출 검증 | [APIM 게이트웨이 배포](03-deploy/case-apim-core-first.md#7-호출-검증) |
| 클라이언트 연결 | [클라이언트 온보딩](07-connect-clients.md) |
| 운영 설정 | [운영](06-operate.md) |
