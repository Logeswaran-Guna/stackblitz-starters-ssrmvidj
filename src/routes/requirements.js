const express = require('express');
const crypto = require('crypto');
const db = require('../db');
const { requireAuth, requireRole } = require('../middleware/auth');

const router = express.Router();

router.post('/', requireAuth, requireRole('PARENT'), (req, res) => {
  const { subject, mode, location, schedulePref, pricingType, budget, student, consent } = req.body;

  if (!consent) return res.status(400).json({ error: 'Consent to be contacted is required' });
  if (!subject || !mode) return res.status(400).json({ error: 'Subject and mode are required' });

  const data = db.load();
  const requirement = {
    id: crypto.randomUUID(),
    parentId: req.user.id,
    subject, mode,
    location: location || null,
    schedulePref: schedulePref || null,
    pricingType: pricingType || null,
    budget: budget || null,
    status: 'open',
    createdAt: new Date().toISOString(),
  };
  data.requirements.push(requirement);

  if (student && (student.studentName || student.ageGrade)) {
    data.studentProfiles.push({
      id: crypto.randomUUID(),
      parentId: req.user.id,
      studentName: student.studentName || null,
      ageGrade: student.ageGrade || null,
      gender: student.gender || null,
      notes: student.notes || null,
    });
  }

  db.save(data);
  res.status(201).json(requirement);
});

router.get('/', requireAuth, requireRole('ADMIN'), (req, res) => {
  const data = db.load();
  const withParent = data.requirements
    .slice()
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
    .map(r => {
      const parent = data.users.find(u => u.id === r.parentId);
      return { ...r, parentName: parent?.name, parentPhone: parent?.phone };
    });
  res.json(withParent);
});

module.exports = router;
