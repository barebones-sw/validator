import Foundation

enum UIAssets {
    static let form = """
    <main>
    <h1>Nu Html Checker</h1>
    <form id="checker" method="post" enctype="multipart/form-data" action="/">
    <fieldset>
    <legend>Checker Input</legend>
    <label for="docselect">Input mode</label>
    <select id="docselect" name="docselect">
    <option value="">Address</option>
    <option value="file">File Upload</option>
    <option value="textarea">Text Field</option>
    </select>
    <div id="address-input"><label for="doc-url">Address</label><input id="doc" name="doc" type="url"></div>
    <div id="file-input" hidden><label for="doc-file">File</label><input id="doc-file" name="uploaded_file" type="file"></div>
    <div id="textarea-input" hidden><label for="doc-textarea">Document</label><textarea id="doc-textarea" name="content" rows="16"><!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Test</title>
    </head>
    <body>
    <p>Ready.</p>
    </body>
    </html></textarea></div>
    <label><input id="level" name="level" type="checkbox" value="warning"> Errors and warnings only</label>
    <button id="submit" type="submit">Check</button>
    </fieldset>
    </form>
    </main>
    """

    static let css = """
    :root { color-scheme: light dark; font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; background: Canvas; color: CanvasText; }
    main, #results { max-width: 920px; margin: 0 auto; padding: 20px; }
    h1 { font-size: 24px; font-weight: 650; margin: 0 0 18px; }
    fieldset { border: 1px solid color-mix(in srgb, CanvasText 25%, transparent); border-radius: 6px; padding: 16px; }
    label { display: block; margin: 10px 0 6px; font-weight: 500; }
    input[type="url"], textarea, select { width: 100%; box-sizing: border-box; font: inherit; border: 1px solid color-mix(in srgb, CanvasText 28%, transparent); border-radius: 5px; padding: 8px; background: Field; color: FieldText; }
    textarea { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; line-height: 1.35; }
    button { margin-top: 14px; font: inherit; padding: 7px 12px; border-radius: 5px; border: 1px solid color-mix(in srgb, CanvasText 30%, transparent); background: ButtonFace; color: ButtonText; }
    #results ol { padding-left: 22px; }
    #results li { margin: 10px 0; }
    .error { color: #b00020; }
    .warning { color: #9a6500; }
    .info { color: #205493; }
    .success { color: #127a39; font-weight: 650; }
    .failure { color: #b00020; font-weight: 650; }
    .location { opacity: .75; }
    #filters { max-width: 920px; margin: 20px auto; padding: 0 20px; }
    #filters fieldset { margin: 10px 0; }
    #filters label { font-weight: 400; }
    .is-hidden-by-filter { display: none; }
    """

    static let javascript = """
    (() => {
      const select = document.querySelector('#docselect');
      const address = document.querySelector('#address-input');
      const file = document.querySelector('#file-input');
      const textarea = document.querySelector('#textarea-input');
      const urlInput = document.querySelector('#address-input input');
      const fileInput = document.querySelector('#file-input input');
      const textareaInput = document.querySelector('#doc-textarea');
      const level = document.querySelector('#level');
      const form = document.querySelector('#checker');
      function setMode(mode, remember = true) {
        if (!mode) mode = '';
        if (select) select.value = mode;
        if (address) address.hidden = mode !== '';
        if (file) file.hidden = mode !== 'file';
        if (textarea) textarea.hidden = mode !== 'textarea';
        if (urlInput) {
          urlInput.id = mode === '' ? 'doc' : 'doc-url';
          urlInput.disabled = mode !== '';
        }
        if (fileInput) {
          fileInput.id = mode === 'file' ? 'doc' : 'doc-file';
          fileInput.disabled = mode !== 'file';
        }
        if (textareaInput) {
          textareaInput.id = mode === 'textarea' ? 'doc' : 'doc-textarea';
          textareaInput.disabled = mode !== 'textarea';
        }
        if (remember) localStorage.setItem('lastInputMode', mode || 'address');
        if (mode) history.replaceState(null, '', '#' + mode);
      }
      const hashMode = location.hash === '#file' ? 'file' : (location.hash === '#textarea' ? 'textarea' : null);
      const saved = localStorage.getItem('lastInputMode');
      setMode(hashMode || (saved === 'textarea' || saved === 'file' ? saved : ''), false);
      if (select) select.addEventListener('change', () => setMode(select.value));
      if (form && level) {
        form.addEventListener('submit', () => { if (level.checked) level.disabled = false; });
      }
      const filters = document.querySelector('#filters');
      if (filters) {
        const button = filters.querySelector('button');
        const count = filters.querySelector('.filtercount');
        button?.addEventListener('click', () => {
          const expanded = filters.classList.toggle('expanded');
          filters.classList.toggle('unexpanded', !expanded);
          filters.querySelectorAll('fieldset').forEach(f => f.hidden = !expanded);
        });
        filters.querySelectorAll('input[type="checkbox"]').forEach(box => {
          box.addEventListener('change', () => {
            box.dataset.targets.split(' ').forEach(id => {
              document.getElementById(id)?.classList.toggle('is-hidden-by-filter', !box.checked);
            });
            const hidden = document.querySelectorAll('.is-hidden-by-filter').length;
            if (count) {
              count.hidden = hidden === 0;
              count.textContent = hidden + (hidden === 1 ? ' message' : ' messages') + ' hidden by filtering';
            }
          });
        });
      }
    })();
    """
}
