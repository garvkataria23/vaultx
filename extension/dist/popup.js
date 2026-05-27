document.addEventListener('DOMContentLoaded', () => {
    const pairSection = document.getElementById('pair-section');
    const connectedSection = document.getElementById('connected-section');
    const statusDiv = document.getElementById('status');
    const btnPair = document.getElementById('btn-pair');
    const btnDisconnect = document.getElementById('btn-disconnect');
    const pairError = document.getElementById('pair-error');

    function updateUI() {
        chrome.runtime.sendMessage({ type: 'GET_STATE' }, (res) => {
            if (res.hasToken) {
                pairSection.style.display = 'none';
                connectedSection.style.display = 'block';
                statusDiv.className = res.connected ? 'connected' : 'disconnected';
                statusDiv.innerText = res.connected ? 'Securely Connected to VaultX' : 'Waiting for VaultX App...';
            } else {
                pairSection.style.display = 'block';
                connectedSection.style.display = 'none';
                statusDiv.className = 'disconnected';
                statusDiv.innerText = 'Not Paired';
            }
        });
    }

    updateUI();

    btnPair.addEventListener('click', () => {
        const ip = document.getElementById('ip').value;
        const port = document.getElementById('port').value;
        const pin = document.getElementById('pin').value;
        
        pairError.innerText = '';
        btnPair.innerText = 'Pairing...';
        
        chrome.runtime.sendMessage({ type: 'PAIR', ip, port, pin }, (res) => {});
    });

    btnDisconnect.addEventListener('click', () => {
        chrome.runtime.sendMessage({ type: 'DISCONNECT' }, () => {
            updateUI();
        });
    });

    chrome.runtime.onMessage.addListener((request) => {
        if (request.type === 'WS_STATE') {
            updateUI();
        } else if (request.type === 'WS_PAIRED') {
            btnPair.innerText = 'Pair Device';
            if (request.success) {
                updateUI();
            } else {
                pairError.innerText = request.error || 'Pairing failed. Check PIN and App status.';
            }
        }
    });
});