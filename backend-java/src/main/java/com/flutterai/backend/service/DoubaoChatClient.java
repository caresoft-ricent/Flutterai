package com.flutterai.backend.service;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.List;
import java.util.Map;

import org.springframework.stereotype.Service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;

@Service
public class DoubaoChatClient {
  private static final String DEFAULT_BASE_URL = "https://ark.cn-beijing.volces.com/api/v3";

  public record LlmResult(
      boolean enabled,
      boolean configured,
      boolean attempted,
      boolean used,
      String provider,
      String model,
      String baseUrl,
      String answer,
      String error
  ) {
    public static LlmResult notEnabled() {
      return new LlmResult(false, false, false, false, "doubao", "", "", null, null);
    }
  }

  private final AiConfigService aiConfig;
  private final ObjectMapper objectMapper;
  private final HttpClient httpClient;

  public DoubaoChatClient(AiConfigService aiConfig, ObjectMapper objectMapper) {
    this.aiConfig = aiConfig;
    this.objectMapper = objectMapper;
    this.httpClient = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(5))
        .build();
  }

  /**
   * Best-effort call to Doubao (Volcengine Ark) OpenAI-compatible chat endpoint.
   * Returns a structured result; caller decides whether to fall back.
   */
  public LlmResult tryRewrite(Boolean enabledOverride, String query, String draftAnswer, Map<String, Object> facts) {
    String apiKey = aiConfig.doubaoApiKey();
    String model = aiConfig.doubaoModel();
    String baseUrl = aiConfig.doubaoBaseUrl();
    if (baseUrl == null || baseUrl.isBlank()) {
      baseUrl = DEFAULT_BASE_URL;
    }

    boolean enabled = enabledOverride != null ? enabledOverride.booleanValue() : aiConfig.isAiEnabled();

    boolean configured = apiKey != null && !apiKey.isBlank() && model != null && !model.isBlank();

    if (!enabled) {
      return new LlmResult(false, configured, false, false, "doubao", modelOrEmpty(model), baseUrl, null,
          enabledOverride != null ? "disabled_by_client" : null);
    }

    if (!configured) {
      return new LlmResult(true, false, false, false, "doubao", modelOrEmpty(model), baseUrl, null,
          "missing api_key/model");
    }

    String url = normalizeBaseUrl(baseUrl) + "/chat/completions";

    String system = String.join("\n", List.of(
        "你是建筑质量巡检/验收数据助手。",
        "你会基于我提供的 facts 进行总结，并用简洁中文输出。",
        "要求：不要编造 facts 之外的数据；不要输出 markdown 代码块；必要时给出下一步建议。",
        "如果用户问题很短（如 'progress' / 'issues_top'），你可以把它理解成查询意图并直接给出汇总。"
    ));

    String user = "用户问题：" + safe(query)
        + "\n\n已计算 facts(JSON)：\n" + toPrettyJsonSafe(facts)
        + "\n\n规则版草稿回答：\n" + safe(draftAnswer)
        + "\n\n请在不改变事实的前提下，用更自然的语言重写，并补充 3 条可执行建议。";

    Map<String, Object> req = Map.of(
        "model", model,
        "temperature", 0.2,
        "messages", List.of(
            Map.of("role", "system", "content", system),
            Map.of("role", "user", "content", user)
        )
    );

    String body;
    try {
      body = objectMapper.writeValueAsString(req);
    } catch (IOException e) {
      return new LlmResult(true, true, false, false, "doubao", model, baseUrl, null,
          "json_encode_failed");
    }

    HttpRequest httpRequest = HttpRequest.newBuilder()
        .uri(URI.create(url))
        .timeout(Duration.ofSeconds(12))
        .header("Content-Type", "application/json")
        .header("Authorization", "Bearer " + apiKey)
        .POST(HttpRequest.BodyPublishers.ofString(body))
        .build();

    try {
      HttpResponse<String> resp = httpClient.send(httpRequest, HttpResponse.BodyHandlers.ofString());
      if (resp.statusCode() < 200 || resp.statusCode() >= 300) {
        return new LlmResult(true, true, true, false, "doubao", model, baseUrl, null,
            "http_" + resp.statusCode());
      }

      String content = extractContent(resp.body());
      if (content == null || content.isBlank()) {
        return new LlmResult(true, true, true, false, "doubao", model, baseUrl, null,
            "empty_response");
      }

      return new LlmResult(true, true, true, true, "doubao", model, baseUrl, content.trim(), null);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      return new LlmResult(true, true, true, false, "doubao", model, baseUrl, null, "interrupted");
    } catch (IOException e) {
      return new LlmResult(true, true, true, false, "doubao", model, baseUrl, null, "request_failed");
    } catch (RuntimeException e) {
      return new LlmResult(true, true, true, false, "doubao", model, baseUrl, null,
          "parse_failed");
    }
  }

  public LlmResult tryRewrite(String query, String draftAnswer, Map<String, Object> facts) {
    return tryRewrite(null, query, draftAnswer, facts);
  }

  private String extractContent(String json) throws IOException {
    Map<String, Object> resp = objectMapper.readValue(json, new TypeReference<Map<String, Object>>() {});
    Object choicesObj = resp.get("choices");
    if (!(choicesObj instanceof List<?> choices) || choices.isEmpty()) {
      return null;
    }
    Object c0 = choices.get(0);
    if (!(c0 instanceof Map<?, ?> c0m)) {
      return null;
    }
    Object msgObj = c0m.get("message");
    if (!(msgObj instanceof Map<?, ?> mm)) {
      return null;
    }
    Object content = mm.get("content");
    return content == null ? null : content.toString();
  }

  private String toPrettyJsonSafe(Map<String, Object> facts) {
    try {
      return objectMapper.writerWithDefaultPrettyPrinter().writeValueAsString(facts);
    } catch (IOException e) {
      return String.valueOf(facts);
    }
  }

  private static String safe(String s) {
    return s == null ? "" : s;
  }

  private static String modelOrEmpty(String s) {
    return s == null ? "" : s;
  }

  private static String normalizeBaseUrl(String baseUrl) {
    String u = baseUrl.trim();
    while (u.endsWith("/")) {
      u = u.substring(0, u.length() - 1);
    }
    return u;
  }
}
