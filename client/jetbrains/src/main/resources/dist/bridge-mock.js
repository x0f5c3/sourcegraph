/******/ (() => { // webpackBootstrap
/******/ 	"use strict";
var __webpack_exports__ = {};
/*!**************************************!*\
  !*** ./webview/bridge-mock/index.ts ***!
  \**************************************/

async function command(command) {
    switch (command) {
        case 'theme':
            return JSON.stringify({ backgroundColor: '#3c3f41', color: '#bbbbbb', fontSize: 13, font: 'DejaVu Sans' });
    }
    throw new Error('mock command not found');
}
function initBridge() {
    const webviewWindow = document.getElementById('webview').contentWindow;
    const webviewDocument = document.getElementById('webview').contentDocument;
    console.log({ webviewWindow, webviewDocument });
    webviewWindow.__sgbridge = command;
    webviewWindow.__sginit();
}
window.initBridge = initBridge;

/******/ })()
;
//# sourceMappingURL=bridge-mock.js.map