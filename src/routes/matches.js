// Section 4.2 — Matches & Demo Booking, with the friendly ID system.
//
// A match's internal `id` (UUID) never changes — every session/payout links to
// it. What DOES change, automatically, is its DISPLAY id, computed from status:
//   PROPOSED              -> FMMATCH26-00001
//   DEMO_PROPOSED/SCHEDULED -> FMDEMO26-00001
//   CONFIRMED              -> FMAPPROVED26-00001
//   DECLINED                -> frozen at whatever stage it last reached, and
//                              flagged dead (hidden from parent/teacher UI
//                              lists by convention, but admin can still see it)
//
// Every :id param and every teacherId/matchId input elsewhere in the API
// accepts EITHER the internal UUID or the current display ID.
const express = require('express');
const crypto = require('crypto');
const db = require('../db');
const { nextMatchSeq, matchDisplayId } = require('../idgen');
const { requireAuth, requireRole } = require('../middleware/auth');

const router = express.Router();

function getOwnTeacherProfile(data, userId) {
  return data.teacherProfiles.find(t => t.userId === userId);
}
function findTeacherByAnyId(data, idOrDisplayId) {
  return data.teacherProfiles.find(t => t.id === idOrDisplayId || t.displayId === idOrDisplayId);
}
function findRequirementByAnyId(data, idOrDisplayId) {
  return data.requirements.find(r => r.id === idOrDisplayId || r.displayId === idOrDisplayId);
}
function findMatchByAnyId(data, idOrDisplayId) {
  return data.matches.find(m => m.id === idOrDisplayId || matchDisplayId(m) === idOrDisplayId);
}

// POST /matches — admin shortlists a teacher for a requirement, with a match score.
// requirementId accepts either the internal id or the FMREQ... display ID;
// teacherId accepts either the teacher's internal profile id or their FMTEACH... ID.
router.post('/', requireAuth, requireRole('ADMIN'), (req, res) => {
  const { requirementId, teacherId, matchScore } = req.body;
  if (!requirementId || !teacherId) {
    return res.status(400).json({ error: 'requirementId and teacherId are required' });
  }

  const data = db.load();
  const requirement = findRequirementByAnyId(data, requirementId);
  const teacher = findTeacherByAnyId(data, teacherId);
  if (!requirement) return res.status(404).json({ error: 'Requirement not found' });
  if (!teacher) return res.status(404).json({ error: 'Teacher profile not found' });

  const { idYear, idSeq } = nextMatchSeq(data);
  const match = {
    id: crypto.randomUUID(),
    idYear, idSeq, frozenDisplayId: null, dead: false,
    requirementId: requirement.id,
    teacherId: teacher.id,
    matchScore: matchScore ?? null,
    status: 'PROPOSED', // PROPOSED -> DEMO_PROPOSED -> DEMO_SCHEDULED -> CONFIRMED (or DECLINED)
    demoDate: null,
    demoTimeSlot: null,
    demoProposedAt: null,
    parentAcceptedDemo: false,
    teacherAcceptedDemo: false,
    scheduledAt: null,
    declinedBy: null,
    declineReason: null,
    parentApprovedAt: null,
    createdAt: new Date().toISOString(),
  };
  data.matches.push(match);
  db.save(data);
  res.status(201).json({ ...match, displayId: matchDisplayId(match) });
});

// GET /matches?requirementId=... — role-scoped visibility
router.get('/', requireAuth, (req, res) => {
  const data = db.load();
  const { requirementId } = req.query;

  let matches = data.matches;
  if (requirementId) {
    const requirement = findRequirementByAnyId(data, requirementId);
    const resolvedId = requirement ? requirement.id : requirementId;
    matches = matches.filter(m => m.requirementId === resolvedId);
  }

  if (req.user.role === 'PARENT') {
    const ownRequirementIds = new Set(
      data.requirements.filter(r => r.parentId === req.user.id).map(r => r.id)
    );
    matches = matches.filter(m => ownRequirementIds.has(m.requirementId));
  } else if (req.user.role === 'TEACHER') {
    const ownTeacherProfile = getOwnTeacherProfile(data, req.user.id);
    matches = matches.filter(m => ownTeacherProfile && m.teacherId === ownTeacherProfile.id);
  }

  const enriched = matches.map(m => {
    const teacher = data.teacherProfiles.find(t => t.id === m.teacherId);
    const teacherUser = teacher && data.users.find(u => u.id === teacher.userId);
    return { ...m, displayId: matchDisplayId(m), teacherName: teacherUser?.name, teacherSubjects: teacher?.subjects };
  });

  res.json(enriched);
});

// PUT /matches/:id/propose-demo — admin proposes a demo date/time to both parties.
// Blocks an exact date+time-slot collision against this teacher's other active
// matches (same day, same slot bucket). NOTE: slots are broad buckets (e.g.
// "Weekday evenings"), not precise start/end times, so this catches literal
// same-slot double-booking only — real minute-level clash detection needs
// actual time fields, which is a Phase 2 item.
router.put('/:id/propose-demo', requireAuth, requireRole('ADMIN'), (req, res) => {
  const { date, timeSlot } = req.body;
  if (!date) return res.status(400).json({ error: 'date is required' });

  const data = db.load();
  const match = findMatchByAnyId(data, req.params.id);
  if (!match) return res.status(404).json({ error: 'Match not found' });
  if (match.status !== 'PROPOSED') {
    return res.status(400).json({ error: `Cannot propose a demo from status ${match.status}` });
  }

  if (timeSlot) {
    const clash = data.matches.find(m =>
      m.id !== match.id &&
      m.teacherId === match.teacherId &&
      ['DEMO_PROPOSED', 'DEMO_SCHEDULED', 'CONFIRMED'].includes(m.status) &&
      m.demoDate === date &&
      m.demoTimeSlot === timeSlot
    );
    if (clash) {
      return res.status(400).json({
        error: `This teacher already has ${matchDisplayId(clash)} booked on ${date} in the "${timeSlot}" slot. Pick a different date/slot or a different teacher.`,
      });
    }
  }

  match.status = 'DEMO_PROPOSED';
  match.demoDate = date;
  match.demoTimeSlot = timeSlot || null;
  match.demoProposedAt = new Date().toISOString();
  match.parentAcceptedDemo = false;
  match.teacherAcceptedDemo = false;
  db.save(data);
  res.json({ ...match, displayId: matchDisplayId(match) });
});

// PUT /matches/:id/accept-demo — parent OR teacher accepts. Both required -> DEMO_SCHEDULED.
router.put('/:id/accept-demo', requireAuth, requireRole('PARENT', 'TEACHER'), (req, res) => {
  const data = db.load();
  const match = findMatchByAnyId(data, req.params.id);
  if (!match) return res.status(404).json({ error: 'Match not found' });
  if (match.status !== 'DEMO_PROPOSED' && match.status !== 'DEMO_SCHEDULED') {
    return res.status(400).json({ error: `No demo awaiting response (status: ${match.status})` });
  }

  if (req.user.role === 'PARENT') {
    const requirement = data.requirements.find(r => r.id === match.requirementId);
    if (!requirement || requirement.parentId !== req.user.id) {
      return res.status(403).json({ error: 'Not your requirement' });
    }
    match.parentAcceptedDemo = true;
  } else {
    const ownTeacher = getOwnTeacherProfile(data, req.user.id);
    if (!ownTeacher || match.teacherId !== ownTeacher.id) {
      return res.status(403).json({ error: 'Not your match' });
    }
    match.teacherAcceptedDemo = true;
  }

  if (match.parentAcceptedDemo && match.teacherAcceptedDemo && match.status === 'DEMO_PROPOSED') {
    match.status = 'DEMO_SCHEDULED';
    match.scheduledAt = new Date().toISOString();
  }

  db.save(data);
  res.json({ ...match, displayId: matchDisplayId(match) });
});

// PUT /matches/:id/decline-demo — parent OR teacher declines. Freezes the display
// ID at its current stage and marks the match dead; it is never reused/reopened.
router.put('/:id/decline-demo', requireAuth, requireRole('PARENT', 'TEACHER'), (req, res) => {
  const data = db.load();
  const match = findMatchByAnyId(data, req.params.id);
  if (!match) return res.status(404).json({ error: 'Match not found' });
  if (!['DEMO_PROPOSED', 'DEMO_SCHEDULED'].includes(match.status)) {
    return res.status(400).json({ error: `No demo awaiting response (status: ${match.status})` });
  }

  if (req.user.role === 'PARENT') {
    const requirement = data.requirements.find(r => r.id === match.requirementId);
    if (!requirement || requirement.parentId !== req.user.id) {
      return res.status(403).json({ error: 'Not your requirement' });
    }
  } else {
    const ownTeacher = getOwnTeacherProfile(data, req.user.id);
    if (!ownTeacher || match.teacherId !== ownTeacher.id) {
      return res.status(403).json({ error: 'Not your match' });
    }
  }

  match.frozenDisplayId = matchDisplayId(match); // freeze BEFORE status flips
  match.status = 'DECLINED';
  match.dead = true;
  match.declinedBy = req.user.role;
  match.declineReason = req.body.reason || null;
  db.save(data);
  res.json({ ...match, displayId: matchDisplayId(match) });
});

// PUT /matches/:id/approve-teacher — parent's final approval AFTER the demo.
// This is what turns FMDEMO... into FMAPPROVED... — the real, ongoing assignment ID.
router.put('/:id/approve-teacher', requireAuth, requireRole('PARENT'), (req, res) => {
  const data = db.load();
  const match = findMatchByAnyId(data, req.params.id);
  if (!match) return res.status(404).json({ error: 'Match not found' });

  const requirement = data.requirements.find(r => r.id === match.requirementId);
  if (!requirement || requirement.parentId !== req.user.id) {
    return res.status(403).json({ error: 'Not your requirement' });
  }
  if (match.status !== 'DEMO_SCHEDULED') {
    return res.status(400).json({ error: `Cannot approve from status ${match.status} — demo must be scheduled first` });
  }

  match.status = 'CONFIRMED';
  match.parentApprovedAt = new Date().toISOString();
  db.save(data);
  const displayId = matchDisplayId(match);
  res.json({ ...match, displayId, note: `This is now your ongoing class ID: ${displayId} — use it to log/confirm sessions and for payouts.` });
});

module.exports = router;