// Section 4.2 — Matches & Demo Booking.
// Admin manually shortlists teachers against a requirement (per the Business
// Case's "managed matching" model — not an automated algorithm at launch).
const express = require('express');
const crypto = require('crypto');
const db = require('../db');
const { requireAuth, requireRole } = require('../middleware/auth');

const router = express.Router();

// POST /matches — admin shortlists a teacher for a requirement
router.post('/', requireAuth, requireRole('ADMIN'), (req, res) => {
  const { requirementId, teacherId, matchScore } = req.body;
  if (!requirementId || !teacherId) {
    return res.status(400).json({ error: 'requirementId and teacherId are required' });
  }

  const data = db.load();
  const requirement = data.requirements.find(r => r.id === requirementId);
  const teacher = data.teacherProfiles.find(t => t.id === teacherId);
  if (!requirement) return res.status(404).json({ error: 'Requirement not found' });
  if (!teacher) return res.status(404).json({ error: 'Teacher profile not found' });

  const match = {
    id: crypto.randomUUID(),
    requirementId,
    teacherId,
    matchScore: matchScore ?? null,
    status: 'PROPOSED', // PROPOSED -> DEMO_BOOKED -> CONFIRMED | DECLINED
    createdAt: new Date().toISOString(),
  };
  data.matches.push(match);
  db.save(data);
  res.status(201).json(match);
});

// GET /matches?requirementId=... — parent sees matches for their own requirement;
// admin can see any; teacher sees matches proposing them.
router.get('/', requireAuth, (req, res) => {
  const data = db.load();
  const { requirementId } = req.query;

  let matches = data.matches;

  if (requirementId) matches = matches.filter(m => m.requirementId === requirementId);

  if (req.user.role === 'PARENT') {
    const ownRequirementIds = new Set(
      data.requirements.filter(r => r.parentId === req.user.id).map(r => r.id)
    );
    matches = matches.filter(m => ownRequirementIds.has(m.requirementId));
  } else if (req.user.role === 'TEACHER') {
    const ownTeacherProfile = data.teacherProfiles.find(t => t.userId === req.user.id);
    matches = matches.filter(m => ownTeacherProfile && m.teacherId === ownTeacherProfile.id);
  }
  // ADMIN sees everything (optionally filtered by requirementId above)

  const enriched = matches.map(m => {
    const teacher = data.teacherProfiles.find(t => t.id === m.teacherId);
    const teacherUser = teacher && data.users.find(u => u.id === teacher.userId);
    return { ...m, teacherName: teacherUser?.name, teacherSubjects: teacher?.subjects };
  });

  res.json(enriched);
});

// PUT /matches/:id/book-demo — parent books a demo with a proposed teacher
router.put('/:id/book-demo', requireAuth, requireRole('PARENT'), (req, res) => {
  const data = db.load();
  const match = data.matches.find(m => m.id === req.params.id);
  if (!match) return res.status(404).json({ error: 'Match not found' });

  const requirement = data.requirements.find(r => r.id === match.requirementId);
  if (!requirement || requirement.parentId !== req.user.id) {
    return res.status(403).json({ error: 'Not your requirement' });
  }
  if (match.status !== 'PROPOSED') {
    return res.status(400).json({ error: `Cannot book demo from status ${match.status}` });
  }

  match.status = 'DEMO_BOOKED';
  match.demoBookedAt = new Date().toISOString();
  db.save(data);
  res.json(match);
});

// PUT /matches/:id/confirm — admin confirms the match after a successful demo
router.put('/:id/confirm', requireAuth, requireRole('ADMIN'), (req, res) => {
  const data = db.load();
  const match = data.matches.find(m => m.id === req.params.id);
  if (!match) return res.status(404).json({ error: 'Match not found' });

  match.status = 'CONFIRMED';
  match.confirmedAt = new Date().toISOString();
  db.save(data);
  res.json(match);
});

// PUT /matches/:id/decline — admin or parent declines a proposed/demo-booked match
router.put('/:id/decline', requireAuth, requireRole('ADMIN', 'PARENT'), (req, res) => {
  const data = db.load();
  const match = data.matches.find(m => m.id === req.params.id);
  if (!match) return res.status(404).json({ error: 'Match not found' });

  if (req.user.role === 'PARENT') {
    const requirement = data.requirements.find(r => r.id === match.requirementId);
    if (!requirement || requirement.parentId !== req.user.id) {
      return res.status(403).json({ error: 'Not your requirement' });
    }
  }

  match.status = 'DECLINED';
  match.declinedAt = new Date().toISOString();
  db.save(data);
  res.json(match);
});

module.exports = router;
