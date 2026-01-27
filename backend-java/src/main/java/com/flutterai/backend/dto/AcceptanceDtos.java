package com.flutterai.backend.dto;

import java.time.OffsetDateTime;
import java.util.List;

import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import com.flutterai.backend.config.LenientOffsetDateTimeDeserializer;

import jakarta.validation.constraints.NotBlank;

public final class AcceptanceDtos {
  private AcceptanceDtos() {}

  public record AcceptanceRecordIn(
      Long projectId,
      String projectName,
      String regionCode,
      String regionText,
      String division,
      String subdivision,
      String item,
      String itemCode,
      String indicator,
      String indicatorCode,
      @NotBlank String result,
      String photoPath,
      String remark,
      String aiJson,
        @JsonDeserialize(using = LenientOffsetDateTimeDeserializer.class)
        OffsetDateTime clientCreatedAt,
      String source,
      String clientRecordId
  ) {}

  public record AcceptanceRecordOut(
      long id,
      long projectId,
      String regionCode,
      String regionText,
      String buildingNo,
      Integer floorNo,
      String zone,
      String division,
      String subdivision,
      String item,
      String itemCode,
      String indicator,
      String indicatorCode,
      String result,
      String photoPath,
      String remark,
      String aiJson,
      OffsetDateTime clientCreatedAt,
      OffsetDateTime createdAt,
      String source,
      String clientRecordId
  ) {}

  public record AcceptanceVerifyIn(
      @NotBlank String result,
      String remark,
      List<String> photoUrls,
      String actorRole,
      String actorName
  ) {
    public AcceptanceVerifyIn {
      if (photoUrls == null) {
        photoUrls = List.of();
      }
    }
  }
}
