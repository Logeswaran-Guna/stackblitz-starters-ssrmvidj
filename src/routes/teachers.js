const express = require('express');
const crypto = require('crypto');
const db = require('../db');
const { requireAuth, requireRole } = require('../middleware/auth');

const router = express.Router();

router.put('/me', requireAuth, requireRole('TEACHER'), (req, res) => {
  const { qualification, experience, subjects, serviceArea, availability, rateExpectation, bankUpiRef } = req.body;

  const data = db.load();
  let profile = data.teacherProfiles.find(t => t.userId === req.user.id);

  const updated = {
    qualification: qualification || null,
    experience: experience || null,
    subjects: subjects || [],
    serviceArea: serviceArea || null,
    availability: availability || [],
    rateExpectation: rateExpectation || null,
    bankUpiRef: bankUpiRef || null,
  };

  if (profile) {
    Object.assign(profile, updated);
  } else {
    profile = { id: crypto.randomUUID(), userId: req.user.id, kycStatus: 'PENDING', rating: null, ...updated };
    data.teacherProfiles.push(profile);
  }

  db.save(data);
  res.json(profile);
});

router.get('/', requireAuth, requireRole('ADMIN'), (req, res) => {
  const data = db.load();
  const { subject } = req.query;
  const teachers = data.teacherProfiles
    .map(t => {
      const user = data.users.find(u => u.id === t.userId);
      return { ...t, name: user?.name, phone: user?.phone, email: user?.email };
    })
    .filter(t => !subject || (t.subjects || []).includes(subject));
  res.json(teachers);
});

module.exports = router;
