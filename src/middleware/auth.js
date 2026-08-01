const jwt = require('jsonwebtoken');
const JWT_SECRET = process.env.JWT_SECRET || 'dev-secret-change-me';
function requireAuth(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'Missing or invalid Authorization header' });
  try { req.user = jwt.verify(token, JWT_SECRET); next(); }
  catch (err) { return res.status(401).json({ error: 'Invalid or expired token' }); }
}
function requireRole(...allowedRoles) {
  return (req, res, next) => {
    if (!req.user) return res.status(401).json({ error: 'Not authenticated' });
    if (!allowedRoles.includes(req.user.role)) return res.status(403).json({ error: 'Not authorized for this action' });
    next();
  };
}
module.exports = { requireAuth, requireRole, JWT_SECRET };
