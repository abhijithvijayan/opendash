// OpenDash's anonymous usage counts. The app sends one small ping at most
// once a week (see the README's Privacy section); this stores it without
// the sender's address and answers aggregate counts to the maintainer.
//
// Nothing here can prove a ping came from a real scooter: the app is open
// source, so anything it holds can be copied. What it does instead is make
// faking many pings cost real work, and make fakes easy to see:
// - each ping carries a proof of work over its own text (BITS zero bits of
//   SHA-256), and each proof is taken once;
// - a ping must be for this week, so they cannot be made in advance;
// - one address may send only a few a minute (Cloudflare's rate limiter,
//   which keys on the address in memory and keeps nothing);
// - the stats count apart versions that were never released, and flag a
//   week far above the ones before it.

const BITS = 22;
const REPO = 'abhijithvijayan/opendash';
const WEEK = /^\d{4}-W\d{2}$/;
const TEXT = /^[\w .()+-]{0,40}$/;

// The head unit's hardware and firmware (OpenDash 0.3.5 on): the same on
// every unit of one model and firmware. Optional, '' when not sent.
export const HARDWARE = ['screen', 'density', 'density_default', 'maker', 'device', 'board', 'soc', 'abi', 'ram_gb', 'fw', 'patch'];
const DAY = 86400000;

const LONG = /^[\w .()+-]{0,80}$/;

function text(v, pattern = TEXT) {
  return typeof v === 'string' && pattern.test(v) ? v : null;
}

// ISO 8601 week of the UTC date of [ms], as 2026-W48.
export function isoWeek(ms) {
  const d = new Date(ms);
  const day = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
  const thursday = new Date(day + (4 - (new Date(day).getUTCDay() || 7)) * DAY);
  const year = thursday.getUTCFullYear();
  const week = Math.floor((thursday - Date.UTC(year, 0, 1)) / DAY / 7) + 1;
  return `${year}-W${String(week).padStart(2, '0')}`;
}

// The weeks a ping sent now may name: a scooter's local date can be a day
// either side of UTC, and a ping held back can arrive a few days late.
function weeksNow(now) {
  return new Set([now - 3 * DAY, now - DAY, now, now + DAY].map(isoWeek));
}

export function leadingZeroBits(bytes) {
  let bits = 0;
  for (const b of bytes) {
    if (b === 0) {
      bits += 8;
      continue;
    }
    return bits + Math.clz32(b) - 24;
  }
  return bits;
}

async function proof(ping, n) {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${ping}:${n}`)));
  return { bits: leadingZeroBits(digest), hex: [...digest].map((b) => b.toString(16).padStart(2, '0')).join('') };
}

export async function check(raw, now) {
  let outer, b;
  try {
    outer = JSON.parse(raw);
    b = JSON.parse(outer.ping);
  } catch {
    return null;
  }
  if (typeof outer.ping !== 'string' || !Number.isSafeInteger(outer.n) || outer.n < 0) return null;
  const row = {
    week: typeof b.week === 'string' && WEEK.test(b.week) && weeksNow(now).has(b.week) ? b.week : null,
    new: b.new === true ? 1 : 0,
    app: text(b.app),
    build: Number.isInteger(b.build) && b.build >= 0 && b.build < 1e7 ? b.build : null,
    gen: text(b.gen),
    model: text(b.model),
    moveos: text(b.moveos),
    stock: text(b.stock),
    // Optional: apps before it was added don't send it.
    android: b.android === undefined ? '' : text(b.android),
    // The firmware build name runs long; the end is the most specific part.
    ...Object.fromEntries(HARDWARE.map((k) => [k, b[k] === undefined ? '' : text(b[k], k === 'fw' ? LONG : TEXT)])),
  };
  // No stock service version: the app ran where there is no stock service,
  // a phone and not a scooter (apps before 0.3.3 sent these).
  if (b.v !== 2 || Object.values(row).some((x) => x === null) || !row.app || !row.stock) return null;
  const p = await proof(outer.ping, outer.n);
  if (p.bits < BITS) return null;
  return { ...row, proof: p.hex };
}

async function ping(request, env) {
  if (Number(request.headers.get('content-length') ?? 0) > 1024) return new Response(null, { status: 413 });
  const address = request.headers.get('cf-connecting-ip') ?? '';
  if (env.PING_LIMIT && !(await env.PING_LIMIT.limit({ key: address })).success) return new Response(null, { status: 429 });
  const row = await check(await request.text(), Date.now());
  if (!row) return new Response(null, { status: 400 });
  const country = text(request.cf?.country ?? '') ?? '';
  // Which deployment took it (the VIA var): the address in released apps
  // changed once, after forks had copied the old one.
  const via = text(env.VIA ?? '') ?? '';
  try {
    const columns = ['week', 'new', 'app', 'build', 'gen', 'model', 'moveos', 'stock', 'android', ...HARDWARE];
    await env.DB.prepare(
      `INSERT INTO pings (${columns.join(', ')}, country, proof, via) VALUES (${columns.map(() => '?').join(', ')}, ?, ?, ?)`,
    )
      .bind(...columns.map((c) => row[c]), country, row.proof, via)
      .run();
  } catch (e) {
    if (String(e).includes('UNIQUE')) return new Response(null, { status: 409 });
    throw e;
  }
  return new Response(null, { status: 204 });
}

// Every version ever released on GitHub, or null when GitHub did not answer.
async function releasedVersions() {
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=100`, {
      headers: { 'User-Agent': 'opendash-usage', Accept: 'application/vnd.github+json' },
    });
    if (!r.ok) return null;
    return [...new Set((await r.json()).map((x) => String(x.tag_name).replace(/^v/, '')))];
  } catch {
    return null;
  }
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  return s.length ? s[Math.floor(s.length / 2)] : 0;
}

async function stats(request, env) {
  if (!env.STATS_TOKEN || request.headers.get('authorization') !== `Bearer ${env.STATS_TOKEN}`) {
    return new Response(null, { status: 404 });
  }
  const all = async (sql, ...args) => (await env.DB.prepare(sql).bind(...args).all()).results;
  const released = await releasedVersions();
  const inReleased = released?.length ? `app IN (${released.map(() => '?').join(',')})` : '0';
  const weeks = await all(
    `SELECT week, COUNT(*) AS users, SUM(new) AS new, SUM(${inReleased}) AS released FROM pings GROUP BY week ORDER BY week DESC LIMIT 27`,
    ...(released ?? []),
  );
  // A week far above the four before it is worth a look before it is believed.
  for (let i = 0; i < weeks.length; i++) {
    const before = weeks.slice(i + 1, i + 5).map((w) => w.users);
    weeks[i].suspect = before.length > 0 && weeks[i].users > 3 * median(before) + 20;
    if (!released) weeks[i].released = null;
  }
  const latest = 'week = (SELECT MAX(week) FROM pings)';
  return Response.json({
    installs: (await all('SELECT COUNT(*) AS n FROM pings WHERE new = 1'))[0].n,
    releasedVersions: released,
    weekly: weeks.slice(0, 26),
    latestWeek: {
      versions: await all(`SELECT app, COUNT(*) AS n FROM pings WHERE ${latest} GROUP BY app ORDER BY n DESC`),
      scooters: await all(
        `SELECT gen, model, moveos, stock, android, COUNT(*) AS n FROM pings WHERE ${latest} GROUP BY gen, model, moveos, stock, android ORDER BY n DESC`,
      ),
      countries: await all(`SELECT country, COUNT(*) AS n FROM pings WHERE ${latest} GROUP BY country ORDER BY n DESC`),
      // legacy: the address in apps before 0.3.4, which forks copied.
      via: await all(`SELECT via, COUNT(*) AS n FROM pings WHERE ${latest} GROUP BY via ORDER BY n DESC`),
      hardware: await all(
        `SELECT gen, ${HARDWARE.join(', ')}, COUNT(*) AS n FROM pings WHERE ${latest} GROUP BY gen, ${HARDWARE.join(', ')} ORDER BY n DESC`,
      ),
    },
  });
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (request.method === 'POST' && pathname === '/v1/ping') return ping(request, env);
    if (request.method === 'GET' && pathname === '/v1/stats') return stats(request, env);
    return new Response(null, { status: 404 });
  },
};
