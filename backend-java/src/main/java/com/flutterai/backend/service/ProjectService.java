package com.flutterai.backend.service;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.flutterai.backend.domain.ProjectEntity;
import com.flutterai.backend.repo.ProjectRepository;

@Service
public class ProjectService {
  private final ProjectRepository projectRepository;

  public ProjectService(ProjectRepository projectRepository) {
    this.projectRepository = projectRepository;
  }

  @Transactional
  public ProjectEntity ensureProject(String name) {
    String n = (name == null ? "" : name.trim());
    if (n.isEmpty()) {
      throw new IllegalArgumentException("project_name is empty");
    }
    return projectRepository.findByName(n).orElseGet(() -> {
      ProjectEntity p = new ProjectEntity();
      p.setName(n);
      return projectRepository.save(p);
    });
  }

  @Transactional
  public ProjectEntity ensureProjectWithAddress(String name, String address) {
    ProjectEntity p = ensureProject(name);
    String addr = (address == null ? "" : address.trim());
    if (!addr.isEmpty()) {
      String cur = p.getAddress() == null ? "" : p.getAddress().trim();
      if (!cur.equals(addr)) {
        p.setAddress(addr);
        p = projectRepository.save(p);
      }
    }
    return p;
  }
}
