package com.flutterai.backend.api;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.flutterai.backend.service.DashboardService;
import com.flutterai.backend.service.ProjectService;

@RestController
public class DashboardController {
  private final DashboardService dashboardService;
  private final ProjectService projectService;

  public DashboardController(DashboardService dashboardService, ProjectService projectService) {
    this.dashboardService = dashboardService;
    this.projectService = projectService;
  }

  @GetMapping("/v1/dashboard/summary")
  public Object summary(
      @RequestParam(name = "project_id", defaultValue = "1") long projectId,
      @RequestParam(name = "project_name", required = false) String projectName,
      @RequestParam(name = "limit", defaultValue = "10") int limit) {

    if (projectName != null && !projectName.trim().isEmpty()) {
      projectId = projectService.ensureProject(projectName.trim()).getId();
    }
    return dashboardService.summary(projectId, limit);
  }

  @GetMapping("/v1/dashboard/focus")
  public Object focus(
      @RequestParam(name = "project_id", defaultValue = "1") long projectId,
      @RequestParam(name = "project_name", required = false) String projectName,
      @RequestParam(name = "time_range_days", defaultValue = "14") int timeRangeDays,
      @RequestParam(name = "building", required = false) String building,
      @RequestParam(name = "do_backfill", defaultValue = "true") boolean doBackfill,
      @RequestParam(name = "backfill_limit", defaultValue = "200") int backfillLimit) {

    if (projectName != null && !projectName.trim().isEmpty()) {
      projectId = projectService.ensureProject(projectName.trim()).getId();
    }

    String b = building == null || building.trim().isEmpty() ? null : building.trim();
    return dashboardService.focusPack(projectId, timeRangeDays, b, doBackfill, backfillLimit);
  }
}
