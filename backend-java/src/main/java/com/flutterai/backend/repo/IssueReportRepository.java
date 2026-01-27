package com.flutterai.backend.repo;

import java.util.List;
import java.util.Optional;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import com.flutterai.backend.domain.IssueReportEntity;

public interface IssueReportRepository extends JpaRepository<IssueReportEntity, Long> {
  List<IssueReportEntity> findByProjectIdOrderByCreatedAtDesc(Long projectId, Pageable pageable);

  List<IssueReportEntity> findByProjectIdAndStatusOrderByCreatedAtDesc(Long projectId, String status, Pageable pageable);

  List<IssueReportEntity> findByProjectIdAndResponsibleUnitOrderByCreatedAtDesc(Long projectId, String responsibleUnit, Pageable pageable);

  List<IssueReportEntity> findByProjectIdAndStatusAndResponsibleUnitOrderByCreatedAtDesc(Long projectId, String status, String responsibleUnit, Pageable pageable);

  Optional<IssueReportEntity> findFirstByProjectIdAndClientRecordId(Long projectId, String clientRecordId);

  long countByProjectIdAndBuildingNoIsNull(Long projectId);
}
