import 'package:flutter/material.dart';

enum ResultKind { action, app, document, web }

enum DocumentAvailability { onDevice, cloudIndex, availableOffline }

/// A displayable destination shared by search, actions, and local history.
class SearchResult {
  final ResultKind kind;
  final String title;
  final String subtitle;
  final IconData icon;
  final String? packageName;
  final String? path;
  final Uri? url;
  final String? webSearchQuery;
  final String? iconBase64;
  final String? previewBase64;
  final String? mimeType;
  final int usageCount;
  final DateTime? timestamp;
  final String? contactName;
  final String? contactPhone;
  final String? contactPhrase;
  final double? contactConfidence;
  final bool recommendedContact;
  final List<SearchResult> contactActions;
  final double relevance;
  final String? documentId;
  final DocumentAvailability? documentAvailability;
  final int? pageNumber;
  final bool localOriginalAvailable;
  final int? expectedFileSize;
  final int? expectedModifiedSeconds;

  const SearchResult({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.packageName,
    this.path,
    this.url,
    this.webSearchQuery,
    this.iconBase64,
    this.previewBase64,
    this.mimeType,
    this.usageCount = 0,
    this.timestamp,
    this.contactName,
    this.contactPhone,
    this.contactPhrase,
    this.contactConfidence,
    this.recommendedContact = false,
    this.contactActions = const [],
    this.relevance = 0,
    this.documentId,
    this.documentAvailability,
    this.pageNumber,
    this.localOriginalAvailable = true,
    this.expectedFileSize,
    this.expectedModifiedSeconds,
  });

  SearchResult withPreview(String preview) => SearchResult(
        kind: kind,
        title: title,
        subtitle: subtitle,
        icon: icon,
        packageName: packageName,
        path: path,
        url: url,
        webSearchQuery: webSearchQuery,
        iconBase64: iconBase64,
        previewBase64: preview,
        mimeType: mimeType,
        usageCount: usageCount,
        timestamp: timestamp,
        contactName: contactName,
        contactPhone: contactPhone,
        contactPhrase: contactPhrase,
        contactConfidence: contactConfidence,
        recommendedContact: recommendedContact,
        contactActions: contactActions,
        relevance: relevance,
        documentId: documentId,
        documentAvailability: documentAvailability,
        pageNumber: pageNumber,
        localOriginalAvailable: localOriginalAvailable,
        expectedFileSize: expectedFileSize,
        expectedModifiedSeconds: expectedModifiedSeconds,
      );
}
