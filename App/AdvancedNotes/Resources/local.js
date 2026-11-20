/* The phone's own engine: every screen from this device's copy of the notes,
   so Notes works with the laptop off.

   The laptop stays the one place that does the clever work (filing, AI, link
   previews, reading pictures). This file only reads the copy the laptop sent
   (see mnemo/sync.py) and works out what the screens show, using the same
   rules as the laptop:

     to-do lines      mnemo/checklist.py   parse, toggle, reset
     pace, alerts     mnemo/reminders.py   pace, due_now, agenda_items, active_lists
     repeats          mnemo/reminders.py   parse_rule, next_after, period_start, roll_items

   tests/test_local_js.py checks these give the laptop's answers.

   Times are wall-clock local, written "YYYY-MM-DDTHH:MM:SS" with no zone, as
   the laptop writes them. Here such a time is held as a Date in UTC, so
   adding days never trips over summer time; wallNow() turns the real clock
   into one. */
(function (root) {
'use strict';

/* ------------------------------------------------------------- sha1 ---- */
// Reminder keys carry the first 8 hex digits of an item's SHA-1 (as the laptop's).
function sha1(text) {
  const bytes = new TextEncoder().encode(String(text));
  const size = ((bytes.length + 9 + 63) >> 6) << 6;
  const buf = new Uint8Array(size); buf.set(bytes); buf[bytes.length] = 0x80;
  const dv = new DataView(buf.buffer), bits = bytes.length * 8;
  dv.setUint32(size - 4, bits >>> 0); dv.setUint32(size - 8, Math.floor(bits / 4294967296));
  let h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
  const w = new Uint32Array(80);
  for (let off = 0; off < size; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getUint32(off + i * 4);
    for (let i = 16; i < 80; i++) { const x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]; w[i] = (x << 1) | (x >>> 31); }
    let a = h0, b = h1, c = h2, d = h3, e = h4;
    for (let i = 0; i < 80; i++) {
      const f = i < 20 ? (b & c) | (~b & d) : i < 40 ? b ^ c ^ d : i < 60 ? (b & c) | (b & d) | (c & d) : b ^ c ^ d;
      const k = i < 20 ? 0x5A827999 : i < 40 ? 0x6ED9EBA1 : i < 60 ? 0x8F1BBCDC : 0xCA62C1D6;
      const t = (((a << 5) | (a >>> 27)) + f + e + k + w[i]) >>> 0;
      e = d; d = c; c = ((b << 30) | (b >>> 2)) >>> 0; b = a; a = t;
    }
    h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0; h3 = (h3 + d) >>> 0; h4 = (h4 + e) >>> 0;
  }
  return [h0, h1, h2, h3, h4].map((h) => h.toString(16).padStart(8, '0')).join('');
}

/* ------------------------------------------------------------ times ---- */
const pad = (n) => String(n).padStart(2, '0');
function naive(s) {
  const m = String(s || '').match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2}))?)?/);
  return m ? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0))) : null;
}
function stampOf(d) {
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`;
}
const ymdOf = (d) => stampOf(d).slice(0, 10);
function wallNow(now = new Date()) {
  return new Date(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate(), now.getHours(), now.getMinutes(), now.getSeconds()));
}
function dayOf(v) { const m = String(v || '').match(/^\d{4}-\d{2}-\d{2}/); return m ? m[0] : null; }
const dayNum = (ymd) => Date.UTC(+ymd.slice(0, 4), +ymd.slice(5, 7) - 1, +ymd.slice(8, 10)) / 864e5;
const plusDays = (d, n) => new Date(+d + n * 864e5);
const weekday = (d) => (d.getUTCDay() + 6) % 7;          // Monday 0, as Python
const midnight = (d) => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
function clock(ymd, hhmm) {
  const p = String(hhmm || '').split(':').slice(0, 2);
  if (p.length < 2 || !/^\s*[+-]?\d+\s*$/.test(p[0]) || !/^\s*[+-]?\d+\s*$/.test(p[1])) return null;
  const h = parseInt(p[0], 10), mi = parseInt(p[1], 10);
  if (h < 0 || h > 23 || mi < 0 || mi > 59) return null;
  const d = naive(ymd); d.setUTCHours(h, mi, 0, 0); return d;
}

/* ------------------------------------------------- to-do lines ---------- */
// mnemo/checklist.py. "[^\n]" where Python has ".", which matches "\r" there.
const CHECK_RE = /^(\s*)([-*+])\s+\[([ xX])\](?:\s+([^\n]*))?$/;
const HEAD_RE = /^(#{1,3})\s+([^\n]*)$/;
const FENCE_RE = /^\s*```/;
const TOKEN = '\\s*([📅⏰✅🔁])\\uFE0F?\\s*([^📅⏰✅🔁]*)';
const DATE_RE = /^(\d{4}-\d{2}-\d{2})(?:[ T](\d{1,2}):(\d{2}))?/;

function splitTokens(content) {
  content = String(content || '');
  const first = content.search(new RegExp(TOKEN, 'u'));
  const text = first >= 0 ? content.slice(0, first) : content;
  const found = {};
  for (const m of content.matchAll(new RegExp(TOKEN, 'gu'))) {
    const symbol = m[1], value = m[2].trim();
    if (symbol === '🔁') { if (value) found.repeat = value; continue; }
    const d = value.match(DATE_RE);
    if (!d) continue;
    if (symbol === '⏰') found.remind = `${d[1]}T${pad(d[2] ? +d[2] : 9)}:${pad(d[3] ? +d[3] : 0)}:00`;
    else if (symbol === '📅') found.due = d[1];
    else found.done_on = d[1];
  }
  return [text.trim(), found];
}
function tokensText(due, remind, repeat, doneOn) {
  const out = [];
  if (due) out.push(`📅 ${due.slice(0, 10)}`);
  if (remind) out.push(`⏰ ${remind.slice(0, 10)} ${remind.slice(11, 16)}`);
  if (repeat) out.push(`🔁 ${repeat}`);
  if (doneOn) out.push(`✅ ${doneOn.slice(0, 10)}`);
  return out.length ? ' ' + out.join(' ') : '';
}
const formatItem = (it) => (`${it.indent}- [${it.done ? 'x' : ' '}] ${it.text}` + tokensText(it.due, it.remind, it.repeat, it.done_on)).replace(/\s+$/, '');

function parse(body) {
  const sections = [], items = [];
  let inCode = false;
  String(body || '').split('\n').forEach((line, i) => {
    if (FENCE_RE.test(line)) { inCode = !inCode; return; }
    if (inCode) return;
    const m = line.match(CHECK_RE);
    if (m) {
      const [text, tok] = splitTokens(m[4] || '');
      items.push({ line: i, indent: m[1], text, done: m[3] !== ' ', due: tok.due || null, remind: tok.remind || null,
        repeat: tok.repeat || null, done_on: tok.done_on || null, section: sections.length ? sections.length - 1 : null });
      if (sections.length) sections[sections.length - 1].items.push(items.length - 1);
      return;
    }
    const h = line.match(HEAD_RE);
    if (h) { const [title, tok] = splitTokens(h[2]); sections.push({ line: i, level: h[1].length, title, due: tok.due || null, items: [] }); }
  });
  return { sections, items };
}
const countDone = (items) => [items.filter((it) => it.done).length, items.length];
const progress = (body) => countDone(parse(body).items);

function findItem(body, line, text) {
  const items = parse(body).items, want = splitTokens(text || '')[0].trim();
  for (const it of items) if (it.line === line && (!want || it.text === want)) return it;
  const same = items.filter((it) => it.text === want);
  if (same.length === 1) return same[0];
  throw Object.assign(new Error('That item changed. Open the note to see it.'), { status: 409 });
}
function replaceItem(body, it) { const lines = body.split('\n'); lines[it.line] = formatItem(it); return lines.join('\n'); }
function toggle(body, line, text, done, today) {
  const it = findItem(body, line, text);
  it.done = done == null ? !it.done : !!done;
  it.done_on = it.done ? today : null;
  return replaceItem(body, it);
}
function setWhen(body, line, text, w) {
  const it = findItem(body, line, text);
  it.remind = w.remind || null; it.due = w.due || null; it.repeat = w.repeat || null;
  return replaceItem(body, it);
}
function reset(body) {
  const lines = String(body || '').split('\n');
  for (const it of parse(body).items) if (it.done) { it.done = false; it.done_on = null; lines[it.line] = formatItem(it); }
  return lines.join('\n');
}

/* --------------------------------------------------- pace and alerts ---- */
// mnemo/reminders.py
function pace(done, total, due, start, now) {
  const left = Math.max(0, total - done);
  if (total === 0) return { state: 'empty', left: 0 };
  if (left === 0) return { state: 'done', left: 0 };
  const dueDay = dayOf(due);
  if (!dueDay) return { state: 'open', left };
  const today = ymdOf(now);
  const daysLeft = dayNum(dueDay) - dayNum(today) + 1;
  if (daysLeft <= 0) return { state: 'late', left, daysLeft: daysLeft - 1 };
  const perDay = Math.ceil(left / daysLeft);
  const startDay = dayOf(start) || today;
  const span = Math.max(1, dayNum(dueDay) - dayNum(startDay) + 1);
  const elapsed = Math.max(0, dayNum(today) - dayNum(startDay));
  const expected = total * Math.min(1, elapsed / span);
  return { state: done + 1 < expected ? 'behind' : 'on_track', left, daysLeft, perDay };
}
const metaOf = (r) => r.meta || {};
const quiet = (r, today) => { const until = dayOf(metaOf(r).quiet_until); return !!until && today < until; };
// Your order: where you dragged it, else newest first (the laptop sends each note's place).
const byOrder = (rows) => rows.slice().sort((a, b) => (b.pos ?? 0) - (a.pos ?? 0));
const childrenOf = (id, records) => byOrder([...records.values()].filter((r) => metaOf(r).parent === id));

function listFacts(r, records, now) {
  const parsed = parse(r.body);
  let [done, total] = countDone(parsed.items);
  for (const kid of childrenOf(r.id, records)) { const [d, t] = progress(kid.body); done += d; total += t; }
  const next = parsed.items.find((it) => !it.done);
  return { noteId: r.id, title: r.title, done, total, due: r.due ?? null, next: next ? next.text : null,
    checkin: metaOf(r).checkin ?? null, quietUntil: metaOf(r).quiet_until ?? null, pace: pace(done, total, r.due, r.created, now) };
}
function listsOf(records) { return new Map(byOrder([...records.values()].filter((r) => r.kind === 'list')).map((r) => [r.id, r])); }

function dueNow(records, seen, now) {
  const today = ymdOf(now), stamp = stampOf(now), out = [], rows = [...records.values()], lists = listsOf(records);
  rows.filter((r) => r.remindAt && !r.reminded && r.status === 'open' && r.remindAt <= stamp)
    .sort((a, b) => (a.remindAt < b.remindAt ? -1 : a.remindAt > b.remindAt ? 1 : 0))
    .forEach((r) => out.push({ type: 'task', key: `task:${r.id}:${r.remindAt}`, noteId: r.id, title: r.title, when: r.remindAt }));
  for (const r of rows) {
    if (!String(r.body || '').includes('⏰') || r.status === 'archived') continue;
    if (lists.has(r.id) && quiet(lists.get(r.id), today)) continue;
    for (const it of parse(r.body).items) {
      if (it.done || !it.remind || it.remind > stamp) continue;
      const key = `item:${r.id}:${it.remind}:${sha1(it.text).slice(0, 8)}`;
      if (!seen.has(key)) out.push({ type: 'item', key, noteId: r.id, listTitle: r.title, text: it.text, line: it.line, when: it.remind, day: it.due, repeat: it.repeat });
    }
  }
  for (const r of lists.values()) {
    if (r.status === 'archived' || quiet(r, today) || lists.has(metaOf(r).parent)) continue;
    const facts = listFacts(r, records, now);
    if (facts.total === 0 || facts.done === facts.total) continue;
    const due = r.due ? naive(String(r.due).slice(0, 19)) : null;
    if (due && now > due) {
      const key = `deadline-missed:${r.id}:${r.due}`;
      if (!seen.has(key)) out.push({ type: 'deadline', key, late: true, ...facts });
      continue;
    }
    if (metaOf(r).checkin) {
      const at = clock(today, metaOf(r).checkin), key = `checkin:${r.id}:${today}`;
      if (at && now >= at && !seen.has(key)) out.push({ type: 'checkin', key, ...facts });
    } else if (due && dayNum(ymdOf(due)) - dayNum(today) === 1) {
      const key = `deadline-soon:${r.id}:${r.due}`;
      if (now >= clock(today, '09:00') && !seen.has(key)) out.push({ type: 'deadline', key, late: false, ...facts });
    }
  }
  return out;
}

function agendaItems(records, now) {
  const today = ymdOf(now), out = [];
  for (const r of records.values()) {
    const body = String(r.body || '');
    if (!(body.includes('⏰') || body.includes('📅')) || r.status === 'archived') continue;
    for (const it of parse(body).items) {
      if (!(it.remind || it.due) || (it.done && it.done_on !== today)) continue;
      out.push({ noteId: r.id, listTitle: r.title, line: it.line, text: it.text, done: it.done, remind: it.remind, day: it.due, repeat: it.repeat });
    }
  }
  return out;
}

function activeLists(records, now) {
  const today = ymdOf(now), lists = listsOf(records), out = [];
  for (const r of lists.values()) {
    if (r.status === 'archived' || lists.has(metaOf(r).parent) || quiet(r, today)) continue;
    if (!(r.due || metaOf(r).checkin)) continue;
    const facts = listFacts(r, records, now);
    if (facts.total && facts.done < facts.total) out.push(facts);
  }
  return out.sort((a, b) => { const x = a.due || '9999', y = b.due || '9999'; return x < y ? -1 : x > y ? 1 : 0; });
}

/* ---------------------------------------------------------- repeats ---- */
const SIMPLE = { daily: ['day', 1], 'every day': ['day', 1], everyday: ['day', 1], weekdays: ['weekday', 1], 'every weekday': ['weekday', 1],
  weekly: ['week', 1], 'every week': ['week', 1], fortnightly: ['week', 2], monthly: ['month', 1], 'every month': ['month', 1],
  yearly: ['year', 1], 'every year': ['year', 1], annually: ['year', 1] };
function parseRule(text) {
  const t = String(text || '').toLowerCase().split(/\s+/).filter(Boolean).join(' ');
  if (Object.prototype.hasOwnProperty.call(SIMPLE, t)) return SIMPLE[t];
  const m = t.match(/^every (\d{1,2}|other) (day|week|month|year)s?$/);
  if (m) return [m[2], m[1] === 'other' ? 2 : Math.max(1, +m[1])];
  if (/^every (?:mon|tues|wednes|thurs|fri|satur|sun)day$/.test(t)) return ['week', 1];
  return null;
}
function addMonths(when, months) {
  const total = when.getUTCMonth() + months, year = when.getUTCFullYear() + Math.floor(total / 12), month = ((total % 12) + 12) % 12;
  const last = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  return new Date(Date.UTC(year, month, Math.min(when.getUTCDate(), last), when.getUTCHours(), when.getUTCMinutes(), when.getUTCSeconds()));
}
function nextAfter(anchor, rule, after) {
  const [unit, n] = rule;
  let when = anchor, k = 0;
  while (when <= after && k < 10000) {
    k++;
    if (unit === 'weekday') { when = plusDays(when, 1); while (weekday(when) >= 5) when = plusDays(when, 1); }
    else if (unit === 'day' || unit === 'week') when = plusDays(anchor, k * n * (unit === 'week' ? 7 : 1));
    else when = addMonths(anchor, k * n * (unit === 'year' ? 12 : 1));
  }
  return when;
}
function periodStart(rule, now, anchor) {
  const [unit, n] = rule;
  let today = midnight(now);
  if (unit === 'weekday') { while (weekday(today) >= 5) today = plusDays(today, -1); return today; }
  const made = n > 1 && anchor ? naive(String(anchor).replace('Z', '').slice(0, 19)) : null;
  if (made) {
    let start = midnight(made);
    if (unit === 'week') start = plusDays(start, -weekday(start));
    let last = start;
    for (;;) { const nxt = nextAfter(start, rule, last); if (nxt > now) return last; last = nxt; }
  }
  if (unit === 'day') return today;
  if (unit === 'week') return plusDays(today, -weekday(today));
  if (unit === 'month') return new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1));
  return new Date(Date.UTC(today.getUTCFullYear(), 0, 1));
}
const resetKey = (id, rule, now, anchor) => `reset:${id}:${ymdOf(periodStart(rule, now, anchor))}`;

function rollItems(body, today) {
  body = String(body || '');
  const lines = body.split('\n');
  let changed = false;
  for (const it of parse(body).items) {
    const rule = it.done && it.repeat ? parseRule(it.repeat) : null;
    if (!rule) continue;
    const doneDay = dayOf(it.done_on) || today;
    if (it.remind || it.due) {
      const anchor = naive(it.remind || `${it.due}T00:00:00`), doneEnd = naive(`${doneDay}T23:59:00`);
      const nxt = nextAfter(anchor, rule, anchor > doneEnd ? anchor : doneEnd);
      if (today < ymdOf(nxt)) continue;
      const shift = dayNum(ymdOf(nxt)) - dayNum(ymdOf(anchor));
      if (it.remind) it.remind = stampOf(nxt);
      if (it.due) it.due = ymdOf(plusDays(naive(it.due), shift));
    } else {
      const start = naive(`${doneDay}T00:00:00`);
      if (today < ymdOf(nextAfter(start, rule, start))) continue;
    }
    it.done = false; it.done_on = null;
    lines[it.line] = formatItem(it);
    changed = true;
  }
  return changed ? lines.join('\n') : body;
}

// engine.advance_repeats: ticked repeating items come round, repeating lists start over.
function advanceRepeats(records, seen, now) {
  const today = ymdOf(now), changed = new Set(), marked = [];
  for (const r of records.values()) {
    if (!String(r.body || '').includes('🔁') || r.status === 'archived') continue;
    const body = rollItems(r.body, today);
    if (body !== r.body) { r.body = body; changed.add(r.id); }
  }
  for (const r of listsOf(records).values()) {
    const rule = parseRule(metaOf(r).repeat);
    if (!rule || r.status === 'archived') continue;
    const key = resetKey(r.id, rule, now, r.created);
    if (seen.has(key)) continue;
    const body = reset(r.body);
    if (body !== r.body) { r.body = body; changed.add(r.id); }
    seen.add(key); marked.push(key);
  }
  return { changed: [...changed], marked };
}

/* ---------------------------------------------------- what screens see -- */
// mnemo/server.py's _preview, _snippet, _list_info and _note_brief.
const MD_MARKS = /^\s{0,3}(?:#{1,6}|[-*+]|\d+[.)])\s+|\*\*|__|`/gm;
const cut = (s, n) => Array.from(s).slice(0, n).join('');
function preview(body, limit = 6) {
  const out = [];
  let inCode = false;
  for (const [i, line] of String(body || '').split('\n').entries()) {
    if (FENCE_RE.test(line)) { inCode = !inCode; continue; }
    if (inCode || !line.trim()) continue;
    const m = line.match(CHECK_RE), h = m ? null : line.match(HEAD_RE);
    if (m) { const [text, tok] = splitTokens(m[4] || ''); out.push({ t: 'check', line: i, text, done: m[3] !== ' ', remind: tok.remind || null }); }
    else if (h) out.push({ t: 'head', text: splitTokens(h[2])[0] });
    else out.push({ t: 'text', text: cut(line.replace(MD_MARKS, '').trim(), 240) });
    if (out.length >= limit) break;
  }
  return out;
}
const snippet = (body) => cut(String(body || '').replace(MD_MARKS, '').split(/\s+/).filter(Boolean).join(' '), 220);
const BRIEF = ['id', 'title', 'kind', 'status', 'path', 'topic', 'snippet', 'created', 'updated', 'review', 'due', 'remind', 'done', 'media', 'source', 'lines', 'progress'];
// "waiting": made on this device, not yet seen by the laptop.
const briefOf = (r) => { const b = Object.fromEntries(BRIEF.map((k) => [k, r[k] ?? null])); if (r.waiting) b.waiting = true; return b; };
const clone = (v) => (v == null ? v : JSON.parse(JSON.stringify(v)));

function listInfo(r, records, now) {
  const parsed = parse(r.body);
  let [done, total] = countDone(parsed.items);
  // The laptop's order of the lists inside a group, then any new ones.
  const known = ((r.list && r.list.children) || []).filter((id) => records.has(id) && metaOf(records.get(id)).parent === r.id);
  const kids = [...known, ...childrenOf(r.id, records).map((k) => k.id).filter((id) => !known.includes(id))];
  for (const id of kids) { const [d, t] = progress(records.get(id).body); done += d; total += t; }
  const next = parsed.items.find((it) => !it.done);
  return { checkin: metaOf(r).checkin ?? null, quietUntil: metaOf(r).quiet_until ?? null, repeat: metaOf(r).repeat ?? null,
    parent: metaOf(r).parent ?? null, children: kids, done, total, pace: pace(done, total, r.due, r.created, now),
    next: next ? next.text : null,
    sections: parsed.sections.map((s) => { const [d, t] = countDone(s.items.map((i) => parsed.items[i])); return { title: s.title, line: s.line, due: s.due, done: d, total: t }; }) };
}

// A note's derived parts, worked out again from its text (after a change here).
function refresh(r) {
  r.lines = preview(r.body);
  const [d, t] = progress(r.body);
  r.progress = t ? [d, t] : null;
  r.done = r.status === 'done';
  r.snippet = snippet([r.summary, r.body].filter(Boolean).join(' '));
  return r;
}

function detail(r, records, now) {
  const out = clone(r);
  if (r.kind === 'list' || r.progress) {
    out.list = listInfo(r, records, now);
    const parent = out.list.parent ? records.get(out.list.parent) : null;
    out.parentTitle = parent ? parent.title : null;
    out.childLists = out.list.children.map((id) => records.get(id)).filter(Boolean).map((k) => ({ ...briefOf(k), list: listInfo(k, records, now) }));
  }
  out.related = (r.related || []).map((b) => (records.has(b.id) ? briefOf(records.get(b.id)) : b));
  for (const k of ['remindAt', 'reminded', 'pos', 'meta', 'fp', 'tmp', 'base']) delete out[k];
  return out;
}

const inTopic = (r, path) => (r.topics || []).some((t) => t === path || t.startsWith(path + '/'));

function search(records, q) {
  const terms = String(q || '').toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return [];
  const hits = [];
  for (const r of records.values()) {
    const text = [r.summary, r.body, r.description, r.ocr].filter(Boolean).join(' ').replace(MD_MARKS, '').replace(/\s+/g, ' ');
    const title = String(r.title || '').toLowerCase(), hay = title + ' ' + text.toLowerCase();
    let score = 0, ok = true;
    for (const t of terms) { if (title.includes(t)) score += 3; else if (hay.includes(t)) score += 1; else { ok = false; break; } }
    if (!ok) continue;
    const i = text.toLowerCase().indexOf(terms[0]);
    const snip = i < 0 ? text.slice(0, 160) : (i > 40 ? '…' : '') + text.slice(Math.max(0, i - 40), i + 140) + (text.length > i + 140 ? '…' : '');
    hits.push({ id: r.id, title: r.title, topic: r.topic ?? null, kind: r.kind, snippet: snip, via: title.includes(terms[0]) ? 'title' : 'text', score: score / (terms.length * 3) });
  }
  return hits.sort((a, b) => b.score - a.score).slice(0, 40);
}

/* ------------------------------------------------------- the engine ---- */
function uid() {
  const b = new Uint8Array(12);
  (root.crypto || globalThis.crypto).getRandomValues(b);      // works without https too
  return [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
}
// A time from the page (maybe with a zone) as the laptop writes it: local wall clock.
function localStamp(v) {
  if (!v) return null;
  const s = String(v);
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(s)) return (s + ':00').slice(0, 19);
  const d = new Date(s);
  return isNaN(d) ? null : stampOf(wallNow(d));
}
const cap = (s) => { s = String(s || '').trim(); return s ? s[0].toUpperCase() + s.slice(1) : s; };
const domain = (u) => { try { return new URL(/^https?:/.test(u) ? u : 'https://' + u).hostname.replace(/^www\./, ''); } catch { return u; } };

/* The same answers as the laptop's /api routes, from `copy` (see openCopy).
   Changes are made here at once and queued (copy.addOp) to be sent, in
   order, the next time the laptop can be reached (see flush). */
function createLocal(copy, opts = {}) {
  const clockNow = opts.now || (() => new Date());
  const now = () => wallNow(clockNow());
  const nowStamp = () => stampOf(now());
  const utcNow = () => clockNow().toISOString().slice(0, 19) + 'Z';      // as the laptop writes created/updated
  const recs = copy.records;
  const fail = (status, msg) => Object.assign(new Error(msg || `${status}`), { status });
  const ordered = (filter) => byOrder([...recs.values()].filter(filter));
  const need = (id) => { const r = recs.get(id); if (!r) throw fail(404, "That note isn't on this device."); return r; };
  const changed = () => opts.onChange && opts.onChange();

  // Changed here: the laptop sends its version again after the change reaches it.
  function touch(r) { r.fp = null; refresh(r); return r; }
  function fresh(fields) {
    const stamp = utcNow();
    return refresh({ id: 'tmp-' + uid(), title: '', kind: 'note', status: 'open', path: null, topic: null, snippet: '', created: stamp,
      updated: stamp, review: false, due: null, remind: false, done: false, media: null, source: null, lines: [], progress: null,
      body: '', related: [], links: [], topics: [], repeat: null, remindAt: null, reminded: false, pos: clockNow().getTime() / 1000,
      meta: { repeat: null, checkin: null, quiet_until: null, parent: null }, tmp: true, waiting: true, fp: null, ...fields });
  }
  // Remember the laptop's version of a note before its first change here.
  const based = (r) => { if (!r.tmp && r.base == null) r.base = r.updated; return r; };
  const shot = (ids) => ids.map((id) => recs.get(id)).filter(Boolean).map(clone);

  /* Queue a change. `before` are copies of the notes it touches, for Undo;
     `made` is a note it created here. An edit right after an edit of the
     same note is one change. */
  async function queue(route, payload, { label, before = [], made = null, tmp = null, merge = false, save = [] } = {}) {
    const ops = copy.ops(), last = ops[ops.length - 1];
    if (merge && last && last.route === route && (route !== '/api/note/update' || last.payload.id === payload.id)) {
      last.payload = { ...last.payload, ...payload, base: last.payload.base };
      await copy.putOp(last, save);
    } else {
      await copy.addOp({ op: uid(), route, payload, label, tmp, at: nowStamp(), undo: { before, made } }, save);
    }
    changed();
  }
  async function dropMade(id) {
    for (const o of copy.ops()) if (o.tmp === id || o.payload.id === id) await copy.dropOp(o);
    changed();
  }
  const titleMatch = (want, filter = () => true) => {
    const w = String(want || '').toLowerCase().trim();
    return w ? ordered((r) => filter(r) && String(r.title || '').toLowerCase().includes(w))[0] || null : null;
  };

  return {
    copy,
    async state() {
      const base = clone(copy.view('state')) || { tree: [], topics: 0 };
      const all = [...recs.values()];
      const count = (node) => { node.count = all.filter((r) => inTopic(r, node.path)).length; (node.children || []).forEach(count); };
      (base.tree || []).forEach(count);
      return { ...base, inbox: all.filter((r) => !(r.topics || []).length).length, review: all.filter((r) => r.review).length,
        notes: all.length, laptop: false, copy: true };
    },
    async notes(p = {}) {
      let rows;
      if (p.topic) rows = ordered((r) => inTopic(r, p.topic) && (!p.kind || r.kind === p.kind) && (!p.status || r.status === p.status));
      else if (p.kind) rows = ordered((r) => r.kind === p.kind);
      else rows = ordered(() => true).slice(0, 300);
      return { notes: rows.map(briefOf) };
    },
    async note(id) { const r = recs.get(id); if (!r) throw fail(404, '404 /api/note'); return detail(r, recs, now()); },
    async inbox() {
      return { notes: ordered((r) => !(r.topics || []).length).map(briefOf),
        review: [...recs.values()].filter((r) => r.review).sort((a, b) => (a.created < b.created ? 1 : -1)).map(briefOf) };
    },
    async lists() { const n = now(); return { lists: ordered((r) => r.kind === 'list').map((r) => ({ ...briefOf(r), list: listInfo(r, recs, n) })) }; },
    async agenda() {
      await this.advance();
      const n = now();
      const notes = [...recs.values()].filter((r) => r.due && r.status !== 'archived')
        .sort((a, b) => ((a.status === 'done') - (b.status === 'done')) || (a.due < b.due ? -1 : a.due > b.due ? 1 : 0))
        .map((r) => ({ ...briefOf(r), repeat: r.repeat ?? null }));
      return { notes, items: agendaItems(recs, n), lists: activeLists(recs, n),
        anytime: ordered((r) => r.kind === 'task' && !r.due && r.status === 'open').map(briefOf) };
    },
    async due() {
      const rolled = await this.advance();
      const reminders = dueNow(recs, copy.fired(), now());
      for (const r of reminders) if (r.type === 'task') r.topic = recs.get(r.noteId)?.topic ?? null;
      return { reminders, rolled };
    },
    async search(q) { return { hits: search(recs, q) }; },
    async links() { return clone(copy.view('links')) || { links: [] }; },
    async personal() { return clone(copy.view('personal')) || { sources: [], links: [], lists: {} }; },
    async personalMessages(source) { const v = copy.view('personal-messages:' + source); if (!v) throw fail(404, '404 /api/personal/messages'); return clone(v); },
    async profiles() { return clone(copy.view('profiles')) || { profiles: [], current: null }; },
    async suggest() { return { suggestions: [] }; },
    // Shown here, so neither this phone nor the laptop shows it again.
    async reminded(keys, { send = false } = {}) {
      const touched = [];
      for (const key of keys) {
        if (key.startsWith('task:')) { const r = recs.get(key.split(':')[1]); if (r && !r.reminded) { r.reminded = true; touched.push(r); } }
      }
      await copy.markShown(keys, touched);
      if (send) {
        const ops = copy.ops(), last = ops[ops.length - 1];
        const all = last && last.route === '/api/reminded' ? [...new Set([...last.payload.keys, ...keys])] : keys;
        await queue('/api/reminded', { keys: all }, { label: 'Reminders seen', merge: true });
      }
      return { ok: true };
    },

    /* ---- changes made here ---- */
    async capture(text, organise) {
      const it = opts.interpret ? opts.interpret(text) : { title: text };
      const payload = { text, organise };
      if (it.append) {
        const target = titleMatch(it.append);
        if (target) {
          const before = shot([target.id]), line = '- ' + cap(it.appendText || it.title || text);
          based(target).body = (target.body ? target.body.replace(/\s*$/, '') + '\n' : '') + line;
          target.updated = utcNow();
          await queue('/api/capture', payload, { label: `Added to “${target.title}”`, before, save: [touch(target)] });
          return { id: target.id, title: target.title, kind: target.kind, appendedTo: target.title, topic: target.topic, queued: true };
        }
      }
      if (it.pause) {
        const list = titleMatch(it.pause.target, (r) => r.kind === 'list'), until = ymdOf(wallNow(new Date(it.pause.until)));
        const before = list ? shot([list.id]) : [];
        if (list) list.meta = { ...metaOf(list), quiet_until: until };
        await queue('/api/capture', payload, { label: 'Paused check-ins', before, save: list ? [touch(list)] : [] });
        return { id: list ? list.id : null, title: list ? list.title : it.pause.target, pausedUntil: until, queued: true };
      }
      let r;
      if (it.list) {
        const due = it.list.due ? stampOf(wallNow(new Date(it.list.due))) : null;
        r = fresh({ title: it.list.title, kind: 'list', due, body: it.list.items.map((t) => `- [ ] ${t}`).join('\n') });
      } else {
        const due = it.due ? stampOf(wallNow(new Date(it.due))) : null;
        let title = it.title || text, body = '', source = null;
        if (it.link) {
          source = /^http/i.test(it.link) ? it.link : 'https://' + it.link;
          const at = title.toLowerCase().indexOf(it.link.toLowerCase());
          title = cap((at < 0 ? title : title.slice(0, at) + title.slice(at + it.link.length)).replace(/\s+/g, ' ').trim()) || domain(it.link);
        }
        if (title.length > 70) { body = text; title = title.slice(0, 60).replace(/\s+\S*$/, '') + '…'; }
        const remindAt = due && /\bremind/i.test(text) ? due : null;
        r = fresh({ title, body, source, due, remindAt, remind: !!remindAt, kind: it.link ? 'link' : (it.todo || due) ? 'task' : 'note' });
      }
      recs.set(r.id, r);
      await queue('/api/capture', payload, { label: `Saved “${r.title}”`, made: r.id, tmp: r.id, save: [r] });
      return { id: r.id, title: r.title, kind: r.kind, due: r.due, reminder: !!r.remindAt, outcome: 'inbox', topic: null,
        listItems: r.kind === 'list' ? parse(r.body).items.length : undefined, queued: true };
    },
    async upload(data, text, organise) {
      const r = fresh({ title: text ? cap(text).slice(0, 60) : 'Photo', kind: 'image', media: data, body: text || '' });
      recs.set(r.id, r);
      await queue('/api/upload', { data, text, organise }, { label: 'Saved a photo', made: r.id, tmp: r.id, save: [r] });
      return { id: r.id, title: r.title, topic: null, outcome: 'inbox', media: data, ocr: null, description: null, queued: true };
    },
    async newNote(title, body, topic, kind) {
      const r = fresh({ title: title || '', body: body || '', kind: kind === 'list' ? 'list' : 'note', topic: topic || null, topics: topic ? [topic] : [] });
      recs.set(r.id, r);
      await queue('/api/note/new', { title, body, topic: topic || undefined, kind }, { label: 'Made a note', made: r.id, tmp: r.id, save: [r] });
      return { id: r.id, path: null, topic: r.topic };
    },
    async update(id, f) {
      const r = need(id), before = shot([id]);
      based(r);
      if (f.title != null) r.title = String(f.title).trim() || r.title;
      if (f.body != null) r.body = f.body;
      r.updated = utcNow();
      const payload = { id, ...(f.title != null ? { title: f.title } : {}), ...(f.body != null ? { body: f.body } : {}), base: r.base || undefined };
      await queue('/api/note/update', payload, { label: 'Edited a note', before, merge: true, save: [touch(r)] });
      return { id, path: r.path, title: r.title };
    },
    async append(id, text) {
      const r = need(id), before = shot([id]), add = String(text || '').trim();
      based(r).body = r.body && r.body.trim() ? `${r.body.replace(/\s+$/, '')}\n\n${add}` : add;
      r.updated = utcNow();
      await queue('/api/note/append', { id, text }, { label: `Added to “${r.title}”`, before, save: [touch(r)] });
      return { ok: true };
    },
    async schedule(id, when, remind, snooze) {
      const r = need(id), before = shot([id]), stamp = localStamp(when);
      if (snooze && stamp) { r.remindAt = stamp; }
      else {
        r.due = stamp; r.remindAt = stamp && remind !== false ? stamp : null;
        if (stamp && r.kind === 'note') r.kind = 'task';
        r.updated = utcNow();
      }
      r.reminded = false; r.remind = !!r.remindAt;
      await queue('/api/note/schedule', { id, when, remind, snooze }, { label: stamp ? 'Changed the time' : 'Removed the reminder', before, save: [touch(r)] });
      return { ok: true };
    },
    async complete(id, done) {
      const r = need(id), before = shot([id]), rule = done && r.repeat ? parseRule(r.repeat) : null, when = r.due || r.remindAt;
      let next = null;
      if (rule && when) {
        const start = naive(String(when).slice(0, 19)), n = now();
        next = stampOf(nextAfter(start, rule, start > n ? start : n));
        r.due = r.due ? next : null;
        r.remindAt = r.remindAt || !r.due ? next : null;
        r.status = 'open'; r.reminded = false; r.remind = !!r.remindAt;
      } else r.status = done ? 'done' : 'open';
      r.updated = utcNow();
      await queue('/api/note/complete', { id, done }, { label: done ? `Marked “${r.title}” done` : 'Marked not done', before, save: [touch(r)] });
      return { ok: true, next };
    },
    async listItem(id, line, text, done) {
      const r = need(id), before = shot([id]);
      r.body = toggle(r.body, line, text, done, ymdOf(now()));
      await queue('/api/list/item', { id, line, text, done }, { label: done ? 'Ticked an item' : 'Unticked an item', before, save: [touch(r)] });
      const [d, t] = progress(r.body);
      return { ok: true, progress: [d, t] };
    },
    async itemWhen(p) {
      const r = need(p.id), before = shot([p.id]);
      r.body = setWhen(r.body, p.line, p.text, { remind: localStamp(p.remind), due: p.due, repeat: p.repeat });
      await queue('/api/list/item/when', p, { label: 'Changed an item', before, save: [touch(r)] });
      return { ok: true };
    },
    async listSettings(p) {
      const r = need(p.id), before = shot([p.id]);
      const m = { ...metaOf(r) };
      for (const k of ['checkin', 'quiet_until', 'repeat', 'parent']) if (k in p) m[k] = p[k] || null;
      r.meta = m;
      if ('repeat' in p) r.repeat = m.repeat;
      if ('due' in p) r.due = localStamp(p.due);
      if ('kind' in p && p.kind) r.kind = p.kind;
      await queue('/api/list/settings', p, { label: 'Changed a list', before, save: [touch(r)] });
      return { ok: true };
    },
    async order(id, beforeId, afterId, view) {
      const r = need(id), before = shot([id]);
      const up = beforeId && recs.has(beforeId) ? recs.get(beforeId).pos : null, down = afterId && recs.has(afterId) ? recs.get(afterId).pos : null;
      if (up != null && down != null) r.pos = (up + down) / 2;
      else if (down != null) r.pos = down + 1e-3;
      else if (up != null) r.pos = up - 60;
      await queue('/api/note/order', { id, before: beforeId, after: afterId, view }, { label: 'Moved a note', before, save: [touch(r)] });
      return { ok: true, pos: r.pos };
    },
    async move(id, topic) {
      const r = need(id), before = shot([id]);
      r.topic = topic || null; r.topics = topic ? [topic, ...(r.topics || []).filter((t) => t !== topic && t !== before[0].topic)] : [];
      r.review = false;
      await queue('/api/move', { id, topic }, { label: `Moved to ${topic || 'Inbox'}`, before, save: [touch(r)] });
      return { ok: true };
    },
    async remove(id) {
      const r = need(id), before = shot([id]);
      recs.delete(id);
      await copy.dropRecords([id]);
      if (r.tmp) { await dropMade(id); return { deleted: true, title: r.title }; }
      await queue('/api/note/delete', { id }, { label: `Deleted “${r.title || 'Untitled'}”`, before });
      return { deleted: true, title: r.title };
    },
    async discard(id) {
      const r = recs.get(id);
      if (!r || (r.title || '').trim() || (r.body || '').trim()) return { discarded: false };
      recs.delete(id);
      await copy.dropRecords([id]);
      if (r.tmp) { await dropMade(id); return { discarded: true }; }
      await queue('/api/note/discard', { id }, { label: 'Dropped an empty note', before: [clone(r)] });
      return { discarded: true };
    },
    async linksLayout(order) {
      const v = copy.views.get('links');
      if (v && v.data && Array.isArray(v.data.links)) {
        const at = new Map(order.map((k, i) => [k, i]));
        v.data.links.sort((a, b) => (at.get(a.key) ?? 1e9) - (at.get(b.key) ?? 1e9));
        v.fp = null; await copy.putView('links', v);
      }
      await queue('/api/links/layout', { order }, { label: 'Arranged links', merge: true });
      return { ok: true };
    },
    async personalLayout(key, order) {
      const ops = copy.ops(), last = ops[ops.length - 1];
      await queue('/api/personal/layout', { key, order }, { label: 'Arranged tiles', merge: !!last && last.payload.key === key });
      return { ok: true };
    },
    // Undo works on changes still waiting here; what reached the laptop is undone there.
    async undo() {
      const ops = copy.ops(), last = [...ops].reverse().find((o) => o.undo && o.route !== '/api/reminded');
      if (!last) return { undone: null };
      const ids = new Set(last.undo.before.map((r) => r.id));
      if (last.undo.made) { recs.delete(last.undo.made); await copy.dropRecords([last.undo.made]); }
      for (const r of last.undo.before) recs.set(r.id, r);
      await copy.dropOp(last, last.undo.before);
      // A note made here and then undone takes its later changes with it.
      if (last.undo.made) for (const o of copy.ops()) if (o.payload.id === last.undo.made) await copy.dropOp(o);
      changed();
      return { undone: last.label, ids: [...ids] };
    },
    // Repeating things come round here too while the laptop is away.
    async advance() {
      const { changed, marked } = advanceRepeats(recs, copy.fired(), now());
      changed.forEach((id) => refresh(recs.get(id)));
      if (changed.length || marked.length) await copy.markShown(marked, changed.map((id) => recs.get(id)));
      return changed.length;
    },
  };
}

/* ------------------------------------------------------- the copy ------ */
/* One IndexedDB database per profile: records (notes), views (collections,
   Links, Personal notes, profiles, reminders already shown) and meta. */
function idb(req) { return new Promise((resolve, reject) => { req.onsuccess = () => resolve(req.result); req.onerror = () => reject(req.error); }); }
function done(tx) { return new Promise((resolve, reject) => { tx.oncomplete = () => resolve(); tx.onerror = tx.onabort = () => reject(tx.error); }); }

async function openCopy(profile) {
  const open = indexedDB.open('notes-' + (profile || 'default'), 1);
  open.onupgradeneeded = () => {
    const db = open.result;
    db.createObjectStore('records', { keyPath: 'id' });
    db.createObjectStore('views');
    db.createObjectStore('meta');
    db.createObjectStore('outbox', { keyPath: 'seq', autoIncrement: true });
  };
  const db = await idb(open);
  const tx = db.transaction(['records', 'views', 'meta', 'outbox'], 'readonly');
  const [recList, viewKeys, viewVals, metaKeys, metaVals, opList] = await Promise.all([
    idb(tx.objectStore('records').getAll()), idb(tx.objectStore('views').getAllKeys()), idb(tx.objectStore('views').getAll()),
    idb(tx.objectStore('meta').getAllKeys()), idb(tx.objectStore('meta').getAll()), idb(tx.objectStore('outbox').getAll())]);
  let ops = opList.sort((a, b) => a.seq - b.seq);
  const records = new Map(recList.map((r) => [r.id, r]));
  const views = new Map(viewKeys.map((k, i) => [k, viewVals[i]]));
  const meta = Object.fromEntries(metaKeys.map((k, i) => [k, metaVals[i]]));
  let shown = new Set(meta.shown || []);

  async function write(fn) {
    const t = db.transaction(['records', 'views', 'meta', 'outbox'], 'readwrite');
    const out = fn(t.objectStore('records'), t.objectStore('views'), t.objectStore('meta'), t.objectStore('outbox'));
    await done(t);
    return out;
  }

  return {
    db, profile, records, views, meta,
    get empty() { return !records.size && !views.size; },
    view(name) { const v = views.get(name); return v ? v.data : null; },
    fired() { return new Set([...(this.view('fired') || []), ...shown]); },
    have() {
      const out = {};
      for (const r of records.values()) if (r.fp && !r.local) out[r.id] = r.fp;
      return out;
    },
    viewFps() { const out = {}; for (const [k, v] of views) out[k] = v.fp; return out; },
    // A pull from the laptop. Notes with changes still waiting to be sent keep
    // their copy here, so what you did isn't undone on screen.
    async apply(pull, keep = new Set()) {
      await write((rs, vs, ms) => {
        for (const rec of pull.records || []) {
          if (keep.has(rec.id)) continue;
          records.set(rec.id, rec); rs.put(rec);
        }
        for (const id of pull.gone || []) if (!keep.has(id)) { records.delete(id); rs.delete(id); }
        for (const [name, v] of Object.entries(pull.views || {})) { views.set(name, v); vs.put(v, name); }
        for (const name of pull.goneViews || []) { views.delete(name); vs.delete(name); }
        // Shown here and now known to the laptop: no need to remember them twice.
        const known = new Set(this.view('fired') || []);
        shown = new Set([...shown].filter((k) => !known.has(k)).slice(-1000));
        meta.shown = [...shown]; ms.put(meta.shown, 'shown');
        meta.lastSync = pull.at || new Date().toISOString(); ms.put(meta.lastSync, 'lastSync');
      });
    },
    /* Changes waiting to be sent, oldest first. `save` are notes changed
       along with them, written in the same step so the two never disagree. */
    ops() { return ops.slice(); },
    async addOp(op, save = []) {
      const req = await write((rs, vs, ms, os) => { save.forEach((r) => rs.put(r)); return os.add(op); });
      op.seq = req.result; ops.push(op);
    },
    async putOp(op, save = []) { await write((rs, vs, ms, os) => { save.forEach((r) => rs.put(r)); os.put(op); }); },
    async dropOp(op, restore = []) {
      ops = ops.filter((o) => o.seq !== op.seq);
      await write((rs, vs, ms, os) => { restore.forEach((r) => { records.set(r.id, r); rs.put(r); }); os.delete(op.seq); });
    },
    // Notes with changes still waiting: a pull mustn't overwrite them here.
    pendingIds() {
      const out = new Set();
      for (const o of ops) {
        if (o.payload && o.payload.id) out.add(o.payload.id);
        if (o.tmp) out.add(o.tmp);
        for (const r of (o.undo && o.undo.before) || []) out.add(r.id);
      }
      return out;
    },
    async putView(name, v) { views.set(name, v); await write((rs, vs) => vs.put(v, name)); },
    async markShown(keys, changed = []) {
      keys.forEach((k) => shown.add(k));
      meta.shown = [...shown].slice(-1000);
      await write((rs, vs, ms) => { changed.forEach((r) => rs.put(r)); ms.put(meta.shown, 'shown'); });
    },
    async putRecords(list) { await write((rs) => list.forEach((r) => { records.set(r.id, r); rs.put(r); })); },
    async dropRecords(ids) { await write((rs) => ids.forEach((id) => { records.delete(id); rs.delete(id); })); },
    async setMeta(key, value) { meta[key] = value; await write((rs, vs, ms) => ms.put(value, key)); },
    async clear() {
      await write((rs, vs, ms, os) => { rs.clear(); vs.clear(); ms.clear(); os.clear(); });
      records.clear(); views.clear(); shown = new Set(); ops = [];
      for (const k of Object.keys(meta)) delete meta[k];
    },
  };
}

// Ask the laptop for what changed since this copy, and keep it.
async function pullInto(copy, post) {
  const out = await post('/api/sync/pull', { have: copy.have(), views: copy.viewFps() });
  if (out.profile && copy.profile && out.profile !== copy.profile) throw Object.assign(new Error('another profile'), { status: 409 });
  await copy.apply(out, copy.pendingIds());
  return out;
}

// What a tunnel or proxy answers when the laptop behind it is off.
const DOWN = new Set([502, 503, 504, 520, 521, 522, 523, 524, 530]);
const isDown = (err) => !!err && (err.network || DOWN.has(err.status));

/* Send the changes made here, one at a time and in order, through the
   laptop's normal routes, so it files, reads and fetches as if you'd made
   them there. `send(route, payload, opId)` posts with the op id, so a change
   whose reply got lost isn't done twice. Stops (throws) when the laptop goes
   away again; what's left is sent next time. Returns notes for the person:
   conflicts saved as copies, and changes the laptop couldn't apply. */
async function flush(copy, send, onStep) {
  const ids = Object.assign({}, copy.meta.idmap || {}), notes = [];
  const remap = (p) => {
    const out = { ...p };
    for (const k of ['id', 'before', 'after', 'parent']) if (out[k] && ids[out[k]]) out[k] = ids[out[k]];
    return out;
  };
  const keepIds = () => copy.setMeta('idmap', Object.fromEntries(Object.entries(ids).slice(-200)));
  const list = copy.ops();
  for (let i = 0; i < list.length; i++) {
    const op = copy.ops().find((o) => o.seq === list[i].seq);
    if (!op) continue;                                                  // dropped along the way
    if (onStep) onStep(i + 1, list.length);
    const payload = remap(op.payload);
    if (/^tmp-/.test(payload.id || '')) {                              // its note never reached the laptop
      notes.push({ kind: 'failed', what: op.label, why: "the note it belongs to couldn't be saved" });
      await copy.dropOp(op); continue;
    }
    let res;
    try { res = await send(op.route, payload, op.op); }
    catch (err) {
      if (isDown(err)) { await keepIds(); throw err; }
      if (err.status === 409 && err.data && err.data.conflict && op.route === '/api/note/update') {
        const r = copy.records.get(op.payload.id), title = `${payload.title || (r && r.title) || 'Note'} (edited on phone)`;
        try { await send('/api/note/new', { title, body: payload.body != null ? payload.body : (r && r.body) || '' }, op.op + '-copy'); }
        catch (e2) { if (isDown(e2)) { await keepIds(); throw e2; } }
        notes.push({ kind: 'conflict', title: (r && r.title) || payload.title || 'a note', copy: title });
      } else notes.push({ kind: 'failed', what: op.label, why: err.reason || err.message });
      await copy.dropOp(op); continue;
    }
    if (op.tmp && res && res.id) { ids[op.tmp] = res.id; copy.records.delete(op.tmp); await copy.dropRecords([op.tmp]); }
    // The laptop's new version of the note: later changes here build on it.
    if (res && res.updated && payload.id) {
      for (const later of copy.ops()) {
        if (later.seq !== op.seq && later.payload.base && remap(later.payload).id === payload.id) { later.payload.base = res.updated; await copy.putOp(later); }
      }
    }
    await copy.dropOp(op);
  }
  await keepIds();
  return { notes, ids };
}

root.NotesLocal = {
  createLocal, openCopy, pullInto, flush, isDown, DOWN, localStamp,
  // the rules, for tests and for the page
  sha1, naive, stampOf, ymdOf, wallNow, parse, progress, splitTokens, formatItem, toggle, setWhen, reset, findItem,
  pace, dueNow, agendaItems, activeLists, listFacts, parseRule, nextAfter, periodStart, resetKey, rollItems, advanceRepeats,
  preview, snippet, briefOf, listInfo, refresh, detail,
};
})(typeof window !== 'undefined' ? window : globalThis);
