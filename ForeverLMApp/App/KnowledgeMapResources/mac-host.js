// The Mac's side of the Map page: one WebKit message handler, `knowledgeMap`,
// carrying `{type, ...}`, and `window.knowledgeMap` for the host to call. A page
// with no WebKit (a browser harness) posts to its parent instead.
(function () {
  'use strict'
  function post(type, detail) {
    const message = Object.assign({ type }, detail || {})
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.knowledgeMap
    if (handler) handler.postMessage(message)
    else if (window.parent && window.parent !== window) window.parent.postMessage({ source: 'knowledge-map', message }, '*')
  }
  window.addEventListener('error', (event) => post('error', { message: String(event.message || event.error || 'Map error') }))
  const canvas = document.getElementById('map')
  window.knowledgeMap = window.ForeverLMKnowledgeMap.create(canvas, { post })
  window.addEventListener('message', (event) => {
    const call = event.data && event.data.source === 'knowledge-map-host' ? event.data : null
    if (call && typeof window.knowledgeMap[call.method] === 'function') window.knowledgeMap[call.method](...(call.args || []))
  })
})()
