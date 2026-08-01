// Zero-config, pure-JS data layer — a single JSON file on disk, no native
// addons. This runs anywhere Node runs, including browser-based sandboxes
// (StackBlitz WebContainers) that block native compiled modules like
// better-sqlite3. Swap to prisma/schema.prisma + Postgres for production.
const fs = require('fs');
const path = require('path');

const DB_FILE = process.env.DATABASE_FILE || path.join(__dirname, '..', 'dev-db.json');

function defaultData() {
  return {
    users: [],
    studentProfiles: [],
    teacherProfiles: [],
    requirements: [],
    matches: [],     // Section 4.2 — Matches & Demo Booking
    sessions: [],     // Section 4.3 — Attendance ledger (class_sessions)
    payouts: [],      // Section 4.3 — Payouts
  };
}

function load() {
  if (!fs.existsSync(DB_FILE)) {
    save(defaultData());
  }
  const data = JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));

  // Self-migrating: if this file was created by an earlier module (before
  // matches/sessions/payouts existed), backfill the missing collections
  // instead of erroring, so existing dev-db.json files keep working.
  let changed = false;
  for (const [key, value] of Object.entries(defaultData())) {
    if (!(key in data)) {
      data[key] = value;
      changed = true;
    }
  }
  if (changed) save(data);

  return data;
}

function save(data) {
  fs.writeFileSync(DB_FILE, JSON.stringify(data, null, 2));
}

module.exports = { load, save };
