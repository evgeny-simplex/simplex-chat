const wefunder = "https://wefunder.com/"

function taggedOption(option, id) {
  if (!option.url || !option.url.startsWith(wefunder)) return option
  const url = new URL(option.url)
  url.searchParams.set("utm_campaign", id)
  return { ...option, url: url.href }
}

function branchPictures(graph) {
  const nodes = new Map(graph.nodes.map((node) => [node.id, node]))
  const pictures = new Map([[graph.start, nodes.get(graph.start).answer.image]])
  const queue = [graph.start]
  while (queue.length > 0) {
    const id = queue.shift()
    for (const { to } of nodes.get(id).options) {
      if (nodes.has(to) && !pictures.has(to)) {
        pictures.set(to, nodes.get(to).answer.image || pictures.get(id))
        queue.push(to)
      }
    }
  }
  return pictures
}

function siteAnswers(graph) {
  const pictures = branchPictures(graph)
  const nodes = graph.nodes.map((node) => ({ ...node, options: node.options.map((option) => taggedOption(option, node.id)) }))
  return {
    graph: { start: graph.start, nodes },
    home: nodes.find((node) => node.id === graph.start),
    pages: nodes.filter((node) => node.id !== graph.start).map((node) => ({ ...node, picture: pictures.get(node.id) })),
  }
}

module.exports = siteAnswers
