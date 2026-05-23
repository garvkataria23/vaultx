let ws = null;
let sessionToken = null;
let isConnected = false;
let serverIp = '127.0.0.1';
let serverPort = '8080';

// Load stored connection info
chrome.storage.local.get(['vaultx_token', 'vaultx_ip', 'vaultx_port'], (res) => {
    if (res.vaultx_token) sessionToken = res.vaultx_token;
    if (res.vaultx_ip) serverIp = res.vaultx_ip;
    if (res.vaultx_port) serverPort = res.vaultx_port;
    if (sessionToken) connectWebSocket();
});

function connectWebSocket() {
    if (ws && ws.readyState === WebSocket.OPEN) return;
    try {
        ws = new WebSocket(`ws://${serverIp}:${serverPort}/ws`);
        
        ws.onopen = () => {
            console.log('VaultX: WebSocket Connected');
            isConnected = true;
            if (sessionToken) {
                ws.send(JSON.stringify({ type: 'auth', token: sessionToken }));
            }
            chrome.runtime.sendMessage({ type: 'WS_STATE', connected: true });
        };

        ws.onmessage = (event) => {
            const data = JSON.parse(event.data);
            if (data.type === 'paired') {
                sessionToken = data.token;
                chrome.storage.local.set({ vaultx_token: sessionToken });
                chrome.runtime.sendMessage({ type: 'WS_PAIRED', success: true });
                console.log('VaultX: Pair success');
            } else if (data.type === 'pair_failed') {
                chrome.runtime.sendMessage({ type: 'WS_PAIRED', success: false, error: data.error });
                console.error('VaultX: Pair failed');
            } else if (data.type === 'credentials') {
                chrome.tabs.query({active: true, currentWindow: true}, function(tabs) {
                    if (tabs[0]) {
                        chrome.tabs.sendMessage(tabs[0].id, { type: 'AUTOFILL_SUGGESTIONS', credentials: data.credentials });
                    }
                });
            }
        };

        ws.onclose = () => {
            console.log('VaultX: WebSocket Disconnected');
            isConnected = false;
            chrome.runtime.sendMessage({ type: 'WS_STATE', connected: false });
            if (sessionToken) {
                console.log('VaultX: Reconnect triggered in 5s');
                setTimeout(connectWebSocket, 5000);
            }
        };
        
        ws.onerror = (err) => {
            console.error('VaultX: WebSocket Error', err);
            ws.close();
        };
    } catch(e) {
        console.error('VaultX: Connection Exception', e);
        if (sessionToken) setTimeout(connectWebSocket, 5000);
    }
}

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.type === 'CHECK_AUTOFILL') {
        if (isConnected && sessionToken) {
            ws.send(JSON.stringify({
                type: 'get_credentials',
                token: sessionToken,
                domain: request.domain
            }));
        }
        sendResponse({ status: "requested" });
    } else if (request.type === 'PAIR') {
        serverIp = request.ip;
        serverPort = request.port;
        chrome.storage.local.set({ vaultx_ip: serverIp, vaultx_port: serverPort });
        
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: 'pair', pin: request.pin }));
        } else {
            connectWebSocket();
            let checkOpen = setInterval(() => {
                if (ws && ws.readyState === WebSocket.OPEN) {
                    clearInterval(checkOpen);
                    ws.send(JSON.stringify({ type: 'pair', pin: request.pin }));
                }
            }, 500);
        }
        sendResponse({ status: "pairing" });
    } else if (request.type === 'DISCONNECT') {
        sessionToken = null;
        chrome.storage.local.remove(['vaultx_token']);
        if (ws) ws.close();
        sendResponse({ status: "disconnected" });
    } else if (request.type === 'GET_STATE') {
        sendResponse({ connected: isConnected, hasToken: !!sessionToken, ip: serverIp, port: serverPort });
    }
});