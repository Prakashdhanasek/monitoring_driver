// To parse this JSON data, do
//
//     final tripStartResponseModel = tripStartResponseModelFromJson(jsonString);

import 'dart:convert';

TripStartResponseModel tripStartResponseModelFromJson(String str) =>
    TripStartResponseModel.fromJson(json.decode(str));

String tripStartResponseModelToJson(TripStartResponseModel data) =>
    json.encode(data.toJson());

class TripStartResponseModel {
  String? id;
  String? vehicleId;
  String? vehicleRegistrationNumber;
  String? driverId;
  String? driverName;
  String? deviceTabletId;
  DateTime? startedAt;
  dynamic endedAt;
  double? startLatitude;
  double? startLongitude;
  dynamic endLatitude;
  dynamic endLongitude;
  dynamic distanceKm;
  String? status;
  DateTime? createdAt;
  double? geofenceCenterLatitude;
  double? geofenceCenterLongitude;
  int? geofenceRadiusMeters;
  String? geofenceId;
  String? geofenceName;
  String? geofenceLocationLabel;
  String? geofenceBoundaryType;
  String? geofencePolygonCoordinatesJson;
  String? geofenceMonitoringMode;

  TripStartResponseModel({
    this.id,
    this.vehicleId,
    this.vehicleRegistrationNumber,
    this.driverId,
    this.driverName,
    this.deviceTabletId,
    this.startedAt,
    this.endedAt,
    this.startLatitude,
    this.startLongitude,
    this.endLatitude,
    this.endLongitude,
    this.distanceKm,
    this.status,
    this.createdAt,
    this.geofenceCenterLatitude,
    this.geofenceCenterLongitude,
    this.geofenceRadiusMeters,
    this.geofenceId,
    this.geofenceName,
    this.geofenceLocationLabel,
    this.geofenceBoundaryType,
    this.geofencePolygonCoordinatesJson,
    this.geofenceMonitoringMode,
  });

  factory TripStartResponseModel.fromJson(Map<String, dynamic> json) =>
      TripStartResponseModel(
        id: json["id"],
        vehicleId: json["vehicleId"],
        vehicleRegistrationNumber: json["vehicleRegistrationNumber"],
        driverId: json["driverId"],
        driverName: json["driverName"],
        deviceTabletId: json["deviceTabletId"],
        startedAt: json["startedAt"] == null
            ? null
            : DateTime.parse(json["startedAt"]),
        endedAt: json["endedAt"],
        startLatitude: json["startLatitude"]?.toDouble(),
        startLongitude: json["startLongitude"]?.toDouble(),
        endLatitude: json["endLatitude"],
        endLongitude: json["endLongitude"],
        distanceKm: json["distanceKm"],
        status: json["status"],
        createdAt: json["createdAt"] == null
            ? null
            : DateTime.parse(json["createdAt"]),
        geofenceCenterLatitude: json["geofenceCenterLatitude"]?.toDouble(),
        geofenceCenterLongitude: json["geofenceCenterLongitude"]?.toDouble(),
        geofenceRadiusMeters: json["geofenceRadiusMeters"],
        geofenceId: json["geofenceId"],
        geofenceName: json["geofenceName"],
        geofenceLocationLabel: json["geofenceLocationLabel"],
        geofenceBoundaryType: json["geofenceBoundaryType"],
        geofencePolygonCoordinatesJson: json["geofencePolygonCoordinatesJson"],
        geofenceMonitoringMode: json["geofenceMonitoringMode"],
      );

  Map<String, dynamic> toJson() => {
    "id": id,
    "vehicleId": vehicleId,
    "vehicleRegistrationNumber": vehicleRegistrationNumber,
    "driverId": driverId,
    "driverName": driverName,
    "deviceTabletId": deviceTabletId,
    "startedAt": startedAt?.toIso8601String(),
    "endedAt": endedAt,
    "startLatitude": startLatitude,
    "startLongitude": startLongitude,
    "endLatitude": endLatitude,
    "endLongitude": endLongitude,
    "distanceKm": distanceKm,
    "status": status,
    "createdAt": createdAt?.toIso8601String(),
    "geofenceCenterLatitude": geofenceCenterLatitude,
    "geofenceCenterLongitude": geofenceCenterLongitude,
    "geofenceRadiusMeters": geofenceRadiusMeters,
    "geofenceId": geofenceId,
    "geofenceName": geofenceName,
    "geofenceLocationLabel": geofenceLocationLabel,
    "geofenceBoundaryType": geofenceBoundaryType,
    "geofencePolygonCoordinatesJson": geofencePolygonCoordinatesJson,
    "geofenceMonitoringMode": geofenceMonitoringMode,
  };
}
