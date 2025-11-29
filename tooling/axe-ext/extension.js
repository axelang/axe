const vscode = require('vscode');
const { LanguageClient, TransportKind, State } = require('vscode-languageclient/node');

let client;
let outputChannel;

const lspMessageType = {
    1: 'Error',
    2: 'Warning',
    3: 'Info',
    4: 'Log'
};

function activate(context) {
    outputChannel = vscode.window.createOutputChannel('Axe LSP');
    outputChannel.appendLine('Activating Axe LSP extension...');
    console.log('[axe-ext] Activating Axe LSP extension');

    const config = vscode.workspace.getConfiguration('axe.lsp');
    let serverPath = config.get('serverPath', '');

    if (!serverPath) {
        serverPath = process.platform === 'win32' ? 'axels.exe' : 'axels';
        outputChannel.appendLine(`Using default server executable: ${serverPath}`);
    } else {
        outputChannel.appendLine(`Using configured serverPath: ${serverPath}`);
        console.log(`[axe-ext] configured serverPath=${serverPath}`);
    }

    const serverOptions = {
        run: {
            command: serverPath,
            transport: TransportKind.stdio,
            options: {
                env: { ...process.env, AXELS_DEBUG: '1' }
            }
        },
        debug: {
            command: serverPath,
            transport: TransportKind.stdio,
            options: {
                env: { ...process.env, AXELS_DEBUG: '1' }
            }
        }
    };

    const clientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'axe' }
        ],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.{axe,axec}')
        },
        outputChannel: outputChannel,
        traceOutputChannel: outputChannel
    };

    client = new LanguageClient(
        'axeLSP',
        'Axe Language Server',
        serverOptions,
        clientOptions
    );

    // Register state change handler
    client.onDidChangeState((event) => {
        const stateNames = {
            1: 'Stopped',
            2: 'Starting', 
            3: 'Running'
        };
        const oldState = stateNames[event.oldState] || event.oldState;
        const newState = stateNames[event.newState] || event.newState;
        outputChannel.appendLine(`Client state changed: ${oldState} -> ${newState}`);
        console.log(`[axe-ext] Client state changed: ${oldState} -> ${newState}`);
        
        if (event.newState === State.Running) {
            outputChannel.appendLine('✓ Language client is now running!');
            console.log('[axe-ext] Language client is now running');
        }
    });

    // Register notification handlers BEFORE starting the client
    client.onNotification('window/logMessage', (params) => {
        try {
            const kind = lspMessageType[params.type] || String(params.type);
            outputChannel.appendLine(`[LSP] ${kind}: ${params.message}`);
            console.log('[axe-ext] server logMessage', params);
        } catch (e) {
            outputChannel.appendLine('Error handling window/logMessage: ' + e);
        }
    });

    client.onNotification('window/showMessage', (params) => {
        try {
            const kind = lspMessageType[params.type] || String(params.type);
            outputChannel.appendLine(`[LSP] showMessage ${kind}: ${params.message}`);
            if (params.type === 1) {
                vscode.window.showErrorMessage(`Axe LSP: ${params.message}`);
            } else if (params.type === 2) {
                vscode.window.showWarningMessage(`Axe LSP: ${params.message}`);
            } else {
                vscode.window.showInformationMessage(`Axe LSP: ${params.message}`);
            }
        } catch (e) {
            outputChannel.appendLine('Error handling window/showMessage: ' + e);
        }
    });

    // Generic notification logger
    client.onNotification((method, params) => {
        try {
            if (!method.startsWith('window/') && !method.startsWith('$/')) {
                outputChannel.appendLine(`[LSP] Notification: ${method}`);
                if (params) {
                    outputChannel.appendLine(`  Params: ${JSON.stringify(params, null, 2)}`);
                }
            }
        } catch (e) {
            outputChannel.appendLine('Error logging notification: ' + e);
        }
    });

    outputChannel.appendLine('Notification handlers registered.');

    // Start the client - in newer versions, start() returns a promise
    // and the client is ready when start() resolves
    const startPromise = client.start();
    
    startPromise.then(() => {
        outputChannel.appendLine('✓ Language client started and ready!');
        outputChannel.appendLine('✓ Hover and completion should now work.');
        outputChannel.appendLine('Try opening a .axe file and pressing Ctrl+Space for completions.');
        console.log('[axe-ext] Language client started successfully');
    }).catch((err) => {
        outputChannel.appendLine(`✗ Language client failed to start: ${err}`);
        console.error('[axe-ext] Language client failed to start:', err);
        vscode.window.showErrorMessage('Axe LSP failed to start — check the "Axe LSP" output channel.');
        outputChannel.show(true);
    });

    // Add the disposable to subscriptions
    context.subscriptions.push({
        dispose: () => {
            if (client) {
                return client.stop();
            }
        }
    });

    outputChannel.appendLine('Axe Language Server activation completed.');
    console.log('[axe-ext] activation completed');

    // Debug command
    const showDebug = vscode.commands.registerCommand('axe.lsp.showDebugInfo', () => {
        const state = client ? client.state : 'no-client';
        const stateNames = {
            1: 'Stopped',
            2: 'Starting',
            3: 'Running'
        };
        const stateName = stateNames[state] || state;
        
        const msg = `Axe LSP Debug Info
==================
Server Path: ${serverPath}
Client State: ${stateName} (${state})
Platform: ${process.platform}
Node Version: ${process.version}

To see detailed LSP communication, check this output channel.
To restart the server, run command: "Axe: Restart Language Server"`;
        
        outputChannel.appendLine('\n' + msg);
        vscode.window.showInformationMessage('Axe LSP: Debug info written to output channel');
        outputChannel.show(true);
    });

    // Restart command
    const restartServer = vscode.commands.registerCommand('axe.lsp.restart', async () => {
        outputChannel.appendLine('\n=== Restarting Axe LSP ===');
        try {
            if (client) {
                await client.stop();
                outputChannel.appendLine('Client stopped.');
            }
            await client.start();
            outputChannel.appendLine('✓ Client restarted successfully.');
            vscode.window.showInformationMessage('Axe LSP restarted successfully');
        } catch (err) {
            outputChannel.appendLine(`✗ Restart failed: ${err}`);
            vscode.window.showErrorMessage(`Failed to restart Axe LSP: ${err}`);
        }
    });

    // Test command to manually trigger completion
    const testCompletion = vscode.commands.registerCommand('axe.lsp.testCompletion', async () => {
        const editor = vscode.window.activeTextEditor;
        if (!editor) {
            vscode.window.showErrorMessage('No active editor');
            return;
        }
        
        outputChannel.appendLine('\n=== Testing Completion ===');
        outputChannel.appendLine(`Document URI: ${editor.document.uri.toString()}`);
        outputChannel.appendLine(`Document Language ID: ${editor.document.languageId}`);
        outputChannel.appendLine(`Position: line ${editor.selection.active.line}, char ${editor.selection.active.character}`);
        outputChannel.appendLine(`Client State: ${client ? client.state : 'no-client'}`);
        outputChannel.appendLine(`File extension: ${editor.document.fileName.split('.').pop()}`);
        
        if (editor.document.languageId !== 'axe') {
            outputChannel.appendLine(`WARNING: Document language is "${editor.document.languageId}", not "axe"`);
            outputChannel.appendLine('Click the language indicator in the bottom-right and select "Axe"');
            vscode.window.showWarningMessage('This file is not recognized as Axe language. Click the language selector in the bottom-right corner.');
        }
        
        try {
            const position = editor.selection.active;
            const completions = await vscode.commands.executeCommand(
                'vscode.executeCompletionItemProvider',
                editor.document.uri,
                position
            );
            
            if (completions && completions.items) {
                outputChannel.appendLine(`✓ Got ${completions.items.length} completion items`);
                completions.items.slice(0, 10).forEach(item => {
                    outputChannel.appendLine(`  - ${item.label} (kind: ${item.kind})`);
                });
            } else {
                outputChannel.appendLine('✗ No completions returned');
            }
        } catch (err) {
            outputChannel.appendLine(`✗ Error: ${err}`);
        }
        
        outputChannel.show(true);
    });

    // Test hover
    const testHover = vscode.commands.registerCommand('axe.lsp.testHover', async () => {
        const editor = vscode.window.activeTextEditor;
        if (!editor) {
            vscode.window.showErrorMessage('No active editor');
            return;
        }
        
        outputChannel.appendLine('\n=== Testing Hover ===');
        outputChannel.appendLine(`Document: ${editor.document.uri.toString()}`);
        outputChannel.appendLine(`Position: ${editor.selection.active.line}:${editor.selection.active.character}`);
        outputChannel.appendLine(`Client State: ${client ? client.state : 'no-client'}`);
        
        try {
            const position = editor.selection.active;
            const hovers = await vscode.commands.executeCommand(
                'vscode.executeHoverProvider',
                editor.document.uri,
                position
            );
            
            if (hovers && hovers.length > 0) {
                outputChannel.appendLine(`✓ Got ${hovers.length} hover result(s)`);
                hovers.forEach((hover, i) => {
                    outputChannel.appendLine(`  Hover ${i + 1}:`);
                    hover.contents.forEach(content => {
                        if (typeof content === 'string') {
                            outputChannel.appendLine(`    ${content}`);
                        } else if (content.value) {
                            outputChannel.appendLine(`    ${content.value}`);
                        }
                    });
                });
            } else {
                outputChannel.appendLine('✗ No hover information returned');
            }
        } catch (err) {
            outputChannel.appendLine(`✗ Error: ${err}`);
        }
        
        outputChannel.show(true);
    });

    context.subscriptions.push(showDebug, restartServer, testCompletion, testHover);
}

function deactivate() {
    if (!client) {
        return undefined;
    }
    if (outputChannel) {
        outputChannel.appendLine('Deactivating Axe LSP extension...');
    }
    return client.stop();
}

module.exports = {
    activate,
    deactivate
};