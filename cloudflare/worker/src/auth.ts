export interface FirebaseClaims {
  sub: string;
  aud: string;
  iss: string;
  exp: number;
  iat?: number;
}

interface JwkSet { keys: JsonWebKey[] }

let cachedKeys: { expiresAt: number; keys: JsonWebKey[] } | undefined;

function decodePart(value: string): Record<string, unknown> {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  const bytes = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes));
}

async function firebaseKeys(): Promise<JsonWebKey[]> {
  const now = Date.now();
  if (cachedKeys && cachedKeys.expiresAt > now) return cachedKeys.keys;
  const response = await fetch(
    "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com",
  );
  if (!response.ok) throw new Error("Firebase signing keys unavailable");
  const payload = await response.json<JwkSet>();
  const maxAge = /max-age=(\d+)/.exec(response.headers.get("cache-control") ?? "")?.[1];
  cachedKeys = {
    keys: payload.keys,
    expiresAt: now + Math.min(Number(maxAge ?? 300), 3600) * 1000,
  };
  return payload.keys;
}

export async function verifyFirebaseToken(
  token: string,
  projectId: string,
): Promise<FirebaseClaims> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("Malformed Firebase token");
  const header = decodePart(parts[0]);
  const claims = decodePart(parts[1]) as unknown as FirebaseClaims;
  if (header.alg !== "RS256" || typeof header.kid !== "string") {
    throw new Error("Unsupported Firebase token");
  }
  const key = (await firebaseKeys()).find(
    (candidate) => (candidate as JsonWebKey & { kid?: string }).kid === header.kid,
  );
  if (!key) throw new Error("Unknown Firebase signing key");
  const cryptoKey = await crypto.subtle.importKey(
    "jwk",
    key,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const signature = Uint8Array.from(
    atob(parts[2].replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(parts[2].length / 4) * 4, "=")),
    (char) => char.charCodeAt(0),
  );
  const verified = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    signature,
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  const now = Math.floor(Date.now() / 1000);
  if (!verified || claims.aud !== projectId ||
      claims.iss !== `https://securetoken.google.com/${projectId}` ||
      typeof claims.sub !== "string" || claims.sub.length === 0 ||
      claims.exp <= now || (claims.iat ?? now) > now + 60) {
    throw new Error("Invalid Firebase token");
  }
  return claims;
}

export async function tenantId(uid: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(uid));
  return [...new Uint8Array(signature)]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}
