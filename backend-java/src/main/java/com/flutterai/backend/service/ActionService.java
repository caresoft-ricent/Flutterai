package com.flutterai.backend.service;

import java.util.List;

import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.flutterai.backend.domain.RectificationActionEntity;
import com.flutterai.backend.dto.ActionDtos.RectificationActionIn;
import com.flutterai.backend.repo.RectificationActionRepository;
import com.flutterai.backend.util.UploadRefNormalizer;

@Service
public class ActionService {
  private static final List<String> VALID_TARGET_TYPES = List.of("issue", "acceptance");
  private static final List<String> VALID_ACTION_TYPES = List.of("rectify", "verify", "close", "comment");

  private final RectificationActionRepository actionRepository;
  private final ObjectMapper objectMapper;

  public ActionService(RectificationActionRepository actionRepository, ObjectMapper objectMapper) {
    this.actionRepository = actionRepository;
    this.objectMapper = objectMapper;
  }

  @Transactional
  public RectificationActionEntity addAction(long projectId, String targetType, long targetId, RectificationActionIn payload) {
    String ttype = targetType == null ? "" : targetType.trim().toLowerCase();
    if (!VALID_TARGET_TYPES.contains(ttype)) {
      throw new IllegalArgumentException("invalid target_type");
    }

    String at = payload == null || payload.actionType() == null ? "" : payload.actionType().trim().toLowerCase();
    if (!VALID_ACTION_TYPES.contains(at)) {
      throw new IllegalArgumentException("invalid action_type");
    }

    String content = payload == null || payload.content() == null ? null : payload.content().trim();
    if (content != null && content.isEmpty()) {
      content = null;
    }

    List<String> photos = payload == null ? List.of() : payload.photoUrls();
    photos = photos.stream()
        .map(UploadRefNormalizer::normalize)
        .filter(p -> p != null && !p.isBlank())
        .toList();

    String photosJson = null;
    if (!photos.isEmpty()) {
      try {
        photosJson = objectMapper.writeValueAsString(photos);
      } catch (JsonProcessingException e) {
        // best-effort: store null if serialization fails
        photosJson = null;
      }
    }

    RectificationActionEntity row = new RectificationActionEntity();
    row.setProjectId(projectId);
    row.setTargetType(ttype);
    row.setTargetId(targetId);
    row.setActionType(at);
    row.setContent(content);
    row.setPhotoUrls(photosJson);
    row.setActorRole(payload == null ? null : trimOrNull(payload.actorRole()));
    row.setActorName(payload == null ? null : trimOrNull(payload.actorName()));

    return actionRepository.save(row);
  }

  @Transactional(readOnly = true)
  public List<RectificationActionEntity> listActions(String targetType, long targetId, int limit) {
    int safeLimit = Math.max(1, Math.min(limit <= 0 ? 200 : limit, 500));
    return actionRepository.findByTargetTypeAndTargetIdOrderByCreatedAtAsc(
        targetType,
        targetId,
        PageRequest.of(0, safeLimit)
    );
  }

  private static String trimOrNull(String s) {
    if (s == null) {
      return null;
    }
    String t = s.trim();
    return t.isEmpty() ? null : t;
  }
}
