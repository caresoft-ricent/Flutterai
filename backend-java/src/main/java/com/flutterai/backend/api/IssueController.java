package com.flutterai.backend.api;

import java.util.List;
import java.util.Map;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.flutterai.backend.dto.ActionDtos.RectificationActionIn;
import com.flutterai.backend.dto.ActionDtos.RectificationActionOut;
import com.flutterai.backend.dto.IssueDtos.IssueReportIn;
import com.flutterai.backend.dto.IssueDtos.IssueReportOut;
import com.flutterai.backend.service.ActionService;
import com.flutterai.backend.service.IssueService;
import com.flutterai.backend.service.ProjectService;

import jakarta.validation.Valid;

@RestController
public class IssueController {
  private final IssueService issueService;
  private final ActionService actionService;
  private final ProjectService projectService;

  public IssueController(IssueService issueService, ActionService actionService, ProjectService projectService) {
    this.issueService = issueService;
    this.actionService = actionService;
    this.projectService = projectService;
  }

  @PostMapping("/v1/issue-reports")
  public Map<String, Object> createIssue(@Valid @RequestBody IssueReportIn payload) {
    var row = issueService.upsert(payload);
    return Map.of("id", row.getId());
  }

  @GetMapping("/v1/issue-reports")
  public List<IssueReportOut> listIssues(
      @RequestParam(name = "project_id", defaultValue = "1") long projectId,
      @RequestParam(name = "project_name", required = false) String projectName,
      @RequestParam(name = "limit", defaultValue = "100") int limit,
      @RequestParam(name = "status", required = false) String status,
      @RequestParam(name = "responsible_unit", required = false) String responsibleUnit) {

    if (projectName != null && !projectName.trim().isEmpty()) {
      projectId = projectService.ensureProject(projectName.trim()).getId();
    }

    return issueService.list(projectId, limit, status, responsibleUnit).stream()
        .map(r -> new IssueReportOut(
            r.getId(),
            r.getProjectId(),
            r.getRegionCode(),
            r.getRegionText(),
            r.getBuildingNo(),
            r.getFloorNo(),
            r.getZone(),
            r.getDivision(),
            r.getSubdivision(),
            r.getItem(),
            r.getIndicator(),
            r.getLibraryId(),
            r.getDescription(),
            r.getSeverity(),
            r.getDeadlineDays(),
            r.getResponsibleUnit(),
            r.getResponsiblePerson(),
            r.getStatus(),
            r.getPhotoPath(),
            r.getAiJson(),
            r.getClientCreatedAt(),
            r.getCreatedAt(),
            r.getSource(),
            r.getClientRecordId()
        ))
        .toList();
  }

  @GetMapping("/v1/issue-reports/{issueId}")
  public IssueReportOut getIssue(@PathVariable("issueId") long issueId) {
    var r = issueService.get(issueId);
    if (r == null) {
      throw new ApiNotFoundException("issue report not found");
    }
    return new IssueReportOut(
        r.getId(),
        r.getProjectId(),
        r.getRegionCode(),
        r.getRegionText(),
        r.getBuildingNo(),
        r.getFloorNo(),
        r.getZone(),
        r.getDivision(),
        r.getSubdivision(),
        r.getItem(),
        r.getIndicator(),
        r.getLibraryId(),
        r.getDescription(),
        r.getSeverity(),
        r.getDeadlineDays(),
        r.getResponsibleUnit(),
        r.getResponsiblePerson(),
        r.getStatus(),
        r.getPhotoPath(),
        r.getAiJson(),
        r.getClientCreatedAt(),
        r.getCreatedAt(),
        r.getSource(),
        r.getClientRecordId()
    );
  }

  @GetMapping("/v1/issue-reports/{issueId}/actions")
  public List<RectificationActionOut> listActions(@PathVariable("issueId") long issueId) {
    var r = issueService.get(issueId);
    if (r == null) {
      throw new ApiNotFoundException("issue report not found");
    }
    return actionService.listActions("issue", issueId, 200).stream()
        .map(a -> new RectificationActionOut(
            a.getId(),
            a.getProjectId(),
            a.getTargetType(),
            a.getTargetId(),
            a.getActionType(),
            a.getContent(),
            a.getPhotoUrls(),
            a.getActorRole(),
            a.getActorName(),
            a.getCreatedAt()
        ))
        .toList();
  }

  @PostMapping("/v1/issue-reports/{issueId}/actions")
  public Map<String, Object> addAction(@PathVariable("issueId") long issueId, @Valid @RequestBody RectificationActionIn payload) {
    var r = issueService.get(issueId);
    if (r == null) {
      throw new ApiNotFoundException("issue report not found");
    }
    var row = actionService.addAction(r.getProjectId(), "issue", issueId, payload);
    return Map.of("id", row.getId());
  }

  @PostMapping("/v1/issue-reports/{issueId}/close")
  public Map<String, Object> close(@PathVariable("issueId") long issueId, @RequestBody RectificationActionIn payload) {
    var r = issueService.close(issueId, payload);
    if (r == null) {
      throw new ApiNotFoundException("issue report not found");
    }
    return Map.of("id", r.getId(), "status", r.getStatus());
  }
}
