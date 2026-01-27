package com.flutterai.backend.api;

public class ApiNotFoundException extends RuntimeException {
  public ApiNotFoundException(String message) {
    super(message);
  }
}
