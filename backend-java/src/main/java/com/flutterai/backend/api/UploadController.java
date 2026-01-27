package com.flutterai.backend.api;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestPart;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.web.servlet.support.ServletUriComponentsBuilder;

import com.flutterai.backend.util.SharedBackendPaths;

@RestController
public class UploadController {

  private static final Set<String> ALLOWED_EXT = Set.of(".jpg", ".jpeg", ".png", ".webp", ".heic");

  @Value("${app.uploads-dir:./uploads}")
  private String uploadsDir;

  @PostMapping(value = "/v1/uploads/photo", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
  public Map<String, Object> uploadPhoto(@RequestPart("file") MultipartFile file) throws IOException {
    if (file == null || file.isEmpty()) {
      throw new IllegalArgumentException("empty file");
    }

    String original = file.getOriginalFilename() == null ? "" : file.getOriginalFilename();
    String ext = "";
    int idx = original.lastIndexOf('.');
    if (idx >= 0) {
      ext = original.substring(idx).toLowerCase().trim();
    }
    if (!ALLOWED_EXT.contains(ext)) {
      ext = ext.isEmpty() ? ".jpg" : ext;
      // allow unknown extensions by defaulting to .jpg, consistent with Python behavior
      if (!ALLOWED_EXT.contains(ext)) {
        ext = ".jpg";
      }
    }

    String name = UUID.randomUUID().toString().replace("-", "") + ext;
    Path dir = SharedBackendPaths.resolveExistingDir(
        uploadsDir,
        List.of("backend/uploads", "../backend/uploads")
    );
    if (dir == null) {
      dir = Path.of("backend/uploads").toAbsolutePath().normalize();
    }
    Files.createDirectories(dir);

    Path dst = dir.resolve(name);
    Files.write(dst, file.getBytes());

    String path = "/uploads/" + name;
    String url = ServletUriComponentsBuilder.fromCurrentContextPath()
        .path(path)
        .toUriString();

    return Map.of("url", url, "path", path);
  }
}
