---
description: 배포 담당자 / 인프라 엔지니어를 위한 페이지 · 선행: 첫 번째 terraform apply
---

# 출력 레퍼런스

`infra/outputs.tf` 기준 전체 Terraform 출력 목록입니다. `terraform output -raw <이름>` 으로 값을 직접 확인할 수 있습니다.

---

## 출력 목록

| 이름 | 조건 | 설명 |
|---|---|---|
| `apim_gateway_url` | 항상 | APIM 게이트웨이 URL. VNet 내부에서 private IP로 해석. 클라이언트 base URL로 사용. |
| `apim_private_ip` | 항상 | APIM 내부 게이트웨이 사설 IP. VNet 내부 도구(`smoke-gateway`)에서 `--resolve` 옵션과 함께 사용. |
| `vscode_base_url` | 항상 | VS Code BYOK `chatLanguageModels.json` 의 `url` 프리픽스. |
| `openai_endpoint` | greenfield만 | Azure OpenAI 계정 엔드포인트. **`reuse_foundry = true` 면 `null`** (전용 Azure OpenAI 계정 없음). |
| `registry_name` | 항상 | ACR(Container Registry) 이름. `az acr build --registry $(terraform output -raw registry_name)` 형태로 사용. |
| `registry_login_server` | 항상 | ACR 로그인 서버. `worker_image` / `admin_ui_image` 변수 값 구성에 사용(`<registry_login_server>/image:tag`). |
| `config_store_endpoint` | 항상 | Cosmos DB 문서 엔드포인트. `scripts/seed-cosmos-jumpbox.sh` 등에 전달. |
| `config_store_account_name` | 항상 | Cosmos DB 계정 이름. `az cosmosdb` CLI 또는 포털 Data Explorer에서 사용. |
| `config_sync_job_name` | `worker_image` 설정 후 | config-sync Container Apps Job 이름. `az containerapp job start` 에 사용. **`worker_image` 미설정 시 `null`.** |
| `admin_ui_fqdn` | `admin_ui_image` 설정 후 | Admin UI 내부 FQDN. jumpbox 또는 EXTERNAL 모드 시 브라우저에서 `https://<this>` 접속. **`admin_ui_image` 미설정 시 `null`.** |
| `resource_group_name` | 항상 | 게이트웨이 워크로드의 기본 리소스 그룹 이름. |

---

## 자주 쓰는 출력 조합

### 클라이언트 설정용 URL

```bash
# APIM 게이트웨이 URL
terraform output -raw apim_gateway_url

# VS Code BYOK base URL
terraform output -raw vscode_base_url
```

### 이미지 빌드 후 push

```bash
acr=$(terraform output -raw registry_login_server)
reg=$(terraform output -raw registry_name)
az acr build --registry $reg --image config-sync-worker:latest ../app/config-sync-worker
az acr build --registry $reg --image admin-ui:latest ../app/admin-ui
```

### config-sync 잡 수동 트리거

```bash
job=$(terraform output -raw config_sync_job_name)
rg=$(terraform output -raw resource_group_name)
az containerapp job start -g $rg -n $job
```

### Admin UI FQDN 확인

```bash
terraform output -raw admin_ui_fqdn
```

---

## null 출력에 대하여

| 출력 | null이 되는 조건 |
|---|---|
| `openai_endpoint` | `reuse_foundry = true` (전용 Azure OpenAI 계정이 생성되지 않음) |
| `config_sync_job_name` | `worker_image = ""` (이미지 빌드 전) |
| `admin_ui_fqdn` | `admin_ui_image = ""` (이미지 빌드 전) |

{% hint style="info" %}
null 출력을 스크립트에서 참조할 경우 빈 문자열로 처리되므로, 해당 단계 완료 후 재확인하세요.
{% endhint %}

---

## 관련 문서

- 변수 레퍼런스 → [variables.md](variables.md)
- 비용 · 정리 → [cost-cleanup.md](cost-cleanup.md)
- Gotchas → [gotchas.md](gotchas.md)
- 이미지 빌드 및 두 번째 apply → [../03-deploy/app-registration-second-apply.md](../03-deploy/app-registration-second-apply.md)
