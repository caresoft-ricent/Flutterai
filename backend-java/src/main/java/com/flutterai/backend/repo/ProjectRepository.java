package com.flutterai.backend.repo;

import java.util.Optional;

import org.springframework.data.jpa.repository.JpaRepository;

import com.flutterai.backend.domain.ProjectEntity;

public interface ProjectRepository extends JpaRepository<ProjectEntity, Long> {
  Optional<ProjectEntity> findByName(String name);
}
