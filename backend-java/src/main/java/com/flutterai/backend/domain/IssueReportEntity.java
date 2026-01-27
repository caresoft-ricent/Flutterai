package com.flutterai.backend.domain;

import java.time.OffsetDateTime;

import org.hibernate.annotations.CreationTimestamp;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Index;
import jakarta.persistence.Table;

@Entity
@Table(
    name = "issue_reports",
    indexes = {
        @Index(name = "idx_issue_project", columnList = "project_id"),
        @Index(name = "idx_issue_client_record", columnList = "project_id,client_record_id")
    })
public class IssueReportEntity {
  @Id
  @GeneratedValue(strategy = GenerationType.IDENTITY)
  private Long id;

  @Column(name = "project_id", nullable = false)
  private Long projectId;

  @Column(name = "location_id")
  private Long locationId;

  @Column(name = "region_code")
  private String regionCode;

  @Column(name = "region_text")
  private String regionText;

  @Column(name = "building_no")
  private String buildingNo;

  @Column(name = "floor_no")
  private Integer floorNo;

  @Column(name = "zone")
  private String zone;

  @Column(name = "division")
  private String division;

  @Column(name = "subdivision")
  private String subdivision;

  @Column(name = "item")
  private String item;

  @Column(name = "indicator")
  private String indicator;

  @Column(name = "library_id")
  private String libraryId;

  @Column(name = "description", columnDefinition = "TEXT", nullable = false)
  private String description;

  @Column(name = "severity")
  private String severity;

  @Column(name = "deadline_days")
  private Integer deadlineDays;

  @Column(name = "responsible_unit")
  private String responsibleUnit;

  @Column(name = "responsible_person")
  private String responsiblePerson;

  @Column(name = "status")
  private String status = "open";

  @Column(name = "photo_path")
  private String photoPath;

  @Column(name = "ai_json", columnDefinition = "TEXT")
  private String aiJson;

  @Column(name = "client_created_at")
  private OffsetDateTime clientCreatedAt;

  @CreationTimestamp
  @Column(name = "created_at")
  private OffsetDateTime createdAt;

  @Column(name = "source")
  private String source;

  @Column(name = "client_record_id")
  private String clientRecordId;

  public Long getId() {
    return id;
  }

  public void setId(Long id) {
    this.id = id;
  }

  public Long getProjectId() {
    return projectId;
  }

  public void setProjectId(Long projectId) {
    this.projectId = projectId;
  }

  public Long getLocationId() {
    return locationId;
  }

  public void setLocationId(Long locationId) {
    this.locationId = locationId;
  }

  public String getRegionCode() {
    return regionCode;
  }

  public void setRegionCode(String regionCode) {
    this.regionCode = regionCode;
  }

  public String getRegionText() {
    return regionText;
  }

  public void setRegionText(String regionText) {
    this.regionText = regionText;
  }

  public String getBuildingNo() {
    return buildingNo;
  }

  public void setBuildingNo(String buildingNo) {
    this.buildingNo = buildingNo;
  }

  public Integer getFloorNo() {
    return floorNo;
  }

  public void setFloorNo(Integer floorNo) {
    this.floorNo = floorNo;
  }

  public String getZone() {
    return zone;
  }

  public void setZone(String zone) {
    this.zone = zone;
  }

  public String getDivision() {
    return division;
  }

  public void setDivision(String division) {
    this.division = division;
  }

  public String getSubdivision() {
    return subdivision;
  }

  public void setSubdivision(String subdivision) {
    this.subdivision = subdivision;
  }

  public String getItem() {
    return item;
  }

  public void setItem(String item) {
    this.item = item;
  }

  public String getIndicator() {
    return indicator;
  }

  public void setIndicator(String indicator) {
    this.indicator = indicator;
  }

  public String getLibraryId() {
    return libraryId;
  }

  public void setLibraryId(String libraryId) {
    this.libraryId = libraryId;
  }

  public String getDescription() {
    return description;
  }

  public void setDescription(String description) {
    this.description = description;
  }

  public String getSeverity() {
    return severity;
  }

  public void setSeverity(String severity) {
    this.severity = severity;
  }

  public Integer getDeadlineDays() {
    return deadlineDays;
  }

  public void setDeadlineDays(Integer deadlineDays) {
    this.deadlineDays = deadlineDays;
  }

  public String getResponsibleUnit() {
    return responsibleUnit;
  }

  public void setResponsibleUnit(String responsibleUnit) {
    this.responsibleUnit = responsibleUnit;
  }

  public String getResponsiblePerson() {
    return responsiblePerson;
  }

  public void setResponsiblePerson(String responsiblePerson) {
    this.responsiblePerson = responsiblePerson;
  }

  public String getStatus() {
    return status;
  }

  public void setStatus(String status) {
    this.status = status;
  }

  public String getPhotoPath() {
    return photoPath;
  }

  public void setPhotoPath(String photoPath) {
    this.photoPath = photoPath;
  }

  public String getAiJson() {
    return aiJson;
  }

  public void setAiJson(String aiJson) {
    this.aiJson = aiJson;
  }

  public OffsetDateTime getClientCreatedAt() {
    return clientCreatedAt;
  }

  public void setClientCreatedAt(OffsetDateTime clientCreatedAt) {
    this.clientCreatedAt = clientCreatedAt;
  }

  public OffsetDateTime getCreatedAt() {
    return createdAt;
  }

  public void setCreatedAt(OffsetDateTime createdAt) {
    this.createdAt = createdAt;
  }

  public String getSource() {
    return source;
  }

  public void setSource(String source) {
    this.source = source;
  }

  public String getClientRecordId() {
    return clientRecordId;
  }

  public void setClientRecordId(String clientRecordId) {
    this.clientRecordId = clientRecordId;
  }
}
