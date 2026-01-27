package com.flutterai.backend.repo;

import java.util.List;
import java.util.Optional;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import com.flutterai.backend.domain.AcceptanceRecordEntity;

public interface AcceptanceRecordRepository extends JpaRepository<AcceptanceRecordEntity, Long> {
  List<AcceptanceRecordEntity> findByProjectIdOrderByCreatedAtDesc(Long projectId, Pageable pageable);

  Optional<AcceptanceRecordEntity> findFirstByProjectIdAndClientRecordId(Long projectId, String clientRecordId);

  long countByProjectIdAndBuildingNoIsNull(Long projectId);
}
