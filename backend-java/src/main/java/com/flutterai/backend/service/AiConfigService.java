package com.flutterai.backend.service;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;

@Service
public class AiConfigService {
  private final ObjectMapper objectMapper;

  @Value("${app.ai.local-config-path:./config.json}")
  private String localConfigPath;

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
      Path p = Path.of(localConfigPath);
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
