import { App } from './App'
import { render } from 'react-dom'
import React from 'react'

async function exec(command: string) {
    return JSON.parse(await (window as any).__sgbridge(command))
}

async function init() {
    const node = document.querySelector('#main') as HTMLDivElement
    const theme = await exec('theme')
    node.style.color = theme.color
    node.style.fontSize = `${theme.fontSize}px`
    node.style.fontFamily = `"${theme.font}", sans-serif`

    render(<App />, node)
    // main.innerHTML = `<pre>${JSON.stringify(theme, null, 2)}</pre>`
    node.style.display = 'block'

    // const trap = focusTrap.createFocusTrap(document.getElementById('main'), {
    //     escapeDeactivates: false,
    //     clickOutsideDeactivates: false,
    //     allowOutsideClick: false,
    // })
    // trap.activate()
}

;(window as any).__sginit = init
;(window as any).__sgfocus = () => {
    ;(document.querySelector('#main input') as any).focus()
}

/* window.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  e.stopPropagation();
  exec(`popup:${event.clientX}:${event.clientY}`);
});*/
