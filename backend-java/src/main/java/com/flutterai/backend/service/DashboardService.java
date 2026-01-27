package com.flutterai.backend.service;

import java.time.Duration;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.OffsetDateTime;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.flutterai.backend.domain.AcceptanceRecordEntity;
import com.flutterai.backend.domain.IssueReportEntity;
import com.flutterai.backend.dto.DashboardDtos.DashboardSummaryOut;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;

import com.flutterai.backend.util.RegionParser;
import com.flutterai.backend.util.RegionParser.ParsedRegion;

@Service
public class DashboardService {
  private final EntityManager entityManager;

  public DashboardService(EntityManager entityManager) {
    this.entityManager = entityManager;
  }

  @Transactional
  public Map<String, Object> focusPack(
      long projectId,
      int timeRangeDays,
      String building,
      boolean doBackfill,
      int backfillLimit) {

    int days = timeRangeDays <= 0 ? 14 : timeRangeDays;
    Instant now = Instant.now();
    Instant start = now.minus(days, ChronoUnit.DAYS);

    String startStr = formatSqliteTimestamp(start);
    String endStr = formatSqliteTimestamp(now);

    Map<String, Object> backfill = doBackfill ? backfillRegionFields(projectId, backfillLimit) : null;

    // Acceptance items within window: building + item_key classified by worst result.
    String itemExpr = "COALESCE(item_code, item, indicator_code, indicator)";
    String sqlA = "SELECT building_no, " + itemExpr + " AS item_key, "
        + "MAX(CASE WHEN result = 'unqualified' THEN 1 ELSE 0 END) AS has_unq, "
        + "MAX(CASE WHEN result = 'pending' THEN 1 ELSE 0 END) AS has_pen "
        + "FROM acceptance_records WHERE project_id = :pid AND created_at >= :start "
        + (building != null ? "AND building_no = :b " : "")
        + "GROUP BY building_no, item_key";

    Query aQ = entityManager.createNativeQuery(sqlA);
    aQ.setParameter("pid", projectId);
    aQ.setParameter("start", startStr);
    if (building != null) {
      aQ.setParameter("b", building);
    }

    List<?> aRows = aQ.getResultList();
    int aItemsUnq = 0;
    int aItemsPen = 0;
    Map<String, Map<String, Object>> byBuilding = new HashMap<>();
    for (Object r : aRows) {
      Object[] row = (Object[]) r;
      String b = normalizeBuilding(row[0]);
      int hasUnq = toInt(row[2]);
      int hasPen = toInt(row[3]);
      Map<String, Object> d = byBuilding.computeIfAbsent(b, k -> baseFocusBucket(k));
      if (hasUnq > 0) {
        aItemsUnq += 1;
        d.put("acceptance_unqualified_items", toInt(d.get("acceptance_unqualified_items")) + 1);
      } else if (hasPen > 0) {
        aItemsPen += 1;
        d.put("acceptance_pending_items", toInt(d.get("acceptance_pending_items")) + 1);
      }
    }

    // Current open issues (snapshot) grouped by building
    String sqlOpen = "SELECT id, building_no, created_at, deadline_days, severity "
        + "FROM issue_reports WHERE project_id = :pid AND status = 'open' "
        + "ORDER BY created_at DESC LIMIT 5000";
    Query openQ = entityManager.createNativeQuery(sqlOpen);
    openQ.setParameter("pid", projectId);

    List<?> openRows = openQ.getResultList();
    int issuesOpen = 0;
    int issuesOpenSevere = 0;
    int issuesOpenOverdue = 0;
    for (Object r : openRows) {
      Object[] row = (Object[]) r;
      String b = normalizeBuilding(row[1]);
      if (building != null && !b.equals(building)) {
        continue;
      }
      Instant createdAt = parseSqliteTimestamp(row[2]);
      Integer deadlineDays = row[3] == null ? null : toInt(row[3]);
      String severity = row[4] == null ? null : row[4].toString();

      Map<String, Object> d = byBuilding.computeIfAbsent(b, k -> baseFocusBucket(k));
      issuesOpen += 1;
      d.put("issues_open", toInt(d.get("issues_open")) + 1);

      if ("severe".equals(normalizeSeverityKey(severity))) {
        issuesOpenSevere += 1;
        d.put("issues_open_severe", toInt(d.get("issues_open_severe")) + 1);
      }

      if (deadlineDays != null && createdAt != null) {
        double ageDays = Duration.between(createdAt, now).toSeconds() / 86400.0;
        if (ageDays > deadlineDays.doubleValue()) {
          issuesOpenOverdue += 1;
          d.put("issues_open_overdue", toInt(d.get("issues_open_overdue")) + 1);
        }
      }
    }

    // Closure metrics within window
    List<Double> closeDays = closureDays(projectId, startStr, building, "issue", "close", "issue_reports");
    List<Double> verifyDays = closureDays(projectId, startStr, building, "acceptance", "verify", "acceptance_records");

    Map<String, Object> closure = new HashMap<>();
    closure.put("issue_close_count", closeDays.size());
    closure.put("issue_close_days_avg", closeDays.isEmpty() ? null : round2(avg(closeDays)));
    closure.put("issue_close_days_median", closeDays.isEmpty() ? null : round2(median(closeDays)));
    closure.put("acceptance_verify_count", verifyDays.size());
    closure.put("acceptance_verify_days_avg", verifyDays.isEmpty() ? null : round2(avg(verifyDays)));
    closure.put("acceptance_verify_days_median", verifyDays.isEmpty() ? null : round2(median(verifyDays)));

    // Data quality indicators
    int accMissingBuilding = countScalar("SELECT COUNT(id) FROM acceptance_records WHERE project_id = :pid AND building_no IS NULL", projectId);
    int issueMissingBuilding = countScalar("SELECT COUNT(id) FROM issue_reports WHERE project_id = :pid AND building_no IS NULL", projectId);

    int issuesClosedMissingCloseAction = countClosedMissingAction(projectId, "issue", "close");
    int acceptanceMissingVerifyAction = countAcceptanceMissingVerify(projectId);

    Map<String, Object> dq = new HashMap<>();
    dq.put("acceptance_missing_building", accMissingBuilding);
    dq.put("issues_missing_building", issueMissingBuilding);
    dq.put("issues_closed_missing_close_action", issuesClosedMissingCloseAction);
    dq.put("acceptance_missing_verify_action", acceptanceMissingVerifyAction);

    // Compute risk score per building
    for (Map<String, Object> d : byBuilding.values()) {
      d.put("risk_score", riskScore(d));
    }

    List<Map<String, Object>> byBuildingList = new ArrayList<>(byBuilding.values());
    byBuildingList.sort((a, b) -> Integer.compare(toInt(b.get("risk_score")), toInt(a.get("risk_score"))));

    List<Map<String, Object>> topFocus = new ArrayList<>();
    for (Map<String, Object> d : byBuildingList) {
      int score = toInt(d.get("risk_score"));
      if (score <= 0) {
        continue;
      }
      String b = d.get("building") == null ? null : d.get("building").toString();
      String title = (b == null || b.isBlank()) ? "优先闭环风险" : (b + " 优先闭环风险");
      Map<String, Object> evidence = Map.of(
          "issues_open", toInt(d.get("issues_open")),
          "issues_open_severe", toInt(d.get("issues_open_severe")),
          "issues_open_overdue", toInt(d.get("issues_open_overdue")),
          "acceptance_unqualified_items", toInt(d.get("acceptance_unqualified_items")),
          "acceptance_pending_items", toInt(d.get("acceptance_pending_items"))
      );
      topFocus.add(Map.of(
          "title", title,
          "building", b,
          "risk_score", score,
          "evidence", evidence
      ));
      if (topFocus.size() >= 5) {
        break;
      }
    }

    Map<String, Object> metrics = new HashMap<>();
    metrics.put("acceptance_unqualified_items", aItemsUnq);
    metrics.put("acceptance_pending_items", aItemsPen);
    metrics.put("issues_open", issuesOpen);
    metrics.put("issues_open_severe", issuesOpenSevere);
    metrics.put("issues_open_overdue", issuesOpenOverdue);

    Map<String, Object> meta = new HashMap<>();
    meta.put("project_id", projectId);
    meta.put("generated_at", OffsetDateTime.now(ZoneOffset.UTC).toString());
    meta.put("window", Map.of("time_range_days", days, "start", startStr, "end", endStr));
    meta.put("backfill", backfill);
    meta.put("scope", building == null ? Map.of() : Map.of("building", building));

    return Map.of(
        "meta", meta,
        "metrics", metrics,
        "closure", closure,
        "data_quality", dq,
        "by_building", byBuildingList,
        "top_focus", topFocus
    );
  }

  @Transactional(readOnly = true)
  public DashboardSummaryOut summary(long projectId, int limit) {
    Map<String, Integer> acceptanceCounts = acceptanceItemCountsWorst(projectId);

    Map<String, Integer> issueStatusCounts = issueCountsByStatus(projectId);
    Map<String, Integer> severityCounts = issueCountsBySeverity(projectId);
    List<Map<String, Object>> topUnits = topResponsibleUnits(projectId);

    List<Map<String, Object>> recentUnqualified = recentAcceptance(projectId, "unqualified", limit);
    List<Map<String, Object>> recentOpenIssues = recentIssues(projectId, "open", limit);

    int acceptanceTotal = acceptanceCounts.values().stream().mapToInt(Integer::intValue).sum();
    int issuesTotal = issueStatusCounts.values().stream().mapToInt(Integer::intValue).sum();

    return new DashboardSummaryOut(
        acceptanceTotal,
        acceptanceCounts.getOrDefault("qualified", 0),
        acceptanceCounts.getOrDefault("unqualified", 0),
        acceptanceCounts.getOrDefault("pending", 0),
        issuesTotal,
        issueStatusCounts.getOrDefault("open", 0),
        issueStatusCounts.getOrDefault("closed", 0),
        severityCounts,
        topUnits,
        recentUnqualified,
        recentOpenIssues
    );
  }

  @Transactional
  public Map<String, Object> backfillRegionFields(long projectId, int limit) {
    int safeLimit = Math.max(0, Math.min(limit <= 0 ? 0 : limit, 2000));
    if (safeLimit <= 0) {
      return Map.of("updated_acceptance", 0, "updated_issues", 0);
    }

    int updatedAcceptance = backfillTable(
        "acceptance_records",
        projectId,
        safeLimit,
        "UPDATE acceptance_records SET building_no = COALESCE(building_no, :bn), floor_no = COALESCE(floor_no, :fn), zone = COALESCE(zone, :zn) WHERE id = :id"
    );

    int updatedIssues = backfillTable(
        "issue_reports",
        projectId,
        safeLimit,
        "UPDATE issue_reports SET building_no = COALESCE(building_no, :bn), floor_no = COALESCE(floor_no, :fn), zone = COALESCE(zone, :zn) WHERE id = :id"
    );

    return Map.of("updated_acceptance", updatedAcceptance, "updated_issues", updatedIssues);
  }

  private int backfillTable(String table, long projectId, int limit, String updateSql) {
    String sql = "SELECT id, region_text, building_no, floor_no, zone FROM " + table + " "
        + "WHERE project_id = :pid AND (building_no IS NULL OR floor_no IS NULL OR zone IS NULL) "
        + "ORDER BY created_at DESC LIMIT :lim";

    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    q.setParameter("lim", limit);

    List<?> rows = q.getResultList();
    int updated = 0;
    for (Object r : rows) {
      Object[] row = (Object[]) r;
      long id = ((Number) row[0]).longValue();
      String regionText = row[1] == null ? "" : row[1].toString();
      ParsedRegion parsed = RegionParser.parse(regionText);
      if (parsed.buildingNo() == null && parsed.floorNo() == null && parsed.zone() == null) {
        continue;
      }

      Query u = entityManager.createNativeQuery(updateSql);
      u.setParameter("bn", parsed.buildingNo());
      u.setParameter("fn", parsed.floorNo());
      u.setParameter("zn", parsed.zone());
      u.setParameter("id", id);
      int n = u.executeUpdate();
      if (n > 0) {
        updated += 1;
      }
    }
    return updated;
  }

  private List<Double> closureDays(
      long projectId,
      String startStr,
      String building,
      String targetType,
      String actionType,
      String targetTable) {

    String sql = "SELECT target_id, MIN(created_at) FROM rectification_actions "
        + "WHERE project_id = :pid AND target_type = :tt AND action_type = :at AND created_at >= :start "
        + "GROUP BY target_id";
    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    q.setParameter("tt", targetType);
    q.setParameter("at", actionType);
    q.setParameter("start", startStr);

    List<?> rows = q.getResultList();
    List<Double> out = new ArrayList<>();
    for (Object r : rows) {
      Object[] row = (Object[]) r;
      long targetId = ((Number) row[0]).longValue();
      Instant actionAt = parseSqliteTimestamp(row[1]);
      if (actionAt == null) {
        continue;
      }

      String createdSql = "SELECT created_at, building_no FROM " + targetTable + " WHERE id = :id";
      Query t = entityManager.createNativeQuery(createdSql);
      t.setParameter("id", targetId);
      List<?> ts = t.getResultList();
      if (ts.isEmpty()) {
        continue;
      }
      Object[] tr = (Object[]) ts.get(0);
      String b = normalizeBuilding(tr[1]);
      if (building != null && !b.equals(building)) {
        continue;
      }
      Instant createdAt = parseSqliteTimestamp(tr[0]);
      if (createdAt == null) {
        continue;
      }

      double days = Duration.between(createdAt, actionAt).toSeconds() / 86400.0;
      if (days >= 0) {
        out.add(days);
      }
    }
    return out;
  }

  private int countClosedMissingAction(long projectId, String targetType, String actionType) {
    String sqlClosed = "SELECT id FROM issue_reports WHERE project_id = :pid AND status = 'closed' ORDER BY created_at DESC LIMIT 5000";
    Query q = entityManager.createNativeQuery(sqlClosed);
    q.setParameter("pid", projectId);
    List<?> rows = q.getResultList();
    List<Long> ids = new ArrayList<>();
    for (Object r : rows) {
      ids.add(((Number) r).longValue());
    }
    if (ids.isEmpty()) {
      return 0;
    }

    Set<Long> has = fetchActionTargets(projectId, targetType, actionType, ids);
    int missing = 0;
    for (Long id : ids) {
      if (!has.contains(id)) {
        missing += 1;
      }
    }
    return missing;
  }

  private int countAcceptanceMissingVerify(long projectId) {
    String sqlAcc = "SELECT id FROM acceptance_records WHERE project_id = :pid AND result IN ('qualified','unqualified') ORDER BY created_at DESC LIMIT 5000";
    Query q = entityManager.createNativeQuery(sqlAcc);
    q.setParameter("pid", projectId);
    List<?> rows = q.getResultList();
    List<Long> ids = new ArrayList<>();
    for (Object r : rows) {
      ids.add(((Number) r).longValue());
    }
    if (ids.isEmpty()) {
      return 0;
    }
    Set<Long> has = fetchActionTargets(projectId, "acceptance", "verify", ids);
    int missing = 0;
    for (Long id : ids) {
      if (!has.contains(id)) {
        missing += 1;
      }
    }
    return missing;
  }

  private Set<Long> fetchActionTargets(long projectId, String targetType, String actionType, List<Long> ids) {
    Set<Long> out = new java.util.HashSet<>();
    int chunk = 900;
    for (int i = 0; i < ids.size(); i += chunk) {
      List<Long> sub = ids.subList(i, Math.min(ids.size(), i + chunk));
      String in = sub.stream().map(x -> "?").reduce((a, b) -> a + "," + b).orElse("?");
      String sql = "SELECT DISTINCT target_id FROM rectification_actions WHERE project_id = ? AND target_type = ? AND action_type = ? AND target_id IN (" + in + ")";
      Query q = entityManager.createNativeQuery(sql);
      int p = 1;
      q.setParameter(p++, projectId);
      q.setParameter(p++, targetType);
      q.setParameter(p++, actionType);
      for (Long id : sub) {
        q.setParameter(p++, id);
      }
      List<?> rows = q.getResultList();
      for (Object r : rows) {
        out.add(((Number) r).longValue());
      }
    }
    return out;
  }

  private static Map<String, Object> baseFocusBucket(String building) {
    Map<String, Object> m = new HashMap<>();
    m.put("building", building);
    m.put("acceptance_unqualified_items", 0);
    m.put("acceptance_pending_items", 0);
    m.put("issues_open", 0);
    m.put("issues_open_severe", 0);
    m.put("issues_open_overdue", 0);
    m.put("risk_score", 0);
    return m;
  }

  private static int riskScore(Map<String, Object> d) {
    int openN = toInt(d.get("issues_open"));
    int severeN = toInt(d.get("issues_open_severe"));
    int overdueN = toInt(d.get("issues_open_overdue"));
    int unqItems = toInt(d.get("acceptance_unqualified_items"));
    int penItems = toInt(d.get("acceptance_pending_items"));
    int dqPen = "未解析".equals(String.valueOf(d.get("building"))) ? 10 : 0;
    int score = severeN * 12 + openN * 4 + overdueN * 8 + unqItems * 6 + penItems * 2 + dqPen;
    score = Math.max(0, Math.min(100, score));
    return score;
  }

  private static String normalizeBuilding(Object o) {
    String b = o == null ? "" : o.toString().trim();
    return b.isEmpty() ? "未解析" : b;
  }

  private int countScalar(String sql, long projectId) {
    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    Object v = q.getSingleResult();
    return toInt(v);
  }

  private static double avg(List<Double> xs) {
    double s = 0;
    for (double x : xs) {
      s += x;
    }
    return s / xs.size();
  }

  private static double median(List<Double> xs) {
    List<Double> ys = new ArrayList<>(xs);
    ys.sort(Double::compareTo);
    int n = ys.size();
    int mid = n / 2;
    if (n % 2 == 1) {
      return ys.get(mid);
    }
    return (ys.get(mid - 1) + ys.get(mid)) / 2.0;
  }

  private static Double round2(double v) {
    return Math.round(v * 100.0) / 100.0;
  }

  private static final Pattern CODE_PAT1 = Pattern.compile("^[A-Za-z]{1,4}-?\\d{2,8}$");
  private static final Pattern CODE_PAT2 = Pattern.compile("^[A-Za-z0-9_-]{2,16}$");

  public static boolean looksLikeCode(String s) {
    if (s == null) {
      return false;
    }
    String t = s.trim();
    if (t.isEmpty()) {
      return false;
    }
    if (CODE_PAT1.matcher(t).matches()) {
      return true;
    }
    if (CODE_PAT2.matcher(t).matches() && !t.chars().anyMatch(ch -> ch >= 0x4e00 && ch <= 0x9fff)) {
      return true;
    }
    return false;
  }

  public static String normalizeSeverityKey(String sev) {
    String s = sev == null ? "" : sev.trim().toLowerCase();
    if (s.isEmpty()) {
      return "unknown";
    }
    if (Set.of("严重", "重大", "high", "severe", "critical", "a", "一级").contains(s)) {
      return "severe";
    }
    if (Set.of("一般", "普通", "medium", "normal", "b", "二级").contains(s)) {
      return "normal";
    }
    return s;
  }

  private static final DateTimeFormatter SQLITE_FMT = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

  private static String formatSqliteTimestamp(Instant instant) {
    return SQLITE_FMT.format(LocalDateTime.ofInstant(instant, ZoneOffset.UTC));
  }

  private static Instant parseSqliteTimestamp(Object o) {
    if (o == null) {
      return null;
    }
    if (o instanceof OffsetDateTime odt) {
      return odt.toInstant();
    }
    String s = o.toString().trim();
    if (s.isEmpty()) {
      return null;
    }
    try {
      return OffsetDateTime.parse(s).toInstant();
    } catch (Exception ignored) {
      // fall through
    }
    try {
      LocalDateTime ldt = LocalDateTime.parse(s, SQLITE_FMT);
      return ldt.toInstant(ZoneOffset.UTC);
    } catch (Exception ignored) {
      // fall through
    }
    try {
      return Instant.parse(s);
    } catch (Exception ignored) {
      return null;
    }
  }

  private Map<String, Integer> acceptanceItemCountsWorst(long projectId) {
    String sql = "\n" +
        "SELECT\n" +
        "  COALESCE(item_code, item, indicator_code, indicator) AS item_key,\n" +
        "  MAX(CASE WHEN result = 'unqualified' THEN 1 ELSE 0 END) AS has_unq,\n" +
        "  MAX(CASE WHEN result = 'pending' THEN 1 ELSE 0 END) AS has_pen\n" +
        "FROM acceptance_records\n" +
        "WHERE project_id = :pid\n" +
        "GROUP BY item_key";

    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);

    List<?> rows = q.getResultList();

    Map<String, Integer> out = new HashMap<>();
    out.put("qualified", 0);
    out.put("unqualified", 0);
    out.put("pending", 0);

    for (Object r : rows) {
      Object[] row = (Object[]) r;
      int hasUnq = toInt(row[1]);
      int hasPen = toInt(row[2]);
      if (hasUnq > 0) {
        out.put("unqualified", out.get("unqualified") + 1);
      } else if (hasPen > 0) {
        out.put("pending", out.get("pending") + 1);
      } else {
        out.put("qualified", out.get("qualified") + 1);
      }
    }

    return out;
  }

  private Map<String, Integer> issueCountsByStatus(long projectId) {
    String sql = "SELECT status, COUNT(id) FROM issue_reports WHERE project_id = :pid GROUP BY status";
    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    List<?> rows = q.getResultList();

    Map<String, Integer> out = new HashMap<>();
    for (Object r : rows) {
      Object[] row = (Object[]) r;
      String status = row[0] == null ? "" : row[0].toString();
      out.put(status, toInt(row[1]));
    }
    return out;
  }

  private Map<String, Integer> issueCountsBySeverity(long projectId) {
    String sql = "SELECT severity, COUNT(id) FROM issue_reports WHERE project_id = :pid GROUP BY severity";
    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    List<?> rows = q.getResultList();

    Map<String, Integer> out = new HashMap<>();
    for (Object r : rows) {
      Object[] row = (Object[]) r;
      String key = row[0] == null ? "未填写" : row[0].toString().trim();
      if (key.isEmpty()) {
        key = "未填写";
      }
      out.put(key, toInt(row[1]));
    }
    return out;
  }

  private List<Map<String, Object>> topResponsibleUnits(long projectId) {
    String expr = "COALESCE(NULLIF(TRIM(responsible_unit),''),'未填写')";
    String sql = "SELECT " + expr + " AS unit, COUNT(id) AS cnt " +
        "FROM issue_reports WHERE project_id = :pid AND status = 'open' " +
        "GROUP BY " + expr + " ORDER BY cnt DESC LIMIT 10";

    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    List<?> rows = q.getResultList();

    List<Map<String, Object>> out = new ArrayList<>();
    for (Object r : rows) {
      Object[] row = (Object[]) r;
      out.add(Map.of(
          "responsible_unit", row[0] == null ? "未填写" : row[0].toString(),
          "count", toInt(row[1])
      ));
    }
    return out;
  }

  private List<Map<String, Object>> recentAcceptance(long projectId, String result, int limit) {
    int safeLimit = Math.max(1, Math.min(limit <= 0 ? 10 : limit, 200));
    String sql = "SELECT id, project_id, region_code, region_text, building_no, floor_no, zone, division, subdivision, item, item_code, indicator, indicator_code, result, photo_path, remark, ai_json, client_created_at, created_at, source, client_record_id " +
        "FROM acceptance_records WHERE project_id = :pid AND result = :res ORDER BY created_at DESC LIMIT :lim";

    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    q.setParameter("res", result);
    q.setParameter("lim", safeLimit);

    List<?> rows = q.getResultList();
    List<Map<String, Object>> out = new ArrayList<>();
    for (Object r : rows) {
      Object[] row = (Object[]) r;
      AcceptanceRecordEntity e = new AcceptanceRecordEntity();
      e.setId(((Number) row[0]).longValue());
      e.setProjectId(((Number) row[1]).longValue());
      e.setRegionCode(asString(row[2]));
      e.setRegionText(asString(row[3]));
      e.setBuildingNo(asString(row[4]));
      e.setFloorNo(row[5] == null ? null : ((Number) row[5]).intValue());
      e.setZone(asString(row[6]));
      e.setDivision(asString(row[7]));
      e.setSubdivision(asString(row[8]));
      e.setItem(asString(row[9]));
      e.setItemCode(asString(row[10]));
      e.setIndicator(asString(row[11]));
      e.setIndicatorCode(asString(row[12]));
      e.setResult(asString(row[13]));
      e.setPhotoPath(asString(row[14]));
      e.setRemark(asString(row[15]));
      e.setAiJson(asString(row[16]));
      e.setClientCreatedAt(asOffsetDateTime(row[17]));
      e.setCreatedAt(asOffsetDateTime(row[18]));
      e.setSource(asString(row[19]));
      e.setClientRecordId(asString(row[20]));

      out.add(acceptanceToMap(e));
    }
    return out;
  }

  private List<Map<String, Object>> recentIssues(long projectId, String status, int limit) {
    int safeLimit = Math.max(1, Math.min(limit <= 0 ? 10 : limit, 200));
    String sql = "SELECT id, project_id, region_code, region_text, building_no, floor_no, zone, division, subdivision, item, indicator, library_id, description, severity, deadline_days, responsible_unit, responsible_person, status, photo_path, ai_json, client_created_at, created_at, source, client_record_id " +
        "FROM issue_reports WHERE project_id = :pid AND status = :st ORDER BY created_at DESC LIMIT :lim";

    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    q.setParameter("st", status);
    q.setParameter("lim", safeLimit);

    List<?> rows = q.getResultList();
    List<Map<String, Object>> out = new ArrayList<>();
    for (Object r : rows) {
      Object[] row = (Object[]) r;
      IssueReportEntity e = new IssueReportEntity();
      e.setId(((Number) row[0]).longValue());
      e.setProjectId(((Number) row[1]).longValue());
      e.setRegionCode(asString(row[2]));
      e.setRegionText(asString(row[3]));
      e.setBuildingNo(asString(row[4]));
      e.setFloorNo(row[5] == null ? null : ((Number) row[5]).intValue());
      e.setZone(asString(row[6]));
      e.setDivision(asString(row[7]));
      e.setSubdivision(asString(row[8]));
      e.setItem(asString(row[9]));
      e.setIndicator(asString(row[10]));
      e.setLibraryId(asString(row[11]));
      e.setDescription(asString(row[12]));
      e.setSeverity(asString(row[13]));
      e.setDeadlineDays(row[14] == null ? null : ((Number) row[14]).intValue());
      e.setResponsibleUnit(asString(row[15]));
      e.setResponsiblePerson(asString(row[16]));
      e.setStatus(asString(row[17]));
      e.setPhotoPath(asString(row[18]));
      e.setAiJson(asString(row[19]));
      e.setClientCreatedAt(asOffsetDateTime(row[20]));
      e.setCreatedAt(asOffsetDateTime(row[21]));
      e.setSource(asString(row[22]));
      e.setClientRecordId(asString(row[23]));

      out.add(issueToMap(e));
    }
    return out;
  }

  private static Map<String, Object> acceptanceToMap(AcceptanceRecordEntity r) {
    Map<String, Object> m = new HashMap<>();
    m.put("id", r.getId());
    m.put("project_id", r.getProjectId());
    m.put("region_code", r.getRegionCode());
    m.put("region_text", r.getRegionText());
    m.put("building_no", r.getBuildingNo());
    m.put("floor_no", r.getFloorNo());
    m.put("zone", r.getZone());
    m.put("division", r.getDivision());
    m.put("subdivision", r.getSubdivision());
    m.put("item", r.getItem());
    m.put("item_code", r.getItemCode());
    m.put("indicator", r.getIndicator());
    m.put("indicator_code", r.getIndicatorCode());
    m.put("result", r.getResult());
    m.put("photo_path", r.getPhotoPath());
    m.put("remark", r.getRemark());
    m.put("ai_json", r.getAiJson());
    m.put("client_created_at", r.getClientCreatedAt());
    m.put("created_at", r.getCreatedAt());
    m.put("source", r.getSource());
    m.put("client_record_id", r.getClientRecordId());
    return m;
  }

  private static Map<String, Object> issueToMap(IssueReportEntity r) {
    Map<String, Object> m = new HashMap<>();
    m.put("id", r.getId());
    m.put("project_id", r.getProjectId());
    m.put("region_code", r.getRegionCode());
    m.put("region_text", r.getRegionText());
    m.put("building_no", r.getBuildingNo());
    m.put("floor_no", r.getFloorNo());
    m.put("zone", r.getZone());
    m.put("division", r.getDivision());
    m.put("subdivision", r.getSubdivision());
    m.put("item", r.getItem());
    m.put("indicator", r.getIndicator());
    m.put("library_id", r.getLibraryId());
    m.put("description", r.getDescription());
    m.put("severity", r.getSeverity());
    m.put("deadline_days", r.getDeadlineDays());
    m.put("responsible_unit", r.getResponsibleUnit());
    m.put("responsible_person", r.getResponsiblePerson());
    m.put("status", r.getStatus());
    m.put("photo_path", r.getPhotoPath());
    m.put("ai_json", r.getAiJson());
    m.put("client_created_at", r.getClientCreatedAt());
    m.put("created_at", r.getCreatedAt());
    m.put("source", r.getSource());
    m.put("client_record_id", r.getClientRecordId());
    return m;
  }

  private static int toInt(Object o) {
    if (o == null) {
      return 0;
    }
    if (o instanceof Number n) {
      return n.intValue();
    }
    try {
      return Integer.parseInt(o.toString());
    } catch (NumberFormatException e) {
      return 0;
    }
  }

  private static String asString(Object o) {
    return o == null ? null : o.toString();
  }

  private static OffsetDateTime asOffsetDateTime(Object o) {
    if (o == null) {
      return null;
    }
    if (o instanceof OffsetDateTime odt) {
      return odt;
    }
    // SQLite often stores timestamps as text; keep best-effort.
    try {
      return OffsetDateTime.parse(o.toString());
    } catch (Exception e) {
      return null;
    }
  }
}
