// Client entry point: launches server/out/server.js (see its own module
// comment for what the server actually does) as a child process and wires
// it up to VS Code's language features for .llpl files. All the real
// logic - diagnostics, completion, hover, go-to-definition, find-references
// - lives in the server; this file only starts/stops it.

import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
    const serverModule = context.asAbsolutePath(path.join('server', 'out', 'server.js'));

    const serverOptions: ServerOptions = {
        run: { module: serverModule, transport: TransportKind.ipc },
        debug: {
            module: serverModule,
            transport: TransportKind.ipc,
            options: { execArgv: ['--nolazy', '--inspect=6009'] },
        },
    };

    const compilerPath = vscode.workspace.getConfiguration('llpl').get<string>('compilerPath') || undefined;

    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'llpl' }],
        initializationOptions: { compilerPath },
    };

    client = new LanguageClient('llplLanguageServer', 'LLPL Language Server', serverOptions, clientOptions);
    void client.start();
}

export function deactivate(): Thenable<void> | undefined {
    return client ? client.stop() : undefined;
}
