package com.flutterai.backend.config;

import java.nio.file.Path;
import java.util.List;

import javax.sql.DataSource;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.core.env.Environment;

import com.flutterai.backend.util.SharedBackendPaths;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

@Configuration
public class SqliteDataSourceConfig {

  @Bean
  @Primary
  public DataSource dataSource(Environment env) {
    String override = firstNonBlank(
        env.getProperty("app.db.path"),
        System.getenv("APP_DB_PATH")
    );

    Path db;
    if (override != null && !override.isBlank()) {
      db = SharedBackendPaths.resolveDbFilePath(override, List.of());
    } else {
      // Single source of truth: repo-root flutterai.db
      db = SharedBackendPaths.repoPath("flutterai.db");
    }

    String busyTimeout = firstNonBlank(env.getProperty("app.sqlite.busy-timeout-ms"), "10000");

    String url = "jdbc:sqlite:" + db.toString() + "?busy_timeout=" + busyTimeout;

    HikariConfig cfg = new HikariConfig();
    cfg.setJdbcUrl(url);
    cfg.setDriverClassName("org.sqlite.JDBC");

    // SQLite is single-writer; a single connection avoids frequent SQLITE_BUSY errors.
    cfg.setMaximumPoolSize(1);

    return new HikariDataSource(cfg);
  }

  private static String firstNonBlank(String... values) {
    if (values == null) {
      return null;
    }
    for (String v : values) {
      if (v != null && !v.trim().isEmpty()) {
        return v.trim();
      }
    }
    return null;
  }
}
