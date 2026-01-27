package com.flutterai.backend.api;

import java.util.List;
import java.util.Map;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import com.flutterai.backend.dto.AcceptanceDtos.AcceptanceRecordIn;
import com.flutterai.backend.dto.AcceptanceDtos.AcceptanceRecordOut;
import com.flutterai.backend.dto.AcceptanceDtos.AcceptanceVerifyIn;
import com.flutterai.backend.dto.ActionDtos.RectificationActionIn;
import com.flutterai.backend.dto.ActionDtos.RectificationActionOut;
import com.flutterai.backend.service.AcceptanceService;
import com.flutterai.backend.service.ActionService;
import com.flutterai.backend.service.ProjectService;

import jakarta.validation.Valid;

@RestController
public class AcceptanceController {
  private final AcceptanceService acceptanceService;
  private final ActionService actionService;
  private final ProjectService projectService;

  public AcceptanceController(AcceptanceService acceptanceService, ActionService actionService, ProjectService projectService) {
    this.acceptanceService = acceptanceService;
    this.actionService = actionService;
    this.projectService = projectService;
  }

  @PostMapping("/v1/acceptance-records")
  public Map<String, Object> createAcceptance(@Valid @RequestBody AcceptanceRecordIn payload) {
    var row = acceptanceService.upsert(payload);
    return Map.of("id", row.getId());
  }

  @GetMapping("/v1/acceptance-records")
  public List<AcceptanceRecordOut> listAcceptance(
      @RequestParam(name = "project_id", defaultValue = "1") long projectId,
      @RequestParam(name = "project_name", required = false) String projectName,
      @RequestParam(name = "limit", defaultValue = "100") int limit) {

    if (projectName != null && !projectName.trim().isEmpty()) {
      projectId = projectService.ensureProject(projectName.trim()).getId();
    }

    return acceptanceService.list(projectId, limit).stream()
        .map(r -> new AcceptanceRecordOut(
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
            r.getItemCode(),
            r.getIndicator(),
            r.getIndicatorCode(),
            r.getResult(),
            r.getPhotoPath(),
            r.getRemark(),
            r.getAiJson(),
            r.getClientCreatedAt(),
            r.getCreatedAt(),
            r.getSource(),
            r.getClientRecordId()
        ))
        .toList();
  }

  @GetMapping("/v1/acceptance-records/{recordId}")
  public AcceptanceRecordOut getAcceptance(@PathVariable("recordId") long recordId) {
    var r = acceptanceService.get(recordId);
    if (r == null) {
      throw new ApiNotFoundException("acceptance record not found");
    }
    return new AcceptanceRecordOut(
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
        r.getItemCode(),
        r.getIndicator(),
        r.getIndicatorCode(),
        r.getResult(),
        r.getPhotoPath(),
        r.getRemark(),
        r.getAiJson(),
        r.getClientCreatedAt(),
        r.getCreatedAt(),
        r.getSource(),
        r.getClientRecordId()
    );
  }

  @GetMapping("/v1/acceptance-records/{recordId}/actions")
  public List<RectificationActionOut> listActions(@PathVariable("recordId") long recordId) {
    var r = acceptanceService.get(recordId);
    if (r == null) {
      throw new ApiNotFoundException("acceptance record not found");
    }
    return actionService.listActions("acceptance", recordId, 200).stream()
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

  @PostMapping("/v1/acceptance-records/{recordId}/actions")
  public Map<String, Object> addAction(@PathVariable("recordId") long recordId, @Valid @RequestBody RectificationActionIn payload) {
    var r = acceptanceService.get(recordId);
    if (r == null) {
      throw new ApiNotFoundException("acceptance record not found");
    }
    var row = actionService.addAction(r.getProjectId(), "acceptance", recordId, payload);
    return Map.of("id", row.getId());
  }

  @PostMapping("/v1/acceptance-records/{recordId}/verify")
  public Map<String, Object> verify(@PathVariable("recordId") long recordId, @Valid @RequestBody AcceptanceVerifyIn payload) {
    var r = acceptanceService.verify(recordId, payload);
    if (r == null) {
      throw new ApiNotFoundException("acceptance record not found");
    }
    return Map.of("id", r.getId(), "result", r.getResult());
  }
}
