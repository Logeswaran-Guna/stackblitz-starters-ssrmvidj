require('dotenv').config();
const express = require('express');
const cors = require('cors');
const path = require('path');

const app = express();
app.use(cors());
app.use(express.json());

// Dev-only browser test console — click through the flow instead of curl.
app.get('/test', (req, res) => res.sendFile(path.join(__dirname, '..', 'public', 'test.html')));

app.get('/', (req, res) => res.json({
  ok: true,
  service: 'future-minds-backend',
  routes: [
    'GET  /health',
    'POST /auth/request-otp',
    'POST /auth/verify-otp',
    'GET  /auth/me',
    'POST /requirements',
    'GET  /requirements',
    'GET  /requirements/my-students',
    'PUT  /teachers/me',
    'GET  /teachers',
    'POST /matches',
    'GET  /matches',
    'PUT  /matches/:id/propose-demo',
    'PUT  /matches/:id/accept-demo',
    'PUT  /matches/:id/decline-demo',
    'PUT  /matches/:id/approve-teacher',
    'POST /attendance/sessions',
    'GET  /attendance/sessions',
    'PUT  /attendance/sessions/:id/confirm',
    'PUT  /attendance/sessions/:id/dispute',
    'PUT  /attendance/sessions/:id/validate',
    'POST /attendance/payouts',
    'GET  /attendance/payouts',
    'GET  /assignments',
    'GET  /test  (browser test console)',
  ],
}));
app.get('/health', (req, res) => res.json({ ok: true, service: 'future-minds-backend' }));

app.use('/auth', require('./routes/auth'));
app.use('/requirements', require('./routes/requirements'));
app.use('/teachers', require('./routes/teachers'));
app.use('/matches', require('./routes/matches'));
app.use('/attendance', require('./routes/attendance'));
app.use('/assignments', require('./routes/assignments'));

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => console.log(`Future Minds backend running on http://localhost:${PORT}`));