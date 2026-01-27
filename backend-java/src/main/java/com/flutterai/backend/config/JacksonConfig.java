package com.flutterai.backend.config;

import java.time.OffsetDateTime;

import org.springframework.boot.autoconfigure.jackson.Jackson2ObjectMapperBuilderCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import com.fasterxml.jackson.databind.module.SimpleModule;

@Configuration
public class JacksonConfig {
  @Bean
  public Jackson2ObjectMapperBuilderCustomizer offsetDateTimeLenientCustomizer() {
    return builder -> {
      SimpleModule m = new SimpleModule("lenient-odt");
      m.addDeserializer(OffsetDateTime.class, new LenientOffsetDateTimeDeserializer());
      // Don't replace Spring Boot's default modules (notably JavaTimeModule).
      builder.modulesToInstall(m);
    };
  }
}
