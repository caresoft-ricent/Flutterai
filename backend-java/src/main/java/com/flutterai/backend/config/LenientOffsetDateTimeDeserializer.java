package com.flutterai.backend.config;

import java.io.IOException;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeFormatterBuilder;
import java.time.temporal.ChronoField;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationContext;
import com.fasterxml.jackson.databind.JsonDeserializer;

/**
 * Accepts ISO-8601 timestamps with or without zone offset.
 *
 * Examples accepted:
 * - 2026-01-27T23:05:43.024144
 * - 2026-01-27T23:05:43.024144Z
 * - 2026-01-27T23:05:43+08:00
 * - 2026-01-27 23:05:43
 */
public final class LenientOffsetDateTimeDeserializer extends JsonDeserializer<OffsetDateTime> {
  private static final DateTimeFormatter LOCAL_FLEX = new DateTimeFormatterBuilder()
      .appendPattern("yyyy-MM-dd")
      .optionalStart()
      .appendLiteral('T')
      .optionalEnd()
      .optionalStart()
      .appendLiteral(' ')
      .optionalEnd()
      .appendPattern("HH:mm:ss")
      .optionalStart()
      .appendFraction(ChronoField.NANO_OF_SECOND, 1, 9, true)
      .optionalEnd()
      .toFormatter();

  @Override
  public OffsetDateTime deserialize(JsonParser p, DeserializationContext ctxt) throws IOException {
    String raw = p.getValueAsString();
    if (raw == null) {
      return null;
    }
    String s = raw.trim();
    if (s.isEmpty()) {
      return null;
    }

    // 1) OffsetDateTime with zone
    try {
      return OffsetDateTime.parse(s);
    } catch (Exception ignored) {
      // fall through
    }

    // 2) Instant
    try {
      Instant ins = Instant.parse(s);
      return ins.atOffset(ZoneOffset.UTC);
    } catch (Exception ignored) {
      // fall through
    }

    // 3) LocalDateTime (no zone): assume UTC (same behavior as Python naive datetimes)
    try {
      LocalDateTime ldt = LocalDateTime.parse(s, LOCAL_FLEX);
      return ldt.atOffset(ZoneOffset.UTC);
    } catch (Exception ignored) {
      // fall through
    }

    // Give a meaningful error
    return (OffsetDateTime) ctxt.handleWeirdStringValue(
        OffsetDateTime.class,
        s,
        "Invalid datetime format; expected ISO-8601 with optional offset"
    );
  }
}
