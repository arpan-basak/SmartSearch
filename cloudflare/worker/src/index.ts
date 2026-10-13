import { tenantId, verifyFirebaseToken, type FirebaseClaims } from "./auth";

export interface Env {
  DB: D1Database;
  OBJECTS: R2Bucket;
  INDEX: VectorizeIndex;
  FIREBASE_PROJECT_ID: string;
  TENANT_HMAC_SECRET: string;
  EMBEDDING_DIMENSIONS: string;
  MAX_REQUEST_BYTES?: string;
  RATE_LIMIT_PER_MINUTE?: string;
  APP_CHECK_REQUIRED?: string;
}

interface Services {
  verifyToken(token: string, projectId: string): Promise<FirebaseClaims>;
}

const defaultServices: Services = { verifyToken: verifyFirebaseToken };
const jsonHeaders = { "content-type": "application/json; charset=utf-8" };

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: jsonHeaders });
}

function isOpaqueId(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
}

function safeString(value: unknown, max: number): string | null {
  return typeof value === "string" && value.length <= max ? value : null;
}

async function body(request: Request, env: Env): Promise<Record<string, unknown>> {
  const maximum = Number(env.MAX_REQUEST_BYTES ?? 1_048_576);
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (declared > maximum) throw new Response("Request too large", { status: 413 });
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > maximum) throw new Response("Request too large", { status: 413 });
  try {
    const value = JSON.parse(new TextDecoder().decode(bytes));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value;
  } catch {
    throw new Response("Invalid JSON", { status: 400 });
  }
}

async function authenticate(
  request: Request,
  env: Env,
  services: Services,
): Promise<string> {
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) throw new Response("Unauthorized", { status: 401 });
  if (env.APP_CHECK_REQUIRED === "true" && !request.headers.get("x-firebase-appcheck")) {
    throw new Response("App Check required", { status: 401 });
  }
  const claims = await services.verifyToken(authorization.slice(7), env.FIREBASE_PROJECT_ID);
  return tenantId(claims.sub, env.TENANT_HMAC_SECRET);
}

async function rateLimit(env: Env, tenant: string): Promise<void> {
  const minute = Math.floor(Date.now() / 60_000);
  await env.DB.prepare(
    `INSERT INTO usage_events(tenant_id,minute_bucket,request_count) VALUES(?,?,1)
     ON CONFLICT(tenant_id,minute_bucket) DO UPDATE SET request_count=request_count+1`,
  ).bind(tenant, minute).run();
  const row = await env.DB.prepare(
    "SELECT request_count FROM usage_events WHERE tenant_id=? AND minute_bucket=?",
  ).bind(tenant, minute).first<{ request_count: number }>();
  if ((row?.request_count ?? 0) > Number(env.RATE_LIMIT_PER_MINUTE ?? 60)) {
    throw new Response("Rate limit exceeded", { status: 429 });
  }
}

function decodeEmbedding(value: unknown, dimensions: number): number[] | null {
  if (Array.isArray(value)) {
    if (value.length !== dimensions || value.some((item) => typeof item !== "number" || !Number.isFinite(item))) return null;
    return value.map(Number);
  }
  if (typeof value !== "string" || value.length > dimensions * 4) return null;
  try {
    const bytes = Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
    if (bytes.length !== dimensions) return null;
    return [...bytes].map((item) => (item > 127 ? item - 256 : item) / 127);
  } catch {
    return null;
  }
}

async function deleteDocument(env: Env, tenant: string, documentId: string): Promise<void> {
  const rows = await env.DB.prepare(
    "SELECT vector_id,storage_key FROM chunks WHERE tenant_id=? AND document_id=?",
  ).bind(tenant, documentId).all<{ vector_id: string; storage_key: string }>();
  const records = rows.results ?? [];
  if (records.length) {
    await env.INDEX.deleteByIds(records.map((row) => row.vector_id));
    await Promise.all(records.map((row) => env.OBJECTS.delete(row.storage_key)));
  }
  await env.DB.batch([
    env.DB.prepare("DELETE FROM relations WHERE tenant_id=? AND document_id=?").bind(tenant, documentId),
    env.DB.prepare("DELETE FROM sync_manifests WHERE tenant_id=? AND document_id=?").bind(tenant, documentId),
    env.DB.prepare("DELETE FROM documents WHERE tenant_id=? AND document_id=?").bind(tenant, documentId),
  ]);
}

async function sync(request: Request, env: Env, tenant: string): Promise<Response> {
  const payload = await body(request, env);
  const device = safeString(payload.deviceId, 128);
  const documents = payload.documents;
  if (!device || !Array.isArray(documents) || documents.length < 1 || documents.length > 10) {
    return json({ error: "Invalid sync request" }, 400);
  }
  const dimensions = Number(env.EMBEDDING_DIMENSIONS);
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO devices(tenant_id,device_id,last_seen_at) VALUES(?,?,?)
     ON CONFLICT(tenant_id,device_id) DO UPDATE SET last_seen_at=excluded.last_seen_at`,
  ).bind(tenant, device, now).run();

  for (const raw of documents) {
    if (!raw || typeof raw !== "object") return json({ error: "Invalid document" }, 400);
    const document = raw as Record<string, unknown>;
    const documentId = document.documentId;
    const revision = document.revision;
    const title = safeString(document.title, 512);
    const mimeType = safeString(document.mimeType, 160);
    const fileHash = safeString(document.fileHash, 256);
    const chunks = document.chunks;
    if (!isOpaqueId(documentId) || !isOpaqueId(revision) || !title || !mimeType ||
        !fileHash || !Array.isArray(chunks) || chunks.length > 100) {
      return json({ error: "Invalid document payload" }, 400);
    }
    const existing = await env.DB.prepare(
      "SELECT revision FROM documents WHERE tenant_id=? AND document_id=?",
    ).bind(tenant, documentId).first<{ revision: string }>();
    if (existing && existing.revision !== revision) {
      await deleteDocument(env, tenant, documentId);
    }
    if (!existing || existing.revision !== revision) {
      await env.DB.prepare(
        `INSERT INTO documents(tenant_id,document_id,device_id,title,mime_type,file_hash,
         file_size,modified_seconds,revision,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)`,
      ).bind(
        tenant, documentId, device, title, mimeType, fileHash,
        Number(document.fileSize ?? 0), Number(document.modifiedSeconds ?? 0), revision, now,
      ).run();
    }

    const vectors: VectorizeVector[] = [];
    const statements: D1PreparedStatement[] = [];
    for (const rawChunk of chunks) {
      if (!rawChunk || typeof rawChunk !== "object") return json({ error: "Invalid chunk" }, 400);
      const chunk = rawChunk as Record<string, unknown>;
      const chunkId = safeString(chunk.chunkId, 96);
      const content = safeString(chunk.content, 150_000);
      const summary = safeString(chunk.summary, 8_000) ?? "";
      const embedding = decodeEmbedding(chunk.embedding, dimensions);
      if (!chunkId || content === null || !embedding) return json({ error: "Invalid embedding or chunk" }, 400);
      const vectorId = `${tenant.slice(0, 24)}:${documentId}:${chunkId}`;
      const storageKey = `users/${tenant}/documents/${documentId}/revisions/${revision}/chunks/${encodeURIComponent(chunkId)}.json`;
      await env.OBJECTS.put(storageKey, JSON.stringify({ content, summary }), {
        httpMetadata: { contentType: "application/json" },
      });
      const pageNumber = Math.max(0, Number(chunk.pageNumber ?? 0));
      vectors.push({
        id: vectorId,
        values: embedding,
        metadata: { tenant, documentId, chunkId, pageNumber, revision },
      });
      statements.push(env.DB.prepare(
        `INSERT INTO chunks(tenant_id,document_id,chunk_id,page_number,revision,vector_id,storage_key)
         VALUES(?,?,?,?,?,?,?)`,
      ).bind(tenant, documentId, chunkId, pageNumber, revision, vectorId, storageKey));
    }
    if (vectors.length) await env.INDEX.upsert(vectors);
    if (statements.length) await env.DB.batch(statements);
    const entities = Array.isArray(document.entities) ? document.entities : [];
    const relations = Array.isArray(document.relations) ? document.relations : [];
    if (entities.length > 200 || relations.length > 400) {
      return json({ error: "Knowledge graph batch too large" }, 400);
    }
    const graphStatements: D1PreparedStatement[] = [];
    for (const rawEntity of entities) {
      if (!rawEntity || typeof rawEntity !== "object") return json({ error: "Invalid entity" }, 400);
      const entity = rawEntity as Record<string, unknown>;
      if (!isOpaqueId(entity.entityId)) return json({ error: "Invalid entity ID" }, 400);
      const label = safeString(entity.label, 512);
      const kind = safeString(entity.kind, 80);
      if (!label || !kind) return json({ error: "Invalid entity" }, 400);
      graphStatements.push(env.DB.prepare(
        `INSERT INTO entities(tenant_id,entity_id,label,kind) VALUES(?,?,?,?)
         ON CONFLICT(tenant_id,entity_id) DO UPDATE SET label=excluded.label,kind=excluded.kind`,
      ).bind(tenant, entity.entityId, label, kind));
    }
    for (const rawRelation of relations) {
      if (!rawRelation || typeof rawRelation !== "object") return json({ error: "Invalid relation" }, 400);
      const relation = rawRelation as Record<string, unknown>;
      if (!isOpaqueId(relation.relationId) || !isOpaqueId(relation.entityId)) {
        return json({ error: "Invalid relation ID" }, 400);
      }
      const relationType = safeString(relation.relationType, 80);
      if (!relationType) return json({ error: "Invalid relation" }, 400);
      graphStatements.push(env.DB.prepare(
        `INSERT INTO relations(tenant_id,relation_id,source_entity_id,target_entity_id,
         relation_type,document_id) VALUES(?,?,?,?,?,?)
         ON CONFLICT(tenant_id,relation_id) DO UPDATE SET
         relation_type=excluded.relation_type,document_id=excluded.document_id`,
      ).bind(tenant, relation.relationId, documentId, relation.entityId, relationType, documentId));
    }
    if (graphStatements.length) await env.DB.batch(graphStatements);
    if (document.complete === true) {
      await env.DB.prepare(
        `INSERT INTO sync_manifests(tenant_id,device_id,document_id,revision,synced_at)
         VALUES(?,?,?,?,?) ON CONFLICT(tenant_id,device_id,document_id)
         DO UPDATE SET revision=excluded.revision,synced_at=excluded.synced_at`,
      ).bind(tenant, device, documentId, revision, now).run();
    }
  }
  return json({ ok: true });
}

async function search(request: Request, env: Env, tenant: string): Promise<Response> {
  const payload = await body(request, env);
  const embedding = decodeEmbedding(payload.embedding, Number(env.EMBEDDING_DIMENSIONS));
  const limit = Math.min(25, Math.max(1, Number(payload.limit ?? 12)));
  if (!embedding) return json({ error: "Invalid search embedding" }, 400);
  const matches = await env.INDEX.query(embedding, {
    topK: limit,
    returnMetadata: "all",
    filter: { tenant: { $eq: tenant } },
  });
  const results = [];
  for (const match of matches.matches) {
    const documentId = String(match.metadata?.documentId ?? "");
    const chunkId = String(match.metadata?.chunkId ?? "");
    if (!isOpaqueId(documentId) || !chunkId) continue;
    const row = await env.DB.prepare(
      `SELECT d.title,d.mime_type,d.revision,c.page_number,c.storage_key
       FROM documents d JOIN chunks c ON c.tenant_id=d.tenant_id AND c.document_id=d.document_id
       WHERE d.tenant_id=? AND d.document_id=? AND c.chunk_id=?`,
    ).bind(tenant, documentId, chunkId).first<{
      title: string; mime_type: string; revision: string; page_number: number; storage_key: string;
    }>();
    if (!row) continue;
    const object = await env.OBJECTS.get(row.storage_key);
    const stored = object ? await object.json<{ content?: string; summary?: string }>() : {};
    const text = (stored.summary || stored.content || "").replace(/\s+/g, " ").trim();
    results.push({
      documentId,
      title: row.title,
      mimeType: row.mime_type,
      revision: row.revision,
      pageNumber: row.page_number,
      snippet: text.slice(0, 280),
      score: match.score,
    });
  }
  return json({ results });
}

async function deleteAll(env: Env, tenant: string): Promise<Response> {
  const documents = await env.DB.prepare(
    "SELECT document_id FROM documents WHERE tenant_id=?",
  ).bind(tenant).all<{ document_id: string }>();
  for (const row of documents.results ?? []) await deleteDocument(env, tenant, row.document_id);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM entities WHERE tenant_id=?").bind(tenant),
    env.DB.prepare("DELETE FROM relations WHERE tenant_id=?").bind(tenant),
    env.DB.prepare("DELETE FROM sync_manifests WHERE tenant_id=?").bind(tenant),
    env.DB.prepare("DELETE FROM devices WHERE tenant_id=?").bind(tenant),
    env.DB.prepare("DELETE FROM usage_events WHERE tenant_id=?").bind(tenant),
  ]);
  return json({ ok: true });
}

export async function handle(
  request: Request,
  env: Env,
  services: Services = defaultServices,
): Promise<Response> {
  let tenant: string;
  try {
    tenant = await authenticate(request, env, services);
  } catch (error) {
    if (error instanceof Response) {
      return json({ error: await error.text() }, error.status);
    }
    return json({ error: "Unauthorized" }, 401);
  }
  try {
    await rateLimit(env, tenant);
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/v1/index/sync") return sync(request, env, tenant);
    if (request.method === "POST" && url.pathname === "/v1/search") return search(request, env, tenant);
    if (request.method === "POST" && url.pathname === "/v1/index/delete-document") {
      const payload = await body(request, env);
      if (!isOpaqueId(payload.documentId)) return json({ error: "Invalid document ID" }, 400);
      await deleteDocument(env, tenant, payload.documentId);
      return json({ ok: true });
    }
    if (request.method === "GET" && url.pathname === "/v1/index/status") {
      const row = await env.DB.prepare(
        "SELECT COUNT(*) AS count,MAX(updated_at) AS lastSync FROM documents WHERE tenant_id=?",
      ).bind(tenant).first<{ count: number; lastSync: number | null }>();
      return json({ documentCount: row?.count ?? 0, lastSuccessfulSync: row?.lastSync ?? null });
    }
    if (request.method === "DELETE" && url.pathname === "/v1/index") return deleteAll(env, tenant);
    return json({ error: "Not found" }, 404);
  } catch (error) {
    if (error instanceof Response) {
      return json({ error: await error.text() }, error.status);
    }
    return json({ error: "Cloud index request failed" }, 500);
  }
}

export default {
  fetch(request: Request, env: Env) {
    return handle(request, env);
  },
} satisfies ExportedHandler<Env>;
