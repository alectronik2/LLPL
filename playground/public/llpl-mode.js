// Minimal CodeMirror 5 "simple mode" for LLPL syntax highlighting - the
// same keyword set editors/vscode-llpl/server/src/server.ts uses for its
// own completion list, kept in sync by hand since this playground has no
// build step to share it directly.
(function () {
    if (typeof CodeMirror === 'undefined' || !CodeMirror.defineSimpleMode) return;

    var KEYWORDS = (
        'import from namespace class struct packed enum macro ' +
        'constructor destructor func let const volatile if ' +
        'else while for foreach in return continue break defer unless ' +
        'try catch finally throw delete asm new true false null ' +
        'extern as match case default alias operator trait ' +
        'impl quote unquote interrupt ' +
        'sizeof self int uint int16 uint16 int32 uint32 ' +
        'char bool void'
    ).split(' ');

    var keywordRegex = new RegExp('^(?:' + KEYWORDS.join('|') + ')\\b');

    CodeMirror.defineSimpleMode('llpl', {
        start: [
            { regex: /\/\/.*/, token: 'comment' },
            { regex: /\/\*/, token: 'comment', next: 'comment' },
            { regex: /"(?:[^"\\]|\\.)*"/, token: 'string' },
            { regex: /0x[0-9a-fA-F_]+|0b[01_]+|\d[\d_]*/, token: 'number' },
            { regex: /@[A-Za-z_][A-Za-z0-9_]*/, token: 'meta' },
            { regex: keywordRegex, token: 'keyword' },
            { regex: /[A-Z][A-Za-z0-9_]*/, token: 'variable-2' },
            { regex: /[a-z_][A-Za-z0-9_]*/, token: 'variable' },
            { regex: /[-+/*%=<>!&|^~]+/, token: 'operator' },
        ],
        comment: [
            { regex: /.*?\*\//, token: 'comment', next: 'start' },
            { regex: /.*/, token: 'comment' },
        ],
    });
})();
