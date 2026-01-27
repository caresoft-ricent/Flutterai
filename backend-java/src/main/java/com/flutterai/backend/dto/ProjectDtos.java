package com.flutterai.backend.dto;

import java.time.OffsetDateTime;

import jakarta.validation.constraints.NotBlank;

public final class ProjectDtos {
  private ProjectDtos() {}

  public record ProjectIn(
      @NotBlank String name,
      String address
  ) {}

  public record ProjectOut(
      long id,
      String name,
      String address,
      OffsetDateTime createdAt
  ) {}
}
