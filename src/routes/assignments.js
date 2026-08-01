// Role-scoped view of every CONFIRMED match (FMAPPROVED... assignment) with
// the columns: Unique ID, Name, Class, Subject, Address, Time-Slot, Fees.
const express = require('express');
const db = require('../db');
const { matchDisplayId } = require('../idgen');
const { requireAuth } = require('../middleware/auth');

const router = express.Router();

function getOwnTeacherProfile(data, userId) {
  return data.teacherProfiles.find(t => t.userId === userId);
}

router.get('/', requireAuth, (req, res) => {
  const data = db.load();
  let matches = data.matches.filter(m => m.status === 'CONFIRMED');

  if (req.user.role === 'PARENT') {
    const ownRequirementIds = new Set(
      data.requirements.filter(r => r.parentId === req.user.id).map(r => r.id)
    );
    matches = matches.filter(m => ownRequirementIds.has(m.requirementId));
  } else if (req.user.role === 'TEACHER') {
    const ownTeacher = getOwnTeacherProfile(data, req.user.id);
    matches = matches.filter(m => ownTeacher && m.teacherId === ownTeacher.id);
  }

  const rows = matches.map(m => {
    const requirement = data.requirements.find(r => r.id === m.requirementId);
    const student = requirement && data.studentProfiles.find(s => s.id === requirement.studentProfileId);
    const teacher = data.teacherProfiles.find(t => t.id === m.teacherId);
    const teacherUser = teacher && data.users.find(u => u.id === teacher.userId);

    return {
      id: m.id,
      displayId: matchDisplayId(m), // FMAPPROVED26-00001
      studentName: student?.studentName || '—',
      class: student?.ageGrade || '—',
      subject: requirement?.subject || '—',
      address: student?.address || requirement?.location || teacher?.address || '—',
      areaCity: student?.areaCity || teacher?.areaCity || '—',
      timeSlot: m.demoTimeSlot || requirement?.schedulePref || '—',
      fees: requirement?.budget ?? '—',
      teacherName: teacherUser?.name || '—',
      teacherDisplayId: teacher?.displayId,
      parentApprovedAt: m.parentApprovedAt,
    };
  });

  res.json(rows);
});

module.exports = router;