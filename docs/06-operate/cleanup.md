---
description: 게이트웨이 운영자·인프라 담당자를 위한 페이지 · 선행: 06-operate/scale-sku.md
---

# 리소스 정리 (Cleanup)

게이트웨이를 더 이상 사용하지 않을 경우 Terraform으로 리소스를 제거합니다. VNet 주입 APIM 환경에서는 `terraform destroy`가 중간에 멈출 수 있으므로 주의가 필요합니다.

---

## 기본 정리 절차

```bash
cd infra
terraform destroy
```

`terraform destroy`는 Terraform이 관리하는 모든 리소스(APIM, Container Apps, Cosmos DB, VNet, Private Endpoint, ACR 등)를 역순으로 삭제합니다.

---

## 주의: VNet 주입 APIM의 Named Value 삭제 문제

VNet 주입 모드(`apim_public`과 무관하게 Developer/Premium SKU는 VNet 주입)로 배포된 APIM은 `terraform destroy` 실행 중 **Named Value 삭제 단계에서 멈출 수 있습니다.** 이는 APIM 내부 의존성 처리 지연 때문이며, 일시적으로 보이더라도 수십 분 이상 멈춰 있을 수 있습니다.

이 경우 **리소스 그룹 전체를 한 번에 삭제**하는 것이 더 깔끔합니다.

{% hint style="warning" %}
`terraform destroy`가 Named Value 삭제 단계에서 멈추면 `az group delete -n <rg> --yes` 로 리소스 그룹 전체를 삭제하십시오. `<rg>`는 `terraform output -raw resource_group_name` 으로 확인합니다. `az group delete`는 APIM VNet 의존성 해제도 Azure 플랫폼이 내부적으로 처리합니다.
{% endhint %}

```bash
az group delete -n <rg> --yes
```

`az group delete`는 해당 RG 내 모든 리소스를 비동기적으로 삭제하며, APIM VNet 의존성 해제도 Azure 플랫폼이 내부적으로 처리합니다.

---

## Brownfield(재사용) 모드에서의 정리

`reuse_foundry = true` 로 배포한 경우, **고객의 기존 Azure AI Foundry 계정은 별도의 리소스 그룹에 있습니다.** `terraform destroy` 또는 `az group delete`로 게이트웨이 RG를 삭제해도 기존 Foundry 계정은 영향을 받지 않습니다.

{% hint style="info" %}
brownfield 고객의 기존 Azure AI Foundry 계정은 별도 RG에 있으므로 게이트웨이 RG 삭제 시 안전하게 보존됩니다. 단, 역할 할당과 Private Endpoint는 제거되므로 해당 Foundry 계정을 다른 서비스에서도 사용 중이라면 사전 확인이 필요합니다.
{% endhint %}

삭제 대상과 보존 대상을 정리하면 다음과 같습니다.

| 리소스 | 삭제 여부 |
|---|---|
| 게이트웨이 RG (APIM, Container Apps, Cosmos DB 등) | 삭제됨 |
| 기존 Foundry 계정 (별도 RG) | **보존됨** |
| 기존 Foundry의 Private Endpoint (게이트웨이 VNet → Foundry) | 삭제됨 |
| 기존 Foundry의 RBAC 역할 할당 (APIM MI) | 삭제됨 |

---

## Entra ID 객체 수동 정리

`./scripts/app-registration.sh` 로 생성된 Entra ID 앱 등록(BFF API, SPA)과 관리자 보안 그룹은 Terraform 관리 범위 밖입니다. 필요한 경우 다음 명령으로 수동 삭제합니다.

```bash
# SPA 앱 등록 삭제
spa_app_id="$(az ad app list --display-name "AI Gateway SPA" --query "[].appId" -o tsv)"
az ad app delete --id "$spa_app_id"

# BFF API 앱 등록 삭제
bff_app_id="$(az ad app list --display-name "AI Gateway BFF" --query "[].appId" -o tsv)"
az ad app delete --id "$bff_app_id"
```

---

## 참고 링크

- [Azure 리소스 그룹 삭제](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/delete-resource-group)
- [Azure API Management — VNet 통합 정리](https://learn.microsoft.com/en-us/azure/api-management/virtual-network-concepts)
- [Terraform — destroy 명령](https://developer.hashicorp.com/terraform/cli/commands/destroy)
