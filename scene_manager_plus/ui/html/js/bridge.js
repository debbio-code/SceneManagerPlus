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
    reorder:         function (ids, beforeId, destFolderId) {
                       call('sm_reorder', { ids: ids, before_id: beforeId, dest_folder_id: destFolderId });
                     },
    selectPage:      function (id)    { call('sm_select_page', { id: id }); },
    updatePage:      function (data)  { call('sm_update_page', data); },
    updateFromView:  function (id)    { call('sm_update_from_view', { id: id }); },
    assignStyle:     function (id, name) { call('sm_assign_style', { id: id, style_name: name }); },
    openStyle:       function (id, name) { call('sm_open_style', { id: id, style_name: name }); },
    newStyle:        function (id)       { call('sm_style_new', { id: id }); },
    deleteScenes:    function (ids)   { call('sm_delete', { ids: ids }); },
    newSceneFromView:function ()      { call('sm_new_scene_from_view'); },
    folderCreate:    function (name)  { call('sm_folder_create', { name: name }); },
    folderUpdate:    function (data)  { call('sm_folder_update', data); },
    folderDelete:    function (id)    { call('sm_folder_delete', { id: id }); },
    folderToggle:    function (id)    { call('sm_folder_toggle', { id: id }); },
    openProperties:  function (id)    { call('sm_open_properties', { id: id }); },
    deferToggle:     function ()      { call('sm_defer_toggle'); },
    generatePreviews:function (ids)   { call('sm_generate_previews', { ids: ids || [] }); },
    openExport:      function (sel)   { call('sm_open_export', { selected: sel || [] }); },
    cancelExport:    function ()      { call('sm_export_cancel_running'); },
    setExportIncluded: function (ids, included) {
                       var arr = Array.isArray(ids) ? ids : [ids];
                       call('sm_set_export_included', { ids: arr, included: !!included });
                     },
    log:             function (msg)   { call('sm_log', String(msg)); }
  };
})();
