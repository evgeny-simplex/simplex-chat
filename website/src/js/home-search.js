(function (root) {
  const stopWords = new Set(("a an the and or but if then else of to in on at by for with from about as am is are was were be been being " +
    "do does did done have has had i me my mine you your yours we us our it its this that these those there here " +
    "what which whom whose how why when where can could should would will shall may might must not no so than " +
    "too very just also into out up down any all some such only same other more most much many one get gets " +
    "use using used want need simplex please tell know don doesn didn isn aren t s ll ve re m d").split(" "))

  const fieldWeights = { title: 2, heading: 3, body: 1 }
  const synonymWeight = 0.6
  const k1 = 1.2
  const b = 0.75
  const recentBlogDays = 548
  const quantityPhrases = ["how many", "how much", "number of"]
  const quantityWords = new Set(["count", "statistics", "stats", "figures", "facts"])
  const excerptLength = 170

  function stem(word) {
    let w = word
    if (w.length > 4 && w.endsWith("ies")) w = w.slice(0, -3) + "y"
    else if (w.length > 4 && /(ss|sh|ch|x|z)es$/.test(w)) w = w.slice(0, -2)
    else if (w.length > 2 && w.endsWith("s") && !w.endsWith("ss")) w = w.slice(0, -1)
    if (w.length > 5 && w.endsWith("ing")) w = w.slice(0, -3)
    else if (w.length > 4 && w.endsWith("ed")) w = w.slice(0, -2)
    else if (w.length > 6 && w.endsWith("ion")) w = w.slice(0, -3)
    else if (w.length > 6 && /[ai]ble$/.test(w)) w = w.slice(0, -4)
    if (w.length > 3 && w.endsWith("e")) w = w.slice(0, -1)
    return w
  }

  function allWords(text) {
    return String(text || "").normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase()
      .split(/[^\p{L}\p{N}]+/u).filter(Boolean)
  }

  function words(text) {
    return allWords(text).filter((word) => !stopWords.has(word))
  }

  function phrase(text) {
    return allWords(text).join(" ")
  }

  function tokens(text) {
    return words(text).map(stem)
  }

  function queryTerms(text, synonyms) {
    const terms = new Map()
    const alternatives = new Map()
    const add = (term, weight) => terms.set(term, Math.max(terms.get(term) || 0, weight))
    words(text).forEach((word) => {
      const term = stem(word)
      const synonymTerms = (synonyms[word] || []).flatMap(tokens)
      add(term, 1)
      synonymTerms.forEach((synonym) => add(synonym, synonymWeight))
      alternatives.set(term, new Set([...(alternatives.get(term) || []), term, ...synonymTerms]))
    })
    return { terms, alternatives }
  }

  function plainText(html) {
    return String(html || "").replace(/<[^>]+>/g, " ").replace(/&[a-z]+;|&#\d+;/gi, " ")
  }

  function createIndex(entries) {
    const docs = entries.map(({ ref, fields, weight, headingFields = ["heading"] }) => {
      const counts = new Map()
      const headingTerms = new Set()
      let length = 0
      Object.entries(fields).forEach(([field, text]) => {
        const fieldWeight = fieldWeights[field] || 1
        tokens(text).forEach((term) => {
          counts.set(term, (counts.get(term) || 0) + fieldWeight)
          length += fieldWeight
          if (headingFields.includes(field)) headingTerms.add(term)
        })
      })
      return { ref, counts, headingTerms, length, weight: weight || 1 }
    })
    const documentFrequency = new Map()
    docs.forEach((doc) => doc.counts.forEach((_, term) => documentFrequency.set(term, (documentFrequency.get(term) || 0) + 1)))
    const averageLength = docs.reduce((sum, doc) => sum + doc.length, 0) / Math.max(1, docs.length)
    return { docs, documentFrequency, averageLength }
  }

  function inverseFrequency(index, term) {
    const frequency = index.documentFrequency.get(term) || 0
    return Math.log(1 + (index.docs.length - frequency + 0.5) / (frequency + 0.5))
  }

  function search(index, query, synonyms) {
    const { terms, alternatives } = queryTerms(query, synonyms || {})
    const idf = new Map(Array.from(terms.keys(), (term) => [term, inverseFrequency(index, term)]))
    const totalWeight = Array.from(alternatives.keys()).reduce((sum, term) => sum + idf.get(term), 0)
    return index.docs.map((doc) => {
      let score = 0
      terms.forEach((queryWeight, term) => {
        const frequency = doc.counts.get(term)
        if (!frequency) return
        const norm = k1 * (1 - b + b * doc.length / index.averageLength)
        score += queryWeight * idf.get(term) * frequency * (k1 + 1) / (frequency + norm)
      })
      const covered = Array.from(alternatives).filter(([, options]) => Array.from(options).some((option) => doc.counts.has(option)))
      const matchedWeight = covered.reduce((sum, [term]) => sum + idf.get(term), 0)
      const headed = covered.some(([, options]) => Array.from(options).some((option) => doc.headingTerms.has(option)))
      return { ref: doc.ref, score: score * doc.weight, coverage: totalWeight ? matchedWeight / totalWeight : 0, matched: covered.length, terms: alternatives.size, headed }
    }).filter((result) => result.score > 0).sort((x, y) => y.score - x.score)
  }

  function covers(result, coverage) {
    return result.coverage >= coverage && result.matched >= Math.min(2, result.terms)
  }

  function kindWeight(doc, now, docWeights) {
    if (doc.url in docWeights) return docWeights[doc.url]
    if (doc.kind === "docs") return 1.1
    if (doc.kind === "blog" && doc.date) {
      const days = (now - Date.parse(doc.date)) / 86400000
      return days <= recentBlogDays ? 1 : 0.85
    }
    return 1
  }

  function urlName(doc) {
    return doc.kind === "blog" ? "" : doc.url.replace(/\.(html|md)$/, "").split("/").filter(Boolean).pop() || ""
  }

  function knowledgeBaseIndex(kb, now, docWeights) {
    const entries = kb.docs.flatMap((doc) => doc.sections.map((section, index) => ({
      ref: { doc, section },
      fields: { title: doc.title + " " + urlName(doc), heading: plainText(section.heading), body: plainText(section.html) },
      weight: kindWeight(doc, now, docWeights || {}),
      headingFields: index === 0 ? ["title", "heading"] : ["heading"],
    })))
    return createIndex(entries)
  }

  function intentIndex(intents, headings) {
    const index = createIndex(intents.map((intent) => ({
      ref: intent,
      fields: { heading: headings[intent.id] || "", body: intent.phrases.join(" . ") },
    })))
    index.phrases = new Map(intents.flatMap((intent) =>
      [headings[intent.id], intent.label, ...intent.phrases].filter(Boolean).map((text) => [phrase(text), intent])))
    return index
  }

  function bestIntent(index, query, synonyms, threshold, margin, coverage) {
    const exact = index.phrases.get(phrase(query))
    if (exact) return { ref: exact, score: Infinity, coverage: 1 }
    const [first, second] = search(index, query, synonyms)
    if (!first || first.score < threshold || !covers(first, coverage)) return null
    return !second || first.score >= margin * second.score ? first : null
  }

  function factIndex(factTexts) {
    return createIndex(Object.entries(factTexts).map(([id, text]) => ({ ref: id, fields: { body: text } })))
  }

  function isQuantity(query) {
    const text = " " + phrase(query) + " "
    return quantityPhrases.some((cue) => text.includes(" " + cue + " ")) || allWords(query).some((word) => quantityWords.has(word))
  }

  function bestFact(index, query, synonyms, coverage) {
    if (!isQuantity(query)) return null
    const [first] = search(index, query, synonyms)
    return first && covers(first, coverage) ? first : null
  }

  function bestDocuments(index, query, synonyms, threshold, coverage, count) {
    const results = search(index, query, synonyms).filter((result) => result.headed && covers(result, coverage))
    if (results.length === 0 || results[0].score < threshold) return []
    const seen = new Set()
    const firstPerDocument = results.filter((result) => {
      if (seen.has(result.ref.doc)) return false
      seen.add(result.ref.doc)
      return true
    })
    return firstPerDocument.slice(0, count)
  }

  function personaOfWords(query, personaWords) {
    const queryWords = words(query)
    const normalized = " " + queryWords.join(" ") + " "
    const isStatement = (entry) => normalized.includes(" " + entry + " ") && 2 * entry.split(" ").length >= queryWords.length
    return Object.keys(personaWords).find((persona) => personaWords[persona].some(isStatement)) || null
  }

  function excerpt(doc) {
    const text = doc.sections
      .flatMap((section) => Array.from(section.html.matchAll(/<p>([\s\S]*?)<\/p>/g), (match) => plainText(match[1]).replace(/\s+/g, " ").trim()))
      .find((paragraph) => paragraph.length > 60 && !paragraph.startsWith("Published")) || ""
    return text.length > excerptLength ? text.slice(0, excerptLength).replace(/\s+\S*$/, "") + "…" : text
  }

  const api = { search, knowledgeBaseIndex, intentIndex, bestIntent, factIndex, bestFact, bestDocuments, personaOfWords, plainText, excerpt }
  if (typeof module === "object" && module.exports) module.exports = api
  else root.homeSearch = api
})(this)
