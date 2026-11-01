(function () {
  const config = JSON.parse(document.getElementById("home-data").textContent)
  const strings = config.strings
  const data = config.data
  const askEndpoint = location.hostname.endsWith(".onion") ? "" : document.querySelector('meta[name="simplex-ask"]').content
  const intentThreshold = 2.5
  const intentMargin = 1.3
  const coverage = 0.6
  const searchThreshold = 4
  const relatedThreshold = 2.5
  const answerLength = 900
  const knowledgeBaseTimeout = 15000
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)")

  const byId = (id) => document.getElementById(id)
  const turns = byId("turns")
  const composer = byId("composer")
  const qa = byId("qa")
  const sheet = byId("sheet")
  const sheetBody = byId("sheet-body")
  const overlayElement = byId("overlay")
  const knowsPanel = byId("knows")
  const knowsButton = byId("knows-btn")
  const pageTitle = document.title
  const homeKey = pathKey(location.pathname)
  const languageHomeKeys = new Set(data.langs.map((lang) => "/" + lang))
  const frameKeys = new Set(data.frame.map(pathKey))
  const intentsById = new Map(data.intents.map((intent) => [intent.id, intent]))
  const personasById = new Map(data.personas.map((persona) => [persona.id, persona]))
  const intentIndex = homeSearch.intentIndex(data.intents, answerHeadings())
  const factIndex = homeSearch.factIndex(data.factTexts)

  const state = { persona: null, asked: [], pending: 0, generation: 0 }
  const overlay = { url: null, depth: 0, opener: null }
  let queue = Promise.resolve()
  let knowledgeBase = null
  let catalog = null

  function escapeHtml(text) {
    return String(text == null ? "" : text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c])
  }

  function inlineMarkup(text) {
    return escapeHtml(text).replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/`([^`]+)`/g, "<code>$1</code>")
  }

  function pathKey(path) {
    const key = path.replace(/index\.html$/, "").replace(/\/$/, "")
    return key || "/"
  }

  function scrollBehavior() {
    return reducedMotion.matches ? "auto" : "smooth"
  }

  function loadKnowledgeBase() {
    if (!knowledgeBase) {
      knowledgeBase = new Promise((resolve, reject) => {
        const worker = new Worker("/js/home-kb.js")
        const requests = new Map()
        let nextId = 0
        const fail = (error) => {
          clearTimeout(timer)
          worker.terminate()
          knowledgeBase = null
          requests.forEach(({ failed }) => failed(error))
          requests.clear()
          reject(error)
        }
        const timer = setTimeout(() => fail(new Error("knowledge base timeout")), knowledgeBaseTimeout)
        const request = (message) => new Promise((done, failed) => {
          nextId += 1
          requests.set(nextId, { done, failed })
          worker.postMessage({ ...message, id: nextId })
        })
        worker.onerror = () => fail(new Error("knowledge base worker"))
        worker.onmessage = ({ data: message }) => {
          if (message.type === "ready") {
            clearTimeout(timer)
            catalog = new Map(message.catalog.map((entry) => [pathKey(entry.url), entry]))
            resolve({
              search: (query) => request({ type: "search", query, synonyms: data.synonyms, threshold: searchThreshold, coverage, count: 3 }),
              doc: (url) => request({ type: "doc", url }),
            })
          } else if (message.type === "error") {
            fail(new Error(message.message))
          } else {
            requests.get(message.id).done(message.result)
            requests.delete(message.id)
          }
        }
        worker.postMessage({ type: "load", weights: data.kbWeights })
      })
    }
    return knowledgeBase
  }

  function answerHeadings() {
    return Object.fromEntries(Array.from(qa.querySelectorAll("h2[id]"), (heading) => [heading.id, heading.textContent]))
  }

  function answerNodes(id) {
    const heading = qa.querySelector('h2[id="' + CSS.escape(id) + '"]')
    const nodes = []
    for (let node = heading && heading.nextElementSibling; node && !/^H[12]$/.test(node.tagName); node = node.nextElementSibling) {
      nodes.push(node.cloneNode(true))
    }
    return { heading, nodes }
  }

  function withoutIds(element) {
    element.removeAttribute("id")
    element.querySelectorAll("[id]").forEach((child) => child.removeAttribute("id"))
    return element
  }

  function kindLabel(entry) {
    return strings.kinds[entry.kind] + (entry.date ? " · " + entry.date : "")
  }

  function cardHtml(entry, section) {
    const href = entry.url + (section && section.id ? "#" + section.id : "")
    const heading = section && section.heading ? homeSearch.plainText(section.heading).trim() : ""
    const title = heading && heading !== entry.title ? heading : entry.title
    return '<a class="card" lang="en" dir="ltr" href="' + escapeHtml(href) + '"><span class="kind">' + escapeHtml(kindLabel(entry)) + '</span> <span class="title">' +
      escapeHtml(title) + '</span> <span class="why">' + escapeHtml(title === entry.title ? entry.excerpt : entry.title) + "</span></a>"
  }

  function cardsHtml(cards) {
    return cards.length ? '<div class="cards">' + cards.join("") + "</div>" : ""
  }

  function questionsHtml(ids) {
    if (ids.length === 0) return ""
    return '<p class="questions">' + ids.map((id) => '<a class="chip" href="#' + escapeHtml(id) + '" data-intent="' + escapeHtml(id) + '">' +
      escapeHtml(intentsById.get(id).label) + "</a>").join(" ") + "</p>"
  }

  function relatedQuestions(text, exclude, filled) {
    const related = homeSearch.search(intentIndex, text, data.synonyms)
      .filter((result) => result.score >= relatedThreshold)
      .map((result) => result.ref.id)
    const defaults = filled ? data.intents.map((intent) => intent.id) : []
    return related.concat(defaults)
      .filter((id, index, ids) => !exclude.includes(id) && ids.indexOf(id) === index)
      .slice(0, 3)
  }

  function catalogEntry(link) {
    const url = new URL(link.getAttribute("href"), location.href)
    return url.origin === location.origin && catalog ? catalog.get(pathKey(url.pathname)) : undefined
  }

  function takeDetailsLinks(prose) {
    const paragraph = prose.lastElementChild
    if (!paragraph || paragraph.tagName !== "P") return []
    const nodes = Array.from(paragraph.childNodes)
    let start = nodes.length
    while (start > 0 && (nodes[start - 1].nodeName === "A" || (nodes[start - 1].nodeType === Node.TEXT_NODE && /^[\s,.]*$/.test(nodes[start - 1].textContent)))) start -= 1
    const lead = nodes[start - 1]
    const links = nodes.slice(start).filter((node) => node.nodeName === "A")
    const entries = links.map(catalogEntry)
    const match = lead && lead.nodeType === Node.TEXT_NODE && lead.textContent.match(/\s*(?:Details:|See)\s*$/)
    if (!match || links.length === 0 || !entries.every(Boolean)) return []
    lead.textContent = lead.textContent.slice(0, match.index)
    nodes.slice(start).forEach((node) => node.remove())
    if (!paragraph.textContent.trim()) paragraph.remove()
    return entries.filter((entry, index) => entries.indexOf(entry) === index)
  }

  function addTurn(said, live) {
    const turn = document.createElement("section")
    turn.className = "turn"
    turn.innerHTML = '<p class="you"><span dir="auto"></span></p><article class="answer" aria-busy="true"></article>'
    turn.querySelector(".you span").textContent = said
    const answer = turn.querySelector(".answer")
    if (live) answer.setAttribute("aria-live", "polite")
    answer.appendChild(byId("busy-template").content.cloneNode(true))
    turns.appendChild(turn)
    showComposer()
    requestAnimationFrame(() => turn.scrollIntoView({ block: "start", behavior: scrollBehavior() }))
    return answer
  }

  function showComposer() {
    composer.hidden = false
    document.body.classList.add("conversation")
  }

  function fillTurn(answer, content, focus) {
    answer.textContent = ""
    answer.appendChild(content)
    answer.removeAttribute("aria-busy")
    const heading = focus && answer.querySelector("h2")
    if (heading) {
      heading.tabIndex = -1
      heading.focus({ preventScroll: true })
    }
  }

  function screenOf(section) {
    const fragment = document.createDocumentFragment()
    Array.from(section.children).forEach((child) => fragment.appendChild(withoutIds(child.cloneNode(true))))
    return fragment
  }

  function htmlFragment(html) {
    const template = document.createElement("template")
    template.innerHTML = html
    return template.content
  }

  function intentAnswer(id) {
    const intent = intentsById.get(id)
    if (intent.screen) return screenOf(byId(intent.screen))
    if (intent.page) return pageAnswer(intent)
    const { heading, nodes } = answerNodes(id)
    const fragment = htmlFragment('<header class="head"><p class="eyebrow">' + escapeHtml(strings.answer) + '</p><h2 lang="en" dir="ltr">' +
      escapeHtml(heading.textContent) + "</h2></header>")
    const prose = document.createElement("div")
    prose.className = "prose"
    prose.lang = "en"
    prose.dir = "ltr"
    prose.append(...nodes)
    fragment.appendChild(prose)
    fragment.appendChild(htmlFragment(cardsHtml(takeDetailsLinks(prose).map((entry) => cardHtml(entry)))))
    fragment.appendChild(htmlFragment(questionsHtml(relatedQuestions(heading.textContent + " " + prose.textContent, [id], true))))
    return fragment
  }

  function docHtml(doc, html) {
    return html.replace(/href="#/g, 'href="' + escapeHtml(doc.url) + "#")
  }

  function shortHtml(html) {
    const container = document.createElement("div")
    container.innerHTML = html
    let length = 0
    Array.from(container.children).forEach((child) => {
      if (length > answerLength) child.remove()
      else length += child.textContent.length
    })
    return container.innerHTML
  }

  async function pageAnswer(intent) {
    const base = await loadKnowledgeBase()
    const url = new URL(intent.page, location.href)
    const doc = await base.doc(catalog.get(pathKey(url.pathname)).url)
    const sectionId = decodeURIComponent(url.hash.slice(1))
    const section = doc.sections.find((candidate) => sectionId ? candidate.id === sectionId : candidate.html)
    const heading = section.heading ? homeSearch.plainText(section.heading) : doc.title
    const continueHref = doc.url + (section.id ? "#" + section.id : "")
    const source = heading === doc.title ? "" : '<p class="source" lang="en" dir="ltr"><a href="' + escapeHtml(doc.url) + '">' + escapeHtml(doc.title) + "</a></p>"
    return htmlFragment(
      '<header class="head"><p class="eyebrow">' + escapeHtml(kindLabel(doc)) + "</p>" +
      '<h2 lang="en" dir="ltr">' + escapeHtml(heading) + "</h2>" + source + "</header>" +
      '<div class="prose" lang="en" dir="ltr">' + shortHtml(docHtml(doc, section.html)) + "</div>" +
      '<p class="links"><a class="pill" href="' + escapeHtml(continueHref) + '">' + escapeHtml(strings.continue) + "</a></p>" +
      questionsHtml(relatedQuestions(intent.label, [intent.id], false)))
  }

  function pagesAnswer(question, results) {
    return htmlFragment(
      '<header class="head"><h2 class="eyebrow">' + escapeHtml(strings.pages) + "</h2></header>" +
      cardsHtml(results.map((result) => cardHtml(catalog.get(pathKey(result.url)), result.section))) +
      questionsHtml(relatedQuestions(question, [], false)))
  }

  function fallbackAnswer(question) {
    const fragment = byId("fallback-template").content.cloneNode(true)
    if (askEndpoint) {
      fragment.appendChild(htmlFragment('<p class="links"><button type="button" class="pill" data-service="' + escapeHtml(question) + '">' + escapeHtml(strings.askService) + "</button></p>"))
    }
    fragment.appendChild(htmlFragment(questionsHtml(relatedQuestions(question, [], true))))
    return fragment
  }

  async function searchAnswer(question) {
    const base = await loadKnowledgeBase()
    const results = await base.search(question)
    return results.length ? pagesAnswer(question, results) : fallbackAnswer(question)
  }

  function answerFor(question) {
    if (homeSearch.bestFact(factIndex, question, data.synonyms, coverage)) return screenOf(byId("facts"))
    const intent = homeSearch.bestIntent(intentIndex, question, data.synonyms, intentThreshold, intentMargin, coverage)
    if (intent) return intentAnswer(intent.ref.id)
    const persona = homeSearch.personaOfWords(question, data.personaWords)
    if (persona) {
      state.persona = persona
      renderKnows()
      return screenOf(byId("for-" + persona))
    }
    return searchAnswer(question)
  }

  function respond(said, produce, { live = false, focus = false } = {}) {
    const generation = state.generation
    state.pending += 1
    setBusy(true)
    const run = async () => {
      if (generation !== state.generation) return
      const answer = addTurn(said, live)
      let content
      try {
        content = await produce()
      } catch (error) {
        content = byId("error-template").content.cloneNode(true)
      }
      if (generation === state.generation) fillTurn(answer, content, focus)
    }
    queue = queue.then(run).catch(() => {}).then(() => {
      if (generation !== state.generation) return
      state.pending -= 1
      setBusy(state.pending > 0)
    })
  }

  function ask(question, form) {
    const text = question.trim().slice(0, 500)
    if (!text || state.pending > 0) return
    state.asked.push(text)
    renderKnows()
    if (form.id === "hero-ask") {
      showComposer()
      composer.querySelector("input").focus({ preventScroll: true })
    }
    respond(text, () => answerFor(text), { live: true })
  }

  function askIntent(id) {
    const intent = intentsById.get(id)
    state.asked.push(intent.label)
    renderKnows()
    respond(intent.label, () => intentAnswer(id), { focus: true })
  }

  function choosePersona(id) {
    const persona = personasById.get(id)
    state.persona = id
    renderKnows()
    respond(persona.label, () => screenOf(byId("for-" + id)), { focus: true })
    loadKnowledgeBase().catch(() => {})
  }

  function getApp() {
    respond(strings.getApp, () => screenOf(byId("get")), { focus: true })
  }

  function setBusy(busy) {
    document.querySelectorAll(".ask button").forEach((button) => { button.disabled = busy })
  }

  async function askService(button) {
    const question = button.dataset.service
    button.disabled = true
    const answer = button.closest(".answer")
    try {
      const response = await fetch(askEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ question, who: state.persona || "", recent: state.asked.slice(-4, -1), lang: config.lang }),
      })
      if (!response.ok) throw new Error("HTTP " + response.status)
      await loadKnowledgeBase()
      fillTurn(answer, serviceAnswer(await response.json()), false)
    } catch (error) {
      fillTurn(answer, byId("error-template").content.cloneNode(true), false)
    }
  }

  function serviceBlock(block) {
    const items = Array.isArray(block.items) ? block.items : []
    switch (block.type) {
      case "lead": return '<p class="lead">' + inlineMarkup(block.text) + "</p>"
      case "text": return String(block.text || "").split(/\n\s*\n/).map((paragraph) => '<p class="text">' + inlineMarkup(paragraph) + "</p>").join("")
      case "stats": return '<div class="stats">' + items.filter((item) => item && data.facts[item.fact])
        .map((item) => '<p class="stat"><b>' + escapeHtml(data.facts[item.fact]) + "</b> <span>" + escapeHtml(item.label) + "</span></p>").join("") + "</div>"
      case "steps": return '<ol class="steps">' + items.map((item) => "<li>" + inlineMarkup(item) + "</li>").join("") + "</ol>"
      case "table": return '<div class="table"><table><thead><tr>' + (block.columns || []).map((column) => "<th>" + escapeHtml(column) + "</th>").join("") +
        "</tr></thead><tbody>" + (block.rows || []).map((row) => "<tr>" + (Array.isArray(row) ? row : []).map((cell) => "<td>" + inlineMarkup(cell) + "</td>").join("") + "</tr>").join("") + "</tbody></table></div>"
      case "pages": return cardsHtml(items.map((item) => item && catalog.get(pathKey(String(item.url || "")))).filter(Boolean).map((entry) => cardHtml(entry)))
      case "questions": return questionsHtml(items.filter((id) => intentsById.has(id)))
      default: return ""
    }
  }

  function serviceAnswer(response) {
    const blocks = Array.isArray(response.blocks) ? response.blocks : []
    return htmlFragment("<h2>" + escapeHtml(response.title) + "</h2>" + blocks.map((block) => block && typeof block === "object" ? serviceBlock(block) : "").join(""))
  }

  function renderKnows() {
    const items = (state.persona ? [personasById.get(state.persona).said] : [])
      .concat(state.asked.map((question) => strings.asked + " “" + question + "”"))
    const count = items.length
    byId("knows-count").textContent = count > 99 ? "99+" : String(count)
    knowsButton.classList.toggle("known", count > 0)
    const list = byId("knows-list")
    list.textContent = ""
    items.forEach((item) => {
      const element = document.createElement("li")
      element.textContent = item
      list.appendChild(element)
    })
    list.hidden = count === 0
    byId("knows-empty").hidden = count > 0
    byId("forget").hidden = count === 0
  }

  function toggleKnows(open) {
    const hadFocus = knowsPanel.contains(document.activeElement)
    knowsPanel.hidden = !open
    knowsButton.setAttribute("aria-expanded", String(open))
    if (open) {
      renderKnows()
      byId("knows-title").focus({ preventScroll: true })
    } else if (hadFocus) {
      knowsButton.focus({ preventScroll: true })
    }
  }

  function forget() {
    state.persona = null
    state.asked = []
    state.generation += 1
    state.pending = 0
    queue = Promise.resolve()
    setBusy(false)
    turns.textContent = ""
    composer.hidden = true
    document.body.classList.remove("conversation")
    toggleKnows(false)
    renderKnows()
    window.scrollTo({ top: 0, behavior: scrollBehavior() })
  }

  function linkTarget(href, base) {
    if (!href || href.startsWith("javascript:")) return null
    const url = new URL(href, base)
    if (url.protocol !== "http:" && url.protocol !== "https:") return null
    const page = url.origin === location.origin && data.markdownPages[url.pathname]
    return page ? new URL(page + url.hash, url) : url
  }

  function linkAction(url) {
    if (url.origin !== location.origin) return "external"
    const key = pathKey(url.pathname)
    if (key === homeKey || key === "/") return "home"
    if (languageHomeKeys.has(key)) return "navigate"
    return "open"
  }

  function setOverlayHeader(kind, url) {
    byId("sheet-kind").textContent = kind
    const uri = byId("sheet-uri")
    uri.textContent = location.host + url.pathname + url.hash
    uri.href = url.href
    byId("sheet-open").href = url.href
    byId("sheet-copy").classList.remove("copied")
  }

  function showOverlay() {
    if (!overlayElement.hidden) return
    overlay.opener = document.activeElement
    overlayElement.hidden = false
    document.documentElement.classList.add("overlay-open")
    document.querySelectorAll("body > .top, body > main, body > .foot, body > .composer").forEach((element) => { element.inert = true })
    byId("sheet-close").focus({ preventScroll: true })
  }

  function hideOverlay() {
    if (overlayElement.hidden) return
    overlayElement.hidden = true
    sheetBody.textContent = ""
    document.documentElement.classList.remove("overlay-open")
    document.querySelectorAll("[inert]").forEach((element) => { element.inert = false })
    document.title = pageTitle
    overlay.url = null
    overlay.depth = 0
    if (overlay.opener && overlay.opener.focus) overlay.opener.focus({ preventScroll: true })
  }

  function scrollToHash(hash) {
    const target = (hash && sheetBody.querySelector('[id="' + CSS.escape(decodeURIComponent(hash.slice(1))) + '"]')) || sheetBody.querySelector("h1")
    sheetBody.scrollTop = target && hash ? target.getBoundingClientRect().top - sheetBody.getBoundingClientRect().top + sheetBody.scrollTop - 24 : 0
    if (target) {
      target.tabIndex = -1
      target.focus({ preventScroll: true })
    }
  }

  function renderDoc(doc, url) {
    const article = document.createElement("article")
    article.className = "doc"
    article.lang = "en"
    article.dir = "ltr"
    const title = document.createElement("h1")
    title.textContent = doc.title
    article.appendChild(title)
    const html = doc.sections.map((section, index) => {
      const isTitle = index === 0 || (section.level === 1 && homeSearch.plainText(section.heading).trim() === doc.title)
      const level = Math.max(2, section.level)
      const heading = section.heading && !isTitle ? "<h" + level + (section.id ? ' id="' + escapeHtml(section.id) + '"' : "") + ">" + section.heading + "</h" + level + ">" : ""
      return heading + section.html
    }).join("\n")
    article.insertAdjacentHTML("beforeend", html)
    sheetBody.textContent = ""
    sheetBody.appendChild(article)
    sheetBody.classList.remove("framed")
    setOverlayHeader(doc.kind === "page" ? "" : kindLabel(doc), url)
    sheet.setAttribute("aria-label", doc.title)
    document.title = doc.title
    scrollToHash(url.hash)
  }

  function onFrameClick(event, frame) {
    const link = event.target.closest && event.target.closest("a[href]")
    if (!link || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    if ((link.target && link.target !== "_self") || link.hasAttribute("download")) return
    const current = frame.contentWindow.location
    const url = linkTarget(link.getAttribute("href"), current.href)
    if (!url) return
    if (url.origin === location.origin && url.pathname === current.pathname && url.search === current.search) {
      if (url.hash !== current.hash) {
        event.preventDefault()
        current.replace(url.href)
      }
      return
    }
    event.preventDefault()
    const action = linkAction(url)
    if (action === "external") window.open(url.href, "_blank", "noopener")
    else if (action === "home") closeOverlay()
    else if (action === "navigate") location.assign(url.href)
    else openOverlay(url)
  }

  function renderFrame(url) {
    const frame = document.createElement("iframe")
    frame.className = "frame"
    frame.src = url.pathname + url.search + url.hash
    frame.title = url.pathname
    frame.addEventListener("load", () => {
      try {
        const current = new URL(frame.contentWindow.location.href)
        frame.contentWindow.addEventListener("keydown", (event) => {
          if (event.key === "Escape") closeOverlay()
        })
        frame.contentDocument.addEventListener("click", (event) => onFrameClick(event, frame))
        document.title = frame.contentDocument.title || pageTitle
        sheet.setAttribute("aria-label", document.title)
        if (current.pathname !== new URL(overlay.url).pathname) {
          overlay.url = current.href
          history.replaceState({ overlay: current.href, depth: overlay.depth }, "", current.href)
          setOverlayHeader("", current)
        }
      } catch (error) {
        sheet.setAttribute("aria-label", url.pathname)
      }
    })
    sheetBody.textContent = ""
    sheetBody.appendChild(frame)
    sheetBody.classList.add("framed")
    setOverlayHeader("", url)
  }

  function renderMessage(text, url) {
    sheetBody.classList.remove("framed")
    sheetBody.innerHTML = '<p class="sheet-message"></p>'
    sheetBody.firstChild.textContent = text
    setOverlayHeader("", url)
  }

  async function renderOverlay(href) {
    const url = new URL(href)
    overlay.url = url.href
    showOverlay()
    const key = pathKey(url.pathname)
    if (frameKeys.has(key)) return renderFrame(url)
    renderMessage(strings.loading, url)
    try {
      const base = await loadKnowledgeBase()
      const entry = catalog.get(key)
      const doc = entry && await base.doc(entry.url)
      if (overlay.url !== url.href) return
      if (doc) renderDoc(doc, url)
      else renderFrame(url)
    } catch (error) {
      if (overlay.url === url.href) renderFrame(url)
    }
  }

  function openOverlay(url) {
    if (overlay.url && new URL(overlay.url).pathname === url.pathname && url.hash) {
      history.replaceState({ overlay: url.href, depth: overlay.depth }, "", url.href)
      overlay.url = url.href
      setOverlayHeader(byId("sheet-kind").textContent, url)
      return scrollToHash(url.hash)
    }
    overlay.depth += 1
    history.pushState({ overlay: url.href, depth: overlay.depth }, "", url.href)
    renderOverlay(url.href)
  }

  function closeOverlay() {
    if (overlay.depth > 0) history.go(-overlay.depth)
    else hideOverlay()
  }

  function onLinkClick(event, link) {
    const url = linkTarget(link.getAttribute("href"), location.href)
    if (!url) return
    const action = linkAction(url)
    if (action === "external") {
      link.target = "_blank"
      link.rel = "noopener"
      return
    }
    if (link.closest(".sheet-head") || action === "navigate") return
    if (action === "home") {
      if (overlay.url) {
        event.preventDefault()
        closeOverlay()
      }
      return
    }
    event.preventDefault()
    openOverlay(url)
  }

  function startCountdown() {
    const target = Date.parse(config.countdownTo)
    const output = byId("countdown")
    const lead = byId("countdown-lead")
    const days = new Intl.RelativeTimeFormat(config.lang.replace("_", "-") + "-u-nu-latn", { numeric: "always" })
    const pad = (n) => String(n).padStart(2, "0")
    let timer = null
    function tick() {
      const ms = target - Date.now()
      if (ms <= 0) {
        clearInterval(timer)
        lead.hidden = true
        output.textContent = strings.countdownDone
        return
      }
      const s = Math.floor(ms / 1000)
      output.textContent = days.format(Math.floor(s / 86400), "day") + " " + pad(Math.floor((s % 86400) / 3600)) + ":" + pad(Math.floor((s % 3600) / 60)) + ":" + pad(s % 60)
    }
    timer = setInterval(tick, 1000)
    tick()
  }

  document.addEventListener("click", (event) => {
    const target = event.target
    const persona = target.closest("[data-persona]")
    if (persona) {
      event.preventDefault()
      return choosePersona(persona.dataset.persona)
    }
    const intent = target.closest("[data-intent]")
    if (intent && intentsById.has(intent.dataset.intent)) {
      event.preventDefault()
      return askIntent(intent.dataset.intent)
    }
    if (target.closest("#get-app")) {
      event.preventDefault()
      return getApp()
    }
    if (target.closest("#knows-btn")) return toggleKnows(knowsPanel.hidden)
    if (target.closest("#knows-close")) return toggleKnows(false)
    if (target.closest("#forget")) return forget()
    const service = target.closest("[data-service]")
    if (service) return askService(service)
    if (target.closest("[data-close]")) {
      event.preventDefault()
      return closeOverlay()
    }
    if (target.closest("#sheet-copy")) {
      const button = byId("sheet-copy")
      return Promise.resolve(navigator.clipboard && navigator.clipboard.writeText(overlay.url))
        .then(() => button.classList.add("copied"), () => {})
    }
    const link = target.closest("a[href]")
    if (link && !event.defaultPrevented && !event.metaKey && !event.ctrlKey && !event.shiftKey && event.button === 0) onLinkClick(event, link)
  })

  document.addEventListener("submit", (event) => {
    if (!event.target.matches(".ask")) return
    event.preventDefault()
    const input = event.target.elements.q
    ask(input.value, event.target)
    input.value = ""
  })

  document.addEventListener("focusin", (event) => {
    if (event.target.matches(".ask input")) loadKnowledgeBase().catch(() => {})
  })

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return
    if (!overlayElement.hidden) closeOverlay()
    else if (!knowsPanel.hidden) toggleKnows(false)
  })

  window.addEventListener("popstate", (event) => {
    const entry = event.state
    if (entry && entry.overlay) {
      overlay.depth = entry.depth
      renderOverlay(entry.overlay)
    } else {
      hideOverlay()
    }
  })

  renderKnows()
  startCountdown()
  document.documentElement.classList.add("ready")
  const start = decodeURIComponent(location.hash.slice(1))
  if (start.startsWith("for-") && personasById.has(start.slice(4))) choosePersona(start.slice(4))
  else if (intentsById.has(start)) askIntent(start)
})()
