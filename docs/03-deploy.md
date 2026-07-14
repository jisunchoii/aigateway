---
description: "배포 — 배포 방식 선택, 공통 순서, 시나리오별 runbook 안내"
---

# 배포

이 장은 **어떤 방식으로 배포할지 선택하는 허브**입니다. 실제 명령과 세부 절차는 각 하위 runbook에서 다룹니다.

APIM 정책은 backend URL, `model_deployments` key, runtime allowed model catalog를 기준으로 생성됩니다. 따라서 APIM을 먼저 띄우고 나중에 모델을 붙이는 흐름이 아니라, **모델 백엔드 방식을 먼저 결정한 뒤 APIM 게이트웨이를 배포**해야 합니다.

## 배포 전에 결정할 것

| 결정 | 선택지 | 기준 |
|---|---|---|
| APIM 공개 여부 | `apim_public=true/false` | VS Code, GitHub Copilot CLI 같은 외부 개발 도구가 붙으면 public |
| 모델 백엔드 | 신규 생성 / 기존 계정 재사용 | 신규 환경이면 새로 생성, 고객 운영 계정이 있으면 재사용 |
| Admin UI | 함께 배포 / 나중에 추가 | 셀프서비스 consumer·key·정책 관리가 필요하면 배포 |
| 배포 순서 | 단계적 / All-in-one | 운영 검증은 단계적, 데모·랩은 All-in-one |
| Entra 객체 | 새로 생성 / 기존 그룹 재사용 | 고객 조직에 admin 보안 그룹이 이미 있으면 재사용 |

{% hint style="warning" %}
`apim_public`과 모델 백엔드 방식(`reuse_foundry`, `reuse_foundry_project`, `model_deployments`)은 첫 APIM 배포 전에 확정하세요. 나중에 바꾸면 APIM 정책, Private Endpoint, RBAC, 모델 라우팅을 다시 적용해야 합니다.
{% endhint %}

## 추천 배포 경로

| 상황 | 읽을 runbook |
|---|---|
| 새 Azure OpenAI/Foundry 모델까지 Terraform으로 만들고 싶다 | [모델 백엔드 신규 생성](03-deploy/case-foundry-greenfield.md) |
| 기존 계정과 모델은 있지만 Foundry 프로젝트가 없다 | [모델 백엔드 기존 계정 재사용](04-reuse-foundry.md#2-기존-계정-재사용-방식) |
| 기존 계정, 모델, Foundry 프로젝트가 모두 있다 | [모델 백엔드 기존 계정 재사용](04-reuse-foundry.md) |
| 모델 백엔드 결정 후 APIM 게이트웨이만 먼저 검증하고 싶다 | [APIM 게이트웨이 배포](03-deploy/case-apim-core-first.md) |
| APIM 게이트웨이 배포 후 Admin UI를 배포하고 싶다 | [Admin UI 배포](03-deploy/case-admin-ui.md) |
| 신규 데모/랩 환경에 전체 스택을 한 번에 올리고 싶다 | [All-in-one 배포](03-deploy/case-all-in-one.md) |

{% hint style="info" %}
Codex CLI 등 Responses API 전용 클라이언트를 위한 `/openai/v1/responses` operation은 APIM 게이트웨이에 포함됩니다. `gpt-5.6-sol`은 Codex proxy 없이 native Foundry Responses로 전달됩니다. `codexproxy_image`를 설정하면 partner/OSS 모델의 Responses 요청을 sidecar가 정규화하고, `searchmcp_image`를 설정하면 `/mcp/` 웹 검색 경로가 활성화됩니다. [Codex CLI 온보딩](07-connect-clients/codex-cli.md) 참고.
{% endhint %}

## 공통 배포 순서

세부 명령은 각 runbook에서 다루지만, 모든 배포는 같은 큰 흐름을 따릅니다.

| 단계 | 목적 | 결과 |
|---|---|---|
| 모델 백엔드 결정 | 신규 생성 또는 기존 계정 재사용 선택 | `reuse_foundry`, `reuse_foundry_project`, 모델 배포 이름, quota/capacity 기준 확정 |
| State backend bootstrap | Terraform state 저장소 생성 | `infra/providers.tf` backend block 갱신 |
| tfvars 작성 | 리전, APIM 공개 여부, 모델/쿼터 결정, 이미지 변수는 빈 값으로 유지 | 첫 번째 apply용 `infra/terraform.tfvars` 준비 |
| 게이트웨이 1차 apply | 네트워크, APIM, 선택한 모델 백엔드 연결, Cosmos, ACR 생성 | APIM gateway와 ACR 리소스 준비. repository는 아직 없음 |
| Image build | 선택한 이미지를 Git SHA 태그로 ACR에 build/push하고 태그 잠금 | ACR repository와 overwrite 방지된 이미지 URI 생성 |
| Sidecar 2차 apply | `codexproxy_image`, `searchmcp_image` 설정 | partner/OSS Responses와 `/mcp/` 활성화 |
| App 2차 apply | `admin_ui_image`, `worker_image`와 Entra 값 설정 | Admin UI FQDN, config-sync job 생성 |
| Seed & sync | Cosmos 초기 문서 생성 및 APIM named value 동기화 | 동적 consumer 정책 활성화 |
| Verify | APIM 경유 모델 호출 검증 | `/openai/v1`, `/vscode/models`, `/mcp/` 정상 확인 |

ACR 리소스 생성과 image repository 생성은 별도 단계입니다. 첫 번째 apply 후 `az acr repository list`가 비어 있어도 정상이며, repository는 첫 `az acr build` 또는 push가 성공한 뒤 나타납니다. Git SHA 태그도 기본적으로 mutable이므로 build 후 `az acr repository update --write-enabled false`로 배포할 태그를 잠급니다. 자세한 명령은 [ACR Tasks 빠른 빌드](https://learn.microsoft.com/azure/container-registry/container-registry-quickstart-task-cli)와 [ACR 이미지 잠금](https://learn.microsoft.com/azure/container-registry/container-registry-image-lock)을 참고하세요.

## 단계적 배포 모델

운영 환경에서는 한 번에 모든 기능을 켜기보다 단계적으로 검증하는 방식을 권장합니다.

| Stage | 켜지는 것 | 비고 |
|---|---|---|
| Stage 0 — 모델 백엔드 결정 | 신규 생성, 프로젝트 없는 기존 계정 재사용, 프로젝트 있는 기존 계정 재사용 중 선택 | APIM 배포 전에 완료 |
| Stage 1 — APIM 게이트웨이 | APIM, 정책, 선택한 모델 백엔드 연결, Cosmos, ACR | 네 이미지 변수를 모두 `""`로 유지 |
| Stage 2 — Codex proxy / Search MCP | partner/OSS Responses 정규화, bounded web search | 필요한 sidecar 이미지만 build 후 두 번째 apply |
| Stage 3 — Admin UI | 셀프서비스 consumer/key/policy 관리 | Entra app registration 필요 |
| Stage 4 — config-sync worker | 소비자별 동적 설정, budget switch | Cosmos seed 후 즉시 sync 권장 |

Stage 1만으로도 APIM subscription key를 수동 발급하면 Chat Completions와 `gpt-5.6-sol` native Responses 호출은 가능합니다. partner/OSS `/responses`는 Stage 2의 Codex proxy가 없으면 `503`, `/mcp/`는 Search MCP가 없으면 `404`입니다. consumer별 동적 정책과 예산 기반 모델 전환은 Stage 4 이후 완전해집니다.

## tfvars에서 가장 먼저 보는 값

모든 배포 runbook의 `tfvars` 예시는 `infra/` 디렉터리의 `terraform.tfvars` 파일에서 수정합니다.

| 변수 | 의미 |
|---|---|
| `location` | 배포 리전 |
| `apim_public` | APIM을 인터넷에서 호출 가능하게 할지 |
| `admin_ui_public` | Admin UI를 public FQDN으로 노출할지 |
| `reuse_foundry` | 기존 AIServices 계정을 재사용할지 |
| `reuse_foundry_project` | 기존 Foundry 프로젝트를 Terraform 비관리 상태로 재사용할지 |
| `foundry_project_name` | 기준 child project 이름 (`codexproj`) |
| `model_deployments` | 지원 모델 네 개(`gpt-5.6-sol`, `FW-GLM-5.2`, `DeepSeek-V4-Pro`, `grok-4.3`) 또는 운영자가 승인한 동일 schema deployment map |
| `rate_tiers` | consumer별 rate tier 정의 |
| `worker_image` | config-sync worker 활성화 여부 |
| `admin_ui_image` | Admin UI 활성화 여부 |
| `codexproxy_image` | partner/OSS `/responses` sidecar 활성화 여부 |
| `searchmcp_image` | APIM `/mcp/`와 Search MCP 활성화 여부 |

`admin_ui_public`은 이미지가 비어 있는 첫 apply에서도 생성되는 Container Apps 환경의 노출 방식을 결정합니다. 나중에 바꾸면 환경과 앱이 재생성될 수 있으므로 스택의 첫 apply 전에 확정합니다.

`reuse_foundry=true`일 때 Terraform은 기존 모델 deployment를 관리하지 않습니다. 프로젝트가 없으면 `reuse_foundry_project=false`로 새 프로젝트를 만들고, 기존 프로젝트를 유지하려면 `reuse_foundry_project=true`와 정확한 `foundry_project_name`을 설정해 조회만 합니다.

전체 변수 목록은 [부록: 변수·출력·문제 해결](10-reference.md)을 참고하세요.

## Admin UI와 Entra 객체

Admin UI를 배포하려면 Entra 값 4개가 필요합니다. 새 Admin 그룹을 만들지, 기존 그룹을 재사용할지는 Admin UI 배포 전에 먼저 결정합니다.

| 객체 | tfvars |
|---|---|
| Entra tenant | `entra_tenant_id` |
| Admin security group | `admin_group_object_id` |
| BFF API app registration | `bff_api_audience` |
| SPA public-client app registration | `spa_client_id` |

결정 기준과 준비 절차는 [사전 준비](02-prerequisites.md)와 [Admin UI 배포](03-deploy/case-admin-ui.md)를 참고하세요.

## 모델 백엔드 선택

| 방식 | Terraform 처리 | 권장 상황 |
|---|---|---|
| 모델 새로 배포 | 계정·프로젝트·모델 deployment 생성 | 신규 환경이나 새 모델 배포가 필요한 경우 |
| 기존 모델 활용, 프로젝트 없음 | 프로젝트·Private Endpoint·RBAC 생성 | 기존 계정과 모델만 있는 경우 |
| 기존 모델 활용, 프로젝트 있음 | 기존 프로젝트 read-only 조회, Private Endpoint·RBAC 생성 또는 import | 기존 계정·모델·프로젝트를 모두 유지하는 경우 |

기존 계정을 재사용하는 두 경우 모두 `reuse_foundry=true`를 사용합니다. 프로젝트가 없으면 `reuse_foundry_project=false`, 기존 프로젝트가 있으면 `true`를 사용합니다. 후자의 프로젝트는 Terraform resource가 아니므로 `terraform destroy`에서도 삭제되지 않습니다.

APIM 정책은 이 선택 결과를 기준으로 생성됩니다. 모델 배포 이름이나 reuse 여부가 바뀌면 `infra/` 디렉터리의 `terraform.tfvars` 파일을 수정합니다.

## 배포 후 확인할 출력

| 출력 | 용도 |
|---|---|
| `apim_gateway_url` | Copilot CLI base URL, direct API base |
| `vscode_base_url` | VS Code BYOK URL prefix |
| `model_account_name` | 기준 AIServices 계정 이름 확인 |
| `model_openai_v1_endpoint` | 기준 모델 계정의 `/openai/v1` backend base 확인 |
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
