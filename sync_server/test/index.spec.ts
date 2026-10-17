import { exports } from 'cloudflare:workers';
import { beforeEach, describe, expect, it } from 'vitest';

const TOKEN = 'test-token';

// `wrangler types` would declare this; the Worker's default export is a fetch handler.
const worker = (exports as unknown as { default: Fetcher }).default;

interface Record {
  kind: string;
  key: string;
  value: string | null;
  updatedAt: string;
  device: string;
  deleted: boolean;
  seq?: number;
}

interface Page {
  records: Record[];
  next: number;
  more: boolean;
}

function call(path: string, init: RequestInit = {}, token = TOKEN): Promise<Response> {
  return worker.fetch(
    new Request(`https://sync.example.test${path}`, {
      ...init,
      headers: { Authorization: `Bearer ${token}`, ...(init.headers ?? {}) },
    }),
  );
}

async function push(records: Record[]): Promise<number> {
  const response = await call('/v1/push', { method: 'POST', body: JSON.stringify(records) });
  expect(response.status).toBe(200);
  return ((await response.json()) as { written: number }).written;
}

async function pull(since: number, device: string, limit = 500): Promise<Page> {
  const response = await call(`/v1/pull?since=${since}&device=${device}&limit=${limit}`);
  expect(response.status).toBe(200);
  return (await response.json()) as Page;
}

async function currentSeq(): Promise<number> {
  return ((await (await call('/v1/info')).json()) as { seq: number }).seq;
}

// The tests share one database; each writes records of its own kind and
// pulls from the seq it started at.
let kindCount = 0;
let kind = '';

function record(key: string, updatedAt: string, device: string, value: string | null = `v-${key}`): Record {
  return { kind, key, value, updatedAt, device, deleted: value === null };
}

const T1 = '2026-10-11T01:00:00.000000Z';
const T2 = '2026-10-11T02:00:00.000000Z';

describe('sync server', () => {
  let start = 0;
  beforeEach(async () => {
    kind = `kind${++kindCount}`;
    start = await currentSeq();
  });

  it('refuses a request without the token', async () => {
    expect((await call('/v1/info', {}, 'wrong')).status).toBe(401);
    expect((await worker.fetch(new Request('https://sync.example.test/v1/info'))).status).toBe(401);
  });

  it('names its database, the same name on every call', async () => {
    const first = (await (await call('/v1/info')).json()) as { protocol: number; database: string; seq: number };
    const second = (await (await call('/v1/info')).json()) as { database: string };
    expect(first.protocol).toBe(1);
    expect(first.database).toMatch(/^[0-9a-f]{32}$/);
    expect(second.database).toBe(first.database);
  });

  it('keeps the newer version of each record, a deletion included', async () => {
    await push([record('a', T2, 'phone'), record('b', T1, 'phone')]);
    // Older for a, newer for b: only b changes; a deletion of b wins over its value.
    const written = await push([record('a', T1, 'desktop', 'stale'), record('b', T2, 'desktop', null)]);
    expect(written).toBe(1);

    const page = await pull(start, 'tablet');
    const byKey = Object.fromEntries(page.records.map((r) => [r.key, r]));
    expect(byKey.a).toMatchObject({ value: 'v-a', updatedAt: T2, device: 'phone', deleted: false });
    expect(byKey.b).toMatchObject({ value: null, updatedAt: T2, device: 'desktop', deleted: true });
  });

  it('settles equal times by device, the same way on every server', async () => {
    await push([record('a', T1, 'b-device', 'from b')]);
    await push([record('a', T1, 'a-device', 'from a')]);
    expect((await pull(start, 'x')).records[0]).toMatchObject({ value: 'from b', device: 'b-device' });
    await push([record('a', T1, 'c-device', 'from c')]);
    expect((await pull(start, 'x')).records[0]).toMatchObject({ value: 'from c', device: 'c-device' });
  });

  it('gives what was written after a cursor, page by page, without the asking device\'s own records', async () => {
    const records: Record[] = [];
    for (let i = 0; i < 7; i++) {
      records.push(record(`k${i}`, T1, i % 2 === 0 ? 'phone' : 'desktop'));
    }
    await push(records);

    // The desktop sees the phone's four records, two per page.
    const first = await pull(start, 'desktop', 2);
    expect(first.records.map((r) => r.key)).toEqual(['k0', 'k2']);
    expect(first.more).toBe(true);
    const second = await pull(first.next, 'desktop', 2);
    expect(second.records.map((r) => r.key)).toEqual(['k4', 'k6']);
    const third = await pull(second.next, 'desktop', 2);
    expect(third.records).toEqual([]);
    expect(third.more).toBe(false);

    // A later change is all the next pull brings.
    await push([record('k0', T2, 'phone', 'again')]);
    const later = await pull(third.next, 'desktop');
    expect(later.records.map((r) => [r.key, r.value])).toEqual([['k0', 'again']]);
    expect((await pull(later.next, 'desktop')).records).toEqual([]);
  });

  it('turns away a body that is not an array of records', async () => {
    expect((await call('/v1/push', { method: 'POST', body: '{"kind":"x"}' })).status).toBe(400);
    expect((await call('/v1/push', { method: 'POST', body: '[{"kind":"x"}]' })).status).toBe(400);
  });

  it('takes a large push in one statement', async () => {
    const records: Record[] = [];
    for (let i = 0; i < 300; i++) {
      records.push({ kind, key: `${i}`, value: 'x'.repeat(3000), updatedAt: T1, device: 'phone', deleted: false });
    }
    expect(await push(records)).toBe(300);
    const page = await pull(start, 'desktop', 500);
    expect(page.records).toHaveLength(300);
    expect(new Set(page.records.map((r) => r.seq)).size).toBe(300);
  });
});
