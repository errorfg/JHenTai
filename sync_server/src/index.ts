/**
 * Record sync server, protocol 1.
 *
 * Every synced item is one record (kind, key, value, updatedAt, device,
 * deleted). For each (kind, key) the version with the larger
 * (updatedAt, device) wins; a deletion is a record with deleted = true and is
 * compared the same way. Each write that wins gets a new, increasing seq, and
 * clients pull what was written after the seq they got last.
 *
 * Limits of D1 on the free plan shape the queries: 50 queries per request,
 * 100 bound parameters per query, 2 MB per string, 10 ms of Worker CPU. So a
 * push hands the whole request body to SQLite as one parameter and json_each
 * expands it inside one upsert, and a pull has SQLite build the JSON array of
 * records; the Worker parses no records itself.
 */

export interface Env {
  DB: D1Database;
  SYNC_TOKEN?: string;
}

const PROTOCOL = 1;
const MAX_PULL = 500;

/** Run before every operation, in the same batch: a fresh database needs no setup. */
const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS records (
     kind TEXT NOT NULL,
     key TEXT NOT NULL,
     value TEXT,
     updated_at TEXT NOT NULL,
     device TEXT NOT NULL,
     deleted INTEGER NOT NULL DEFAULT 0,
     seq INTEGER NOT NULL,
     PRIMARY KEY (kind, key)
   )`,
  `CREATE INDEX IF NOT EXISTS records_seq ON records (seq)`,
  `CREATE TABLE IF NOT EXISTS meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  `INSERT OR IGNORE INTO meta (name, value) VALUES ('database', lower(hex(randomblob(16))))`,
];

/**
 * The scalar subquery is not correlated, so every row of one push gets
 * max(seq) + its position + 1. Writes to D1 are serial, so seq order is commit
 * order and a client pulling by seq never skips a row committed later.
 */
const PUSH = `
INSERT INTO records (kind, key, value, updated_at, device, deleted, seq)
SELECT json_extract(j.value, '$.kind'),
       json_extract(j.value, '$.key'),
       json_extract(j.value, '$.value'),
       json_extract(j.value, '$.updatedAt'),
       json_extract(j.value, '$.device'),
       CASE WHEN json_extract(j.value, '$.deleted') THEN 1 ELSE 0 END,
       (SELECT coalesce(max(seq), 0) FROM records) + j.key + 1
FROM json_each(?1) AS j
WHERE true
ON CONFLICT (kind, key) DO UPDATE SET
  value = excluded.value,
  updated_at = excluded.updated_at,
  device = excluded.device,
  deleted = excluded.deleted,
  seq = excluded.seq
WHERE excluded.updated_at > records.updated_at
   OR (excluded.updated_at = records.updated_at AND excluded.device > records.device)`;

const PULL = `
SELECT json_group_array(json_object(
         'kind', kind,
         'key', key,
         'value', value,
         'updatedAt', updated_at,
         'device', device,
         'deleted', json(CASE deleted WHEN 1 THEN 'true' ELSE 'false' END),
         'seq', seq)) AS records,
       count(*) AS n,
       max(seq) AS last
FROM (SELECT * FROM records WHERE seq > ?1 AND device <> ?2 ORDER BY seq LIMIT ?3)`;

const MAX_SEQ = `SELECT coalesce(max(seq), 0) AS seq FROM records`;

const DATABASE = `SELECT value FROM meta WHERE name = 'database'`;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (!env.SYNC_TOKEN) {
      return error(500, 'SYNC_TOKEN is not set for this Worker');
    }
    if (!authorized(request.headers.get('Authorization'), env.SYNC_TOKEN)) {
      return error(401, 'Unauthorized');
    }

    const url = new URL(request.url);
    try {
      if (request.method === 'GET' && url.pathname === '/v1/info') {
        return await info(env.DB);
      }
      if (request.method === 'POST' && url.pathname === '/v1/push') {
        return await push(env.DB, await request.text());
      }
      if (request.method === 'GET' && url.pathname === '/v1/pull') {
        return await pull(env.DB, url.searchParams);
      }
      return error(404, 'Not found');
    } catch (e) {
      return error(400, e instanceof Error ? e.message : String(e));
    }
  },
};

async function info(db: D1Database): Promise<Response> {
  const results = await run(db, [db.prepare(DATABASE), db.prepare(MAX_SEQ)]);
  const database = (results[0].results[0] as { value: string }).value;
  const seq = (results[1].results[0] as { seq: number }).seq;
  return json(`{"protocol":${PROTOCOL},"database":${JSON.stringify(database)},"seq":${seq}}`);
}

async function push(db: D1Database, body: string): Promise<Response> {
  if (!body.trimStart().startsWith('[')) {
    return error(400, 'The body must be a JSON array of records');
  }
  const results = await run(db, [db.prepare(PUSH).bind(body)]);
  return json(`{"written":${results[0].meta.changes ?? 0}}`);
}

async function pull(db: D1Database, params: URLSearchParams): Promise<Response> {
  const since = Number(params.get('since') ?? '0');
  const device = params.get('device') ?? '';
  const limit = Math.min(Number(params.get('limit') ?? `${MAX_PULL}`), MAX_PULL);
  if (!Number.isInteger(since) || since < 0 || !Number.isInteger(limit) || limit <= 0) {
    return error(400, 'since and limit must be non-negative integers');
  }

  // One batch is one transaction: the page and the maximum come from the
  // same state, so a short page can move the cursor to the maximum safely.
  const results = await run(db, [db.prepare(PULL).bind(since, device, limit), db.prepare(MAX_SEQ)]);
  const page = results[0].results[0] as { records: string; n: number; last: number | null };
  const max = (results[1].results[0] as { seq: number }).seq;
  const more = page.n === limit;
  const next = more ? page.last! : Math.max(max, since);
  return json(`{"records":${page.records},"next":${next},"more":${more}}`);
}

/** Results of [statements], run after the schema statements in one batch. */
async function run(db: D1Database, statements: D1PreparedStatement[]): Promise<D1Result[]> {
  const results = await db.batch([...SCHEMA.map((s) => db.prepare(s)), ...statements]);
  return results.slice(SCHEMA.length);
}

function authorized(header: string | null, token: string): boolean {
  if (header === null || !header.startsWith('Bearer ')) {
    return false;
  }
  const given = new TextEncoder().encode(header.slice('Bearer '.length));
  const expected = new TextEncoder().encode(token);
  return given.byteLength === expected.byteLength && crypto.subtle.timingSafeEqual(given, expected);
}

function json(body: string): Response {
  return new Response(body, { headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}

function error(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}
