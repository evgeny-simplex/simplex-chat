const fs = require("fs")
const path = require("path")
const markdownPages = require("./markdown_pages")
const { imageSize } = require("./image_size")

const siteLocation = "https://simplex.chat"
const headingPattern = /^<h([1-3])((?:\s[^>]*)?)>(.*?)<\/h\1>$/gm
const idPattern = /\bid="([^"]*)"/
const urlAttributePattern = /\b(href|src)="([^"]*)"/g
const blogDatePattern = /^\/blog\/(\d{4})(\d{2})(\d{2})-/
const imagePattern = /<(?:img|image)\b[^>]*>/g
const imageNamePattern = /^<\w+/
const imageSourcePattern = /\ssrc="(\/[^"]*)"/
const imageWidthPattern = /\swidth=/
const imageHeightPattern = /\sheight=/
const imageStylePattern = /\sstyle="/

function siteLink(link, baseUrl) {
  if (link.startsWith("#")) return link
  let url
  try {
    url = new URL(link.replace(/&amp;/g, "&"), siteLocation + baseUrl)
  } catch {
    return link
  }
  if (url.origin !== siteLocation) return link
  return (markdownPages.pageUrl(url.pathname) + url.search + url.hash).replace(/&/g, "&amp;")
}

function siteLinks(html, baseUrl = "/") {
  return html.replace(urlAttributePattern, (_, name, link) => `${name}="${siteLink(link, baseUrl)}"`)
}

function sizedImage(tag, siteDir) {
  const source = tag.match(imageSourcePattern)
  const size = source && !imageHeightPattern.test(tag) && imageSize(path.join(siteDir, decodeURIComponent(source[1])))
  if (!size) return tag
  const ratio = `aspect-ratio: auto ${size.ratio.join(" / ")}`
  const width = imageWidthPattern.test(tag) ? "" : ` width="${size.width || "100%"}"`
  const style = imageStylePattern.test(tag) ? "" : ` style="${ratio}"`
  return tag.replace(imageStylePattern, `$&${ratio}; `).replace(imageNamePattern, `$&${width}${style}`)
}

function sizedImages(html, siteDir) {
  return html.replace(imagePattern, (tag) => sizedImage(tag, siteDir))
}

function sections(html) {
  const headings = Array.from(html.matchAll(headingPattern))
  const end = (index) => index < headings.length ? headings[index].index : html.length
  const lead = html.slice(0, end(0)).trim()
  const headed = headings.map((match, index) => ({
    level: Number(match[1]),
    id: (match[2].match(idPattern) || [])[1] || "",
    heading: match[3],
    html: html.slice(match.index + match[0].length, end(index + 1)).trim(),
  }))
  return lead ? [{ level: 1, id: "", heading: "", html: lead }, ...headed] : headed
}

function docKind(url, inputPath) {
  if (path.relative("src", inputPath).startsWith("docs" + path.sep)) return "docs"
  if (url.startsWith("/blog/")) return "blog"
  if (url.endsWith(".md")) return "summary"
  return "page"
}

function knowledgeBaseDoc({ url, markdown, inputPath }, render, siteDir) {
  const docSections = sections(sizedImages(siteLinks(render(markdown, inputPath), url), siteDir))
  const titleSection = docSections.find((section) => section.level === 1 && section.heading) || docSections.find((section) => section.heading)
  const date = url.match(blogDatePattern)
  return {
    url,
    title: titleSection ? markdownPages.plainText(titleSection.heading).trim() : url,
    kind: docKind(url, inputPath),
    ...(date && { date: `${date[1]}-${date[2]}-${date[3]}` }),
    sections: docSections,
  }
}

function writeKnowledgeBase(file, sources, render, siteDir) {
  const docs = Array.from(sources)
    .sort((a, b) => a.url.localeCompare(b.url))
    .map((source) => knowledgeBaseDoc(source, render, siteDir))
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify({ v: 1, docs }))
  return docs
}

module.exports = {
  siteLinks,
  writeKnowledgeBase,
}
