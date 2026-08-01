// Future Minds friendly-ID system.
//
// Internal `id` fields (crypto.randomUUID) never change — every other record
// links to them, so they must stay stable. The IDs in this file are DISPLAY
// IDs: human-readable, status-aware identifiers that are what users actually
// see, type, and paste around. Any API endpoint that takes an ":id" or an
// "...Id" field accepts EITHER form — see resolve* helpers in each route file.

function pad(n, len) {
    return String(n).padStart(len, '0');
  }
  
  function todayStamp() {
    const d = new Date();
    const yy = pad(d.getFullYear() % 100, 2);
    const mm = pad(d.getMonth() + 1, 2);
    const dd = pad(d.getDate(), 2);
    return `${yy}${mm}${dd}`;
  }
  
  function currentYY() {
    return new Date().getFullYear() % 100;
  }
  
  // ---- Daily-reset IDs: students, teachers, parents ----
  // Format: FMSTU260802-01  (prefix + YYMMDD + 2-digit daily sequence)
  function nextDailyId(data, bucketKey, prefix) {
    if (!data.counters) data.counters = {};
    if (!data.counters[bucketKey]) data.counters[bucketKey] = {};
    const stamp = todayStamp();
    data.counters[bucketKey][stamp] = (data.counters[bucketKey][stamp] || 0) + 1;
    return `${prefix}${stamp}-${pad(data.counters[bucketKey][stamp], 2)}`;
  }
  
  // ---- Yearly-reset sequence for matches (Match -> Demo -> Approved) ----
  // Format: FMMATCH26-00001 / FMDEMO26-00001 / FMAPPROVED26-00001
  // Same underlying (year, seq) pair; only the prefix changes with status.
  function nextMatchSeq(data) {
    const year = currentYY();
    if (!data.counters) data.counters = {};
    if (!data.counters.match || data.counters.match.year !== year) {
      data.counters.match = { year, seq: 0 };
    }
    data.counters.match.seq += 1;
    return { idYear: data.counters.match.year, idSeq: data.counters.match.seq };
  }
  
  function matchDisplayId(match) {
    if (match.frozenDisplayId) return match.frozenDisplayId; // DECLINED: frozen at last stage reached
    const num = `${pad(match.idYear, 2)}-${pad(match.idSeq, 5)}`;
    if (match.status === 'CONFIRMED') return `FMAPPROVED${num}`;
    if (match.status === 'DEMO_PROPOSED' || match.status === 'DEMO_SCHEDULED') return `FMDEMO${num}`;
    return `FMMATCH${num}`; // PROPOSED
  }
  
  module.exports = { pad, todayStamp, currentYY, nextDailyId, nextMatchSeq, matchDisplayId };