const express = require('express');
const mongoose = require('mongoose');
const dotenv = require('dotenv');
const path = require('path');
const morgan = require('morgan');
const cookieParser = require('cookie-parser');
const WebSocket = require('ws');
const fs = require('fs');
const nodemailer = require('nodemailer');

dotenv.config({ path: './.env' });
const app = express();
const server = require('http').createServer(app);
const wss = new WebSocket.Server({ server });

// Live Stream In-Memory Storage (Multiple Zones)
let zones = {
    "Zone 1": null,
    "Zone 2": null
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
app.use(express.json({ limit: '100mb' }));
app.use(express.urlencoded({ extended: true, limit: '100mb' }));
app.use(morgan('dev'));
app.use(cookieParser());
app.use(express.static(path.join(__dirname)));

// --- HTTP BACKUP ROUTES ---
app.post('/v1/camera', (req, res) => {
    const { zone, image } = req.body;
    zones[zone] = image;
    res.status(200).json({ status: 'success' });
});
app.get('/v1/camera', (req, res) => {
    res.status(200).json({ status: 'success', zones });
});

// --- MODELS ---
const defectSchema = new mongoose.Schema({
    image: String,
    message: String,
    zone: { type: String, default: "Zone 1" },
    timestamp: { type: Date, default: Date.now }
});
const Defect = mongoose.model('Defect', defectSchema);

// --- API ROUTES ---
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

app.delete('/api/defects/:id', async (req, res) => {
    try {
        await Defect.findByIdAndDelete(req.params.id);
        res.status(204).json({ status: 'success' });
    } catch (err) { res.status(400).json({ status: 'fail' }); }
});

// --- EMERGENCY EMAIL ALERT ---
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

    const mailOptions = {
        from: `"QualiSight AI Alert" <${process.env.EMAIL_USER}>`,
        to: 'mukesh710017@gmail.com',
        subject: `⚠️ EMERGENCY: ${zone} - STOP CONVEYOR`,
        html: `
            <div style="font-family: Arial, sans-serif; border: 4px solid #ef4444; padding: 20px; border-radius: 10px;">
                <h1 style="color: #ef4444;">⚠️ EMERGENCY STOP: ${zone}</h1>
                <p><strong>Action:</strong> STOP THE CONVEYOR BELT IMMEDIATELY</p>
                <hr/>
                <p><strong>Zone:</strong> ${zone}</p>
                <p><strong>Issue:</strong> ${message}</p>
                <p><strong>Time:</strong> ${new Date(timestamp).toLocaleString()}</p>
                <img src="${image}" style="max-width: 100%; border-radius: 10px;" />
            </div>
        `
    };

    try {
        await transporter.sendMail(mailOptions);
        res.status(200).json({ status: 'success' });
    } catch (err) {
        console.error("Email Error:", err);
        res.status(500).json({ status: 'fail', message: err.message });
    }
});

// Catch-all
app.use((req, res, next) => {
    if (req.method === 'GET' && !req.url.startsWith('/api') && !req.url.startsWith('/v1')) {
        return res.sendFile(path.join(__dirname, 'index.html'));
    }
    next();
});

const PORT = process.env.PORT || 3000;
mongoose.connect(process.env.MONGODB_URI).then(() => {
    server.listen(PORT, () => console.log(`Multi-Zone Backend running on port ${PORT}...`));
});
