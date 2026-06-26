> 읽는 사람: 개발자 (VS Code 사용자) · 선행: 07-connect-clients/overview.md

# VS Code BYOK (Bring Your Own Key) 연동

VS Code의 **chatLanguageModels.json** 설정 파일에 APIM 게이트웨이를 AI 모델 제공자로 등록합니다. `/vscode/openai` 경로를 사용하며, APIM 구독 키를 `Ocp-Apim-Subscription-Key` 헤더로 전달합니다.

---

## 사전 준비

- VS Code 최신 버전
- Admin UI에서 발급한 APIM 구독 키 (`<APIM subscription key>`)
- `terraform output -raw apim_gateway_url` 로 확인한 APIM 호스트 (`<apim-host>`)

---

## chatLanguageModels.json 설정

VS Code 설정 파일(`chatLanguageModels.json`)에 아래 엔트리를 추가합니다. 모델 4개를 각각 1개씩 등록합니다.

```json
[
  {
    "id": "gpt-5.4",
    "name": "GPT-5.4 via APIM",
    "url": "https://<apim-host>/vscode/openai/deployments/gpt-5.4/chat/completions?api-version=2025-01-01-preview",
    "toolCalling": true, "vision": false,
    "maxInputTokens": 128000, "maxOutputTokens": 16000,
    "requestHeaders": { "Ocp-Apim-Subscription-Key": "<APIM subscription key>" }
  },
  {
    "id": "gpt-5.4-mini",
    "name": "GPT-5.4 Mini via APIM",
    "url": "https://<apim-host>/vscode/openai/deployments/gpt-5.4-mini/chat/completions?api-version=2025-01-01-preview",
    "toolCalling": true, "vision": false,
    "maxInputTokens": 128000, "maxOutputTokens": 16000,
    "requestHeaders": { "Ocp-Apim-Subscription-Key": "<APIM subscription key>" }
  },
  {
    "id": "grok-4.3",
    "name": "Grok 4.3 via APIM",
    "url": "https://<apim-host>/vscode/openai/deployments/grok-4.3/chat/completions?api-version=2025-01-01-preview",
    "toolCalling": false, "vision": false,
    "maxInputTokens": 128000, "maxOutputTokens": 16000,
    "requestHeaders": { "Ocp-Apim-Subscription-Key": "<APIM subscription key>" }
  },
  {
    "id": "DeepSeek-V4-Pro",
    "name": "DeepSeek V4 Pro via APIM",
    "url": "https://<apim-host>/vscode/openai/deployments/DeepSeek-V4-Pro/chat/completions?api-version=2025-01-01-preview",
    "toolCalling": false, "vision": false,
    "maxInputTokens": 128000, "maxOutputTokens": 16000,
    "requestHeaders": { "Ocp-Apim-Subscription-Key": "<APIM subscription key>" }
  }
]
```

> `<apim-host>` 와 `<APIM subscription key>` 를 실제 값으로 교체하십시오. 구독 키는 소스 코드나 버전 관리 시스템에 커밋하지 마십시오.

---

## 경로 설명

- `/vscode/openai` 경로는 APIM 내부에서 VS Code BYOK 전용 입구입니다.
- URL 경로에 포함된 모델명(`/deployments/gpt-5.4`)을 APIM 정책이 추출하여 요청 body의 `model` 필드에 주입합니다.
- `api-version=2025-01-01-preview` 는 APIM 정책 처리에 필요한 파라미터입니다.

---

## 연결 확인

설정 완료 후 VS Code의 GitHub Copilot Chat 또는 커스텀 LLM 채팅 패널에서 모델 목록에 등록한 모델이 표시되는지 확인합니다. 연결이 되지 않는 경우:

1. 구독 키가 올바른지 Admin UI에서 재확인합니다.
2. `<apim-host>` 에 `https://` 가 포함되어 있는지 확인합니다.
3. `apim_public = true` 인지 확인합니다. Internal 모드라면 VPN 또는 VNet 연결이 필요합니다.
4. 오류 코드 의미는 [10-reference/gotchas.md](../10-reference/gotchas.md)를 참조하십시오.

---

## 참고 링크

- [VS Code — Language Model API (BYOK)](https://code.visualstudio.com/docs/copilot/language-models)
- [Azure API Management — 구독 키](https://learn.microsoft.com/en-us/azure/api-management/api-management-subscriptions)
