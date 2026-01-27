package com.flutterai.backend.util;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Objects;
import java.util.List;

public final class SharedBackendPaths {
  private SharedBackendPaths() {}

  public static Path repoRoot() {
    Path dir = Path.of(System.getProperty("user.dir")).toAbsolutePath().normalize();
    for (int i = 0; i < 12; i++) {
      if (Files.exists(dir.resolve("pubspec.yaml"))) {
        return dir;
      }
      Path parent = dir.getParent();
      if (parent == null || parent.equals(dir)) {
        break;
      }
      dir = parent;
    }
    return Path.of(System.getProperty("user.dir")).toAbsolutePath().normalize();
  }

  public static Path repoPath(String relative) {
    Objects.requireNonNull(relative, "relative");
    String t = relative.trim();
    if (t.isEmpty()) {
      throw new IllegalArgumentException("relative is blank");
    }
    return repoRoot().resolve(t).toAbsolutePath().normalize();
  }

  public static Path resolveExistingFile(String overrideOrRelative, List<String> fallbacks) {
    Path p = resolvePath(overrideOrRelative);
    if (p != null && Files.exists(p)) {
      return p;
    }
    for (String s : fallbacks) {
      Path fp = resolvePath(s);
      if (fp != null && Files.exists(fp)) {
        return fp;
      }
    }
    return p;
  }

  public static Path resolveExistingDir(String overrideOrRelative, List<String> fallbacks) {
    Path p = resolvePath(overrideOrRelative);
    if (p != null && Files.isDirectory(p)) {
      return p;
    }
    for (String s : fallbacks) {
      Path fp = resolvePath(s);
      if (fp != null && Files.isDirectory(fp)) {
        return fp;
      }
    }
    return p;
  }

  public static Path resolveDbFilePath(String overrideOrRelative, List<String> fallbacks) {
    // For SQLite we mainly need the parent directory to exist; the file itself may be created.
    Path p = resolvePath(overrideOrRelative);
    if (p != null && p.getParent() != null && Files.isDirectory(p.getParent())) {
      return p;
    }
    for (String s : fallbacks) {
      Path fp = resolvePath(s);
      if (fp != null && fp.getParent() != null && Files.isDirectory(fp.getParent())) {
        return fp;
      }
    }
    return p;
  }

  private static Path resolvePath(String s) {
    String t = (s == null) ? "" : s.trim();
    if (t.isEmpty()) {
      return null;
    }
    Path p = Path.of(t);
    return p.toAbsolutePath().normalize();
  }
}
