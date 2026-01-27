package com.flutterai.backend.service;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.flutterai.backend.dto.AiDtos.ChatIn;
import com.flutterai.backend.dto.AiDtos.ChatOut;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;

@Service
public class ChatService {
  private final EntityManager entityManager;
  private final ProjectService projectService;
  private final DashboardService dashboardService;

  public ChatService(EntityManager entityManager, ProjectService projectService, DashboardService dashboardService) {
    this.entityManager = entityManager;
    this.projectService = projectService;
    this.dashboardService = dashboardService;
  }

  @Transactional
  public ChatOut chat(ChatIn payload) {
    String q = payload == null || payload.query() == null ? "" : payload.query().trim();
    if (q.isEmpty()) {
      // Python accepts message fallback; keep simple here.
      throw new IllegalArgumentException("query is empty");
    }

    long projectId = projectService.ensureProject(
        payload != null && payload.projectName() != null && !payload.projectName().trim().isEmpty()
            ? payload.projectName().trim()
            : "默认项目")
        .getId();

    // Best-effort backfill for building/floor fields.
    dashboardService.backfillRegionFields(projectId, 200);

    IntentAndScope det = inferIntentAndScope(q, payload == null ? null : payload.messages());
    String intent = det.intent;
    Map<String, Object> scope = det.scope;

    String building = (String) scope.get("building");
    Integer floor = (Integer) scope.get("floor");

    // 0) Deterministic tool-like intents.
    if ("progress".equals(intent)) {
      List<Map<String, Object>> progress = progressByBuildingAndProcess(projectId, building, 6, 10);

      List<String> lines = new ArrayList<>();
      if (building != null) {
        lines.add(building + "工序进度（按已落库验收记录推算）：");
      } else {
        lines.add("项目工序进度（每栋：工序→到几层，按已落库验收记录推算）：");
      }

      if (progress.isEmpty()) {
        lines.add("- 暂无可用的楼栋/楼层数据（请确保部位包含‘1栋6层’且已录入验收）。");
      } else {
        for (Map<String, Object> it : progress) {
          String bn = asStr(it.get("building"), "未解析");
          Object psObj = it.get("processes");
          if (!(psObj instanceof List<?> ps) || ps.isEmpty()) {
            continue;
          }
          List<String> segs = new ArrayList<>();
          for (Object pObj : ps) {
            if (!(pObj instanceof Map<?, ?> p)) {
              continue;
            }
            String proc = asStr(p.get("process"), "工序");
            int mf = toInt(p.get("max_floor"));
            String st = asStr(p.get("status"), "");
            if (!st.isEmpty() && !"合格".equals(st)) {
              segs.add(proc + "到" + mf + "层（" + st + "）");
            } else {
              segs.add(proc + "到" + mf + "层");
            }
          }
          if (!segs.isEmpty()) {
            lines.add("- " + bn + "：" + String.join("；", segs));
          }
        }
      }

      lines.add("\n提示：统计口径=同一工序在该楼栋出现过的最高楼层；楼栋/楼层解析依赖部位格式‘1栋6层/区域’。");

      Map<String, Object> meta = Map.of(
          "route", "chat",
          "tool", Map.of("intent", "progress", "scope", scope),
          "llm", Map.of("used", false, "provider", "doubao", "model", ""));

      return new ChatOut(String.join("\n", lines), Map.of("progress", progress), meta);
    }

    if ("issues_top".equals(intent) || "issues_detail".equals(intent)) {
      boolean detail = "issues_detail".equals(intent);
      List<Map<String, Object>> cats = topIssueCategories(projectId, building, floor, null, 5, detail ? 3 : 1);

      List<String> scopeTxt = new ArrayList<>();
      if (building != null) {
        scopeTxt.add(building);
      }
      if (floor != null) {
        scopeTxt.add(floor + "层");
      }
      String scopeS = String.join("，", scopeTxt);

      List<String> lines = new ArrayList<>();
      String head = detail ? "巡检问题明细（按类型汇总+示例）" : "巡检问题类型排行";
      lines.add(head + (scopeS.isEmpty() ? "" : "（" + scopeS + "）") + "：");

      if (cats.isEmpty()) {
        lines.add("- 暂无可统计的问题数据（可能未录入巡检，或楼栋/楼层未解析）。");
      } else {
        int idx = 0;
        for (Map<String, Object> c : cats) {
          idx++;
          String cat = asStr(c.get("category"), "未分类");
          int total = toInt(c.get("total"));
          int open = toInt(c.get("open"));
          int sev = toInt(c.get("severe"));
          lines.add(idx + ") " + cat + "：" + total + "条（未闭环" + open + "，严重" + sev + "）");
          if (detail) {
            Object samplesObj = c.get("samples");
            if (samplesObj instanceof List<?> samples && !samples.isEmpty()) {
              int n = 0;
              for (Object smObj : samples) {
                if (!(smObj instanceof Map<?, ?> sm)) {
                  continue;
                }
                n++;
                if (n > 3) {
                  break;
                }
                String where = asStr(sm.get("where"), "-");
                String desc = asStr(sm.get("desc"), "");
                String st = asStr(sm.get("status"), "");
                String sv = asStr(sm.get("severity"), "");
                lines.add("   - 例：" + where + "｜" + desc + "（" + st + "，" + sv + "）");
              }
            }
          }
        }
      }

      if (!detail) {
        lines.add("\n你可以继续问：‘具体什么问题？’我会把每类的示例条目列出来。");
      }

      Map<String, Object> meta = Map.of(
          "route", "chat",
          "tool", Map.of("intent", intent, "scope", scope),
          "llm", Map.of("used", false, "provider", "doubao", "model", ""));

      return new ChatOut(String.join("\n", lines), Map.of("issue_categories", cats), meta);
    }

    // Focus keyword route (deterministic pack).
    if (isFocusQuery(q)) {
      int days = scope.get("time_range_days") instanceof Integer i ? i : 14;
      if (days <= 0) {
        days = 14;
      }

      Map<String, Object> focusPack = dashboardService.focusPack(projectId, days, building, true, 200);
      // Attach plan-like info
      @SuppressWarnings("unchecked")
      Map<String, Object> meta = (Map<String, Object>) focusPack.getOrDefault("meta", new HashMap<>());
      meta = new HashMap<>(meta);
      meta.put("plan", Map.of("intent", "focus", "scope", scope));
      focusPack.put("meta", meta);

      String answer = focusAnswerFromPack(focusPack);
      Map<String, Object> outMeta = Map.of(
          "route", "focus",
          "llm", Map.of("used", false, "provider", "doubao", "model", ""));
      return new ChatOut(answer, Map.of("focus_pack", focusPack), outMeta);
    }

    // Fallback: scoped facts (like _facts_for_plan) + rule-based answer.
    Map<String, Object> facts = factsForScope(projectId, scope, 10);
    facts.put("plan", Map.of("intent", "fallback", "scope", scope, "style", "analysis"));

    String answer = fallbackAnswer(q, facts);
    Map<String, Object> meta = Map.of(
        "route", "chat",
        "llm", Map.of("used", false, "provider", "doubao", "model", ""));
    return new ChatOut(answer, facts, meta);
  }

  private String fallbackAnswer(String q, Map<String, Object> facts) {
    int aUnq = toInt(facts.get("acceptance_unqualified"));
    int aOk = toInt(facts.get("acceptance_qualified"));
    int aPen = toInt(facts.get("acceptance_pending"));
    int iOpen = toInt(facts.get("issues_open"));
    int iTotal = toInt(facts.get("issues_total"));

    if (q.contains("不合格") && q.contains("验收")) {
      return "当前验收不合格 " + aUnq + " 条（合格 " + aOk + "，甩项 " + aPen + "）。";
    }
    if (q.contains("巡检") && (q.contains("多少") || q.contains("几条") || q.contains("数量"))) {
      return "当前巡检问题共 " + iTotal + " 条，其中未闭环(open) " + iOpen + " 条。";
    }
    if (q.contains("责任单位") || q.contains("谁")) {
      Object topObj = facts.get("top_responsible_units");
      if (topObj instanceof List<?> top && !top.isEmpty() && top.get(0) instanceof Map<?, ?> head) {
        return "未闭环问题最多的责任单位是 " + asStr(head.get("responsible_unit"), "-") + "（" + toInt(head.get("count")) + " 条）。";
      }
      return "当前没有可统计的责任单位分布。";
    }

    if (containsAny(q, List.of("解释", "怎么理解", "含义"))) {
      return String.join(
          "\n",
          List.of(
              "说明：我基于本项目已写入的验收/巡检数据进行汇总。",
              "- ‘验收分项’：按分项(item/item_code)去重后统计，并按最差结果归类（不合格>甩项>合格）。",
              "- ‘巡检未闭环’：status=open 的问题数。",
              "- ‘未解析’楼栋：说明该条记录的 region_text/building_no 无法解析到楼栋，建议按‘1栋6层/区域’规范填写。"
          ));
    }

    if (containsAny(q, List.of("为什么", "原因", "归因", "分析", "风险", "建议", "怎么改", "怎么做"))) {
      List<String> lines = new ArrayList<>();
      lines.add("分析与建议（基于现有事实）：");

      Object topObj = facts.get("top_responsible_units");
      if (topObj instanceof List<?> top && !top.isEmpty() && top.get(0) instanceof Map<?, ?> head) {
        lines.add(
            "- 当前未闭环问题主要集中在责任单位：" + asStr(head.get("responsible_unit"), "-") + "（" + toInt(head.get("count")) + " 条）。");
      }

      Object recentBadObj = facts.get("recent_unqualified_acceptance");
      if (recentBadObj instanceof List<?> bad && !bad.isEmpty() && bad.get(0) instanceof Map<?, ?> r0) {
        lines.add(
            "- 最近一次不合格验收：" + asStr(r0.get("region_text"), "-") + " / " + asStr(r0.get("item"), "-") + " / "
                + asStr(r0.get("indicator"), "-") + "（备注：" + (r0.get("remark") == null ? "无" : asStr(r0.get("remark"), "无")) + "）。");
      }

      Object recentOpenObj = facts.get("recent_open_issues");
      if (recentOpenObj instanceof List<?> open && !open.isEmpty() && open.get(0) instanceof Map<?, ?> i0) {
        lines.add(
            "- 最近一条未闭环巡检：" + asStr(i0.get("region_text"), "-") + "（责任单位：" + asStr(i0.get("responsible_unit"), "未填写") + "）。");
      }

      lines.add("- 建议：优先闭环 open 问题；对不合格分项复查并补充照片/整改记录；统一位置填写以提升楼栋/楼层统计质量。"
      );
      return String.join("\n", lines);
    }

    if (containsAny(q, List.of("进展", "进度", "每栋", "各栋", "楼栋", "几栋"))) {
      Object byBObj = facts.get("by_building");
      List<Map<String, Object>> scoped = new ArrayList<>();
      String targetBuilding = extractBuilding(q);

      if (byBObj instanceof List<?> byB) {
        for (Object bObj : byB) {
          if (!(bObj instanceof Map<?, ?> b)) {
            continue;
          }
          String bn = asStr(b.get("building"), "未解析");
          if (targetBuilding != null && !targetBuilding.equals(bn)) {
            continue;
          }
          scoped.add((Map<String, Object>) b);
        }
      }

      List<String> lines = new ArrayList<>();
      if (targetBuilding != null) {
        lines.add(targetBuilding + "进展（基于已落库数据）：");
      } else {
        lines.add("项目进展（按楼栋汇总）：");
      }

      if (!scoped.isEmpty()) {
        for (Map<String, Object> b : scoped) {
          String bn = asStr(b.get("building"), "未解析");
          lines.add(
              "- " + bn + "：验收" + toInt(b.get("acceptance_total")) + "（不合格" + toInt(b.get("acceptance_unqualified")) + "，合格"
                  + toInt(b.get("acceptance_qualified")) + "，甩项" + toInt(b.get("acceptance_pending")) + "）；巡检" + toInt(b.get("issues_total"))
                  + "（未闭环" + toInt(b.get("issues_open")) + "）");
        }
      } else if (targetBuilding != null) {
        lines.add("- 暂无该楼栋的数据（可能楼栋未解析或尚未录入）。");
      } else {
        lines.add("- 暂无可按楼栋汇总的数据（可能还没有写入 building_no）。");
      }
      return String.join("\n", lines);
    }

    return "我已读取本项目的验收与巡检汇总数据。你可以更自由地问：‘项目进展如何？’、‘每栋情况总结并解释原因？’、‘为什么巡检未闭环这么多？’、‘给出风险点和整改建议’。";
  }

  private Map<String, Object> factsForScope(long projectId, Map<String, Object> scope, int limit) {
    String building = (String) scope.get("building");
    Integer floor = (Integer) scope.get("floor");
    String responsibleUnit = (String) scope.get("responsible_unit");

    var base = dashboardService.summary(projectId, limit);
    Map<String, Object> out = new HashMap<>();
    out.put("acceptance_total", base.acceptanceTotal());
    out.put("acceptance_qualified", base.acceptanceQualified());
    out.put("acceptance_unqualified", base.acceptanceUnqualified());
    out.put("acceptance_pending", base.acceptancePending());
    out.put("issues_total", base.issuesTotal());
    out.put("issues_open", base.issuesOpen());
    out.put("issues_closed", base.issuesClosed());
    out.put("issues_by_severity", base.issuesBySeverity());
    out.put("top_responsible_units", base.topResponsibleUnits());
    out.put("recent_unqualified_acceptance", base.recentUnqualifiedAcceptance());
    out.put("recent_open_issues", base.recentOpenIssues());
    out.put("by_building", buildingProgressFacts(projectId));

    if (building == null && floor == null && responsibleUnit == null) {
      return out;
    }

    Map<String, Integer> a = acceptanceItemCounts(projectId, building, floor);
    Map<String, Integer> i = issueCounts(projectId, building, floor, responsibleUnit);

    out.put("scope", Map.of("building", building, "floor", floor, "responsible_unit", responsibleUnit));
    out.put(
        "scope_acceptance",
        Map.of(
            "acceptance_total", a.getOrDefault("qualified", 0) + a.getOrDefault("unqualified", 0) + a.getOrDefault("pending", 0),
            "acceptance_qualified", a.getOrDefault("qualified", 0),
            "acceptance_unqualified", a.getOrDefault("unqualified", 0),
            "acceptance_pending", a.getOrDefault("pending", 0),
            "definition", "验收分项口径：按 item/item_code 去重并按最差结果归类（不合格>甩项>合格）"
        )
    );
    out.put(
        "scope_issues",
        Map.of(
            "issues_total", i.getOrDefault("total", 0),
            "issues_open", i.getOrDefault("open", 0),
            "issues_closed", i.getOrDefault("closed", 0)
        )
    );

    if (building != null) {
      out.put("by_floor", byFloorFacts(projectId, building));
    }
    return out;
  }

  private List<Map<String, Object>> progressByBuildingAndProcess(long projectId, String building, int topNProcess, int buildingLimit) {
    int topN = topNProcess <= 0 ? 6 : topNProcess;
    int bLimit = buildingLimit <= 0 ? 10 : buildingLimit;

    String processExpr = "COALESCE(item, indicator, subdivision, division, item_code, indicator_code)";
    String sql = "SELECT building_no, " + processExpr + " AS process, MAX(floor_no) AS max_floor, COUNT(id) AS record_count, "
        + "MAX(CASE WHEN result='unqualified' THEN 1 ELSE 0 END) AS has_unq, "
        + "MAX(CASE WHEN result='pending' THEN 1 ELSE 0 END) AS has_pen "
        + "FROM acceptance_records WHERE project_id=:pid AND floor_no IS NOT NULL "
        + (building != null ? "AND building_no=:b " : "")
        + "GROUP BY building_no, process";

    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    if (building != null) {
      q.setParameter("b", building);
    }

    List<?> rows = q.getResultList();
    Map<String, List<Map<String, Object>>> byB = new HashMap<>();
    for (Object r : rows) {
      Object[] row = (Object[]) r;
      String bn = normalizeBuilding(row[0]);
      String proc = asStr(row[1], "未命名工序").trim();
      if (DashboardService.looksLikeCode(proc)) {
        proc = "工序（未命名）";
      }
      int mf = toInt(row[2]);
      int cnt = toInt(row[3]);
      int hasUnq = toInt(row[4]);
      int hasPen = toInt(row[5]);
      if (mf <= 0) {
        continue;
      }
      String status = "合格";
      if (hasUnq > 0) {
        status = "含不合格";
      } else if (hasPen > 0) {
        status = "含甩项";
      }

      Map<String, Object> item = new HashMap<>();
      item.put("process", proc.isEmpty() ? "未命名工序" : proc);
      item.put("max_floor", mf);
      item.put("record_count", cnt);
      item.put("status", status);
      byB.computeIfAbsent(bn, k -> new ArrayList<>()).add(item);
    }

    List<String> buildings = new ArrayList<>(byB.keySet());
    buildings.sort((a, b) -> buildingSortKey(a).compareTo(buildingSortKey(b)));
    if (buildings.size() > bLimit) {
      buildings = buildings.subList(0, bLimit);
    }

    List<Map<String, Object>> out = new ArrayList<>();
    for (String bn : buildings) {
      List<Map<String, Object>> items = byB.get(bn);
      items.sort((x, y) -> {
        int c1 = Integer.compare(toInt(y.get("max_floor")), toInt(x.get("max_floor")));
        if (c1 != 0) {
          return c1;
        }
        return Integer.compare(toInt(y.get("record_count")), toInt(x.get("record_count")));
      });
      if (items.size() > topN) {
        items = items.subList(0, topN);
      }
      out.add(Map.of("building", bn, "processes", items));
    }
    return out;
  }

  private List<Map<String, Object>> topIssueCategories(
      long projectId,
      String building,
      Integer floor,
      String responsibleUnit,
      int topN,
      int samplePerCat) {
    int t = topN <= 0 ? 5 : topN;
    int s = samplePerCat <= 0 ? 1 : samplePerCat;

    String sql = "SELECT id, region_text, building_no, division, subdivision, item, indicator, description, status, severity, responsible_unit, floor_no "
        + "FROM issue_reports WHERE project_id=:pid "
        + (building != null ? "AND building_no=:b " : "")
        + (floor != null ? "AND floor_no=:f " : "")
        + (responsibleUnit != null ? "AND responsible_unit=:ru " : "")
        + "ORDER BY created_at DESC LIMIT 5000";

    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    if (building != null) {
      q.setParameter("b", building);
    }
    if (floor != null) {
      q.setParameter("f", floor);
    }
    if (responsibleUnit != null) {
      q.setParameter("ru", responsibleUnit);
    }

    List<?> rows = q.getResultList();
    Map<String, Map<String, Object>> buckets = new HashMap<>();
    for (Object r : rows) {
      Object[] row = (Object[]) r;
      String regionText = asStr(row[1], "");
      String buildingNo = asStr(row[2], "");
      String division = asStr(row[3], "");
      String subdivision = asStr(row[4], "");
      String item = asStr(row[5], "");
      String indicator = asStr(row[6], "");
      String desc = asStr(row[7], "");
      String status = asStr(row[8], "open");
      String severity = asStr(row[9], "-");

      String key = categoryKeyForIssue(indicator, item, subdivision, division);
      Map<String, Object> b = buckets.computeIfAbsent(key, k -> {
        Map<String, Object> m = new HashMap<>();
        m.put("category", k);
        m.put("total", 0);
        m.put("open", 0);
        m.put("severe", 0);
        m.put("samples", new ArrayList<Map<String, Object>>());
        return m;
      });

      b.put("total", toInt(b.get("total")) + 1);
      if ("open".equals(status.trim().toLowerCase())) {
        b.put("open", toInt(b.get("open")) + 1);
      }
      if ("severe".equals(DashboardService.normalizeSeverityKey(severity))) {
        b.put("severe", toInt(b.get("severe")) + 1);
      }

      @SuppressWarnings("unchecked")
      List<Map<String, Object>> samples = (List<Map<String, Object>>) b.get("samples");
      if (samples.size() < s) {
        String where = !regionText.trim().isEmpty() ? regionText.trim() : (!buildingNo.trim().isEmpty() ? buildingNo.trim() : "-");
        samples.add(
            Map.of(
                "where", where,
                "desc", shortText(desc, 26),
                "status", status.trim().isEmpty() ? "open" : status.trim(),
                "severity", severity.trim().isEmpty() ? "-" : severity.trim()
            )
        );
      }
    }

    List<Map<String, Object>> cats = new ArrayList<>(buckets.values());
    cats.sort((x, y) -> {
      int c1 = Integer.compare(toInt(y.get("open")), toInt(x.get("open")));
      if (c1 != 0) {
        return c1;
      }
      int c2 = Integer.compare(toInt(y.get("total")), toInt(x.get("total")));
      if (c2 != 0) {
        return c2;
      }
      return Integer.compare(toInt(y.get("severe")), toInt(x.get("severe")));
    });
    if (cats.size() > t) {
      cats = cats.subList(0, t);
    }
    return cats;
  }

  private Map<String, Integer> acceptanceItemCounts(long projectId, String building, Integer floor) {
    String itemExpr = "COALESCE(item_code, item, indicator_code, indicator)";
    String sql = "SELECT " + itemExpr + " AS item_key, "
        + "MAX(CASE WHEN result='unqualified' THEN 1 ELSE 0 END) AS has_unq, "
        + "MAX(CASE WHEN result='pending' THEN 1 ELSE 0 END) AS has_pen "
        + "FROM acceptance_records WHERE project_id=:pid "
        + (building != null ? "AND building_no=:b " : "")
        + (floor != null ? "AND floor_no=:f " : "")
        + "GROUP BY item_key";
    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    if (building != null) {
      q.setParameter("b", building);
    }
    if (floor != null) {
      q.setParameter("f", floor);
    }
    List<?> rows = q.getResultList();
    int qualified = 0;
    int unqualified = 0;
    int pending = 0;
    for (Object r : rows) {
      Object[] row = (Object[]) r;
      int hasUnq = toInt(row[1]);
      int hasPen = toInt(row[2]);
      if (hasUnq > 0) {
        unqualified += 1;
      } else if (hasPen > 0) {
        pending += 1;
      } else {
        qualified += 1;
      }
    }
    Map<String, Integer> out = new HashMap<>();
    out.put("qualified", qualified);
    out.put("unqualified", unqualified);
    out.put("pending", pending);
    return out;
  }

  private Map<String, Integer> issueCounts(long projectId, String building, Integer floor, String responsibleUnit) {
    String sql = "SELECT status, COUNT(id) FROM issue_reports WHERE project_id=:pid "
        + (building != null ? "AND building_no=:b " : "")
        + (floor != null ? "AND floor_no=:f " : "")
        + (responsibleUnit != null ? "AND responsible_unit=:ru " : "")
        + "GROUP BY status";
    Query q = entityManager.createNativeQuery(sql);
    q.setParameter("pid", projectId);
    if (building != null) {
      q.setParameter("b", building);
    }
    if (floor != null) {
      q.setParameter("f", floor);
    }
    if (responsibleUnit != null) {
      q.setParameter("ru", responsibleUnit);
    }
    List<?> rows = q.getResultList();
    Map<String, Integer> m = new HashMap<>();
    for (Object r : rows) {
      Object[] row = (Object[]) r;
      String s = asStr(row[0], "").trim().toLowerCase();
      m.put(s, toInt(row[1]));
    }
    int open = m.getOrDefault("open", 0);
    int closed = m.getOrDefault("closed", 0);
    Map<String, Integer> out = new HashMap<>();
    out.put("open", open);
    out.put("closed", closed);
    out.put("total", open + closed);
    return out;
  }

  private List<Map<String, Object>> byFloorFacts(long projectId, String building) {
    String itemExpr = "COALESCE(item_code, item, indicator_code, indicator)";
    String aSql = "SELECT floor_no, " + itemExpr + " AS item_key, "
        + "MAX(CASE WHEN result='unqualified' THEN 1 ELSE 0 END) AS has_unq, "
        + "MAX(CASE WHEN result='pending' THEN 1 ELSE 0 END) AS has_pen "
        + "FROM acceptance_records WHERE project_id=:pid AND building_no=:b "
        + "GROUP BY floor_no, item_key";

    Query aq = entityManager.createNativeQuery(aSql);
    aq.setParameter("pid", projectId);
    aq.setParameter("b", building);
    List<?> aRows = aq.getResultList();

    Map<Integer, Map<String, Object>> byF = new HashMap<>();
    for (Object r : aRows) {
      Object[] row = (Object[]) r;
      int fkey = toInt(row[0]);
      if (fkey == 0) {
        continue;
      }
      Map<String, Object> d = byF.computeIfAbsent(fkey, k -> baseFloor(k));
      d.put("acceptance_total", toInt(d.get("acceptance_total")) + 1);
      int hasUnq = toInt(row[2]);
      int hasPen = toInt(row[3]);
      if (hasUnq > 0) {
        d.put("acceptance_unqualified", toInt(d.get("acceptance_unqualified")) + 1);
      } else if (hasPen > 0) {
        d.put("acceptance_pending", toInt(d.get("acceptance_pending")) + 1);
      } else {
        d.put("acceptance_qualified", toInt(d.get("acceptance_qualified")) + 1);
      }
    }

    String iSql = "SELECT floor_no, status, COUNT(id) FROM issue_reports WHERE project_id=:pid AND building_no=:b GROUP BY floor_no, status";
    Query iq = entityManager.createNativeQuery(iSql);
    iq.setParameter("pid", projectId);
    iq.setParameter("b", building);
    List<?> iRows = iq.getResultList();
    for (Object r : iRows) {
      Object[] row = (Object[]) r;
      int fkey = toInt(row[0]);
      if (fkey == 0) {
        continue;
      }
      String st = asStr(row[1], "").trim().toLowerCase();
      int cnt = toInt(row[2]);
      Map<String, Object> d = byF.computeIfAbsent(fkey, k -> baseFloor(k));
      d.put("issues_total", toInt(d.get("issues_total")) + cnt);
      if ("open".equals(st)) {
        d.put("issues_open", toInt(d.get("issues_open")) + cnt);
      } else if ("closed".equals(st)) {
        d.put("issues_closed", toInt(d.get("issues_closed")) + cnt);
      }
    }

    List<Integer> floors = new ArrayList<>(byF.keySet());
    floors.sort(Integer::compareTo);
    List<Map<String, Object>> out = new ArrayList<>();
    for (Integer f : floors) {
      out.add(byF.get(f));
    }
    return out;
  }

  private List<Map<String, Object>> buildingProgressFacts(long projectId) {
    String itemExpr = "COALESCE(item_code, item, indicator_code, indicator)";
    String aSql = "SELECT building_no, " + itemExpr + " AS item_key, "
        + "MAX(CASE WHEN result='unqualified' THEN 1 ELSE 0 END) AS has_unq, "
        + "MAX(CASE WHEN result='pending' THEN 1 ELSE 0 END) AS has_pen "
        + "FROM acceptance_records WHERE project_id=:pid GROUP BY building_no, item_key";
    Query aq = entityManager.createNativeQuery(aSql);
    aq.setParameter("pid", projectId);
    List<?> aRows = aq.getResultList();

    Map<String, Map<String, Object>> byB = new HashMap<>();
    for (Object r : aRows) {
      Object[] row = (Object[]) r;
      String bkey = normalizeBuilding(row[0]);
      Map<String, Object> d = byB.computeIfAbsent(bkey, k -> baseBuilding(k));
      d.put("acceptance_total", toInt(d.get("acceptance_total")) + 1);
      int hasUnq = toInt(row[2]);
      int hasPen = toInt(row[3]);
      if (hasUnq > 0) {
        d.put("acceptance_unqualified", toInt(d.get("acceptance_unqualified")) + 1);
      } else if (hasPen > 0) {
        d.put("acceptance_pending", toInt(d.get("acceptance_pending")) + 1);
      } else {
        d.put("acceptance_qualified", toInt(d.get("acceptance_qualified")) + 1);
      }
    }

    String iSql = "SELECT building_no, status, COUNT(id) FROM issue_reports WHERE project_id=:pid GROUP BY building_no, status";
    Query iq = entityManager.createNativeQuery(iSql);
    iq.setParameter("pid", projectId);
    List<?> iRows = iq.getResultList();
    for (Object r : iRows) {
      Object[] row = (Object[]) r;
      String bkey = normalizeBuilding(row[0]);
      Map<String, Object> d = byB.computeIfAbsent(bkey, k -> baseBuilding(k));
      int cnt = toInt(row[2]);
      d.put("issues_total", toInt(d.get("issues_total")) + cnt);
      String st = asStr(row[1], "").trim().toLowerCase();
      if ("open".equals(st)) {
        d.put("issues_open", toInt(d.get("issues_open")) + cnt);
      } else if ("closed".equals(st)) {
        d.put("issues_closed", toInt(d.get("issues_closed")) + cnt);
      }
    }

    List<Map<String, Object>> out = new ArrayList<>(byB.values());
    out.sort((x, y) -> buildingSortKey(asStr(x.get("building"), "")).compareTo(buildingSortKey(asStr(y.get("building"), ""))));
    return out;
  }

  private static Map<String, Object> baseFloor(int floor) {
    Map<String, Object> d = new HashMap<>();
    d.put("floor", floor);
    d.put("acceptance_total", 0);
    d.put("acceptance_qualified", 0);
    d.put("acceptance_unqualified", 0);
    d.put("acceptance_pending", 0);
    d.put("issues_total", 0);
    d.put("issues_open", 0);
    d.put("issues_closed", 0);
    return d;
  }

  private static Map<String, Object> baseBuilding(String building) {
    Map<String, Object> d = new HashMap<>();
    d.put("building", building);
    d.put("acceptance_total", 0);
    d.put("acceptance_qualified", 0);
    d.put("acceptance_unqualified", 0);
    d.put("acceptance_pending", 0);
    d.put("issues_total", 0);
    d.put("issues_open", 0);
    d.put("issues_closed", 0);
    return d;
  }

  private static String focusAnswerFromPack(Map<String, Object> focusPack) {
    Map<String, Object> metrics = asMap(focusPack.get("metrics"));
    int issuesOpen = toInt(metrics.get("issues_open"));
    int issuesOverdue = toInt(metrics.get("issues_open_overdue"));
    int severe = toInt(metrics.get("issues_open_severe"));
    int unqItems = toInt(metrics.get("acceptance_unqualified_items"));
    int penItems = toInt(metrics.get("acceptance_pending_items"));

    StringBuilder sb = new StringBuilder();
    sb.append("重点关注（基于近一段时间验收+巡检数据）：\n");
    sb.append("- 未闭环问题：").append(issuesOpen).append(" 条（严重 ").append(severe).append("，超期 ").append(issuesOverdue).append("）\n");
    sb.append("- 验收风险分项：不合格 ").append(unqItems).append(" 项，甩项 ").append(penItems).append(" 项\n");

    Object topObj = focusPack.get("top_focus");
    if (topObj instanceof List<?> top && !top.isEmpty() && top.get(0) instanceof Map<?, ?> t0) {
      sb.append("\n优先闭环建议：\n");
      int n = 0;
      for (Object it : top) {
        if (!(it instanceof Map<?, ?> m)) {
          continue;
        }
        n++;
        if (n > 5) {
          break;
        }
        sb.append(n).append(") ").append(asStr(m.get("title"), "关注点")).append("（风险分 ").append(toInt(m.get("risk_score"))).append("）\n");
      }
    }

    sb.append("\n提示：楼栋/楼层解析依赖部位格式‘1栋6层/区域’，数据不全会影响统计。\n");
    sb.append("如果你想看更细：可以问‘1栋进展’、‘2栋哪类问题最多’、‘具体什么问题’。" );
    return sb.toString();
  }

  private static IntentAndScope inferIntentAndScope(String q, List<Map<String, Object>> messages) {
    String intent = inferIntent(q, messages);
    Map<String, Object> scope = extractBasicScope(q);
    return new IntentAndScope(intent, scope);
  }

  private static String inferIntent(String q, List<Map<String, Object>> messages) {
    String s = q == null ? "" : q.replace(" ", "").trim();

    if (containsAny(s, List.of("进度", "进展", "工序", "到几层"))) {
      return "progress";
    }
    if (containsAny(s, List.of("关注", "关注点", "重点", "风险", "预警", "下一步", "focus", "驾驶舱"))) {
      // Still handled later via keyword focus route.
      return "unknown";
    }

    // Follow-up like “1栋呢/那1栋怎么样”
    if (s.matches("(?:那|这个|再看下)?\\s*\\d+\\s*(?:栋|楼|#)\\s*(?:呢|怎么样|情况)?")) {
      String last = lastUserUtterances(messages, 6);
      if (containsAny(last, List.of("进度", "进展", "工序", "到几层", "楼栋"))) {
        return "progress";
      }
      if (containsAny(last, List.of("哪类问题", "问题多", "具体什么问题", "巡检", "缺陷"))) {
        return "issues_detail";
      }
    }

    if (containsAny(s, List.of("哪类", "哪个类型", "类型", "问题多", "最多", "top", "排行")) && containsAny(s, List.of("问题", "缺陷", "巡检"))) {
      return "issues_top";
    }

    if (containsAny(s, List.of("具体", "明细", "分别", "列出", "都有什么", "哪些问题", "什么问题"))) {
      if (containsAny(s, List.of("问题", "缺陷", "巡检"))) {
        return "issues_detail";
      }
      String last = lastUserUtterances(messages, 4);
      if (containsAny(last, List.of("问题", "缺陷", "巡检", "未闭环"))) {
        return "issues_detail";
      }
    }

    return "unknown";
  }

  private static String lastUserUtterances(List<Map<String, Object>> messages, int n) {
    if (messages == null || messages.isEmpty() || n <= 0) {
      return "";
    }
    StringBuilder sb = new StringBuilder();
    int count = 0;
    for (int i = messages.size() - 1; i >= 0 && count < n; i--) {
      Map<String, Object> m = messages.get(i);
      if (m == null) {
        continue;
      }
      String role = asStr(m.get("role"), "").trim().toLowerCase();
      if (!role.equals("user") && !role.equals("human")) {
        continue;
      }
      String content = asStr(m.get("content"), "").trim();
      if (content.isEmpty()) {
        continue;
      }
      sb.append(content);
      count++;
    }
    return sb.toString();
  }

  private static Map<String, Object> extractBasicScope(String q) {
    Map<String, Object> scope = new HashMap<>();
    String s = q == null ? "" : q.replace(" ", "");

    String building = extractBuilding(s);
    if (building != null) {
      scope.put("building", building);
    }
    Integer floor = extractFloor(s);
    if (floor != null) {
      scope.put("floor", floor);
    }

    Integer days = extractDays(s);
    if (days != null) {
      scope.put("time_range_days", days);
    }

    String ru = extractResponsibleUnit(s);
    if (ru != null) {
      scope.put("responsible_unit", ru);
    }

    return scope;
  }

  private static String extractBuilding(String s) {
    if (s == null) {
      return null;
    }
    Matcher m = Pattern.compile("(\\d+)\\s*(?:栋|楼|#)").matcher(s);
    if (m.find()) {
      return m.group(1) + "栋";
    }
    return null;
  }

  private static Integer extractFloor(String s) {
    if (s == null) {
      return null;
    }
    Matcher m = Pattern.compile("(\\d+)\\s*(?:层|F)", Pattern.CASE_INSENSITIVE).matcher(s);
    if (m.find()) {
      try {
        return Integer.parseInt(m.group(1));
      } catch (Exception ignored) {
        return null;
      }
    }
    return null;
  }

  private static Integer extractDays(String s) {
    if (s == null) {
      return null;
    }
    if (containsAny(s, List.of("本周", "近7天", "最近7天"))) {
      return 7;
    }
    if (containsAny(s, List.of("近两周", "最近两周", "近14天", "最近14天"))) {
      return 14;
    }
    if (containsAny(s, List.of("近30天", "最近30天", "近一月", "最近一月"))) {
      return 30;
    }
    Matcher m = Pattern.compile("近(\\d+)(?:天|日)").matcher(s);
    if (m.find()) {
      try {
        int d = Integer.parseInt(m.group(1));
        return d > 0 ? d : null;
      } catch (Exception ignored) {
        return null;
      }
    }
    return null;
  }

  private static String extractResponsibleUnit(String s) {
    if (s == null) {
      return null;
    }
    Matcher m = Pattern.compile("责任单位[:：]?([^\n\r，,。；; ]{2,20})").matcher(s);
    if (m.find()) {
      String ru = m.group(1).trim();
      return ru.isEmpty() ? null : ru;
    }
    return null;
  }

  private static boolean isFocusQuery(String q) {
    String s = q == null ? "" : q.toLowerCase();
    return containsAny(s, List.of("关注", "关注点", "重点", "风险", "预警", "下一步", "focus", "驾驶舱"));
  }

  private static boolean containsAny(String s, List<String> keys) {
    if (s == null || s.isEmpty() || keys == null) {
      return false;
    }
    for (String k : keys) {
      if (k != null && !k.isEmpty() && s.contains(k)) {
        return true;
      }
    }
    return false;
  }

  private static String categoryKeyForIssue(String indicator, String item, String subdivision, String division) {
    String[] parts = new String[] {
        safeTrim(indicator),
        safeTrim(item),
        safeTrim(subdivision),
        safeTrim(division)
    };
    for (String p : parts) {
      if (!p.isEmpty() && !DashboardService.looksLikeCode(p)) {
        return p;
      }
    }
    return "其他问题";
  }

  private static String shortText(String s, int maxLen) {
    String t = s == null ? "" : s.trim().replace("\n", " ");
    if (t.length() <= maxLen) {
      return t;
    }
    return t.substring(0, Math.max(0, maxLen - 1)) + "…";
  }

  private static String normalizeBuilding(Object o) {
    String b = asStr(o, "").trim();
    return b.isEmpty() ? "未解析" : b;
  }

  private static BuildingSortKey buildingSortKey(String bn) {
    Matcher m = Pattern.compile("(\\d+)").matcher(bn == null ? "" : bn);
    if (m.find()) {
      try {
        return new BuildingSortKey(0, Integer.parseInt(m.group(1)), bn);
      } catch (Exception ignored) {
        return new BuildingSortKey(1, 0, bn);
      }
    }
    return new BuildingSortKey(1, 0, bn);
  }

  private static Map<String, Object> asMap(Object o) {
    if (o instanceof Map<?, ?> m) {
      @SuppressWarnings("unchecked")
      Map<String, Object> mm = (Map<String, Object>) m;
      return mm;
    }
    return Map.of();
  }

  private static String safeTrim(String s) {
    return s == null ? "" : s.trim();
  }

  private static String asStr(Object o, String def) {
    if (o == null) {
      return def;
    }
    String s = o.toString();
    return s == null ? def : s;
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
    } catch (Exception ignored) {
      return 0;
    }
  }

  private record IntentAndScope(String intent, Map<String, Object> scope) {}

  private record BuildingSortKey(int kind, int num, String raw) implements Comparable<BuildingSortKey> {
    @Override
    public int compareTo(BuildingSortKey o) {
      int c1 = Integer.compare(this.kind, o.kind);
      if (c1 != 0) {
        return c1;
      }
      int c2 = Integer.compare(this.num, o.num);
      if (c2 != 0) {
        return c2;
      }
      return (this.raw == null ? "" : this.raw).compareTo(o.raw == null ? "" : o.raw);
    }
  }
}
