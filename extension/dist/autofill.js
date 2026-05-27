/**
 * VaultX Autofill Logic
 * Injected into the page to handle field filling and interaction.
 */

window.vaultxAutofill = {
    fill: function(username, password, userField, passField) {
        if (userField) {
            userField.value = username;
            userField.dispatchEvent(new Event('input', { bubbles: true }));
            userField.dispatchEvent(new Event('change', { bubbles: true }));
        }
        if (passField) {
            passField.value = password;
            passField.dispatchEvent(new Event('input', { bubbles: true }));
            passField.dispatchEvent(new Event('change', { bubbles: true }));
        }
        console.log("VaultX: Autofill applied successfully.");
    }
};