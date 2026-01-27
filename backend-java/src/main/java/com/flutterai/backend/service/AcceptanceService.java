package com.flutterai.backend.service;

import java.util.List;
import java.util.Set;

import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.flutterai.backend.domain.AcceptanceRecordEntity;
import com.flutterai.backend.domain.ProjectEntity;
import com.flutterai.backend.dto.AcceptanceDtos.AcceptanceRecordIn;
import com.flutterai.backend.dto.AcceptanceDtos.AcceptanceVerifyIn;
import com.flutterai.backend.dto.ActionDtos.RectificationActionIn;
import com.flutterai.backend.repo.AcceptanceRecordRepository;
import com.flutterai.backend.util.RegionParser;
import com.flutterai.backend.util.RegionParser.ParsedRegion;
import com.flutterai.backend.util.UploadRefNormalizer;

@Service
public class AcceptanceService {
  private static final Set<String> VALID_RESULTS = Set.of("qualified", "unqualified", "pending");

  private final AcceptanceRecordRepository acceptanceRepository;
  private final ProjectService projectService;
  private final ActionService actionService;

  public AcceptanceService(
      AcceptanceRecordRepository acceptanceRepository,
      ProjectService projectService,
      ActionService actionService) {
    this.acceptanceRepository = acceptanceRepository;
    this.projectService = projectService;
    this.actionService = actionService;
  }

  @Transactional
  public AcceptanceRecordEntity upsert(AcceptanceRecordIn payload) {
    Long projectId = resolveProjectId(payload.projectId(), payload.projectName());

    ParsedRegion parsed = RegionParser.parse(payload.regionText());
    String normalizedPhoto = UploadRefNormalizer.normalize(payload.photoPath());

    String clientRecordId = payload.clientRecordId() == null ? null : payload.clientRecordId().trim();
    if (clientRecordId != null && !clientRecordId.isEmpty()) {
      var existingOpt = acceptanceRepository.findFirstByProjectIdAndClientRecordId(projectId, clientRecordId);
      if (existingOpt.isPresent()) {
        AcceptanceRecordEntity existing = existingOpt.get();
        apply(existing, payload, parsed, normalizedPhoto);
        return acceptanceRepository.save(existing);
      }
    }

    AcceptanceRecordEntity row = new AcceptanceRecordEntity();
    row.setProjectId(projectId);
    apply(row, payload, parsed, normalizedPhoto);
    return acceptanceRepository.save(row);
  }

  @Transactional(readOnly = true)
  public List<AcceptanceRecordEntity> list(long projectId, int limit) {
    int safeLimit = Math.max(1, Math.min(limit <= 0 ? 100 : limit, 500));
    return acceptanceRepository.findByProjectIdOrderByCreatedAtDesc(projectId, PageRequest.of(0, safeLimit));
  }

  @Transactional(readOnly = true)
  public AcceptanceRecordEntity get(long recordId) {
    return acceptanceRepository.findById(recordId).orElse(null);
  }

  @Transactional
  public AcceptanceRecordEntity verify(long recordId, AcceptanceVerifyIn payload) {
    AcceptanceRecordEntity r = get(recordId);
    if (r == null) {
      return null;
    }
    String next = (payload.result() == null ? "" : payload.result().trim().toLowerCase());
    if (!VALID_RESULTS.contains(next)) {
      throw new IllegalArgumentException("invalid result");
    }

    r.setResult(next);
    if (payload.remark() != null) {
      r.setRemark(payload.remark());
    }
    r = acceptanceRepository.save(r);

    String content = (payload.remark() == null ? "" : payload.remark().trim());
    if (content.isEmpty()) {
      content = "复验结果：" + next;
    }

    actionService.addAction(
        r.getProjectId(),
        "acceptance",
        r.getId(),
        new RectificationActionIn(
            "verify",
            content,
            payload.photoUrls(),
            payload.actorRole(),
            payload.actorName()
        )
    );

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

  private void apply(AcceptanceRecordEntity row, AcceptanceRecordIn payload, ParsedRegion parsed, String normalizedPhoto) {
    row.setRegionCode(payload.regionCode());
    row.setRegionText(payload.regionText());

    row.setBuildingNo(parsed.buildingNo());
    row.setFloorNo(parsed.floorNo());
    row.setZone(parsed.zone());

    row.setDivision(payload.division());
    row.setSubdivision(payload.subdivision());
    row.setItem(payload.item());
    row.setItemCode(payload.itemCode());
    row.setIndicator(payload.indicator());
    row.setIndicatorCode(payload.indicatorCode());

    row.setResult(payload.result());
    row.setPhotoPath(normalizedPhoto);
    row.setRemark(payload.remark());
    row.setAiJson(payload.aiJson());
    row.setClientCreatedAt(payload.clientCreatedAt());
    row.setSource(payload.source());
    row.setClientRecordId(payload.clientRecordId());
  }
}
