package com.flutterai.backend.util;

import java.net.URI;
import java.util.Optional;

public final class UploadRefNormalizer {
  private UploadRefNormalizer() {}

  public static String normalize(String ref) {
    String p = uploadsPathFromRef(ref);
    if (p != null && !p.isBlank()) {
      return p;
    }
    String t = Optional.ofNullable(ref).orElse("").trim();
    return t.isEmpty() ? null : t;
  }

  public static String uploadsPathFromRef(String ref) {
    String s = Optional.ofNullable(ref).orElse("").trim();
    if (s.isEmpty()) {
      return null;
    }
    if (s.startsWith("/uploads/")) {
      return s;
    }
    if (s.startsWith("uploads/")) {
      return "/" + s;
    }

    if (s.startsWith("http://") || s.startsWith("https://")) {
      try {
        URI uri = URI.create(s);
        String path = uri.getPath();
        if (path != null && path.startsWith("/uploads/")) {
          return path;
        }
      } catch (IllegalArgumentException ignored) {
        return null;
      }
    }

    return null;
  }
}
