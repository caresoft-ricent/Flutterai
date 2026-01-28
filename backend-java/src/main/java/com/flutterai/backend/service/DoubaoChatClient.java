package com.flutterai.backend.service;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.time.Duration;
import java.util.HashMap;
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
      String error,
      Long timeoutMs,
      Long elapsedMs
  ) {
    public static LlmResult notEnabled() {
      return new LlmResult(false, false, false, false, "doubao", "", "", null, null, null, null);
    }
  }

  private final AiConfigService aiConfig;
  private final ObjectMapper objectMapper;
  private final HttpClient httpClient;

  public DoubaoChatClient(AiConfigService aiConfig, ObjectMapper objectMapper) {
    this.aiConfig = aiConfig;
    this.objectMapper = objectMapper;
    this.httpClient = HttpClient.newBuilder()
        .connectTimeout(Duration.ofMillis(Math.max(500L, aiConfig.llmConnectTimeoutMs())))
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
        enabledOverride != null ? "disabled_by_client" : null, null, null);
    }

    if (!configured) {
      return new LlmResult(true, false, false, false, "doubao", modelOrEmpty(model), baseUrl, null,
        "missing api_key/model", null, null);
    }

    long timeoutMs = Math.max(1000L, aiConfig.llmRequestTimeoutMs());
    long startNs = System.nanoTime();

    String url = normalizeBaseUrl(baseUrl) + "/chat/completions";

    String system = String.join("\n", List.of(
      "你是建筑质量巡检/验收数据助手。",
      "你只做‘改写润色’，不得改变事实。",
      "硬性规则：",
      "1) 绝对禁止编造/新增任何数字、条数、楼栋、楼层、状态(open/closed)、严重程度。",
      "2) 规则版草稿回答里的所有阿拉伯数字(0-9)必须原样保留；不得把非零改成 0。",
      "3) 若无法严格遵守，请原样输出规则版草稿回答，不要新增结论。",
      "4) 不要输出 markdown 代码块；不要输出多余解释。"
    ));

    String user = "用户问题：" + safe(query)
        + "\n\n已计算 facts_view(JSON)：\n" + toPrettyJsonSafe(factsView(facts))
        + "\n\n规则版草稿回答：\n" + safe(draftAnswer)
        + "\n\n任务：在不改变任何事实/数字的前提下，把‘规则版草稿回答’改写得更自然；"
        + "建议必须从草稿或 facts_view 推导，不允许新增事实。";

    Map<String, Object> req = Map.of(
        "model", model,
      "temperature", 0.0,
      "max_tokens", 256,
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
          "json_encode_failed", timeoutMs, elapsedMs(startNs));
    }

    HttpRequest httpRequest = HttpRequest.newBuilder()
        .uri(URI.create(url))
        .timeout(Duration.ofMillis(timeoutMs))
        .header("Content-Type", "application/json")
        .header("Authorization", "Bearer " + apiKey)
        .POST(HttpRequest.BodyPublishers.ofString(body))
        .build();

    try {
      HttpResponse<String> resp = httpClient.send(httpRequest, HttpResponse.BodyHandlers.ofString());
      if (resp.statusCode() < 200 || resp.statusCode() >= 300) {
        return new LlmResult(true, true, true, false, "doubao", model, baseUrl, null,
            "http_" + resp.statusCode(), timeoutMs, elapsedMs(startNs));
      }

      String content = extractContent(resp.body());
      if (content == null || content.isBlank()) {
        return new LlmResult(true, true, true, false, "doubao", model, baseUrl, null,
            "empty_response", timeoutMs, elapsedMs(startNs));
      }

      return new LlmResult(true, true, true, true, "doubao", model, baseUrl, content.trim(), null, timeoutMs, elapsedMs(startNs));
    } catch (HttpTimeoutException e) {
      return new LlmResult(true, true, true, false, "doubao", model, baseUrl, null, "timeout", timeoutMs, elapsedMs(startNs));
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      return new LlmResult(true, true, true, false, "doubao", model, baseUrl, null, "interrupted", timeoutMs, elapsedMs(startNs));
    } catch (IOException e) {
      return new LlmResult(true, true, true, false, "doubao", model, baseUrl, null, "request_failed", timeoutMs, elapsedMs(startNs));
    } catch (RuntimeException e) {
      return new LlmResult(true, true, true, false, "doubao", model, baseUrl, null,
          "parse_failed", timeoutMs, elapsedMs(startNs));
    }
  }

  public LlmResult tryRewrite(String query, String draftAnswer, Map<String, Object> facts) {
    return tryRewrite(null, query, draftAnswer, facts);
  }

  /**
   * Returns current enable/config status without making any network calls.
   */
  public LlmResult status(Boolean enabledOverride, String reason) {
    String apiKey = aiConfig.doubaoApiKey();
    String model = aiConfig.doubaoModel();
    String baseUrl = aiConfig.doubaoBaseUrl();
    if (baseUrl == null || baseUrl.isBlank()) {
      baseUrl = DEFAULT_BASE_URL;
    }

    boolean enabled = enabledOverride != null ? enabledOverride.booleanValue() : aiConfig.isAiEnabled();
    boolean configured = apiKey != null && !apiKey.isBlank() && model != null && !model.isBlank();

    String err = (reason == null || reason.isBlank()) ? null : reason;
    if (!enabled && enabledOverride != null) {
      err = "disabled_by_client";
    }
    if (!enabled && err == null) {
      err = null;
    }

    return new LlmResult(enabled, configured, false, false, "doubao", modelOrEmpty(model), baseUrl, null, err, null, null);
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

  private static Long elapsedMs(long startNs) {
    try {
      return Math.max(0L, (System.nanoTime() - startNs) / 1_000_000L);
    } catch (RuntimeException e) {
      return null;
    }
  }

  @SuppressWarnings("unchecked")
  private static Map<String, Object> factsView(Map<String, Object> facts) {
    if (facts == null || facts.isEmpty()) {
      return Map.of();
    }

    Object byBuildingObj = facts.get("by_building");
    List<Map<String, Object>> byBuilding = List.of();
    if (byBuildingObj instanceof List<?> l) {
      byBuilding = l.stream()
          .filter(it -> it instanceof Map<?, ?>)
          .limit(6)
          .map(it -> (Map<String, Object>) it)
          .map(m -> Map.<String, Object>of(
              "building", m.getOrDefault("building", ""),
              "acceptance_total", m.getOrDefault("acceptance_total", 0),
              "acceptance_unqualified", m.getOrDefault("acceptance_unqualified", 0),
              "acceptance_pending", m.getOrDefault("acceptance_pending", 0),
              "issues_total", m.getOrDefault("issues_total", 0),
              "issues_open", m.getOrDefault("issues_open", 0)
          ))
          .toList();
    }

    Object topUnitsObj = facts.get("top_responsible_units");
    List<Map<String, Object>> topUnits = List.of();
    if (topUnitsObj instanceof List<?> l) {
      topUnits = l.stream()
          .filter(it -> it instanceof Map<?, ?>)
          .limit(3)
          .map(it -> (Map<String, Object>) it)
          .map(m -> Map.<String, Object>of(
              "responsible_unit", m.getOrDefault("responsible_unit", ""),
              "count", m.getOrDefault("count", 0)
          ))
          .toList();
    }

    Object planObj = facts.get("plan");
    Map<String, Object> plan = (planObj instanceof Map<?, ?> m) ? (Map<String, Object>) m : Map.of();

    Map<String, Object> view = new HashMap<>();
    view.put("plan", plan);
    view.put("acceptance_total", facts.getOrDefault("acceptance_total", 0));
    view.put("acceptance_qualified", facts.getOrDefault("acceptance_qualified", 0));
    view.put("acceptance_unqualified", facts.getOrDefault("acceptance_unqualified", 0));
    view.put("acceptance_pending", facts.getOrDefault("acceptance_pending", 0));
    view.put("issues_total", facts.getOrDefault("issues_total", 0));
    view.put("issues_open", facts.getOrDefault("issues_open", 0));
    view.put("issues_closed", facts.getOrDefault("issues_closed", 0));
    view.put("issues_by_severity", facts.getOrDefault("issues_by_severity", Map.of()));
    view.put("top_responsible_units", topUnits);
    view.put("by_building", byBuilding);
    return view;
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
