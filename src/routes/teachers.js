const express = require('express');
const crypto = require('crypto');
const db = require('../db');
const { requireAuth, requireRole } = require('../middleware/auth');
const router = express.Router();
router.put('/me', requireAuth, requireRole('TEACHER'), (req, res) => {
  const { qualification, experience, subjects, serviceArea, availability, rateExpectation, bankUpiRef } = req.body;
  const existing = db.prepare('SELECT id FROM teacher_profiles WHERE user_id = ?').get(req.user.id);
  if (existing) {
    db.prepare(`UPDATE teacher_profiles SET qualification=?, experience=?, subjects=?, service_area=?, availability=?, rate_expectation=?, bank_upi_ref=? WHERE user_id = ?`).run(qualification || null, experience || null, JSON.stringify(subjects || []), serviceArea || null, JSON.stringify(availability || []), rateExpectation || null, bankUpiRef || null, req.user.id);
  } else {
    db.prepare(`INSERT INTO teacher_profiles (id, user_id, qualification, experience, subjects, service_area, availability, rate_expectation, bank_upi_ref) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(crypto.randomUUID(), req.user.id, qualification || null, experience || null, JSON.stringify(subjects || []), serviceArea || null, JSON.stringify(availability || []), rateExpectation || null, bankUpiRef || null);
  }
  const profile = db.prepare('SELECT * FROM teacher_profiles WHERE user_id = ?').get(req.user.id);
  res.json(profile);
});
router.get('/', requireAuth, requireRole('ADMIN'), (req, res) => {
  const teachers = db.prepare(`SELECT t.*, u.name, u.phone, u.email FROM teacher_profiles t JOIN users u ON u.id = t.user_id`).all();
  const { subject } = req.query;
  const filtered = subject ? teachers.filter(t => JSON.parse(t.subjects || '[]').includes(subject)) : teachers;
  res.json(filtered);
});
module.exports = router;
