package com.flutterai.backend.repo;

import java.util.List;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import com.flutterai.backend.domain.RectificationActionEntity;

public interface RectificationActionRepository extends JpaRepository<RectificationActionEntity, Long> {
  List<RectificationActionEntity> findByTargetTypeAndTargetIdOrderByCreatedAtAsc(String targetType, Long targetId, Pageable pageable);
}
