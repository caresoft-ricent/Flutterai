package com.flutterai.backend.dto;

import java.util.List;
import java.util.Map;

public final class DashboardDtos {
  private DashboardDtos() {}

  public record DashboardSummaryOut(
      int acceptanceTotal,
      int acceptanceQualified,
      int acceptanceUnqualified,
      int acceptancePending,
      int issuesTotal,
      int issuesOpen,
      int issuesClosed,
      Map<String, Integer> issuesBySeverity,
      List<Map<String, Object>> topResponsibleUnits,
      List<Map<String, Object>> recentUnqualifiedAcceptance,
      List<Map<String, Object>> recentOpenIssues
  ) {}
}
