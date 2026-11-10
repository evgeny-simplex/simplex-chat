(function () {
  const STORE = 'simplex-answers'
  const PAUSE = 140
  const FOLD = 300
  const GLIDE = 620
  const ICONS = {
    fold: '<svg class="fold" aria-hidden="true" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m3.5 6 4.5 4.5L12.5 6"/></svg>',
    tick: '<svg class="tick" aria-hidden="true" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m3 8.5 3.2 3.2L13 5"/></svg>',
    out: '<svg class="out" aria-hidden="true" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M5 11 11 5M6 5h5v5"/></svg>',
  }

  const byId = (id) => document.getElementById(id)
  const stepsRoot = byId('steps')
  const dock = byId('dock')
  const pathPanel = byId('path-panel')
  const sharePanel = byId('share-panel')
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)')

  let graph = null
  let nodes = new Map()
  let path = []
  let last = {}
  let seen = new Set()
  let openStep = null
  let busy = false
  let stopGlide = () => {}

  const stepAt = (i) => stepsRoot.children[i]
  const stepOf = (chip) => Array.prototype.indexOf.call(stepsRoot.children, chip.closest('.step'))
  const choicesAt = (i) => stepAt(i).querySelector('.choices')
  const chosenChip = (i) => choicesAt(i).querySelector('.opt.chosen')
  const tokenOf = (ids) => ids.slice(1).join('~')
  const leadsTo = (id, target) => nodes.get(id).options.some((option) => option.to === target)
  const pause = (ms) => new Promise((resolve) => setTimeout(resolve, reducedMotion.matches ? 0 : ms))

  function make(tag, className, text) {
    const element = document.createElement(tag)
    if (className) element.className = className
    if (text !== undefined) element.textContent = text
    return element
  }

  function readSaved() {
    try {
      return JSON.parse(localStorage.getItem(STORE)) || {}
    } catch (error) {
      return {}
    }
  }

  function save() {
    try {
      localStorage.setItem(STORE, JSON.stringify({ path, last, seen: [...seen] }))
    } catch (error) {}
    try {
      const token = tokenOf(path)
      history.replaceState(null, '', token ? '#' + token : location.pathname + location.search)
    } catch (error) {}
  }

  function forget() {
    try {
      localStorage.removeItem(STORE)
    } catch (error) {}
  }

  function walkable(ids) {
    const walked = [graph.start]
    for (const id of ids) {
      if (!nodes.has(id) || !leadsTo(walked[walked.length - 1], id)) break
      walked.push(id)
    }
    return walked
  }

  function followMemory(walked) {
    let next = last[walked[walked.length - 1]]
    while (next && nodes.has(next) && !walked.includes(next) && leadsTo(walked[walked.length - 1], next)) {
      walked.push(next)
      next = last[next]
    }
    return walked
  }

  function themedImages(image) {
    const light = make('img', image.dark ? 'only-light' : '')
    light.src = image.src
    const pictures = [light]
    if (image.dark) {
      const dark = make('img', 'only-dark')
      dark.src = image.dark
      pictures.push(dark)
    }
    pictures.forEach((picture) => {
      picture.alt = image.alt
      picture.width = image.w
      picture.height = image.h
      picture.loading = 'lazy'
      picture.decoding = 'async'
    })
    return pictures
  }

  function paragraphs(text) {
    return text.split(/\n\s*\n/).map((paragraph) => make('p', '', paragraph))
  }

  function addChipIcons(chip) {
    chip.insertAdjacentHTML('beforeend', ICONS.tick + ICONS.fold)
  }

  function optionElement(option) {
    if (option.url) {
      const link = make('a', 'opt action', option.label)
      link.href = option.url
      if (!option.url.startsWith('/')) {
        link.target = '_blank'
        link.rel = 'noopener'
        link.insertAdjacentHTML('beforeend', ICONS.out)
      }
      return link
    }
    const chip = make('button', 'opt', option.label)
    chip.type = 'button'
    chip.dataset.to = option.to
    addChipIcons(chip)
    return chip
  }

  function paintChoices(i) {
    const box = choicesAt(i)
    const next = path[i + 1]
    box.querySelectorAll('[data-to]').forEach((chip) => {
      const chosen = chip.dataset.to === next
      chip.classList.toggle('chosen', chosen)
      chip.querySelector('.tick').style.display = seen.has(chip.dataset.to) ? '' : 'none'
      if (chosen) chip.setAttribute('aria-expanded', String(openStep === i))
      else chip.removeAttribute('aria-expanded')
    })
    box.classList.toggle('closed', next !== undefined && openStep !== i)
  }

  function choicesElement(node, i) {
    const box = make('div', 'choices')
    box.setAttribute('role', 'group')
    box.setAttribute('aria-label', 'Choices')
    const shown = path.slice(0, i)
    box.append(...node.options.filter((option) => !shown.includes(option.to)).map(optionElement))
    return box
  }

  function pictureAt(i) {
    return nodes.get(path[i]).answer.image || pictureAt(i - 1)
  }

  function answerStep(i) {
    const node = nodes.get(path[i])
    const section = make('section', 'step')
    const { title, text } = node.answer
    const image = pictureAt(i)
    const tall = image.h > image.w * 0.8
    const inner = make('div', 'col')
    const answer = make('article', tall ? 'answer split' : 'answer')
    const words = make('div', 'words')
    const heading = make('h2', '', title || '')
    heading.tabIndex = -1
    if (title) words.append(heading)
    words.append(...paragraphs(text))
    const figure = make('figure', tall ? 'art tall' : 'art')
    figure.append(...themedImages(image))
    answer.append(words, figure)
    inner.append(answer, choicesElement(node, i))
    section.append(inner)
    return section
  }

  function appendSteps(from, entering) {
    for (let i = from; i < path.length; i++) {
      const section = answerStep(i)
      if (entering) section.classList.add('enter')
      stepsRoot.append(section)
      paintChoices(i)
    }
  }

  function morph(box, chip, change) {
    const fromHeight = box.offsetHeight
    const fromRect = chip.getBoundingClientRect()
    change()
    if (reducedMotion.matches) return
    const toHeight = box.offsetHeight
    const toRect = chip.getBoundingClientRect()
    const timing = { duration: FOLD, easing: 'cubic-bezier(0.22, 0.8, 0.2, 1)' }
    box.animate([{ height: fromHeight + 'px' }, { height: toHeight + 'px' }], timing)
    chip.animate([{ transform: `translate(${fromRect.left - toRect.left}px, ${fromRect.top - toRect.top}px)` }, { transform: 'none' }], timing)
  }

  function closeOpenStep() {
    if (openStep === null) return
    const i = openStep
    openStep = null
    if (i < path.length - 1) morph(choicesAt(i), chosenChip(i), () => paintChoices(i))
  }

  function openChoices(i) {
    if (openStep === i || i >= path.length - 1) return
    closeOpenStep()
    openStep = i
    const box = choicesAt(i)
    box.classList.add('opening')
    morph(box, chosenChip(i), () => paintChoices(i))
    setTimeout(() => box.classList.remove('opening'), FOLD)
  }

  function glideTo(position) {
    stopGlide()
    if (reducedMotion.matches) {
      window.scrollTo(0, position())
      return
    }
    const start = window.scrollY
    const startedAt = performance.now()
    let stopped = false
    const stop = () => { stopped = true }
    stopGlide = stop
    window.addEventListener('wheel', stop, { once: true, passive: true })
    window.addEventListener('touchstart', stop, { once: true, passive: true })
    const frame = (now) => {
      if (stopped) return
      const progress = Math.min(1, (now - startedAt) / GLIDE)
      const eased = 1 - Math.pow(1 - progress, 3)
      window.scrollTo(0, start + (position() - start) * eased)
      if (progress < 1) requestAnimationFrame(frame)
    }
    requestAnimationFrame(frame)
  }

  function topOfStep(i) {
    return () => stepAt(i).getBoundingClientRect().top + window.scrollY
  }

  function currentStep() {
    const line = window.innerHeight * 0.45
    let current = 0
    Array.from(stepsRoot.children).forEach((section, i) => {
      if (section.getBoundingClientRect().top <= line) current = i
    })
    return current
  }

  function labelOfStep(i) {
    if (i === 0) return nodes.get(graph.start).answer.title || 'Start'
    return nodes.get(path[i - 1]).options.find((option) => option.to === path[i]).label
  }

  function paintDock() {
    dock.hidden = path.length < 2
    if (dock.hidden) closePanels()
    const current = currentStep()
    byId('where-label').textContent = labelOfStep(current)
    byId('where-count').textContent = `${current + 1} of ${path.length}`
    byId('back').disabled = current === 0
  }

  function paintPathList() {
    const current = currentStep()
    const list = byId('path-list')
    list.textContent = ''
    path.forEach((id, i) => {
      const item = make('li')
      const jump = make('button', 'jump')
      jump.type = 'button'
      jump.dataset.jump = i
      jump.append(make('span', 'n', String(i + 1)), make('span', '', labelOfStep(i)))
      if (i === current) jump.setAttribute('aria-current', 'step')
      item.append(jump)
      list.append(item)
    })
  }

  function closePanels() {
    pathPanel.hidden = true
    sharePanel.hidden = true
    byId('where').setAttribute('aria-expanded', 'false')
    byId('share').setAttribute('aria-expanded', 'false')
  }

  function togglePanel(panel, button) {
    const opening = panel.hidden
    closePanels()
    panel.hidden = !opening
    button.setAttribute('aria-expanded', String(opening))
    return opening
  }

  function goToStep(i) {
    closePanels()
    if (i < path.length - 1) openChoices(i)
    else closeOpenStep()
    glideTo(topOfStep(i))
    paintDock()
  }

  async function choose(i, target, chip) {
    busy = true
    const box = choicesAt(i)
    box.querySelectorAll('[data-to]').forEach((other) => other.classList.toggle('chosen', other === chip))
    box.classList.add('leaving')
    await pause(PAUSE)
    last[path[i]] = target
    path = followMemory(path.slice(0, i + 1).concat(target))
    path.forEach((id) => seen.add(id))
    openStep = null
    while (stepsRoot.children.length > i + 1) stepsRoot.lastChild.remove()
    morph(box, chip, () => {
      box.classList.remove('leaving')
      paintChoices(i)
    })
    appendSteps(i + 1, true)
    save()
    document.dispatchEvent(new CustomEvent('answer:open', { detail: { id: target } }))
    glideTo(topOfStep(i + 1))
    paintDock()
    const heading = stepAt(i + 1).querySelector('h2')
    if (heading) heading.focus({ preventScroll: true })
    busy = false
  }

  function startOver() {
    forget()
    last = {}
    seen = new Set()
    path = [graph.start]
    openStep = null
    closePanels()
    while (stepsRoot.children.length > 1) stepsRoot.lastChild.remove()
    paintChoices(0)
    save()
    paintDock()
    glideTo(() => 0)
  }

  async function shareLink() {
    if (!togglePanel(sharePanel, byId('share'))) return
    const token = tokenOf(path)
    const base = location.origin + location.pathname
    const link = token ? base + '#' + token : base
    const field = byId('share-link')
    const status = byId('share-status')
    field.value = link
    try {
      await navigator.clipboard.writeText(link)
      status.textContent = 'Link copied'
    } catch (error) {
      status.textContent = 'Select the link and copy it'
      field.focus()
      field.select()
    }
  }

  function onStepsClick(event) {
    const chip = event.target.closest('[data-to]')
    if (!chip) return
    if (chip.href && (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)) return
    event.preventDefault()
    if (busy) return
    const i = stepOf(chip)
    const target = chip.dataset.to
    if (target !== path[i + 1]) return choose(i, target, chip)
    if (openStep === i) closeOpenStep()
    else openChoices(i)
  }

  function onDocumentClick(event) {
    if (!event.target.closest('.dock, .panel')) closePanels()
  }

  function wireEvents() {
    stepsRoot.addEventListener('click', onStepsClick)
    document.addEventListener('click', onDocumentClick)
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') closePanels()
    })
    byId('logo').addEventListener('click', (event) => {
      event.preventDefault()
      goToStep(0)
    })
    byId('back').addEventListener('click', () => goToStep(Math.max(0, currentStep() - 1)))
    byId('where').addEventListener('click', () => {
      if (togglePanel(pathPanel, byId('where'))) paintPathList()
    })
    byId('share').addEventListener('click', shareLink)
    byId('reset').addEventListener('click', startOver)
    byId('path-list').addEventListener('click', (event) => {
      const jump = event.target.closest('[data-jump]')
      if (jump) goToStep(Number(jump.dataset.jump))
    })
    byId('share-link').addEventListener('focus', (event) => event.target.select())
    let scheduled = false
    window.addEventListener('scroll', () => {
      if (scheduled) return
      scheduled = true
      requestAnimationFrame(() => {
        scheduled = false
        paintDock()
      })
    }, { passive: true })
    window.addEventListener('resize', paintDock, { passive: true })
  }

  function restore() {
    const saved = readSaved()
    const token = location.hash.slice(1)
    const own = Array.isArray(saved.path) ? saved.path : [graph.start]
    last = saved.last && typeof saved.last === 'object' ? saved.last : {}
    seen = new Set(Array.isArray(saved.seen) ? saved.seen : [])
    const shared = token && token !== tokenOf(own)
    path = walkable(shared ? token.split('~') : own.slice(1))
    path.forEach((id) => seen.add(id))
  }

  async function start() {
    try {
      const response = await fetch('/answers.json')
      graph = await response.json()
    } catch (error) {
      return
    }
    nodes = new Map(graph.nodes.map((node) => [node.id, node]))
    restore()
    choicesAt(0).querySelectorAll('[data-to]').forEach(addChipIcons)
    paintChoices(0)
    appendSteps(1, false)
    wireEvents()
    paintDock()
    if (path.length > 1) window.scrollTo(0, topOfStep(path.length - 1)())
  }

  start()
})()
