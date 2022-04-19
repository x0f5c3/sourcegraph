async function command(command: string) {
    switch (command) {
        case 'theme':
            return JSON.stringify({ backgroundColor: '#3c3f41', color: '#bbbbbb', fontSize: 13, font: 'DejaVu Sans' })
    }

    throw new Error('mock command not found')
}

function initBridge() {
    const webviewWindow: any = (document.getElementById('webview') as HTMLIFrameElement).contentWindow
    const webviewDocument: any = (document.getElementById('webview') as HTMLIFrameElement).contentDocument

    console.log({ webviewWindow, webviewDocument })
    webviewWindow.__sgbridge = command
    webviewWindow.__sginit()
}
window.initBridge = initBridge
