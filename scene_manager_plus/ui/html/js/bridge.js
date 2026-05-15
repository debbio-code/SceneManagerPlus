// Wrapper sulle action_callback registrate in dialog.rb.
// Su SU < 2017 (WebDialog) sketchup.<name>(payload) non esiste e si usa
// location.href = 'skp:<name>@payload'. Qui supportiamo solo HtmlDialog.
window.SMBridge = (function () {
  function call(name, data) {
    var payload = (data === undefined) ? '' : JSON.stringify(data);
    if (window.sketchup && typeof window.sketchup[name] === 'function') {
      try {
        window.sketchup[name](payload);
      } catch (err) {
        console.warn('Bridge call failed: ' + name, err);
      }
    } else {
      // Visible diagnostic: bridge not wired up at all
      var status = document.getElementById('status');
      if (status) status.textContent = 'Bridge not available (' + name + ')';
      console.warn('Bridge stub: ' + name, data);
    }
  }
  return {
    ready:           function ()      { call('sm_ready'); },
    refresh:         function ()      { call('sm_refresh'); },
    reorder:         function (ids, target) { call('sm_reorder', { ids: ids, target_id: target }); },
    selectPage:      function (id)    { call('sm_select_page', { id: id }); },
    updatePage:      function (data)  { call('sm_update_page', data); },
    updateFromView:  function (id)    { call('sm_update_from_view', { id: id }); },
    deleteScenes:    function (ids)   { call('sm_delete', { ids: ids }); },
    log:             function (msg)   { call('sm_log', String(msg)); }
  };
})();
