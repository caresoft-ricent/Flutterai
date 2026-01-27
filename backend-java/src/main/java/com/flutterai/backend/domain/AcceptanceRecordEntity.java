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
    name = "acceptance_records",
    indexes = {
        @Index(name = "idx_acceptance_project", columnList = "project_id"),
        @Index(name = "idx_acceptance_client_record", columnList = "project_id,client_record_id")
    })
public class AcceptanceRecordEntity {
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

  @Column(name = "item_code")
  private String itemCode;

  @Column(name = "indicator")
  private String indicator;

  @Column(name = "indicator_code")
  private String indicatorCode;

  @Column(name = "result", nullable = false)
  private String result;

  @Column(name = "photo_path")
  private String photoPath;

  @Column(name = "remark", columnDefinition = "TEXT")
  private String remark;

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

  public String getItemCode() {
    return itemCode;
  }

  public void setItemCode(String itemCode) {
    this.itemCode = itemCode;
  }

  public String getIndicator() {
    return indicator;
  }

  public void setIndicator(String indicator) {
    this.indicator = indicator;
  }

  public String getIndicatorCode() {
    return indicatorCode;
  }

  public void setIndicatorCode(String indicatorCode) {
    this.indicatorCode = indicatorCode;
  }

  public String getResult() {
    return result;
  }

  public void setResult(String result) {
    this.result = result;
  }

  public String getPhotoPath() {
    return photoPath;
  }

  public void setPhotoPath(String photoPath) {
    this.photoPath = photoPath;
  }

  public String getRemark() {
    return remark;
  }

  public void setRemark(String remark) {
    this.remark = remark;
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
