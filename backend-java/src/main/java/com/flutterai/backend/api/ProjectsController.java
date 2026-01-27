package com.flutterai.backend.api;

import java.util.List;
import java.util.Map;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import com.flutterai.backend.dto.ProjectDtos.ProjectIn;
import com.flutterai.backend.dto.ProjectDtos.ProjectOut;
import com.flutterai.backend.repo.ProjectRepository;
import com.flutterai.backend.service.ProjectService;

import jakarta.validation.Valid;

@RestController
public class ProjectsController {
  private final ProjectRepository projectRepository;
  private final ProjectService projectService;

  public ProjectsController(ProjectRepository projectRepository, ProjectService projectService) {
    this.projectRepository = projectRepository;
    this.projectService = projectService;
  }

  @GetMapping("/v1/projects")
  public List<ProjectOut> listProjects() {
    return projectRepository.findAll().stream()
        .sorted((a, b) -> b.getCreatedAt().compareTo(a.getCreatedAt()))
        .limit(200)
        .map(p -> new ProjectOut(p.getId(), p.getName(), p.getAddress(), p.getCreatedAt()))
        .toList();
  }

  @PostMapping("/v1/projects/ensure")
  public Map<String, Object> ensureProject(@Valid @RequestBody ProjectIn payload) {
    var p = projectService.ensureProjectWithAddress(payload.name(), payload.address());
    return Map.of("id", p.getId(), "name", p.getName());
  }
}
