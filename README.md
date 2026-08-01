# Future Minds — Backend (Module 1: Data Model + Auth)

Working starter project implementing **Section 5 (Data Model)** and **Section 4.7 / 7.1
(Sign In / Sign Up, Auth)** of the Developer Requirements Specification. Tested end-to-end:
sign-up, OTP verification, JWT sessions, role-based route protection, requirement
submission with Student Details, and tutor profile registration all work out of the box.

## 0. Install-check (do this first, on your own machine)

```bash
node -v     # need 18+, ideally 20 or 22
npm -v
```

If Node isn't installed: get it from https://nodejs.org (LTS version) or via `nvm`.

If you're using **Claude Code** to continue building this:

```bash
npm install -g @anthropic-ai/claude-code   # one-time
claude                                      # run from inside this project folder
```

Then just tell it what to build next, module by module (see "What's next" below).

## 1. Setup

```bash
npm install
cp .env.example .env
npm run dev
```

Server starts on `http://localhost:4000`. The SQLite database file (`dev.db`) and all
tables are created automatically on first run — nothing else to configure.

## 2. Quick test

```bash
curl -X POST http://localhost:4000/auth/request-otp \
  -H "Content-Type: application/json" -d '{"phone":"9876543210"}'
# -> {"ok":true,"message":"OTP sent","devHint":"123456"}   (devHint only shown outside production)

curl -X POST http://localhost:4000/auth/verify-otp \
  -H "Content-Type: application/json" \
  -d '{"phone":"9876543210","otp":"123456","name":"Radha Krishnan","role":"PARENT","consent":true}'
# -> {"ok":true,"token":"...","user":{...}}
```

Use the returned `token` as `Authorization: Bearer <token>` on protected routes.

## 3. What's implemented

| Route | Method | Role | Maps to |
|---|---|---|---|
| `/auth/request-otp` | POST | public | Sign In Step 1 / Sign Up phone field (4.7) |
| `/auth/verify-otp` | POST | public | Sign In Step 2, and Sign Up if the phone is new (4.7) |
| `/auth/me` | GET | any logged-in user | session check |
| `/requirements` | POST | PARENT | "Get Matched" form + Student Details (4.1) |
| `/requirements` | GET | ADMIN | admin requirement queue (4.6) |
| `/teachers/me` | PUT | TEACHER | "Register as a Tutor" Step 1 (4.4) |
| `/teachers` | GET | ADMIN | teacher database, filterable by `?subject=` (4.2, 4.6) |

## 4. Data layer

Two things ship side by side, deliberately:

- **`prisma/schema.prisma`** — the documented data model (matches Section 5 exactly).
  This is what a developer/agency should treat as the source of truth if they move to
  Postgres/MySQL for production.
- **`prisma/schema.sql` + `src/db.js`** (via `better-sqlite3`) — the actual runtime used
  by this starter, so it installs and runs with zero configuration and no external
  services. It mirrors the Prisma schema table-for-table.

**To move to Prisma + Postgres later:** set `DATABASE_URL` to a real Postgres connection
string, change the `provider` in `schema.prisma` to `"postgresql"`, run
`npx prisma generate && npx prisma db push`, and swap the `db.prepare(...)` calls in
`src/routes/*.js` for `prisma.<model>.<method>(...)` calls — the field names line up
directly. This is a natural task to hand to Claude Code once you're ready.

## 5. Known placeholders (intentional, flagged in the requirements doc)

- **OTP delivery is fake.** `request-otp` logs the code to the server console
  (`devHint` in the response, dev-mode only) instead of sending a real SMS/WhatsApp
  message. Swap in Firebase Auth, MSG91, or Twilio Verify per Section 7.1.
- **No payment integration yet** — Section 7.3 in the requirements doc.
- **No WhatsApp/notification integration yet** — Section 7.2.
- **KYC document upload** for tutors isn't wired to file storage yet — `teacher_profiles.kyc_status`
  exists in the schema and defaults to `PENDING`, ready for an admin approval flow.

## 6. Suggested next modules (in order)

1. **Matches & Demo Booking** (Section 4.2) — endpoint for admin to shortlist teachers
   against a requirement, and for a parent to book a demo.
2. **Attendance & Payout Ledger** (Section 4.3) — the `class_sessions` and `payouts`
   tables already exist; needs the mark → confirm → validate → release state machine.
3. **Admin panel API** (Section 4.6) — list/search/filter endpoints for the front-end
   admin views.
4. **Real OTP provider integration** (Section 7.1) — replace the dev OTP store.
5. **One payment integration** (Section 7.3) — scope to a single revenue model first.

Each of these can be hand-built with Claude Code by pointing it at this repo plus the
Developer Requirements doc — the data model and auth foundation here is what everything
else attaches to.
