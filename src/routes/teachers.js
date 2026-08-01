const express = require('express');
const crypto = require('crypto');
const db = require('../db');
const { requireAuth, requireRole } = require('../middleware/auth');

const router = express.Router();

router.put('/me', requireAuth, requireRole('TEACHER'), (req, res) => {
  const {
    qualification, experience, subjects, availability, timeSlot,
    rateExpectation, bankUpiRef, address, areaCity, pincode, whatsapp,
  } = req.body;

  const data = db.load();
  const user = data.users.find(u => u.id === req.user.id);
  let profile = data.teacherProfiles.find(t => t.userId === req.user.id);

  const updated = {
    qualification: qualification || null,
    experience: experience || null,
    subjects: subjects || [],
    // "availability" is stored as an array for future multi-slot support; a
    // single dropdown pick from the UI is sent as [timeSlot].
    availability: availability || (timeSlot ? [timeSlot] : []),
    rateExpectation: rateExpectation || null,
    bankUpiRef: bankUpiRef || null,
    address: address || null,
    areaCity: areaCity || null,
    pincode: pincode || null,
    whatsapp: whatsapp || null,
  };

  if (profile) {
    Object.entries(updated).forEach(([key, val]) => {
      if (val !== null && val !== undefined && !(Array.isArray(val) && val.length === 0)) {
        profile[key] = val;
      }
    });
    if (!profile.displayId && user) profile.displayId = user.displayId;
  } else {
    profile = {
      id: crypto.randomUUID(),
      displayId: user ? user.displayId : null, // same FMTEACH... ID issued at signup
      userId: req.user.id,
      kycStatus: 'PENDING',
      rating: null,
      ...updated,
    };
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