package com.flutterai.backend.api;

import java.util.Map;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import com.flutterai.backend.dto.AiDtos.ChatIn;
import com.flutterai.backend.dto.AiDtos.ChatOut;
import com.flutterai.backend.service.AiConfigService;
import com.flutterai.backend.service.ChatService;
import com.flutterai.backend.service.ProjectService;

@RestController
public class AiController {
  private final AiConfigService aiConfig;
  private final ProjectService projectService;
  private final ChatService chatService;

  public AiController(AiConfigService aiConfig, ProjectService projectService, ChatService chatService) {
    this.aiConfig = aiConfig;
    this.projectService = projectService;
    this.chatService = chatService;
  }

  @GetMapping("/v1/ai/status")
  public Map<String, Object> status() {
    String apiKey = aiConfig.doubaoApiKey();
    String model = aiConfig.doubaoModel();
    String baseUrl = aiConfig.doubaoBaseUrl();
    boolean enabled = aiConfig.isAiEnabled();

    return Map.of(
      "llm",
      Map.of(
        "provider", "doubao",
        "enabled", enabled,
        "configured", apiKey != null && model != null,
        "has_api_key", apiKey != null,
        "has_model", model != null,
        "has_client", true,
        "model", model == null ? "" : model,
        "base_url", baseUrl == null ? "" : baseUrl,
        "note", enabled
            ? "已启用 app.ai.enabled=true；会尝试调用豆包 Ark /chat/completions，失败自动回退规则答案。"
            : "当前未启用（app.ai.enabled=false）；/v1/ai/chat 仅返回规则/意图路由答案。"
      )
    );
  }

  @PostMapping("/v1/ai/chat")
  public ChatOut chat(@RequestBody ChatIn payload) {
    // Ensure default project exists for backward compatibility.
    if (payload != null && payload.projectName() != null && !payload.projectName().trim().isEmpty()) {
      projectService.ensureProject(payload.projectName().trim());
    } else {
      projectService.ensureProject("默认项目");
    }

    return chatService.chat(payload);
  }

  // firstNonNull moved to AiConfigService
}
