package com.flutterai.backend.api;

import java.util.Map;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class NotFoundAdvice {
  @ExceptionHandler(ApiNotFoundException.class)
  public ResponseEntity<Map<String, Object>> handleNotFound(ApiNotFoundException ex) {
    return ResponseEntity.status(HttpStatus.NOT_FOUND)
        .body(Map.of("detail", ex.getMessage() == null ? "not found" : ex.getMessage()));
  }
}
