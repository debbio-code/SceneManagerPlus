// Scene Manager+ -- Scene Clipboard dialog JS
(function () {
  'use strict';

  var SMClip = { state: null };
  window.SMClip = SMClip;

  function call(name, payload) {
    try {
      if (window.sketchup && typeof window.sketchup[name] === 'function') {
        window.sketchup[name](payload ? JSON.stringify(payload) : '');
      }
    } catch (e) { console.error('[SMClip] call failed', name, e); }
  }
  function $(s) { return document.querySelector(s); }
  function escapeHtml(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function plural(n) { return n === 1 ? '' : 's'; }

  function renderCopy(state) {
    var scenes = (state && state.selected) || [];
    var copyable = scenes.filter(function (s) { return !s.mp; });
    var summary = $('#copy-summary');
    var list = $('#copy-list');
    var btn = $('#btn-copy');

    if (scenes.length === 0) {
      summary.textContent = 'No scenes selected in the main window.';
      list.innerHTML = '<li class="empty">Select scenes in the main window.</li>';
      btn.disabled = true;
      return;
    }
    summary.textContent = scenes.length + ' scene' + plural(scenes.length) +
      ' selected (' + copyable.length + ' copyable).';
    list.innerHTML = scenes.map(function (s) {
      var badge = s.mp ? '<span class="mp-badge">Match Photo</span>' : '';
      return '<li><span class="name">' + escapeHtml(s.name) + '</span>' + badge + '</li>';
    }).join('');
    btn.disabled = copyable.length === 0;
  }

  function renderClipboard(state) {
    var cb = state && state.clipboard;
    var summary = $('#clip-summary');
    var list = $('#clip-list');
    var btn = $('#btn-paste');

    if (!cb || !cb.scene_count) {
      summary.textContent = 'Empty -- nothing copied yet.';
      list.innerHTML = '<li class="empty">Empty.</li>';
      btn.disabled = true;
      return;
    }
    var src = cb.source_model || 'unknown file';
    summary.innerHTML = '<span id="clip-meta">' +
      cb.scene_count + ' scene' + plural(cb.scene_count) + ' &middot; ' +
      cb.style_count + ' style' + plural(cb.style_count) + ' &middot; from ' +
      escapeHtml(src) + ' &middot; ' + escapeHtml(cb.created_at || '') + '</span>';
    var names = cb.scene_names || [];
    list.innerHTML = names.length
      ? names.map(function (n) {
          return '<li><span class="name">' + escapeHtml(n) + '</span></li>';
        }).join('')
      : '<li class="empty">(no scene names)</li>';
    btn.disabled = false;
  }

  SMClip.setState = function (state) {
    SMClip.state = state;
    renderCopy(state);
    renderClipboard(state);
  };

  document.addEventListener('DOMContentLoaded', function () {
    $('#btn-copy').addEventListener('click', function () { call('sm_clip_copy'); });
    $('#btn-paste').addEventListener('click', function () { call('sm_clip_paste'); });
    call('sm_clip_ready');
  });
})();
