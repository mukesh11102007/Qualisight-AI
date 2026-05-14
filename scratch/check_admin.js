const mongoose = require('mongoose');
const dotenv = require('dotenv');
dotenv.config({ path: './.env' });

const userSchema = new mongoose.Schema({
    username: { type: String, required: true, unique: true },
    password: { type: String, required: true }
});
const User = mongoose.model('User', userSchema);

mongoose.connect(process.env.MONGODB_URI).then(async () => {
    const user = await User.findOne({ username: 'admin' });
    if (user) {
        console.log('Admin user found:', user.username);
    } else {
        console.log('Admin user NOT found');
    }
    process.exit(0);
});
