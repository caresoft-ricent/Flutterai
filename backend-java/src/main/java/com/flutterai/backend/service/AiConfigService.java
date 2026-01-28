package com.flutterai.backend.service;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.flutterai.backend.util.SharedBackendPaths;

@Service
public class AiConfigService {
  private final ObjectMapper objectMapper;

  @Value("${app.ai.enabled:false}")
  private boolean enabled;

  @Value("${app.ai.local-config-path:./config.json}")
  private String localConfigPath;

  // LLM HTTP client timeouts (ms). Keep request timeout < mobile client's receiveTimeout.
  @Value("${app.ai.llm.connect-timeout-ms:5000}")
  private long llmConnectTimeoutMs;

  @Value("${app.ai.llm.request-timeout-ms:12000}")
  private long llmRequestTimeoutMs;

  public AiConfigService(ObjectMapper objectMapper) {
    this.objectMapper = objectMapper;
  }

  public String getEnv(String... names) {
    for (String n : names) {
      String v = System.getenv(n);
      if (v != null && !v.trim().isEmpty()) {
        return v.trim();
      }
    }
    return null;
  }

  public boolean isAiEnabled() {
    String env = getEnv("APP_AI_ENABLED", "AI_ENABLED");
    if (env != null) {
      String v = env.trim().toLowerCase();
      return v.equals("1") || v.equals("true") || v.equals("yes") || v.equals("y") || v.equals("on");
    }
    return enabled;
  }

  public long llmConnectTimeoutMs() {
    return llmConnectTimeoutMs;
  }

  public long llmRequestTimeoutMs() {
    return llmRequestTimeoutMs;
  }

  public String doubaoApiKey() {
    return firstNonNull(
        getEnv("ARK_API_KEY", "DOUBAO_API_KEY"),
        getCfg("doubao.api_key")
    );
  }

  public String doubaoModel() {
    return firstNonNull(
        getEnv("ARK_MODEL", "DOUBAO_MODEL", "DOUBAO_ENDPOINT_ID"),
        getCfg("doubao.model"),
        getCfg("doubao.endpoint_id")
    );
  }

  public String doubaoBaseUrl() {
    return firstNonNull(
        getEnv("ARK_BASE_URL", "DOUBAO_BASE_URL"),
        getCfg("doubao.base_url")
    );
  }

  private static String firstNonNull(String... values) {
    if (values == null) {
      return null;
    }
    for (String v : values) {
      if (v != null && !v.trim().isEmpty()) {
        return v.trim();
      }
    }
    return null;
  }

  public String getCfg(String path) {
    Map<String, Object> cfg = loadLocalConfig();
    if (cfg == null) {
      return null;
    }
    Object cur = cfg;
    for (String part : path.split("\\.")) {
      if (!(cur instanceof Map<?, ?> m) || !m.containsKey(part)) {
        return null;
      }
      cur = m.get(part);
    }
    if (cur == null) {
      return null;
    }
    String s = cur.toString().trim();
    return s.isEmpty() ? null : s;
  }

  @SuppressWarnings("unchecked")
  private Map<String, Object> loadLocalConfig() {
    try {
      Path p = SharedBackendPaths.resolveExistingFile(
          localConfigPath,
          List.of("backend/config.json", "../backend/config.json")
      );
      if (p == null) {
        p = Path.of("backend/config.json").toAbsolutePath().normalize();
      }
      if (!Files.exists(p)) {
        return Map.of();
      }
      String json = Files.readString(p);
      Object data = objectMapper.readValue(json, new TypeReference<Map<String, Object>>() {});
      return data instanceof Map<?, ?> m ? (Map<String, Object>) m : Map.of();
    } catch (IOException e) {
      return Map.of();
    }
  }
}
