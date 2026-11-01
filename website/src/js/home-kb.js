importScripts("/js/home-search.js")

let base = null

async function load({ weights }) {
  const response = await fetch("/kb/en.json")
  if (!response.ok) throw new Error("HTTP " + response.status)
  const kb = await response.json()
  base = {
    byUrl: new Map(kb.docs.map((doc) => [doc.url, doc])),
    index: homeSearch.knowledgeBaseIndex(kb, Date.now(), weights),
  }
  return kb.docs.map((doc) => ({ url: doc.url, title: doc.title, kind: doc.kind, date: doc.date, excerpt: homeSearch.excerpt(doc) }))
}

function search({ query, synonyms, threshold, coverage, count }) {
  return homeSearch.bestDocuments(base.index, query, synonyms, threshold, coverage, count).map(({ ref }) => ({
    url: ref.doc.url,
    section: { id: ref.section.id, heading: ref.section.heading },
  }))
}

self.onmessage = async ({ data }) => {
  if (data.type === "load") {
    try {
      postMessage({ type: "ready", catalog: await load(data) })
    } catch (error) {
      postMessage({ type: "error", message: String(error) })
    }
  } else if (data.type === "search") {
    postMessage({ id: data.id, result: search(data) })
  } else if (data.type === "doc") {
    postMessage({ id: data.id, result: base.byUrl.get(data.url) || null })
  }
}
