// Section 4.3 — Attendance & Payout Ledger.
const express = require('express');
const crypto = require('crypto');
const db = require('../db');
const { matchDisplayId, nextDailyId } = require('../idgen');
const { requireAuth, requireRole } = require('../middleware/auth');

const router = express.Router();

function getOwnTeacherProfile(data, userId) {
  return data.teacherProfiles.find(t => t.userId === userId);
}
function findMatchByAnyId(data, idOrDisplayId) {
  return data.matches.find(m => m.id === idOrDisplayId || matchDisplayId(m) === idOrDisplayId);
}
function findTeacherByAnyId(data, idOrDisplayId) {
  return data.teacherProfiles.find(t => t.id === idOrDisplayId || t.displayId === idOrDisplayId);
}
function findSessionByAnyId(data, idOrDisplayId) {
  return data.sessions.find(s => s.id === idOrDisplayId || s.displayId === idOrDisplayId);
}

function deriveTrackingFields(session, data) {
  const parentApproval =
    session.status === 'LOGGED' ? 'PENDING' :
    session.status === 'DISPUTED' ? 'DISPUTED' :
    'APPROVED';
  const adminApproval =
    session.status === 'ADMIN_VALIDATED' ? 'APPROVED' : 'PENDING';

  let payout = null;
  if (session.payoutId) payout = data.payouts.find(p => p.id === session.payoutId) || null;

  return {
    parentApproval,
    adminApproval,
    paymentReleased: !!payout,
    payoutAmount: payout ? payout.amount : null,
    payoutCommissionPercent: payout ? payout.commissionPercent : null,
    payoutReleasedAt: payout ? payout.releasedAt : null,
  };
}

// POST /attendance/sessions — teacher logs a class taught. matchId accepts the
// internal id or the FMAPPROVED... display ID (the only valid stage to log against).
router.post('/sessions', requireAuth, requireRole('TEACHER'), (req, res) => {
  const { matchId, date, timeSlot, amount } = req.body;
  if (!matchId || !date) return res.status(400).json({ error: 'matchId and date are required' });

  const data = db.load();
  const match = findMatchByAnyId(data, matchId);
  if (!match) return res.status(404).json({ error: 'Match not found' });

  const ownTeacher = getOwnTeacherProfile(data, req.user.id);
  if (!ownTeacher || match.teacherId !== ownTeacher.id) {
    return res.status(403).json({ error: 'Not your match' });
  }
  if (match.status !== 'CONFIRMED') {
    return res.status(400).json({ error: 'Match must be CONFIRMED (an FMAPPROVED... ID) before logging classes' });
  }

  const session = {
    id: crypto.randomUUID(),
    displayId: nextDailyId(data, 'attendanceDaily', 'FMATTEND'),
    matchId: match.id,
    matchDisplayId: matchDisplayId(match),
    date,
    timeSlot: timeSlot || null,
    teacherMarkedAt: new Date().toISOString(),
    parentConfirmedAt: null,
    adminValidatedAt: null,
    status: 'LOGGED',
    amount: amount || null,
    payoutId: null,
  };
  data.sessions.push(session);
  db.save(data);
  res.status(201).json(session);
});

router.put('/sessions/:id/confirm', requireAuth, requireRole('PARENT'), (req, res) => {
  const data = db.load();
  const session = findSessionByAnyId(data, req.params.id);
  if (!session) return res.status(404).json({ error: 'Session not found' });

  const match = data.matches.find(m => m.id === session.matchId);
  const requirement = match && data.requirements.find(r => r.id === match.requirementId);
  if (!requirement || requirement.parentId !== req.user.id) {
    return res.status(403).json({ error: 'Not your class session' });
  }
  if (session.status !== 'LOGGED') {
    return res.status(400).json({ error: `Cannot confirm from status ${session.status}` });
  }

  session.status = 'PARENT_CONFIRMED';
  session.parentConfirmedAt = new Date().toISOString();
  db.save(data);
  res.json(session);
});

router.put('/sessions/:id/dispute', requireAuth, requireRole('PARENT'), (req, res) => {
  const data = db.load();
  const session = findSessionByAnyId(data, req.params.id);
  if (!session) return res.status(404).json({ error: 'Session not found' });

  const match = data.matches.find(m => m.id === session.matchId);
  const requirement = match && data.requirements.find(r => r.id === match.requirementId);
  if (!requirement || requirement.parentId !== req.user.id) {
    return res.status(403).json({ error: 'Not your class session' });
  }

  session.status = 'DISPUTED';
  session.disputedAt = new Date().toISOString();
  session.disputeReason = req.body.reason || null;
  db.save(data);
  res.json(session);
});

router.put('/sessions/:id/validate', requireAuth, requireRole('ADMIN'), (req, res) => {
  const data = db.load();
  const session = findSessionByAnyId(data, req.params.id);
  if (!session) return res.status(404).json({ error: 'Session not found' });
  if (session.status !== 'PARENT_CONFIRMED') {
    return res.status(400).json({ error: 'Session must be PARENT_CONFIRMED before admin validation' });
  }

  session.status = 'ADMIN_VALIDATED';
  session.adminValidatedAt = new Date().toISOString();
  db.save(data);
  res.json(session);
});

router.get('/sessions', requireAuth, (req, res) => {
  const data = db.load();
  const { matchId, status } = req.query;
  let sessions = data.sessions;

  if (matchId) sessions = sessions.filter(s => s.matchId === matchId);
  if (status) sessions = sessions.filter(s => s.status === status);

  if (req.user.role === 'PARENT') {
    const ownRequirementIds = new Set(
      data.requirements.filter(r => r.parentId === req.user.id).map(r => r.id)
    );
    const ownMatchIds = new Set(
      data.matches.filter(m => ownRequirementIds.has(m.requirementId)).map(m => m.id)
    );
    sessions = sessions.filter(s => ownMatchIds.has(s.matchId));
  } else if (req.user.role === 'TEACHER') {
    const ownTeacher = getOwnTeacherProfile(data, req.user.id);
    const ownMatchIds = new Set(
      data.matches.filter(m => ownTeacher && m.teacherId === ownTeacher.id).map(m => m.id)
    );
    sessions = sessions.filter(s => ownMatchIds.has(s.matchId));
  }

  const enriched = sessions.map(s => ({ ...s, ...deriveTrackingFields(s, data) }));
  res.json(enriched);
});

// POST /attendance/payouts — admin releases payout for a teacher's validated,
// not-yet-paid sessions. Requires the teacher to have bank/UPI details on file.
//
// Per the founder's design: since a CONFIRMED match (FMAPPROVED... ID) ties to
// exactly one teacher, you can pass `matchId` INSTEAD of `teacherId` and the
// teacher is resolved automatically from that match.
router.post('/payouts', requireAuth, requireRole('ADMIN'), (req, res) => {
  let { teacherId, matchId, period, commissionPercent } = req.body;
  const data = db.load();

  if (!teacherId && matchId) {
    const match = findMatchByAnyId(data, matchId);
    if (!match) return res.status(404).json({ error: 'Match not found for that ID' });
    teacherId = match.teacherId;
  }
  if (!teacherId) return res.status(400).json({ error: 'Provide teacherId, or a matchId (FMAPPROVED...) to resolve it automatically' });

  const teacher = findTeacherByAnyId(data, teacherId);
  if (!teacher) return res.status(404).json({ error: 'Teacher profile not found' });
  if (!teacher.bankUpiRef) {
    return res.status(400).json({ error: 'Teacher has no bank/UPI details on file — cannot release payout until they add one' });
  }

  const ownMatchIds = new Set(data.matches.filter(m => m.teacherId === teacher.id).map(m => m.id));
  const eligibleSessions = data.sessions.filter(
    s => ownMatchIds.has(s.matchId) && s.status === 'ADMIN_VALIDATED' && !s.payoutId
  );

  if (eligibleSessions.length === 0) {
    return res.status(400).json({ error: 'No validated, unpaid sessions for this teacher' });
  }

  const grossAmount = eligibleSessions.reduce((sum, s) => sum + (s.amount || 0), 0);
  const pct = commissionPercent || 0;
  const commissionDeducted = Math.round(grossAmount * (pct / 100));

  const payout = {
    id: crypto.randomUUID(),
    teacherId: teacher.id,
    teacherDisplayId: teacher.displayId,
    period: period || null,
    grossAmount,
    commissionPercent: pct,
    commissionDeducted,
    amount: grossAmount - commissionDeducted,
    bankUpiRef: teacher.bankUpiRef,
    status: 'RELEASED',
    releasedAt: new Date().toISOString(),
    sessionIds: eligibleSessions.map(s => s.id),
  };
  data.payouts.push(payout);
  eligibleSessions.forEach(s => { s.payoutId = payout.id; });

  db.save(data);
  res.status(201).json(payout);
});

router.get('/payouts', requireAuth, (req, res) => {
  const data = db.load();
  let payouts = data.payouts;

  if (req.user.role === 'TEACHER') {
    const ownTeacher = getOwnTeacherProfile(data, req.user.id);
    payouts = payouts.filter(p => ownTeacher && p.teacherId === ownTeacher.id);
  } else if (req.user.role !== 'ADMIN') {
    return res.status(403).json({ error: 'Not authorized' });
  }

  res.json(payouts);
});

module.exports = router;