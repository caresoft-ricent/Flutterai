package com.flutterai.backend.dto;

import java.util.List;
import java.util.Map;

public final class AiDtos {
  private AiDtos() {}

  public record ChatIn(
      String query,
      String projectName,
      List<Map<String, Object>> messages,
      Boolean aiEnabled
  ) {}

  public record ChatOut(
      String answer,
      Map<String, Object> facts,
      Map<String, Object> meta
  ) {}
}
