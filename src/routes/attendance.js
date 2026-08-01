// Section 4.3 — Attendance & Payout Ledger. The platform's core trust
// mechanism: Class conducted -> Teacher marks attendance -> Parent confirms
// -> Future Minds validates -> Payout released.
const express = require('express');
const crypto = require('crypto');
const db = require('../db');
const { requireAuth, requireRole } = require('../middleware/auth');

const router = express.Router();

function getOwnTeacherProfile(data, userId) {
  return data.teacherProfiles.find(t => t.userId === userId);
}

// POST /attendance/sessions — teacher logs a class taught against a CONFIRMED match
router.post('/sessions', requireAuth, requireRole('TEACHER'), (req, res) => {
  const { matchId, date, timeSlot, amount } = req.body;
  if (!matchId || !date) return res.status(400).json({ error: 'matchId and date are required' });

  const data = db.load();
  const match = data.matches.find(m => m.id === matchId);
  if (!match) return res.status(404).json({ error: 'Match not found' });

  const ownTeacher = getOwnTeacherProfile(data, req.user.id);
  if (!ownTeacher || match.teacherId !== ownTeacher.id) {
    return res.status(403).json({ error: 'Not your match' });
  }
  if (match.status !== 'CONFIRMED') {
    return res.status(400).json({ error: 'Match must be CONFIRMED before logging classes' });
  }

  const session = {
    id: crypto.randomUUID(),
    matchId,
    date,
    timeSlot: timeSlot || null,
    teacherMarkedAt: new Date().toISOString(),
    parentConfirmedAt: null,
    adminValidatedAt: null,
    status: 'LOGGED', // LOGGED -> PARENT_CONFIRMED -> ADMIN_VALIDATED (or DISPUTED)
    amount: amount || null,
    payoutId: null,
  };
  data.sessions.push(session);
  db.save(data);
  res.status(201).json(session);
});

// PUT /attendance/sessions/:id/confirm — parent confirms the class actually happened
router.put('/sessions/:id/confirm', requireAuth, requireRole('PARENT'), (req, res) => {
  const data = db.load();
  const session = data.sessions.find(s => s.id === req.params.id);
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

// PUT /attendance/sessions/:id/dispute — parent flags a discrepancy instead of confirming
router.put('/sessions/:id/dispute', requireAuth, requireRole('PARENT'), (req, res) => {
  const data = db.load();
  const session = data.sessions.find(s => s.id === req.params.id);
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

// PUT /attendance/sessions/:id/validate — admin validates a parent-confirmed session
// (this is what makes it eligible for payout)
router.put('/sessions/:id/validate', requireAuth, requireRole('ADMIN'), (req, res) => {
  const data = db.load();
  const session = data.sessions.find(s => s.id === req.params.id);
  if (!session) return res.status(404).json({ error: 'Session not found' });
  if (session.status !== 'PARENT_CONFIRMED') {
    return res.status(400).json({ error: 'Session must be PARENT_CONFIRMED before admin validation' });
  }

  session.status = 'ADMIN_VALIDATED';
  session.adminValidatedAt = new Date().toISOString();
  db.save(data);
  res.json(session);
});

// GET /attendance/sessions?matchId=... — role-scoped visibility
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

  res.json(sessions);
});

// POST /attendance/payouts — admin releases payout for a teacher's validated,
// not-yet-paid sessions
router.post('/payouts', requireAuth, requireRole('ADMIN'), (req, res) => {
  const { teacherId, period, commissionPercent } = req.body;
  if (!teacherId) return res.status(400).json({ error: 'teacherId is required' });

  const data = db.load();
  const teacher = data.teacherProfiles.find(t => t.id === teacherId);
  if (!teacher) return res.status(404).json({ error: 'Teacher profile not found' });

  const ownMatchIds = new Set(data.matches.filter(m => m.teacherId === teacherId).map(m => m.id));
  const eligibleSessions = data.sessions.filter(
    s => ownMatchIds.has(s.matchId) && s.status === 'ADMIN_VALIDATED' && !s.payoutId
  );

  if (eligibleSessions.length === 0) {
    return res.status(400).json({ error: 'No validated, unpaid sessions for this teacher' });
  }

  const grossAmount = eligibleSessions.reduce((sum, s) => sum + (s.amount || 0), 0);
  const commissionDeducted = commissionPercent
    ? Math.round(grossAmount * (commissionPercent / 100))
    : 0;

  const payout = {
    id: crypto.randomUUID(),
    teacherId,
    period: period || null,
    amount: grossAmount - commissionDeducted,
    commissionDeducted,
    status: 'RELEASED',
    releasedAt: new Date().toISOString(),
    sessionIds: eligibleSessions.map(s => s.id),
  };
  data.payouts.push(payout);

  eligibleSessions.forEach(s => { s.payoutId = payout.id; });

  db.save(data);
  res.status(201).json(payout);
});

// GET /attendance/payouts — admin sees all; teacher sees their own
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
