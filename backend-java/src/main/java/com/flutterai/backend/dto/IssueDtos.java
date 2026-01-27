package com.flutterai.backend.dto;

import java.time.OffsetDateTime;

import jakarta.validation.constraints.NotBlank;

public final class IssueDtos {
  private IssueDtos() {}

  public record IssueReportIn(
      Long projectId,
      String projectName,
      String regionCode,
      String regionText,
      String division,
      String subdivision,
      String item,
      String indicator,
      String libraryId,
      @NotBlank String description,
      String severity,
      Integer deadlineDays,
      String responsibleUnit,
      String responsiblePerson,
      String status,
      String photoPath,
      String aiJson,
      OffsetDateTime clientCreatedAt,
      String source,
      String clientRecordId
  ) {}

  public record IssueReportOut(
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
      String indicator,
      String libraryId,
      String description,
      String severity,
      Integer deadlineDays,
      String responsibleUnit,
      String responsiblePerson,
      String status,
      String photoPath,
      String aiJson,
      OffsetDateTime clientCreatedAt,
      OffsetDateTime createdAt,
      String source,
      String clientRecordId
  ) {}
}
