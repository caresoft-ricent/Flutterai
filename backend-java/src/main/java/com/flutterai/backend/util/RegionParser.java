package com.flutterai.backend.util;

import java.util.Map;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class RegionParser {
  private RegionParser() {}

  public record ParsedRegion(String buildingNo, Integer floorNo, String zone) {}

  private static final Map<String, Integer> CN_NUM = Map.ofEntries(
      Map.entry("零", 0),
      Map.entry("一", 1),
      Map.entry("二", 2),
      Map.entry("两", 2),
      Map.entry("三", 3),
      Map.entry("四", 4),
      Map.entry("五", 5),
      Map.entry("六", 6),
      Map.entry("七", 7),
      Map.entry("八", 8),
      Map.entry("九", 9),
      Map.entry("十", 10)
  );

  private static final Pattern BUILDING = Pattern.compile("([\\d一二三四五六七八九十两]+)(?:栋|楼|#)");
  private static final Pattern FLOOR = Pattern.compile("([\\d一二三四五六七八九十两]+)(?:层|楼)");
  private static final Pattern ROOM_AFTER_FLOOR = Pattern.compile("(?:层|楼)([A-Za-z0-9]{2,}|[\\d]{2,})$");

  public static ParsedRegion parse(String regionText) {
    String raw = Optional.ofNullable(regionText).orElse("").trim();
    if (raw.isEmpty()) {
      return new ParsedRegion(null, null, null);
    }

    String compact = raw.replace(" ", "");

    String buildingNo = null;
    Matcher mb = BUILDING.matcher(compact);
    if (mb.find()) {
      Integer bi = cnToInt(mb.group(1));
      if (bi != null) {
        buildingNo = bi + "栋";
      }
    }

    Integer floorNo = null;
    Matcher mf = FLOOR.matcher(compact);
    if (mf.find()) {
      floorNo = cnToInt(mf.group(1));
    }

    String zone = null;
    if (raw.contains("/")) {
      String[] parts = raw.split("/");
      String last = null;
      for (String p : parts) {
        String t = (p == null ? "" : p.trim());
        if (!t.isEmpty()) {
          last = t;
        }
      }
      if (parts.length >= 2) {
        zone = last;
      }
    } else {
      Matcher mRoom = ROOM_AFTER_FLOOR.matcher(compact);
      if (mRoom.find()) {
        zone = mRoom.group(1);
      }
    }

    return new ParsedRegion(buildingNo, floorNo, zone);
  }

  private static Integer cnToInt(String s) {
    String t = Optional.ofNullable(s).orElse("").trim();
    if (t.isEmpty()) {
      return null;
    }
    if (t.chars().allMatch(Character::isDigit)) {
      try {
        return Integer.parseInt(t);
      } catch (NumberFormatException e) {
        return null;
      }
    }

    for (int i = 0; i < t.length(); i++) {
      String ch = String.valueOf(t.charAt(i));
      if (!CN_NUM.containsKey(ch)) {
        return null;
      }
    }

    if (t.equals("十")) {
      return 10;
    }
    if (t.startsWith("十")) {
      String onesKey = t.substring(1);
      int ones = CN_NUM.getOrDefault(onesKey, 0);
      return 10 + ones;
    }
    int idx = t.indexOf("十");
    if (idx >= 0) {
      String a = t.substring(0, idx);
      String b = t.substring(idx + 1);
      int tens = CN_NUM.getOrDefault(a, 0) * 10;
      int ones = b.isEmpty() ? 0 : CN_NUM.getOrDefault(b, 0);
      return tens + ones;
    }

    return CN_NUM.get(t);
  }
}
