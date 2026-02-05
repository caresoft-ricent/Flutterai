package com.flutterai.backend.api;

import java.util.Map;

import jakarta.servlet.http.HttpServletRequest;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.dao.CannotAcquireLockException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class ApiExceptionHandler {

  private static final Logger log = LoggerFactory.getLogger(ApiExceptionHandler.class);

  @ExceptionHandler(IllegalArgumentException.class)
  public ResponseEntity<Map<String, Object>> handleIllegalArgument(IllegalArgumentException ex) {
    return ResponseEntity.status(HttpStatus.BAD_REQUEST)
        .body(Map.of("detail", ex.getMessage() == null ? "bad request" : ex.getMessage()));
  }

  @ExceptionHandler(MethodArgumentNotValidException.class)
  public ResponseEntity<Map<String, Object>> handleValidation(MethodArgumentNotValidException ex) {
    return ResponseEntity.status(HttpStatus.UNPROCESSABLE_ENTITY)
        .body(Map.of("detail", "validation error"));
  }

  @ExceptionHandler(CannotAcquireLockException.class)
  public ResponseEntity<Map<String, Object>> handleDbLock(CannotAcquireLockException ex, HttpServletRequest req) {
    String path = req == null ? "" : req.getRequestURI();
    log.warn("DB is locked: {} {}", req == null ? "" : req.getMethod(), path, ex);
    return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
        .body(Map.of(
            "detail", "database busy, please retry",
            "path", path));
  }

  @ExceptionHandler(Exception.class)
  public ResponseEntity<Map<String, Object>> handleAny(Exception ex, HttpServletRequest req) {
    String method = req == null ? "" : req.getMethod();
    String path = req == null ? "" : req.getRequestURI();
    log.error("Unhandled exception: {} {}", method, path, ex);

    String msg = ex.getMessage();
    if (msg == null) {
      msg = "";
    }
    if (msg.length() > 500) {
      msg = msg.substring(0, 500);
    }

    return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
        .body(Map.of(
            "detail", "internal server error",
            "error", msg,
            "path", path));
  }
}
