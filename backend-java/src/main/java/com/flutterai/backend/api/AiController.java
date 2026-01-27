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
    String apiKey = firstNonNull(
        aiConfig.getEnv("ARK_API_KEY", "DOUBAO_API_KEY"),
        aiConfig.getCfg("doubao.api_key")
    );
    String model = firstNonNull(
        aiConfig.getEnv("ARK_MODEL", "DOUBAO_MODEL", "DOUBAO_ENDPOINT_ID"),
        aiConfig.getCfg("doubao.model"),
        aiConfig.getCfg("doubao.endpoint_id")
    );
    String baseUrl = firstNonNull(
        aiConfig.getEnv("ARK_BASE_URL", "DOUBAO_BASE_URL"),
        aiConfig.getCfg("doubao.base_url")
    );

    return Map.of(
      "llm",
      Map.of(
        "provider", "doubao",
        "configured", apiKey != null && model != null,
        "has_api_key", apiKey != null,
        "has_model", model != null,
        "has_client", false,
        "model", model == null ? "" : model,
        "base_url", baseUrl == null ? "" : baseUrl,
        "note", "Java 参考实现暂不直连豆包；configured 仅表示检测到配置。实际调用请在此处接入 SDK。"
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

  private static String firstNonNull(String... values) {
    if (values == null) {
      return null;
    }
    for (String v : values) {
      if (v != null) {
        return v;
      }
    }
    return null;
  }
}
