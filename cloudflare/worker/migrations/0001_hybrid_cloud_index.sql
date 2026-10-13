PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS devices (
  tenant_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  last_seen_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, device_id)
);

CREATE TABLE IF NOT EXISTS documents (
  tenant_id TEXT NOT NULL,
  document_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  title TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  file_hash TEXT NOT NULL,
  file_size INTEGER NOT NULL,
  modified_seconds INTEGER NOT NULL,
  revision TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, document_id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES devices(tenant_id, device_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS chunks (
  tenant_id TEXT NOT NULL,
  document_id TEXT NOT NULL,
  chunk_id TEXT NOT NULL,
  page_number INTEGER NOT NULL DEFAULT 0,
  revision TEXT NOT NULL,
  vector_id TEXT NOT NULL,
  storage_key TEXT NOT NULL,
  PRIMARY KEY (tenant_id, document_id, chunk_id),
  FOREIGN KEY (tenant_id, document_id) REFERENCES documents(tenant_id, document_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS entities (
  tenant_id TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  label TEXT NOT NULL,
  kind TEXT NOT NULL,
  PRIMARY KEY (tenant_id, entity_id)
);

CREATE TABLE IF NOT EXISTS relations (
  tenant_id TEXT NOT NULL,
  relation_id TEXT NOT NULL,
  source_entity_id TEXT NOT NULL,
  target_entity_id TEXT NOT NULL,
  relation_type TEXT NOT NULL,
  document_id TEXT,
  PRIMARY KEY (tenant_id, relation_id)
);

CREATE TABLE IF NOT EXISTS sync_manifests (
  tenant_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  document_id TEXT NOT NULL,
  revision TEXT NOT NULL,
  synced_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, device_id, document_id)
);

CREATE TABLE IF NOT EXISTS usage_events (
  tenant_id TEXT NOT NULL,
  minute_bucket INTEGER NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (tenant_id, minute_bucket)
);

CREATE INDEX IF NOT EXISTS documents_tenant_updated
  ON documents(tenant_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS chunks_tenant_document
  ON chunks(tenant_id, document_id);
