package com.flutterai.backend.dto;

import java.time.OffsetDateTime;
import java.util.List;

import jakarta.validation.constraints.NotBlank;

public final class ActionDtos {
  private ActionDtos() {}

  public record RectificationActionIn(
      @NotBlank String actionType,
      String content,
      List<String> photoUrls,
      String actorRole,
      String actorName
  ) {
    public RectificationActionIn {
      if (photoUrls == null) {
        photoUrls = List.of();
      }
    }
  }

  public record RectificationActionOut(
      long id,
      long projectId,
      String targetType,
      long targetId,
      String actionType,
      String content,
      String photoUrls,
      String actorRole,
      String actorName,
      OffsetDateTime createdAt
  ) {}
}
