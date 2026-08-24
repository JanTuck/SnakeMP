(function () {
    'use strict';

    var root = document.getElementById('server_state');
    var players = document.getElementById('status_players');
    var lobbies = document.getElementById('status_lobbies');
    var playersLabel = document.getElementById('status_players_label');
    var lobbiesLabel = document.getElementById('status_lobbies_label');
    var stateLabel = root && root.querySelector('.server-state-label');
    var summary = document.getElementById('status_summary');
    if (!root || !players || !lobbies || !playersLabel || !lobbiesLabel || !stateLabel || !summary) return;

    var refreshTimer = 0;
    var requestInFlight = false;
    var hasTotals = false;
    var lastSuccess = 0;
    var REFRESH_MS = 15000;
    var REQUEST_TIMEOUT_MS = 4000;

    function plural(value, singular, pluralForm) {
        return value === 1 ? singular : pluralForm;
    }

    function visibleNumber(value) {
        if (value < 10000) return value.toLocaleString();
        if (value < 1000000) {
            var thousands = value / 1000;
            return (thousands < 100 && thousands % 1 ? thousands.toFixed(1) : Math.round(thousands)) + 'K';
        }
        var millions = value / 1000000;
        return (millions < 100 && millions % 1 ? millions.toFixed(1) : Math.round(millions)) + 'M';
    }

    function isCount(value) {
        return Number.isSafeInteger(value) && value >= 0;
    }

    function render(data) {
        players.textContent = visibleNumber(data.players);
        lobbies.textContent = visibleNumber(data.lobbies);
        playersLabel.textContent = plural(data.players, 'player', 'players');
        lobbiesLabel.textContent = plural(data.lobbies, 'lobby', 'lobbies');
        root.dataset.state = 'live';
        stateLabel.textContent = 'Live';
        summary.textContent = data.players.toLocaleString() + ' ' + plural(data.players, 'player', 'players') +
            ' across ' + data.lobbies.toLocaleString() + ' ' + plural(data.lobbies, 'lobby', 'lobbies') + ' right now.';
        hasTotals = true;
        lastSuccess = Date.now();
    }

    function markUnavailable() {
        if (root.dataset.state === 'retrying') return;
        root.dataset.state = 'retrying';
        stateLabel.textContent = 'Retrying';
        summary.textContent = hasTotals
            ? 'Live totals are temporarily unavailable. Showing the last reported values and retrying automatically.'
            : 'Live totals are temporarily unavailable. Retrying automatically.';
    }

    function schedule() {
        window.clearTimeout(refreshTimer);
        refreshTimer = window.setTimeout(refresh, REFRESH_MS);
    }

    function refresh() {
        if (requestInFlight || document.hidden) {
            schedule();
            return;
        }
        if (typeof window.fetch !== 'function') {
            markUnavailable();
            schedule();
            return;
        }
        requestInFlight = true;
        var controller = typeof AbortController === 'function' ? new AbortController() : null;
        var timeout = controller ? window.setTimeout(function () { controller.abort(); }, REQUEST_TIMEOUT_MS) : 0;
        var options = {
            cache: 'no-store',
            credentials: 'same-origin',
            headers: { Accept: 'application/json' }
        };
        if (controller) options.signal = controller.signal;

        window.fetch('/status', options).then(function (response) {
            if (!response.ok) throw new Error('Status request failed');
            return response.json();
        }).then(function (data) {
            if (!data || !isCount(data.players) || !isCount(data.lobbies)) throw new Error('Invalid status response');
            render(data);
        }).catch(markUnavailable).then(function () {
            if (timeout) window.clearTimeout(timeout);
            requestInFlight = false;
            schedule();
        });
    }

    document.addEventListener('visibilitychange', function () {
        if (!document.hidden && Date.now() - lastSuccess >= REFRESH_MS) refresh();
    });
    window.addEventListener('online', refresh);
    window.addEventListener('offline', markUnavailable);
    refresh();
}());
