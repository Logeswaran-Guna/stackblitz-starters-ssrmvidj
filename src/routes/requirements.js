const express = require('express');
const crypto = require('crypto');
const db = require('../db');
const { nextDailyId } = require('../idgen');
const { requireAuth, requireRole } = require('../middleware/auth');

const router = express.Router();

function findOwnStudent(data, idOrDisplayId, parentId) {
  return data.studentProfiles.find(
    s => (s.id === idOrDisplayId || s.displayId === idOrDisplayId) && s.parentId === parentId
  );
}

// POST /requirements — the "Get Matched" form + Student Details section (Section 4.1).
// Every submission (one per subject) gets its own FMREQ... display ID, so a
// student enrolling in Maths + Science + Dance ends up with 3 FMREQ IDs, all
// pointing back to the same FMSTU... student.
// Supports multiple enrollments per student: pass an existing student.studentId
// (accepts either the internal id or the FMSTU... display ID) to enroll the SAME
// child in another subject.
router.post('/', requireAuth, requireRole('PARENT'), (req, res) => {
  const { subject, mode, location, schedulePref, pricingType, budget, student, consent } = req.body;

  if (!consent) return res.status(400).json({ error: 'Consent to be contacted is required' });
  if (!subject || !mode) return res.status(400).json({ error: 'Subject and mode are required' });

  const data = db.load();
  let studentProfileId = null;
  let studentDisplayId = null;

  if (student && student.studentId) {
    const existing = findOwnStudent(data, student.studentId, req.user.id);
    if (!existing) return res.status(404).json({ error: 'Student not found for your account' });
    studentProfileId = existing.id;
    studentDisplayId = existing.displayId;
    if (student.address) existing.address = student.address;
    if (student.areaCity) existing.areaCity = student.areaCity;
    if (student.pincode) existing.pincode = student.pincode;
    if (student.whatsapp) existing.whatsapp = student.whatsapp;
  } else if (student && (student.studentName || student.ageGrade)) {
    const existingCount = data.studentProfiles.filter(s => s.parentId === req.user.id).length;
    if (existingCount >= 4) {
      return res.status(400).json({ error: 'You can register up to 4 students per parent account. To add a subject for an existing student instead, pass their Student ID.' });
    }
    const newStudent = {
      id: crypto.randomUUID(),
      displayId: nextDailyId(data, 'studentDaily', 'FMSTU'),
      parentId: req.user.id,
      studentName: student.studentName || null,
      ageGrade: student.ageGrade || null,
      age: student.age || null,
      gender: student.gender || null,
      address: student.address || null,
      areaCity: student.areaCity || null,
      pincode: student.pincode || null,
      whatsapp: student.whatsapp || null,
      notes: student.notes || null,
    };
    data.studentProfiles.push(newStudent);
    studentProfileId = newStudent.id;
    studentDisplayId = newStudent.displayId;
  }

  const requirement = {
    id: crypto.randomUUID(),
    displayId: nextDailyId(data, 'requirementDaily', 'FMREQ'),
    parentId: req.user.id,
    studentProfileId,
    subject, mode,
    location: location || null,
    schedulePref: schedulePref || null,
    pricingType: pricingType || null,
    budget: budget || null,
    status: 'open',
    createdAt: new Date().toISOString(),
  };
  data.requirements.push(requirement);

  db.save(data);
  res.status(201).json({ ...requirement, studentProfileId, studentDisplayId });
});

// GET /requirements — admin queue (Section 4.6)
router.get('/', requireAuth, requireRole('ADMIN'), (req, res) => {
  const data = db.load();
  const withParent = data.requirements
    .slice()
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
    .map(r => {
      const parent = data.users.find(u => u.id === r.parentId);
      const student = data.studentProfiles.find(s => s.id === r.studentProfileId);
      return {
        ...r,
        parentDisplayId: parent?.displayId,
        parentName: parent?.name,
        parentPhone: parent?.phone,
        studentDisplayId: student?.displayId,
        studentName: student?.studentName,
      };
    });
  res.json(withParent);
});

// GET /requirements/mine — parent's own requirements (one row per subject).
// Once a teacher is assigned, this also surfaces the teacher's name/ID/mobile,
// the class/grade, subject, time slot, and training mode — not just "open".
router.get('/mine', requireAuth, requireRole('PARENT'), (req, res) => {
  const data = db.load();
  const mine = data.requirements
    .filter(r => r.parentId === req.user.id)
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
    .map(r => {
      const student = data.studentProfiles.find(s => s.id === r.studentProfileId);

      // Prefer a CONFIRMED match; otherwise the most recent still-live match; else none.
      const relatedMatches = data.matches.filter(m => m.requirementId === r.id);
      const match = relatedMatches.find(m => m.status === 'CONFIRMED')
        || relatedMatches.filter(m => m.status !== 'DECLINED').sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))[0]
        || null;

      let teacher = null, teacherUser = null;
      if (match) {
        teacher = data.teacherProfiles.find(t => t.id === match.teacherId);
        teacherUser = teacher && data.users.find(u => u.id === teacher.userId);
      }

      return {
        ...r,
        studentDisplayId: student?.displayId,
        studentName: student?.studentName,
        studentGrade: student?.ageGrade,
        matchStatus: match ? match.status : null, // null = no match created yet
        teacherDisplayId: teacher?.displayId || null,
        teacherName: teacherUser?.name || null,
        teacherPhone: teacherUser?.phone || null,
        timeSlot: match?.demoTimeSlot || r.schedulePref || null,
      };
    });
  res.json(mine);
});

// GET /requirements/my-students — parent's list of their own children/students.
router.get('/my-students', requireAuth, requireRole('PARENT'), (req, res) => {
  const data = db.load();
  const students = data.studentProfiles.filter(s => s.parentId === req.user.id);
  res.json(students);
});

module.exports = router;