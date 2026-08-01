// Zero-config, pure-JS data layer — a single JSON file on disk, no native
// addons. This runs anywhere Node runs, including browser-based sandboxes
// (StackBlitz WebContainers) that block native compiled modules like
// better-sqlite3. Swap to prisma/schema.prisma + Postgres for production.
const fs = require('fs');
const path = require('path');

const DB_FILE = process.env.DATABASE_FILE || path.join(__dirname, '..', 'dev-db.json');

function load() {
  if (!fs.existsSync(DB_FILE)) {
    save({
      users: [],
      studentProfiles: [],
      teacherProfiles: [],
      requirements: [],
    });
  }
  return JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
}

function save(data) {
  fs.writeFileSync(DB_FILE, JSON.stringify(data, null, 2));
}

module.exports = { load, save };
