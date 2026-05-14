const dotenv = require('dotenv');
dotenv.config({ path: './.env' });

const express = require('express');
const mongoose = require('mongoose');
const path = require('path');
const morgan = require('morgan');
const cookieParser = require('cookie-parser');
const WebSocket = require('ws');
const fs = require('fs');
const nodemailer = require('nodemailer');
const { GoogleGenerativeAI } = require("@google/generative-ai");
const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');

// --- GEMINI MULTI-KEY ROTATION LOGIC ---
const apiKeys = (process.env.GEMINI_API_KEYS || process.env.GEMINI_API_KEY || "").split(',').filter(k => k.trim());
let currentKeyIndex = 0;

function getNextModel(modelName = "gemini-3.1-flash-lite-preview") {
    const key = apiKeys[currentKeyIndex];
    const genAI = new GoogleGenerativeAI(key);
    return genAI.getGenerativeModel({ model: modelName });
}

async function safeGenerateContent(prompt, modelName = "gemini-3.1-flash-lite-preview", imageConfig = null) {
    let lastError;
    const maxTries = apiKeys.length;

    for (let i = 0; i < maxTries; i++) {
        try {
            const model = getNextModel(modelName);
            const content = imageConfig ? [prompt, imageConfig] : prompt;
            const result = await model.generateContent(content);
            const response = await result.response;
            return response.text();
        } catch (error) {
            lastError = error;
            console.error(`[AI] Error with Key ${currentKeyIndex + 1}:`, error.message);

            // Rotate if forbidden (leaked) or too many requests
            if (error.status === 403 || error.status === 429) {
                console.log(`[AI] Rotating to next API key...`);
                currentKeyIndex = (currentKeyIndex + 1) % apiKeys.length;
            } else {
                throw error; // Other errors should be handled by caller
            }
        }
    }
    throw lastError;
}


const app = express();
const server = require('http').createServer(app);
const wss = new WebSocket.Server({ server });

// Live Stream In-Memory Storage (Multiple Zones)
let zones = {
    "Chennai Unit 1": null,
    "Chennai Unit 2": null,
    "Global Unit 1": null,
    "Global Unit 2": null
};

// WebSocket Broadcast Logic
wss.on('connection', (ws) => {
    console.log('[WS] New Client Connected');
    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);
            if (data.type === 'stream') {
                zones[data.zone] = data.image;
                // Broadcast to all clients
                wss.clients.forEach((client) => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(JSON.stringify({ type: 'stream', zone: data.zone, image: data.image }));
                    }
                });
            }
        } catch (e) { }
    });
});

// --- MIDDLEWARES ---
// --- REQUEST LOGGER ---
app.use((req, res, next) => {
    console.log(`[${new Date().toLocaleTimeString()}] ${req.method} ${req.url}`);
    next();
});

app.use(express.json({ limit: '100mb' }));
app.use(express.urlencoded({ extended: true, limit: '100mb' }));
app.use(morgan('dev'));
app.use(cookieParser());

// --- ROOT ENTRY POINT (MUST BE BEFORE STATIC) ---
app.get('/', (req, res) => {
    res.redirect('/login.html');
});

app.use(express.static(path.join(__dirname), { index: false }));

// --- HEALTH CHECK ---
app.get('/api/health', (req, res) => {
    res.status(200).json({ status: 'ok', time: new Date().toISOString() });
});

// --- HTTP BACKUP ROUTES ---
app.post('/v1/camera', (req, res) => {
    const { zone, image } = req.body;
    zones[zone] = image;
    
    // Broadcast to all WebSocket clients (like index.html)
    const msg = JSON.stringify({ type: 'stream', zone, image });
    wss.clients.forEach((client) => {
        if (client.readyState === WebSocket.OPEN) {
            client.send(msg);
        }
    });
    
    res.status(200).json({ status: 'success' });
});
app.get('/v1/camera', (req, res) => {
    res.status(200).json({ status: 'success', zones });
});

// --- MODELS ---
const defectSchema = new mongoose.Schema({
    image: String,
    message: String,
    zone: { type: String, default: "Chennai Unit 1" },
    timestamp: { type: Date, default: Date.now }
});
const Defect = mongoose.model('Defect', defectSchema);

const userSchema = new mongoose.Schema({
    username: { type: String, required: true, unique: true },
    password: { type: String, required: true }
});
const User = mongoose.model('User', userSchema);

// --- AUTH MIDDLEWARE ---
const protect = async (req, res, next) => {
    try {
        const token = req.cookies.jwt;
        if (!token) return res.status(401).redirect('/login.html');

        const decoded = jwt.verify(token, process.env.JWT_SECRET || 'secret');
        const user = await User.findById(decoded.id);
        if (!user) return res.status(401).redirect('/login.html');

        req.user = user;
        next();
    } catch (err) {
        res.status(401).redirect('/login.html');
    }
};

// --- AUTH ROUTES ---
app.post('/api/auth/login', async (req, res) => {
    console.log(`[AUTH] Login attempt for user: ${req.body.username}`);
    const { username, password } = req.body;
    const user = await User.findOne({ username });
    if (!user || !(await bcrypt.compare(password, user.password))) {
        console.log(`[AUTH] Login failed for user: ${username}`);
        return res.status(401).json({ status: 'fail', message: 'Invalid credentials' });
    }

    const token = jwt.sign({ id: user._id }, process.env.JWT_SECRET || 'secret', { expiresIn: '7d' });
    res.cookie('jwt', token, { 
        httpOnly: true, 
        secure: process.env.NODE_ENV === 'production',
        sameSite: 'lax'
    });
    
    // Role-based redirection
    let redirectUrl = '/dashboard.html';
    if (username === 'inspect') redirectUrl = '/test.html';
    
    console.log(`[AUTH] Login successful for user: ${username}, redirecting to ${redirectUrl}`);
    res.status(200).json({ status: 'success', redirectUrl });
});

app.get('/logout', (req, res) => {
    res.clearCookie('jwt');
    res.redirect('/login.html');
});

// --- AI INSPECTION PROXY (SECURE & ROTATING) ---
app.post('/api/ai/inspect', async (req, res) => {
    try {
        const { image, prompt } = req.body;
        if (!image) return res.status(400).json({ status: 'fail', message: 'No image provided' });

        const base64Data = image.includes(',') ? image.split(',')[1] : image;
        const text = await safeGenerateContent(
            prompt || "Perform Industrial Quality Check",
            "gemini-3.1-flash-lite-preview",
            { inlineData: { mimeType: "image/jpeg", data: base64Data } }
        );

        res.status(200).json({ status: 'success', result: text });
    } catch (err) {
        console.error("AI Inspection Error:", err);
        res.status(500).json({ status: 'fail', message: "AI analysis failed after multiple attempts" });
    }
});



app.post('/api/defects', async (req, res) => {
    try {
        const { image, message, zone } = req.body;
        const newDefect = await Defect.create({ image, message, zone });
        wss.clients.forEach((client) => {
            if (client.readyState === WebSocket.OPEN) {
                client.send(JSON.stringify({ type: 'defect', data: newDefect }));
            }
        });
        res.status(201).json({ status: 'success', data: newDefect });
    } catch (err) { res.status(400).json({ status: 'fail' }); }
});

app.get('/api/defects', async (req, res) => {
    const defects = await Defect.find().sort('-timestamp');
    res.status(200).json({ status: 'success', data: defects });
});

// --- ENTERPRISE ANALYTICS ---
app.get('/api/analytics', async (req, res) => {
    try {
        const lastHour = new Date(Date.now() - 60 * 60 * 1000);
        const defectCount = await Defect.countDocuments({ timestamp: { $gte: lastHour } });
        const maintenanceRequired = defectCount > 10;
        const status = maintenanceRequired ? "MAINTENANCE_REQUIRED" : "SYSTEM_HEALTHY";
        
        res.status(200).json({
            status: 'success',
            hourlyDefectRate: defectCount,
            maintenanceStatus: status,
            performanceIndex: Math.max(0, 100 - (defectCount * 5))
        });
    } catch (err) { res.status(500).json({ status: 'fail' }); }
});

// --- AI NEURAL INSIGHTS (ROTATING) ---
app.get('/api/analytics/insights', async (req, res) => {
    try {
        const recentDefects = await Defect.find().sort('-timestamp').limit(15);
        if (recentDefects.length === 0) {
            return res.json({ status: 'success', insight: "No recent incidents. System operating at peak efficiency." });
        }

        const defectLog = recentDefects.map(d => `- ${d.zone}: ${d.message} at ${new Date(d.timestamp).toLocaleTimeString()}`).join('\n');
        const prompt = `You are the QualiSight Industrial AI Brain. Analyze these recent defect logs from our pen manufacturing plant and provide a concise, high-end "Managerial Insight" (max 2 sentences). Suggest a potential root cause or maintenance action.

Logs:
${defectLog}

Response Format: One sentence on the trend, one sentence on the recommendation. Keep it professional and technical.`;

        const text = await safeGenerateContent(prompt);
        res.status(200).json({ status: 'success', insight: text });
    } catch (err) {
        console.error("AI Insight Error:", err);
        res.status(500).json({ status: 'fail', insight: "AI analysis currently calibrating..." });
    }
});


app.delete('/api/defects/:id', async (req, res) => {
    try {
        await Defect.findByIdAndDelete(req.params.id);
        res.status(204).json({ status: 'success' });
    } catch (err) { res.status(400).json({ status: 'fail' }); }
});

const PDFDocument = require('pdfkit');
const stream = require('stream');

// --- PDF REPORT ENDPOINT ---
app.get('/api/report', async (req, res) => {
  try {
    const defects = await Defect.find().sort('-timestamp');
    const doc = new PDFDocument({ margin: 30, size: 'A4' });
    const buffers = [];
    doc.on('data', buffers.push.bind(buffers));
    doc.on('end', () => {
      const pdfData = Buffer.concat(buffers);
      res.setHeader('Content-Type', 'application/pdf');
      res.setHeader('Content-Disposition', 'attachment; filename="Defect_Report.pdf"');
      res.send(pdfData);
    });

    doc.fontSize(20).text('QualiSight Defect Report', { align: 'center' });
    doc.moveDown();
    defects.forEach((def, idx) => {
      doc.fontSize(12).text(`${idx + 1}. Zone: ${def.zone}`);
      const ts = new Date(def.timestamp).toLocaleString();
      doc.text(`Timestamp: ${ts}`);
      doc.text(`Message: ${def.message}`);
      if (def.image) {
        // Image is base64 data URL; extract base64 part
        const base64 = def.image.split(',')[1];
        const imgBuffer = Buffer.from(base64, 'base64');
        try {
          doc.image(imgBuffer, { fit: [250, 150] });
        } catch (e) {}
      }
      doc.moveDown();
    });
    doc.end();
  } catch (e) {
    console.error(e);
    res.status(500).json({ status: 'fail' });
  }
});
app.post('/api/alerts/send', async (req, res) => {
  const { message, image, timestamp, zone } = req.body;
  const transporter = nodemailer.createTransport({
    host: 'smtp.gmail.com',
    port: 465,
    secure: true,
    auth: {
      user: process.env.EMAIL_USER,
      pass: process.env.EMAIL_PASS
    }
  });

  const formattedTime = new Date(timestamp).toLocaleString();
  
  // Extract base64 content and extension
  const matches = image.match(/^data:image\/([a-zA-Z+]+);base64,(.+)$/);
  const ext = matches ? matches[1] : 'png';
  const base64Data = matches ? matches[2] : image;

  const mailOptions = {
    from: `"QualiSight AI Alert" <${process.env.EMAIL_USER}>`,
    to: 'mukesh710017@gmail.com',
    subject: `⚠️ EMERGENCY: ${zone} - STOP CONVEYOR`,
    html: `
      <div style="font-family: Arial, sans-serif; border: 4px solid #ef4444; padding: 20px; border-radius: 10px; max-width: 600px; margin: auto;">
        <h1 style="color: #ef4444; margin-top: 0;">⚠️ EMERGENCY STOP: ${zone}</h1>
        <p style="font-size: 16px;"><strong>Action Required:</strong> STOP THE CONVEYOR BELT IMMEDIATELY</p>
        <hr style="border: 0; border-top: 1px solid #eee; margin: 20px 0;"/>
        <div style="background: #f9fafb; padding: 15px; border-radius: 8px; margin-bottom: 20px;">
          <p style="margin: 5px 0;"><strong>Zone:</strong> ${zone}</p>
          <p style="margin: 5px 0;"><strong>Issue:</strong> ${message}</p>
          <p style="margin: 5px 0;"><strong>Time:</strong> ${formattedTime}</p>
        </div>
        <div style="text-align: center;">
          <img src="cid:defectImage" style="max-width: 100%; border-radius: 10px; border: 1px solid #ddd;" />
        </div>
        <p style="color: #64748b; font-size: 12px; text-align: center; margin-top: 20px;">
          This is an automated alert from the QualiSight AI Industrial Inspection System.
        </p>
      </div>
    `,
    attachments: [{
      filename: `defect.${ext}`,
      content: base64Data,
      encoding: 'base64',
      cid: 'defectImage' // same cid value as in the html img src
    }]
  };

  try {
    await transporter.sendMail(mailOptions);
    res.status(200).json({ status: 'success' });
  } catch (err) {
    console.error("Email Error:", err);
    res.status(500).json({ status: 'fail', message: err.message });
  }
});
    

// Catch-all (Authenticated)
app.use((req, res, next) => {
    if (req.method === 'GET' && !req.url.startsWith('/api') && !req.url.startsWith('/v1')) {
        // Protect main HTML files
        if (req.url.endsWith('.html') || req.url === '/') {
            if (req.url.includes('login.html')) return next();
            return protect(req, res, () => {
                const file = req.url === '/' ? 'dashboard.html' : req.url;
                res.sendFile(path.join(__dirname, file));
            });
        }
    }
    next();
});

const PORT = process.env.PORT || 3000;
mongoose.connect(process.env.MONGODB_URI).then(async () => {
    console.log('[DB] Connected to MongoDB');
    
    // Create default users if not exist
    const adminExists = await User.findOne({ username: 'admin' });
    if (!adminExists) {
        const hashedPassword = await bcrypt.hash('admin123', 12);
        await User.create({ username: 'admin', password: hashedPassword });
        console.log('[AUTH] Default admin created (admin/admin123)');
    }

    const inspectExists = await User.findOne({ username: 'inspect' });
    if (!inspectExists) {
        const hashedPassword = await bcrypt.hash('inspect123', 12);
        await User.create({ username: 'inspect', password: hashedPassword });
        console.log('[AUTH] Default inspector created (inspect/inspect123)');
    }

    server.listen(PORT, () => console.log(`Multi-Zone Backend running on port ${PORT}...`));
});
