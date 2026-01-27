package com.flutterai.backend.service;

import java.util.List;

import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.flutterai.backend.domain.IssueReportEntity;
import com.flutterai.backend.domain.ProjectEntity;
import com.flutterai.backend.dto.ActionDtos.RectificationActionIn;
import com.flutterai.backend.dto.IssueDtos.IssueReportIn;
import com.flutterai.backend.repo.IssueReportRepository;
import com.flutterai.backend.util.RegionParser;
import com.flutterai.backend.util.RegionParser.ParsedRegion;
import com.flutterai.backend.util.UploadRefNormalizer;

@Service
public class IssueService {
  private final IssueReportRepository issueRepository;
  private final ProjectService projectService;
  private final ActionService actionService;

  public IssueService(
      IssueReportRepository issueRepository,
      ProjectService projectService,
      ActionService actionService) {
    this.issueRepository = issueRepository;
    this.projectService = projectService;
    this.actionService = actionService;
  }

  @Transactional
  public IssueReportEntity upsert(IssueReportIn payload) {
    Long projectId = resolveProjectId(payload.projectId(), payload.projectName());

    String regionText = payload.regionText() == null ? "" : payload.regionText();
    ParsedRegion parsed = RegionParser.parse(regionText);

    String normalizedPhoto = UploadRefNormalizer.normalize(payload.photoPath());

    String clientRecordId = payload.clientRecordId() == null ? null : payload.clientRecordId().trim();
    if (clientRecordId != null && !clientRecordId.isEmpty()) {
      var existingOpt = issueRepository.findFirstByProjectIdAndClientRecordId(projectId, clientRecordId);
      if (existingOpt.isPresent()) {
        IssueReportEntity existing = existingOpt.get();
        apply(existing, payload, parsed, normalizedPhoto);
        return issueRepository.save(existing);
      }
    }

    IssueReportEntity row = new IssueReportEntity();
    row.setProjectId(projectId);
    apply(row, payload, parsed, normalizedPhoto);
    return issueRepository.save(row);
  }

  @Transactional(readOnly = true)
  public List<IssueReportEntity> list(long projectId, int limit, String status, String responsibleUnit) {
    int safeLimit = Math.max(1, Math.min(limit <= 0 ? 100 : limit, 500));
    var pageable = PageRequest.of(0, safeLimit);

    boolean hasStatus = status != null && !status.trim().isEmpty();
    boolean hasUnit = responsibleUnit != null && !responsibleUnit.trim().isEmpty();

    if (hasStatus && hasUnit) {
      return issueRepository.findByProjectIdAndStatusAndResponsibleUnitOrderByCreatedAtDesc(projectId, status, responsibleUnit, pageable);
    }
    if (hasStatus) {
      return issueRepository.findByProjectIdAndStatusOrderByCreatedAtDesc(projectId, status, pageable);
    }
    if (hasUnit) {
      return issueRepository.findByProjectIdAndResponsibleUnitOrderByCreatedAtDesc(projectId, responsibleUnit, pageable);
    }

    return issueRepository.findByProjectIdOrderByCreatedAtDesc(projectId, pageable);
  }

  @Transactional(readOnly = true)
  public IssueReportEntity get(long issueId) {
    return issueRepository.findById(issueId).orElse(null);
  }

  @Transactional
  public IssueReportEntity close(long issueId, RectificationActionIn payload) {
    IssueReportEntity r = get(issueId);
    if (r == null) {
      return null;
    }
    r.setStatus("closed");
    r = issueRepository.save(r);

  RectificationActionIn p = payload == null
    ? new RectificationActionIn("close", null, List.of(), null, null)
    : new RectificationActionIn("close", payload.content(), payload.photoUrls(), payload.actorRole(), payload.actorName());
  actionService.addAction(r.getProjectId(), "issue", r.getId(), p);

    return r;
  }

  private Long resolveProjectId(Long projectId, String projectName) {
    if (projectId != null) {
      return projectId;
    }
    if (projectName != null && !projectName.trim().isEmpty()) {
      ProjectEntity p = projectService.ensureProject(projectName);
      return p.getId();
    }
    return projectService.ensureProject("默认项目").getId();
  }

  private void apply(IssueReportEntity row, IssueReportIn payload, ParsedRegion parsed, String normalizedPhoto) {
    row.setRegionCode(payload.regionCode());
    row.setRegionText(payload.regionText());

    row.setBuildingNo(parsed.buildingNo());
    row.setFloorNo(parsed.floorNo());
    row.setZone(parsed.zone());

    row.setDivision(payload.division());
    row.setSubdivision(payload.subdivision());
    row.setItem(payload.item());
    row.setIndicator(payload.indicator());
    row.setLibraryId(payload.libraryId());

    row.setDescription(payload.description());
    row.setSeverity(payload.severity());
    row.setDeadlineDays(payload.deadlineDays());
    row.setResponsibleUnit(payload.responsibleUnit());
    row.setResponsiblePerson(payload.responsiblePerson());

    String status = payload.status();
    row.setStatus(status == null || status.isBlank() ? "open" : status);

    row.setPhotoPath(normalizedPhoto);
    row.setAiJson(payload.aiJson());
    row.setClientCreatedAt(payload.clientCreatedAt());
    row.setSource(payload.source());
    row.setClientRecordId(payload.clientRecordId());
  }
}
