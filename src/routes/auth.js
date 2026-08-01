const express = require('express');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const db = require('../db');
const { nextDailyId } = require('../idgen');
const { JWT_SECRET, requireAuth } = require('../middleware/auth');

const router = express.Router();

const otpStore = new Map();
const OTP_TTL_MS = 5 * 60 * 1000;

function normalizePhone(phone) {
  return String(phone || '').replace(/\D/g, '');
}

router.post('/request-otp', (req, res) => {
  const phone = normalizePhone(req.body.phone);
  if (phone.length < 10) return res.status(400).json({ error: 'Enter a valid phone number' });

  const code = String(Math.floor(100000 + Math.random() * 900000));
  otpStore.set(phone, { code, expiresAt: Date.now() + OTP_TTL_MS });

  console.log(`[DEV OTP] ${phone} -> ${code} (expires in 5 min)`);
  res.json({ ok: true, message: 'OTP sent', devHint: process.env.NODE_ENV !== 'production' ? code : undefined });
});

router.post('/verify-otp', (req, res) => {
  const phone = normalizePhone(req.body.phone);
  const { otp, name, role, email, consent } = req.body;

  const record = otpStore.get(phone);
  if (!record || record.code !== String(otp) || Date.now() > record.expiresAt) {
    return res.status(400).json({ error: 'Invalid or expired OTP' });
  }
  otpStore.delete(phone);

  const data = db.load();
  let user = data.users.find(u => u.phone === phone);

  if (!user) {
    if (!name || !role) {
      return res.status(400).json({ error: 'New account requires name and role (PARENT or TEACHER)' });
    }
    if (!consent) {
      return res.status(400).json({ error: 'Terms & Privacy consent is required' });
    }
    const finalRole = role === 'TEACHER' ? 'TEACHER' : 'PARENT';
    const displayId = finalRole === 'TEACHER'
      ? nextDailyId(data, 'teacherDaily', 'FMTEACH')
      : nextDailyId(data, 'parentDaily', 'FMPAR');

    user = {
      id: crypto.randomUUID(),
      displayId,
      role: finalRole,
      name,
      phone,
      email: email || null,
      consentAt: new Date().toISOString(),
      createdAt: new Date().toISOString(),
    };
    data.users.push(user);
    db.save(data);
  }

  const token = jwt.sign({ id: user.id, role: user.role, phone: user.phone }, JWT_SECRET, { expiresIn: '30d' });
  res.json({ ok: true, token, user: { id: user.id, displayId: user.displayId, name: user.name, role: user.role, phone: user.phone } });
});

router.get('/me', requireAuth, (req, res) => {
  const data = db.load();
  const user = data.users.find(u => u.id === req.user.id);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const { id, displayId, name, role, phone, email } = user;
  res.json({ id, displayId, name, role, phone, email });
});

module.exports = router;