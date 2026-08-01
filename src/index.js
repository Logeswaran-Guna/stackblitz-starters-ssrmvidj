require('dotenv').config();
const express = require('express');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

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
    'PUT  /teachers/me',
    'GET  /teachers',
    'POST /matches',
    'GET  /matches',
    'PUT  /matches/:id/book-demo',
    'PUT  /matches/:id/confirm',
    'PUT  /matches/:id/decline',
    'POST /attendance/sessions',
    'GET  /attendance/sessions',
    'PUT  /attendance/sessions/:id/confirm',
    'PUT  /attendance/sessions/:id/dispute',
    'PUT  /attendance/sessions/:id/validate',
    'POST /attendance/payouts',
    'GET  /attendance/payouts',
  ],
}));
app.get('/health', (req, res) => res.json({ ok: true, service: 'future-minds-backend' }));

app.use('/auth', require('./routes/auth'));
app.use('/requirements', require('./routes/requirements'));
app.use('/teachers', require('./routes/teachers'));
app.use('/matches', require('./routes/matches'));
app.use('/attendance', require('./routes/attendance'));

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => console.log(`Future Minds backend running on http://localhost:${PORT}`));
