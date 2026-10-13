import { describe, expect, it } from "vitest";
import { tenantId } from "../src/auth";
import { handle, type Env } from "../src/index";

class FakeStatement {
  values: unknown[] = [];
  constructor(private readonly database: FakeDatabase, readonly sql: string) {}
  bind(...values: unknown[]) { this.values = values; return this; }
  async run() {
    if (this.sql.includes("usage_events")) {
      const key = `${this.values[0]}:${this.values[1]}`;
      this.database.usage.set(key, (this.database.usage.get(key) ?? 0) + 1);
    }
    if (this.sql.startsWith("DELETE FROM documents")) {
      this.database.deleted.push([String(this.values[0]), String(this.values[1])]);
    }
    return { success: true };
  }
  async first<T>(): Promise<T | null> {
    if (this.sql.includes("request_count FROM usage_events")) {
      const key = `${this.values[0]}:${this.values[1]}`;
      return { request_count: this.database.usage.get(key) ?? 0 } as T;
    }
    if (this.sql.includes("COUNT(*) AS count")) return { count: 0, lastSync: null } as T;
    if (this.sql.includes("FROM documents d JOIN chunks")) {
      const [tenant, document] = this.values.map(String);
      if (tenant === this.database.ownerTenant && document === this.database.ownerDocument) {
        return {
          title: "Private B document",
          mime_type: "application/pdf",
          revision: "b".repeat(64),
          page_number: 1,
          storage_key: "private-b",
        } as T;
      }
      return null;
    }
    return null;
  }
  async all<T>() {
    if (this.sql.includes("SELECT vector_id,storage_key")) return { results: [] as T[] };
    if (this.sql.includes("SELECT document_id FROM documents")) return { results: [] as T[] };
    return { results: [] as T[] };
  }
}

class FakeDatabase {
  usage = new Map<string, number>();
  deleted: Array<[string, string]> = [];
  ownerTenant = "";
  ownerDocument = "b".repeat(64);
  prepare(sql: string) { return new FakeStatement(this, sql); }
  async batch(statements: FakeStatement[]) {
    await Promise.all(statements.map((statement) => statement.run()));
    return [];
  }
}

async function environment(limit = 60) {
  const database = new FakeDatabase();
  const ownerTenant = await tenantId("user-b", "test-secret");
  database.ownerTenant = ownerTenant;
  const env = {
    DB: database,
    OBJECTS: {
      get: async () => ({ json: async () => ({ content: "secret B text" }) }),
      delete: async () => undefined,
      put: async () => undefined,
    },
    INDEX: {
      query: async () => ({ matches: [{
        id: "b-vector",
        score: 0.99,
        metadata: { documentId: database.ownerDocument, chunkId: "0" },
      }] }),
      deleteByIds: async () => undefined,
      upsert: async () => undefined,
    },
    FIREBASE_PROJECT_ID: "project",
    TENANT_HMAC_SECRET: "test-secret",
    EMBEDDING_DIMENSIONS: "2",
    RATE_LIMIT_PER_MINUTE: String(limit),
  } as unknown as Env;
  return { env, database };
}

function request(path: string, method = "GET", body?: unknown) {
  return new Request(`https://worker.test${path}`, {
    method,
    headers: { authorization: "Bearer token", "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

const verifier = (uid: string) => ({
  verifyToken: async () => ({
    sub: uid,
    aud: "project",
    iss: "https://securetoken.google.com/project",
    exp: Math.floor(Date.now() / 1000) + 600,
  }),
});

describe("Apex cloud index isolation", () => {
  it("rejects invalid Firebase tokens", async () => {
    const { env } = await environment();
    const response = await handle(request("/v1/index/status"), env, {
      verifyToken: async () => { throw new Error("invalid"); },
    });
    expect(response.status).toBe(401);
  });

  it("does not return User B data to User A even if Vectorize returns it", async () => {
    const { env } = await environment();
    const response = await handle(
      request("/v1/search", "POST", { embedding: [0.1, 0.2] }),
      env,
      verifier("user-a"),
    );
    expect(response.status).toBe(200);
    expect((await response.json() as { results: unknown[] }).results).toEqual([]);
  });

  it("scopes deletion so User A cannot delete User B records", async () => {
    const { env, database } = await environment();
    const response = await handle(
      request("/v1/index/delete-document", "POST", { documentId: database.ownerDocument }),
      env,
      verifier("user-a"),
    );
    expect(response.status).toBe(200);
    const userATenant = await tenantId("user-a", "test-secret");
    expect(database.deleted).toContainEqual([userATenant, database.ownerDocument]);
    expect(database.deleted).not.toContainEqual([database.ownerTenant, database.ownerDocument]);
  });

  it("validates malformed requests", async () => {
    const { env } = await environment();
    const response = await handle(
      request("/v1/search", "POST", { embedding: [0.1] }),
      env,
      verifier("user-a"),
    );
    expect(response.status).toBe(400);
  });

  it("rate limits repeated requests per verified tenant", async () => {
    const { env } = await environment(1);
    expect((await handle(request("/v1/index/status"), env, verifier("user-a"))).status).toBe(200);
    expect((await handle(request("/v1/index/status"), env, verifier("user-a"))).status).toBe(429);
  });
});
