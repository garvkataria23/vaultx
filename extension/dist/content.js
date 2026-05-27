let currentPassInput = null;
let currentUserInput = null;

function findLoginFields() {
    const passwordInputs = document.querySelectorAll('input[type="password"]');
    if (passwordInputs.length > 0) {
        currentPassInput = passwordInputs[0];
        
        const allInputs = Array.from(document.querySelectorAll('input:not([type="hidden"]):not([type="submit"])'));
        const passIndex = allInputs.indexOf(currentPassInput);
        if (passIndex > 0) {
            currentUserInput = allInputs[passIndex - 1];
        }

        const domain = window.location.hostname;
        console.log("VaultX: Autofill detected for domain:", domain);
        chrome.runtime.sendMessage({ type: "CHECK_AUTOFILL", domain: domain });
    }
}

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.type === 'AUTOFILL_SUGGESTIONS') {
        if (request.credentials && request.credentials.length > 0 && currentPassInput) {
            console.log("VaultX: Credential matched", request.credentials);
            showAutofillPopup(request.credentials);
        }
    }
});

function showAutofillPopup(credentials) {
    if (document.getElementById('vaultx-autofill-popup')) return;

    const popup = document.createElement('div');
    popup.id = 'vaultx-autofill-popup';
    popup.style.cssText = `
        position: absolute;
        z-index: 2147483647;
        background: white;
        border: 1px solid #ccc;
        box-shadow: 0 4px 12px rgba(0,0,0,0.15);
        border-radius: 8px;
        padding: 8px 0;
        font-family: sans-serif;
        font-size: 14px;
        min-width: 200px;
    `;

    const title = document.createElement('div');
    title.innerText = 'VaultX Autofill';
    title.style.cssText = 'padding: 4px 16px; font-weight: bold; color: #333; border-bottom: 1px solid #eee; margin-bottom: 4px;';
    popup.appendChild(title);

    credentials.forEach(cred => {
        const item = document.createElement('div');
        item.style.cssText = 'padding: 8px 16px; cursor: pointer; color: #000; display: flex; flex-direction: column;';
        item.innerHTML = \`<span style="font-weight: 500">\${cred.username || 'No Username'}</span><span style="font-size: 12px; color: #666;">\${cred.serviceName}</span>\`;
        item.onmouseover = () => item.style.backgroundColor = '#f0f0f0';
        item.onmouseout = () => item.style.backgroundColor = 'transparent';
        
        item.onclick = () => {
            if (currentUserInput) {
                currentUserInput.value = cred.username;
                currentUserInput.dispatchEvent(new Event('input', { bubbles: true }));
            }
            if (currentPassInput) {
                currentPassInput.value = cred.password;
                currentPassInput.dispatchEvent(new Event('input', { bubbles: true }));
            }
            console.log("VaultX: Autofill success");
            popup.remove();
        };
        popup.appendChild(item);
    });

    const rect = currentPassInput.getBoundingClientRect();
    popup.style.top = (window.scrollY + rect.bottom + 4) + 'px';
    popup.style.left = (window.scrollX + rect.left) + 'px';

    document.body.appendChild(popup);

    document.addEventListener('click', (e) => {
        if (!popup.contains(e.target) && e.target !== currentPassInput) {
            popup.remove();
        }
    }, { once: true });
}

setTimeout(findLoginFields, 1000);