(function () {
  const config = JSON.parse(document.getElementById("home-data").textContent)
  const strings = config.strings
  const data = config.data
  const askEndpoint = location.hostname.endsWith(".onion") ? "" : document.querySelector('meta[name="simplex-ask"]').content
  const intentThreshold = 2.5
  const intentMargin = 1.3
  const intentCoverage = 0.6
  const searchThreshold = 4
  const relatedThreshold = 2.5
  const excerptLength = 170
  const answerLength = 900
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
  const frameKeys = new Set(data.frame.map(pathKey))
  const intentsById = new Map(data.intents.map((intent) => [intent.id, intent]))
  const personasById = new Map(data.personas.map((persona) => [persona.id, persona]))

  const state = { persona: null, asked: [], busy: false }
  const overlay = { url: null, depth: 0, opener: null }
  let knowledgeBase = null
  let intentIndex = null

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
      knowledgeBase = fetch("/kb/en.json")
        .then((response) => {
          if (!response.ok) throw new Error("HTTP " + response.status)
          return response.json()
        })
        .then((kb) => ({
          byKey: new Map(kb.docs.map((doc) => [pathKey(doc.url), doc])),
          index: homeSearch.knowledgeBaseIndex(kb, Date.now(), data.kbWeights),
        }))
      knowledgeBase.catch(() => { knowledgeBase = null })
    }
    return knowledgeBase
  }

  function answerHeadings() {
    return Object.fromEntries(Array.from(qa.querySelectorAll("h2[id]"), (heading) => [heading.id, heading.textContent]))
  }

  function intents() {
    intentIndex = intentIndex || homeSearch.intentIndex(data.intents, answerHeadings())
    return intentIndex
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

  function kindLabel(doc) {
    return strings.kinds[doc.kind] + (doc.date ? " · " + doc.date : "")
  }

  function excerpt(doc) {
    const text = doc.sections
      .flatMap((section) => Array.from(section.html.matchAll(/<p>([\s\S]*?)<\/p>/g), (match) => homeSearch.plainText(match[1]).replace(/\s+/g, " ").trim()))
      .find((paragraph) => paragraph.length > 60 && !paragraph.startsWith("Published")) || ""
    return text.length > excerptLength ? text.slice(0, excerptLength).replace(/\s+\S*$/, "") + "…" : text
  }

  function cardHtml(doc, section) {
    const href = doc.url + (section && section.id ? "#" + section.id : "")
    const title = section && section.heading ? homeSearch.plainText(section.heading) : doc.title
    return '<a class="card" lang="en" dir="ltr" href="' + escapeHtml(href) + '"><span class="kind">' + escapeHtml(kindLabel(doc)) + '</span> <span class="title">' +
      escapeHtml(title) + '</span> <span class="why">' + escapeHtml(section && section.heading ? doc.title : excerpt(doc)) + "</span></a>"
  }

  function questionsHtml(ids) {
    if (ids.length === 0) return ""
    return '<p class="questions">' + ids.map((id) => '<a class="chip" href="#' + escapeHtml(id) + '" data-intent="' + escapeHtml(id) + '">' +
      escapeHtml(intentsById.get(id).label) + "</a>").join(" ") + "</p>"
  }

  function relatedQuestions(text, exclude, filled) {
    const related = homeSearch.search(intents(), text, data.synonyms)
      .filter((result) => result.score >= relatedThreshold)
      .map((result) => result.ref.id)
    const defaults = filled ? data.intents.map((intent) => intent.id) : []
    return related.concat(defaults)
      .filter((id, index, ids) => !exclude.includes(id) && ids.indexOf(id) === index)
      .slice(0, 3)
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

  function addTurn(said) {
    const turn = document.createElement("section")
    turn.className = "turn"
    turn.innerHTML = '<p class="you"><span dir="auto"></span></p><article class="answer" aria-live="polite" aria-busy="true"></article>'
    turn.querySelector(".you span").textContent = said
    const answer = turn.querySelector(".answer")
    answer.appendChild(byId("busy-template").content.cloneNode(true))
    turns.appendChild(turn)
    composer.hidden = false
    document.body.classList.add("conversation")
    requestAnimationFrame(() => turn.scrollIntoView({ block: "start", behavior: scrollBehavior() }))
    return answer
  }

  function fillTurn(answer, content) {
    answer.textContent = ""
    answer.appendChild(content)
    answer.removeAttribute("aria-busy")
  }

  function screenOf(section) {
    const fragment = document.createDocumentFragment()
    Array.from(section.children).forEach((child) => fragment.appendChild(withoutIds(child.cloneNode(true))))
    return fragment
  }

  function choosePersona(id) {
    if (state.busy) return
    const persona = personasById.get(id)
    state.persona = id
    renderKnows()
    fillTurn(addTurn(persona.label), screenOf(byId("for-" + id)))
    loadKnowledgeBase().catch(() => {})
  }

  function getApp() {
    if (state.busy) return
    fillTurn(addTurn(strings.getApp), screenOf(byId("get")))
  }

  async function intentAnswer(id) {
    if (id === "roadmap") return screenOf(byId("roadmap"))
    const { heading, nodes } = answerNodes(id)
    const fragment = document.createDocumentFragment()
    const header = document.createElement("div")
    header.innerHTML = '<p class="eyebrow">' + escapeHtml(strings.answer) + '</p><h2 lang="en" dir="ltr"></h2>'
    header.querySelector("h2").textContent = heading.textContent
    fragment.append(...header.childNodes)
    const prose = document.createElement("div")
    prose.className = "prose"
    prose.lang = "en"
    prose.dir = "ltr"
    prose.append(...nodes)
    fragment.appendChild(prose)
    const base = await loadKnowledgeBase().catch(() => null)
    if (base) {
      const docs = Array.from(prose.querySelectorAll("a[href]"), (link) => new URL(link.getAttribute("href"), location.href))
        .filter((url) => url.origin === location.origin)
        .map((url) => base.byKey.get(pathKey(url.pathname)))
        .filter((doc, index, all) => doc && all.indexOf(doc) === index)
        .slice(0, 3)
      if (docs.length) fragment.appendChild(htmlFragment('<div class="cards">' + docs.map((doc) => cardHtml(doc)).join("") + "</div>"))
    }
    fragment.appendChild(htmlFragment(questionsHtml(relatedQuestions(heading.textContent + " " + prose.textContent, [id], true))))
    return fragment
  }

  function htmlFragment(html) {
    const template = document.createElement("template")
    template.innerHTML = html
    return template.content
  }

  function searchAnswer(question, results) {
    const [best, ...more] = results
    const { doc, section } = best.ref
    const heading = section.heading ? homeSearch.plainText(section.heading) : doc.title
    const continueHref = doc.url + (section.id ? "#" + section.id : "")
    return htmlFragment(
      '<p class="eyebrow">' + escapeHtml(strings.fromSite) + "</p>" +
      '<p class="source"><span class="kind">' + escapeHtml(kindLabel(doc)) + '</span> <a lang="en" dir="ltr" href="' + escapeHtml(doc.url) + '">' + escapeHtml(doc.title) + "</a></p>" +
      '<h2 lang="en" dir="ltr">' + escapeHtml(heading) + "</h2>" +
      '<div class="prose" lang="en" dir="ltr">' + shortHtml(docHtml(doc, section.html)) + "</div>" +
      '<p class="links"><a class="pill" href="' + escapeHtml(continueHref) + '">' + escapeHtml(strings.continue) + "</a></p>" +
      (more.length ? '<p class="more">' + escapeHtml(strings.more) + '</p><div class="cards">' + more.map((result) => cardHtml(result.ref.doc, result.ref.section)).join("") + "</div>" : "") +
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

  async function answerFor(question) {
    const intent = homeSearch.bestIntent(intents(), question, data.synonyms, intentThreshold, intentMargin, intentCoverage)
    if (intent) return intentAnswer(intent.ref.id)
    const persona = homeSearch.personaOfWords(question, data.personaWords)
    if (persona) {
      state.persona = persona
      renderKnows()
      return screenOf(byId("for-" + persona))
    }
    const base = await loadKnowledgeBase()
    const results = homeSearch.bestDocuments(base.index, question, data.synonyms, searchThreshold, 3)
    return results.length ? searchAnswer(question, results) : fallbackAnswer(question)
  }

  async function respond(said, produce) {
    if (state.busy) return
    state.busy = true
    setBusy(true)
    const answer = addTurn(said)
    try {
      fillTurn(answer, await produce())
    } catch (error) {
      fillTurn(answer, byId("error-template").content.cloneNode(true))
    } finally {
      state.busy = false
      setBusy(false)
    }
  }

  function ask(question) {
    const text = question.trim().slice(0, 500)
    if (!text || state.busy) return
    state.asked.push(text)
    renderKnows()
    respond(text, () => answerFor(text))
  }

  function askIntent(id) {
    if (state.busy) return
    const intent = intentsById.get(id)
    state.asked.push(intent.label)
    renderKnows()
    respond(intent.label, () => intentAnswer(id))
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
      const base = await loadKnowledgeBase()
      fillTurn(answer, serviceAnswer(await response.json(), base))
    } catch (error) {
      fillTurn(answer, byId("error-template").content.cloneNode(true))
    }
  }

  function serviceBlock(block, base) {
    const items = Array.isArray(block.items) ? block.items : []
    switch (block.type) {
      case "lead": return '<p class="lead">' + inlineMarkup(block.text) + "</p>"
      case "text": return String(block.text || "").split(/\n\s*\n/).map((paragraph) => '<p class="text">' + inlineMarkup(paragraph) + "</p>").join("")
      case "stats": return '<div class="stats">' + items.filter((item) => item && data.facts[item.fact])
        .map((item) => '<p class="stat"><b>' + escapeHtml(data.facts[item.fact]) + "</b> <span>" + escapeHtml(item.label) + "</span></p>").join("") + "</div>"
      case "steps": return '<ol class="steps">' + items.map((item) => "<li>" + inlineMarkup(item) + "</li>").join("") + "</ol>"
      case "table": return '<div class="table"><table><thead><tr>' + (block.columns || []).map((column) => "<th>" + escapeHtml(column) + "</th>").join("") +
        "</tr></thead><tbody>" + (block.rows || []).map((row) => "<tr>" + (Array.isArray(row) ? row : []).map((cell) => "<td>" + inlineMarkup(cell) + "</td>").join("") + "</tr>").join("") + "</tbody></table></div>"
      case "pages": return '<div class="cards">' + items.map((item) => item && base.byKey.get(pathKey(String(item.url || "")))).filter(Boolean).map((doc) => cardHtml(doc)).join("") + "</div>"
      case "questions": return questionsHtml(items.filter((id) => intentsById.has(id)))
      default: return ""
    }
  }

  function serviceAnswer(response, base) {
    const blocks = Array.isArray(response.blocks) ? response.blocks : []
    return htmlFragment("<h2>" + escapeHtml(response.title) + "</h2>" + blocks.map((block) => block && typeof block === "object" ? serviceBlock(block, base) : "").join(""))
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
    knowsPanel.hidden = !open
    knowsButton.setAttribute("aria-expanded", String(open))
    if (open) renderKnows()
  }

  function forget() {
    state.persona = null
    state.asked = []
    turns.textContent = ""
    composer.hidden = true
    document.body.classList.remove("conversation")
    toggleKnows(false)
    renderKnows()
    window.scrollTo({ top: 0, behavior: scrollBehavior() })
  }

  function linkTarget(link) {
    const href = link.getAttribute("href")
    if (!href || href.startsWith("javascript:")) return null
    const url = new URL(href, location.href)
    if (url.protocol !== "http:" && url.protocol !== "https:") return null
    return url
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
    document.querySelectorAll("body > .top, body > main, body > .foot, body > .composer, body > .knows").forEach((element) => { element.inert = true })
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
    const target = hash && sheetBody.querySelector('[id="' + CSS.escape(decodeURIComponent(hash.slice(1))) + '"]')
    sheetBody.scrollTop = target ? target.getBoundingClientRect().top - sheetBody.getBoundingClientRect().top + sheetBody.scrollTop - 24 : 0
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

  function renderFrame(url) {
    const frame = document.createElement("iframe")
    frame.className = "frame"
    frame.src = url.pathname + url.search + url.hash
    frame.title = url.pathname
    frame.addEventListener("load", () => {
      try {
        const current = new URL(frame.contentWindow.location.href)
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
      if (overlay.url !== url.href) return
      const doc = base.byKey.get(key)
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
    const url = linkTarget(link)
    if (!url) return
    if (url.origin !== location.origin) {
      link.target = "_blank"
      link.rel = "noopener"
      return
    }
    if (link.closest(".sheet-head")) return
    if (pathKey(url.pathname) === homeKey) {
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
    ask(input.value)
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
  const start = decodeURIComponent(location.hash.slice(1))
  if (start.startsWith("for-") && personasById.has(start.slice(4))) choosePersona(start.slice(4))
  else if (intentsById.has(start)) askIntent(start)
})()
