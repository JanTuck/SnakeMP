(function () {
    'use strict';

    var inviteInput = document.getElementById('invite_url');
    var shareButton = document.getElementById('share_link');
    var copyButton = document.getElementById('copy_link');
    var copyLabel = document.getElementById('copy_link_label');
    var status = document.getElementById('invite_status');

    if (!inviteInput || !shareButton || !copyButton || !copyLabel || !status) return;

    var pathParts = window.location.pathname.split('/').filter(Boolean);
    var encodedLobbyId = pathParts.length ? pathParts[pathParts.length - 1] : '';
    var lobbyId = encodedLobbyId;
    try { lobbyId = decodeURIComponent(encodedLobbyId); } catch (_) { /* keep the safe raw segment */ }

    var inviteUrl = new URL('/game/' + encodeURIComponent(lobbyId), window.location.origin).href;
    var resetLabelTimer = 0;
    inviteInput.value = inviteUrl;

    function setStatus(message) {
        status.textContent = message;
    }

    function showCopied(message) {
        copyLabel.textContent = 'Copied';
        setStatus(message);
        window.clearTimeout(resetLabelTimer);
        resetLabelTimer = window.setTimeout(function () {
            copyLabel.textContent = 'Copy';
        }, 2200);
    }

    function selectInviteLink() {
        try {
            inviteInput.focus();
            inviteInput.select();
            inviteInput.setSelectionRange(0, inviteInput.value.length);
        } catch (_) { /* selection is a best-effort fallback */ }
    }

    async function copyInvite(message) {
        if (window.navigator.clipboard && typeof window.navigator.clipboard.writeText === 'function') {
            try {
                await window.navigator.clipboard.writeText(inviteUrl);
                showCopied(message || 'Invite link copied.');
                return true;
            } catch (_) {
                // A browser can expose Clipboard API while denying the call.
            }
        }

        selectInviteLink();
        try {
            if (document.execCommand && document.execCommand('copy')) {
                showCopied(message || 'Invite link copied.');
                return true;
            }
        } catch (_) { /* leave the selected link ready for manual copying */ }

        setStatus('Copy is blocked here. The invite link is selected so you can copy it manually.');
        return false;
    }

    copyButton.addEventListener('click', async function () {
        await copyInvite();
    });

    shareButton.addEventListener('click', async function () {
        if (typeof window.navigator.share !== 'function') {
            await copyInvite('Sharing is unavailable here, so the invite link was copied instead.');
            return;
        }

        try {
            await window.navigator.share({
                title: 'Join my Snek lobby',
                text: 'Join my Snek lobby.',
                url: inviteUrl
            });
            setStatus('Invite link shared.');
        } catch (error) {
            if (error && error.name === 'AbortError') {
                setStatus('Sharing canceled.');
                return;
            }
            await copyInvite('Sharing failed, so the invite link was copied instead.');
        }
    });
})();
