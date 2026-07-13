(function () {
    var textarea = document.getElementById('source-editor');
    var editor = null;
    if (typeof CodeMirror !== 'undefined') {
        editor = CodeMirror.fromTextArea(textarea, {
            mode: 'llpl',
            theme: 'dracula',
            lineNumbers: true,
            indentUnit: 4,
            tabSize: 4,
            indentWithTabs: false,
        });
    }

    var cViewer = null;
    var cTextarea = document.getElementById('c-viewer');
    if (typeof CodeMirror !== 'undefined') {
        cViewer = CodeMirror.fromTextArea(cTextarea, {
            mode: 'text/x-csrc',
            theme: 'dracula',
            lineNumbers: true,
            readOnly: true,
        });
    }

    var outputViewer = document.getElementById('output-viewer');
    var symbolsViewer = document.getElementById('symbols-viewer');
    var statusEl = document.getElementById('status');
    var runBtn = document.getElementById('run-btn');
    var examplesSelect = document.getElementById('examples');

    // The compiler's own baked-in backtrace symbol table (codegen.d's
    // generateBacktraceSymbolTable) - one row per function/method/
    // constructor this snippet itself declares, in source order, with
    // the exact C symbol name/line llpl_resolve_symbol would report for
    // a real panic backtrace through it.
    function setSymbols(symbols) {
        symbolsViewer.textContent = '';
        if (!symbols || symbols.length === 0) {
            var note = document.createElement('div');
            note.className = 'empty-note';
            note.textContent = '(no symbols - the compiler only emits this table once ' +
                'at least one function/method/constructor is defined)';
            symbolsViewer.appendChild(note);
            return;
        }
        var table = document.createElement('table');
        var thead = document.createElement('thead');
        thead.innerHTML = '<tr><th>Name</th><th>Line</th><th>C symbol</th></tr>';
        table.appendChild(thead);
        var tbody = document.createElement('tbody');
        symbols.forEach(function (sym) {
            var tr = document.createElement('tr');
            var nameTd = document.createElement('td');
            nameTd.className = 'sym-name';
            nameTd.textContent = sym.name;
            var lineTd = document.createElement('td');
            lineTd.className = 'sym-loc';
            lineTd.textContent = sym.file + ':' + sym.line;
            var cNameTd = document.createElement('td');
            cNameTd.className = 'sym-cname';
            cNameTd.textContent = sym.cName;
            tr.appendChild(nameTd);
            tr.appendChild(lineTd);
            tr.appendChild(cNameTd);
            tbody.appendChild(tr);
        });
        table.appendChild(tbody);
        symbolsViewer.appendChild(table);
    }

    function getSource() {
        return editor ? editor.getValue() : textarea.value;
    }

    function setC(text) {
        if (cViewer) cViewer.setValue(text || '');
        else cTextarea.value = text || '';
    }

    function setStatus(text, cls) {
        statusEl.textContent = text;
        statusEl.className = cls || '';
    }

    function appendOutputLine(text, cls) {
        var span = document.createElement('div');
        if (cls) span.className = cls;
        span.textContent = text;
        outputViewer.appendChild(span);
    }

    async function runCompile() {
        runBtn.disabled = true;
        setStatus('Compiling…', 'status-busy');
        setC('');
        setSymbols([]);
        outputViewer.textContent = '';

        try {
            var resp = await fetch('/api/compile', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ source: getSource() }),
            });
            var data = await resp.json();

            if (data.error) {
                setStatus('Request failed', 'status-error');
                appendOutputLine(data.error, 'line-stderr');
                return;
            }

            if (!data.compile.ok) {
                setStatus('Compile error', 'status-error');
                appendOutputLine(data.compile.stderr || '(no output)', 'line-stderr');
                return;
            }

            setC(data.generatedC);
            setSymbols(data.symbols);

            if (!data.run || !data.run.ran) {
                setStatus('Compiled, but gcc failed', 'status-error');
                appendOutputLine((data.run && data.run.gccError) || '(no output)', 'line-stderr');
                return;
            }

            if (data.run.stdout) appendOutputLine(data.run.stdout, 'line-stdout');
            if (data.run.stderr) appendOutputLine(data.run.stderr, 'line-stderr');
            if (data.run.timedOut) {
                appendOutputLine('(process timed out and was killed)', 'line-stderr');
            }
            appendOutputLine('(exit code ' + data.run.exitCode + ')', 'line-meta');
            setStatus(data.run.exitCode === 0 ? 'Ran successfully' : 'Ran (nonzero exit)',
                data.run.exitCode === 0 ? 'status-ok' : 'status-error');
        } catch (e) {
            setStatus('Request failed', 'status-error');
            appendOutputLine(String(e), 'line-stderr');
        } finally {
            runBtn.disabled = false;
        }
    }

    runBtn.addEventListener('click', runCompile);

    document.addEventListener('keydown', function (e) {
        if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
            e.preventDefault();
            runCompile();
        }
    });

    Object.keys(LLPL_EXAMPLES).forEach(function (name) {
        var opt = document.createElement('option');
        opt.value = name;
        opt.textContent = name;
        examplesSelect.appendChild(opt);
    });
    examplesSelect.addEventListener('change', function () {
        var src = LLPL_EXAMPLES[examplesSelect.value];
        if (editor) editor.setValue(src);
        else textarea.value = src;
    });

    var firstExample = Object.keys(LLPL_EXAMPLES)[0];
    if (firstExample) {
        if (editor) editor.setValue(LLPL_EXAMPLES[firstExample]);
        else textarea.value = LLPL_EXAMPLES[firstExample];
    }

    setSymbols([]);
})();
