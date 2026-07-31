require 'json'

module SceneManagerPlus
  module UI
    # Finestra col contenuto di un layer (quanti gruppi, componenti, facce,
    # spigoli... ci stanno sopra). Aperta dal bottone "i" di ogni riga nella
    # sezione Layers del Properties dialog.
    #
    # Ogni riga di conteggio e' azionabile:
    #  - click sinistro  = seleziona nel modello le entita' enumerate;
    #  - click destro    = menu "Select all" / "Select all and isolate the
    #                      layer" / "Restore layer visibility".
    # Vedi `Core::Layers.select_on_layer` per il limite del contesto di editing
    # in SU 2019 (le entita' dentro gruppi/componenti non sono selezionabili
    # dall'esterno del gruppo).
    #
    # Il conteggio e' uno SNAPSHOT: si aggiorna col bottone ↻ e ogni volta che
    # la finestra riprende il fuoco (l'utente torna qui dopo aver lavorato nel
    # viewport). Su un modello reale da 478 definition il ricalcolo costa
    # ~150ms, quindi il refresh su focus e' sostenibile; c'e' comunque un
    # debounce per non ricalcolare a raffica.
    #
    # A differenza degli altri dialog del plugin qui NON ci sono asset HTML su
    # disco: il contenuto e' un report generato in Ruby e iniettato con
    # `set_html`. Il body viene sostituito via `execute_script` a ogni refresh,
    # quindi tutti i listener JS sono in delegation su `document` e definiti
    # nell'<head>: sopravvivono alla sostituzione. Per lo stesso motivo lo stato
    # che il JS deve conoscere (isolamento attivo) viaggia come data-attribute
    # dentro il body, non come variabile globale JS.
    module LayerInfoDialog
      module_function

      @dialog      = nil
      @layer_name  = nil
      @last_status = nil
      @last_body   = nil

      DEFAULT_STATUS = 'Click a row to select those entities in the model. ' \
                       'Right-click for more.'.freeze

      def show_for(layer_name)
        stats = Core::Layers.stats_for(layer_name)
        unless stats
          ::UI.messagebox("Layer \"#{layer_name}\" not found (it may have been deleted).")
          return nil
        end
        @layer_name  = stats['name']
        @last_status = DEFAULT_STATUS

        body = build_body(stats)

        if @dialog && (@dialog.visible? rescue false)
          @dialog.bring_to_front
          swap_body(body)
          return @dialog
        end

        @dialog = ::UI::HtmlDialog.new(
          dialog_title:    "#{PLUGIN_NAME} — Layer contents",
          preferences_key: 'SceneManagerPlus.LayerInfoDialog',
          scrollable:      true,
          resizable:       true,
          width:           380,
          height:          470,
          min_width:       300,
          min_height:      260,
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )
        register_callbacks(@dialog)
        @last_body = body
        @dialog.set_html(page(body))
        @dialog.show
        @dialog
      rescue => e
        warn "[SM+] LayerInfoDialog.show_for failed: #{e.class}: #{e.message}"
        nil
      end

      def register_callbacks(dlg)
        dlg.add_action_callback('sm_layerinfo_select') do |_ctx, payload|
          data = (JSON.parse(payload) rescue {})
          handle_action(data['cat'].to_s, data['def'].to_s, data['action'].to_s)
        end

        dlg.add_action_callback('sm_layerinfo_refresh') do |_ctx|
          refresh
        end
      end

      # Il refresh automatico su focus arriva proprio mentre l'utente sta per
      # cliccare una riga: se sostituissimo il body a conteggi invariati, il
      # mouseup cadrebbe su un elemento nuovo e il click andrebbe perso (e'
      # esattamente il bug del "devo cliccare due volte"). Quindi tocchiamo il
      # DOM solo se il report e' davvero cambiato.
      def swap_body(body)
        return unless @dialog && (@dialog.visible? rescue false)
        return if body == @last_body
        @last_body = body
        @dialog.execute_script("document.body.innerHTML = #{body.to_json};")
      end

      # Ricalcola i conteggi e ridisegna, mantenendo l'ultimo messaggio di
      # stato: dopo un refresh su focus sarebbe seccante perdere il "Selected 2
      # of 110" appena letto.
      def refresh
        return unless @layer_name
        stats = Core::Layers.stats_for(@layer_name)
        unless stats
          swap_body("<div class=\"empty\">Layer \"#{esc(@layer_name)}\" no longer exists.</div>")
          return
        end
        swap_body(build_body(stats))
      rescue => e
        warn "[SM+] LayerInfoDialog.refresh failed: #{e.class}: #{e.message}"
      end

      # ── Azioni sulle righe ────────────────────────────────────────────

      def handle_action(cat, def_name, action)
        case action
        when 'container'
          status(container_message(Core::Layers.select_containers_of(def_name)))
        when 'restore'
          if Core::Layers.restore_visibility
            status(esc('Layer visibility restored.'))
          else
            status(esc('Nothing to restore: the isolation is no longer in place. ' \
                       'Activating a scene rewrites layer visibility, which undoes it.'))
          end
          refresh
        when 'isolate'
          return if @layer_name.nil? || cat.empty?
          sel = do_select(cat, def_name)
          iso = Core::Layers.isolate_layer(@layer_name)
          if iso
            # La nota sull'isolamento va PRIMA: l'esito della selezione puo'
            # finire con l'elenco dei contenitori, che e' un blocco.
            note = "Isolated \"#{@layer_name}\": #{iso['hidden']} other layer(s) hidden."
            ref  = iso['refused'] || []
            note += " SketchUp keeps #{ref.join(', ')} visible." unless ref.empty?
            note += ' Right-click a row to restore, or Ctrl+Z.'
            status("#{esc(note)}<br>#{sel}")
          else
            status(sel)
          end
          refresh
        else
          return if @layer_name.nil? || cat.empty?
          status(do_select(cat, def_name))
        end
      rescue => e
        warn "[SM+] LayerInfoDialog.handle_action failed: #{e.class}: #{e.message}"
      end

      def do_select(cat, def_name)
        dn  = def_name.to_s.empty? ? nil : def_name.to_s
        res = Core::Layers.select_on_layer(@layer_name, cat, dn)
        select_message(res, cat, dn)
      end

      # Ritorna HTML: quando qualcosa NON si riesce a selezionare, dire "sono
      # dentro gruppi o componenti" senza dire QUALI non serve a niente. Sotto
      # la frase compare l'elenco dei contenitori con i rispettivi conteggi,
      # cosi' si sa dove andare a guardare / cosa aprire.
      MISS_ROWS = 12

      def select_message(res, cat, dn)
        return 'Selection failed.' unless res
        sel = res['selected'].to_i
        tot = res['total'].to_i
        els = res['elsewhere'].to_i
        plural = dn ? "instances of \"#{dn}\"" : Core::Layers.category_label(cat)
        return esc("Nothing to select: no #{plural} on this layer.") if tot.zero?

        head =
          if sel.zero?
            # Per la riga "Inside groups / components" l'etichetta dice gia'
            # dove stanno: ripeterlo darebbe "all 108 entities inside groups /
            # components live inside groups or components".
            what = (cat == 'nested') ? "these #{tot} entities" : "all #{labeled(tot, cat, dn)}"
            "Nothing selected: #{what} are inside groups or components, and SketchUp " \
            'only selects in the context you have open. Click a container below to ' \
            'select it in the model:'
          elsif els > 0
            "Selected #{sel} of #{labeled(tot, cat, dn)}. The other #{els} are inside " \
            'groups or components — click one below to select it in the model:'
          else
            "Selected #{labeled(sel, cat, dn)}."
          end

        esc(head) + miss_list_html(res['inside'] || [])
      end

      # Ogni contenitore e' cliccabile: seleziona il gruppo/componente che tiene
      # dentro quella roba (vedi Core::Layers.select_containers_of). Senza
      # questo l'elenco sarebbe un vicolo cieco: "non ho selezionato niente,
      # arrangiati".
      def miss_list_html(inside)
        return '' if inside.empty?
        rows = inside.first(MISS_ROWS).map do |name, n|
          "<div data-cont=\"#{esc(name)}\" title=\"Select the group / component that " \
          "contains them\"><span>#{esc(name)}</span><span class=\"n2\">#{n.to_i}</span></div>"
        end
        rest = inside.size - MISS_ROWS
        if rest > 0
          hidden_n = inside.drop(MISS_ROWS).inject(0) { |a, pair| a + pair[1].to_i }
          rows << "<div class=\"more\"><span>(#{rest} more container#{rest == 1 ? '' : 's'})</span>" \
                  "<span class=\"n2\">#{hidden_n}</span></div>"
        end
        "<div class=\"miss\">#{rows.join}</div>"
      end

      def container_message(res)
        return esc('That group / component no longer exists.') unless res
        n = res['selected'].to_i
        nm = res['name'].to_s
        if n.zero?
          return esc("Could not reach any instance of \"#{nm}\" from the context you " \
                     'have open. Close the group you are editing (Esc) and try again.')
        end
        up  = res['climbed'].to_i
        msg = "Selected #{n} #{n == 1 ? 'object' : 'objects'} in the model"
        msg += if up.zero?
                 ": instance#{n == 1 ? '' : 's'} of \"#{nm}\"."
               else
                 " #{n == 1 ? 'that contains' : 'that contain'} \"#{nm}\" " \
                 "(#{up} level#{up == 1 ? '' : 's'} up)."
               end
        esc(msg)
      end

      def labeled(n, cat, dn)
        return "#{n} instance#{n.to_i == 1 ? '' : 's'} of \"#{dn}\"" if dn
        Core::Layers.count_label(n, cat)
      end

      # `html` e' gia' HTML sicuro: le parti dinamiche passano da esc().
      def status(html)
        @last_status = html
        return unless @dialog && (@dialog.visible? rescue false)
        @dialog.execute_script(
          "var e = document.getElementById('sel-status'); if (e) { e.innerHTML = #{html.to_json}; }"
        )
      end

      # ── Rendering ─────────────────────────────────────────────────────

      def esc(s)
        s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end

      # Etichette nell'ordine in cui vanno mostrate. Le prime quattro si vedono
      # anche a zero (sono quelle che l'utente va a cercare), le altre solo se
      # presenti, per non annegare il report in righe vuote.
      ROWS = [
        ['groups',         'Groups',              true],
        ['components',     'Component instances', true],
        ['faces',          'Faces',               true],
        ['edges',          'Edges',               true],
        ['guides',         'Guides',              false],
        ['text',           'Text',                false],
        ['images',         'Images',              false],
        ['section_planes', 'Section planes',      false]
      ].freeze

      # `cat` (+ `dname`) finiscono in data-attribute: click e menu contestuale
      # li rimandano a Ruby, che seleziona quelle entita' nel modello.
      def row(label, n, cat, dname = nil)
        d = dname ? " data-def=\"#{esc(dname)}\"" : ''
        "<tr data-cat=\"#{esc(cat)}\"#{d}><td>#{label}</td><td class=\"n\">#{n.to_i}</td></tr>"
      end

      def build_body(s)
        counts = s['counts'] || {}
        total  = s['total'].to_i
        iso    = Core::Layers.isolation_active? ? '1' : '0'

        h = []
        h << "<div class=\"hdr\" data-iso=\"#{iso}\">"
        h << swatch_html(s['color'])
        h << "<span class=\"lname\">#{esc(s['name'])}</span>"
        h << '<span class="hspace"></span>'
        h << '<button id="btn-refresh" class="hbtn" title="Recount now (also happens ' \
             'automatically when this window regains focus)">&#8635;</button>'
        h << '</div>'

        h << '<div class="badges">'
        h << badge('Current layer', 'ok') if s['current']
        h << badge('Hidden in the model', 'warn') unless s['visible']
        h << badge('Default layer', 'plain') if s['is_default']
        h << badge('Isolation active', 'warn') if iso == '1'
        ls = s['line_style'].to_s
        h << badge("Dashes: #{esc(ls)}", 'plain') unless ls.empty?
        h << '</div>'

        h << '<div class="total" data-cat="all" title="Click to select all of them in the model">' \
             "<b>#{total}</b> entit#{total == 1 ? 'y' : 'ies'} on this layer</div>"

        if total.zero?
          h << '<div class="empty">Nothing in the model uses this layer.<br>' \
               'Purge would remove it.</div>'
        else
          h << '<table class="tbl">'
          ROWS.each do |key, label, always|
            n = counts[key].to_i
            next if n.zero? && !always
            h << row(label, n, key)
          end
          (s['other'] || {}).sort_by { |k, v| [-v.to_i, k.to_s] }.each do |klass, n|
            h << row(esc(klass), n, klass)
          end
          h << '</table>'

          h << '<table class="tbl sub">'
          h << row('At the model root', s['root'], 'root')
          h << row('Inside groups / components', s['nested'], 'nested')
          h << '</table>'

          defs = s['definitions'] || []
          unless defs.empty?
            h << '<div class="sect">Component instances by definition</div>'
            h << '<table class="tbl">'
            defs.first(30).each do |pair|
              h << row(esc(pair[0]), pair[1], 'components', pair[0])
            end
            h << '</table>'
            if defs.size > 30
              h << "<div class=\"note\">(#{defs.size - 30} more definition(s) not listed)</div>"
            end
          end
        end

        h << '<div class="note">Contents of groups and components are counted ' \
             'once per definition, not once per instance: a component placed ' \
             '10 times contributes its inner geometry once.</div>'
        h << "<div class=\"note\">Counted on #{esc(s['model_title'])}.</div>"

        # Ultimo elemento + position:sticky = resta incollato in fondo alla
        # finestra. Prima stava in coda al report e su un layer con 250
        # definition finiva a schermate di distanza: si cliccava una riga e
        # sembrava che non succedesse niente, perche' la risposta era fuori
        # vista. @last_status e' gia' HTML (vedi `status`), niente esc qui.
        h << "<div id=\"sel-status\" class=\"selstat\">#{@last_status || DEFAULT_STATUS}</div>"
        h.join("\n")
      end

      def swatch_html(hex)
        c = hex.to_s
        return '<span class="sw sw-empty"></span>' if c.empty?
        "<span class=\"sw\" style=\"background:#{esc(c)}\"></span>"
      end

      def badge(text, kind)
        "<span class=\"badge badge-#{kind}\">#{text}</span>"
      end

      def page(body)
        <<-HTML
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Layer contents</title>
<style>
  html, body { margin: 0; padding: 0; }
  body {
    background: #2b2b2b; color: #ddd; padding: 10px 12px 16px;
    font-family: "Segoe UI", Tahoma, sans-serif; font-size: 12px;
  }
  .hdr { display: flex; align-items: center; gap: 7px; margin-bottom: 6px; }
  .hspace { flex: 1; }
  .hbtn {
    background: #3a3a3a; border: 1px solid #1e1e1e; color: #ddd;
    width: 22px; height: 22px; padding: 0; border-radius: 2px;
    cursor: pointer; font-size: 13px; line-height: 1; flex: 0 0 auto;
  }
  .hbtn:hover { background: #4a4a4a; border-color: #4ea1ff; color: #fff; }
  .lname { font-size: 14px; font-weight: bold; color: #fff; word-break: break-all; }
  .sw {
    width: 16px; height: 14px; flex: 0 0 auto;
    border: 1px solid #1e1e1e; border-radius: 2px; display: inline-block;
  }
  .sw-empty {
    background-image:
      linear-gradient(45deg, #555 25%, transparent 25%, transparent 75%, #555 75%),
      linear-gradient(45deg, #555 25%, #333 25%, #333 75%, #555 75%);
    background-size: 8px 8px; background-position: 0 0, 4px 4px;
  }
  .badges { display: flex; flex-wrap: wrap; gap: 4px; margin-bottom: 10px; }
  .badge {
    font-size: 10px; padding: 1px 6px; border-radius: 8px;
    border: 1px solid #1e1e1e; background: #3a3a3a; color: #bbb;
  }
  .badge-ok   { background: #2b5a86; color: #cfe6ff; border-color: #1b3a56; }
  .badge-warn { background: #5a4020; color: #ffd9a0; border-color: #3a2a14; }
  .total {
    font-size: 12px; color: #bbb; margin-bottom: 8px;
    cursor: pointer; border-radius: 2px; padding: 2px 4px;
  }
  .total:hover { background: #3a3a3a; color: #fff; }
  .total b { font-size: 18px; color: #fff; }
  .tbl { width: 100%; border-collapse: collapse; margin-bottom: 10px; }
  .tbl td {
    padding: 3px 4px; border-bottom: 1px solid #333;
    word-break: break-all;
  }
  .tbl td.n { text-align: right; width: 70px; color: #fff; font-variant-numeric: tabular-nums; }
  .tbl.sub td { color: #aaa; }
  /* Righe azionabili = selezionano quelle entita' nel modello */
  .tbl tr[data-cat] { cursor: pointer; }
  .tbl tr[data-cat]:hover td { background: #3a3a3a; color: #fff; }
  .sect {
    font-size: 10px; text-transform: uppercase; letter-spacing: 0.4px;
    color: #888; margin: 12px 0 4px;
  }
  .empty { color: #888; font-style: italic; padding: 12px 0; }
  /* Sticky: la risposta a un click deve stare dove l'utente guarda, non in
     fondo a un report lungo tre schermate. */
  .selstat {
    position: sticky; bottom: 0; z-index: 5;
    background: #232323; border: 1px solid #1e1e1e; border-radius: 2px;
    color: #cfe6ff; font-size: 11px; line-height: 1.45; padding: 6px 8px;
    margin-top: 8px;
    box-shadow: 0 -6px 12px rgba(0, 0, 0, 0.5);
  }
  /* Elenco dei contenitori che tengono dentro cio' che non si e' potuto
     selezionare: nome a sinistra, conteggio a destra. */
  .selstat .miss { margin-top: 5px; border-top: 1px solid #333; padding-top: 4px; }
  .selstat .miss div {
    display: flex; justify-content: space-between; gap: 10px;
    color: #bbb; padding: 1px 0;
  }
  .selstat .miss div span:first-child {
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .selstat .miss .n2 { color: #fff; flex: 0 0 auto; }
  .selstat .miss div[data-cont] { cursor: pointer; border-radius: 2px; padding: 1px 3px; }
  .selstat .miss div[data-cont]:hover { background: #2b5a86; color: #fff; }
  .selstat .miss .more { color: #888; font-style: italic; }
  .note { color: #777; font-size: 10px; font-style: italic; line-height: 1.5; margin-top: 8px; }
  .ctxmenu {
    position: fixed; z-index: 99; min-width: 190px;
    background: #333; border: 1px solid #555; border-radius: 3px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.5); padding: 3px 0;
  }
  .ctxmenu div {
    padding: 5px 12px; font-size: 11px; color: #ddd; cursor: pointer;
    white-space: nowrap;
  }
  .ctxmenu div:hover { background: #2b5a86; color: #fff; }
</style>
<script>
  // Delegation su document: il body viene sostituito a ogni refresh, un
  // listener agganciato alle righe morirebbe al primo ricalcolo.
  function smliSend(cat, dname, action) {
    if (!window.sketchup || typeof sketchup.sm_layerinfo_select !== 'function') return;
    var st = document.getElementById('sel-status');
    if (st) st.textContent = 'Working...';
    sketchup.sm_layerinfo_select(JSON.stringify({ cat: cat, def: dname || '', action: action }));
  }
  function smliRefresh() {
    if (window.sketchup && typeof sketchup.sm_layerinfo_refresh === 'function') {
      sketchup.sm_layerinfo_refresh();
    }
  }
  function smliHideMenu() {
    var m = document.getElementById('smli-menu');
    if (m && m.parentNode) m.parentNode.removeChild(m);
    document.removeEventListener('mousedown', smliDocDown, true);
  }
  // Chiude SOLO se il mousedown e' fuori dal menu: chiudere su qualsiasi
  // mousedown toglierebbe la voce da sotto il cursore prima del click, e il
  // click non arriverebbe mai.
  function smliDocDown(ev) {
    var m = document.getElementById('smli-menu');
    if (m && !m.contains(ev.target)) smliHideMenu();
  }
  function smliMenu(x, y, cat, dname) {
    smliHideMenu();
    // Lo stato "isolamento attivo" arriva da Ruby come data-attribute nel
    // body: una variabile JS non sopravviverebbe alla sostituzione del body.
    var hdr = document.querySelector('[data-iso]');
    var iso = hdr && hdr.getAttribute('data-iso') === '1';
    var items = [
      ['Select all', 'select'],
      ['Select all and isolate the layer', 'isolate']
    ];
    if (iso) items.push(['Restore layer visibility', 'restore']);
    var m = document.createElement('div');
    m.className = 'ctxmenu';
    m.id = 'smli-menu';
    items.forEach(function (it) {
      var d = document.createElement('div');
      d.textContent = it[0];
      d.addEventListener('click', function () {
        smliHideMenu();
        smliSend(cat, dname, it[1]);
      });
      m.appendChild(d);
    });
    document.body.appendChild(m);
    var mw = m.offsetWidth, mh = m.offsetHeight;
    if (x + mw > window.innerWidth)  x = Math.max(0, window.innerWidth - mw - 2);
    if (y + mh > window.innerHeight) y = Math.max(0, window.innerHeight - mh - 2);
    m.style.left = x + 'px';
    m.style.top  = y + 'px';
    setTimeout(function () {
      document.addEventListener('mousedown', smliDocDown, true);
    }, 0);
  }
  document.addEventListener('click', function (ev) {
    if (!ev.target.closest) return;
    if (ev.target.closest('#btn-refresh')) { smliRefresh(); return; }
    if (ev.target.closest('.ctxmenu')) return;
    // Riga dell'elenco contenitori: seleziona il gruppo/componente che tiene
    // dentro le entita' non raggiungibili. Va controllata PRIMA di [data-cat].
    var c = ev.target.closest('[data-cont]');
    if (c) { smliSend('', c.getAttribute('data-cont'), 'container'); return; }
    var el = ev.target.closest('[data-cat]');
    if (el) smliSend(el.getAttribute('data-cat'), el.getAttribute('data-def'), 'select');
  });
  document.addEventListener('contextmenu', function (ev) {
    if (!ev.target.closest) return;
    var el = ev.target.closest('[data-cat]');
    if (!el) return;
    ev.preventDefault();
    smliMenu(ev.clientX, ev.clientY, el.getAttribute('data-cat'), el.getAttribute('data-def'));
  });
  // I conteggi sono uno snapshot: quando l'utente torna qui dopo aver lavorato
  // nel viewport, ricalcoliamo. Debounce perche' focus e visibilitychange
  // possono arrivare in coppia.
  var smliLastRef = 0;
  function smliAutoRefresh() {
    var now = Date.now();
    if (now - smliLastRef < 600) return;
    smliLastRef = now;
    smliRefresh();
  }
  window.addEventListener('focus', smliAutoRefresh);
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) smliAutoRefresh();
  });
</script>
</head>
<body>
#{body}
</body></html>
        HTML
      end
    end
  end
end
