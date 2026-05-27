const fs = require('fs');
const path = require('path');

function copyFile(src, dest) {
    fs.copyFileSync(src, dest);
}

function build() {
    const distDir = path.join(__dirname, 'dist');
    if (!fs.existsSync(distDir)) {
        fs.mkdirSync(distDir);
    }
    
    // Files to copy to dist/
    const files = [
        'manifest.json',
        'background.js',
        'content.js',
        'autofill.js',
        'popup.html',
        'popup.js',
        'icon16.png',
        'icon48.png',
        'icon128.png'
    ];
    
    console.log('VaultX: Starting build...');
    
    files.forEach(file => {
        const srcPath = path.join(__dirname, file);
        const destPath = path.join(distDir, file);
        if (fs.existsSync(srcPath)) {
            copyFile(srcPath, destPath);
            console.log(`Copied ${file} to dist/`);
        } else {
            console.warn(`Warning: ${file} not found, skipping.`);
        }
    });

    console.log('\nVaultX: Extension built successfully in extension/dist/');
    console.log('To install:');
    console.log('1. Open chrome://extensions');
    console.log('2. Enable "Developer mode"');
    console.log('3. Click "Load unpacked" and select the extension/dist folder.');
}

try {
    build();
} catch (err) {
    console.error('Build failed:', err);
    process.exit(1);
}