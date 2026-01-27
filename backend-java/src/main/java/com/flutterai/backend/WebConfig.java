package com.flutterai.backend;

import java.nio.file.Path;
import java.util.List;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.CorsRegistry;
import org.springframework.web.servlet.config.annotation.ResourceHandlerRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

import com.flutterai.backend.util.SharedBackendPaths;

@Configuration
public class WebConfig implements WebMvcConfigurer {

  @Value("${app.uploads-dir:./uploads}")
  private String uploadsDir;

  @Override
  public void addCorsMappings(CorsRegistry registry) {
    registry.addMapping("/**")
        .allowedOrigins("*")
        .allowedMethods("*")
        .allowedHeaders("*");
  }

  @Override
  public void addResourceHandlers(ResourceHandlerRegistry registry) {
    Path dir = SharedBackendPaths.resolveExistingDir(
        uploadsDir,
        List.of("backend/uploads", "../backend/uploads")
    );
    if (dir == null) {
      dir = Path.of("backend/uploads").toAbsolutePath().normalize();
    }
    String location = dir.toUri().toString();
    registry.addResourceHandler("/uploads/**")
        .addResourceLocations(location);
  }
}
