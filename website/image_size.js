const fs = require("fs")

const jpegFrameMarkers = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf])
const exifOrientationTag = 0x0112
const svgRootPattern = /<svg\b[^>]*>/
const svgPixelsPattern = /^\d+(\.\d+)?(px)?$/

function naturalSize(width, height) {
  return width > 0 && height > 0 ? { width, ratio: [width, height] } : undefined
}

function pngSize(data) {
  return naturalSize(data.readUInt32BE(16), data.readUInt32BE(20))
}

function gifSize(data) {
  return naturalSize(data.readUInt16LE(6), data.readUInt16LE(8))
}

function webpSize(data) {
  const chunk = data.toString("latin1", 12, 16)
  if (chunk === "VP8 ") return naturalSize(data.readUInt16LE(26) & 0x3fff, data.readUInt16LE(28) & 0x3fff)
  if (chunk === "VP8X") return naturalSize(data.readUIntLE(24, 3) + 1, data.readUIntLE(27, 3) + 1)
  if (chunk === "VP8L") {
    const bits = data.readUInt32LE(21)
    return naturalSize((bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1)
  }
}

function exifOrientation(data, tiff) {
  const littleEndian = data.toString("latin1", tiff, tiff + 2) === "II"
  const read16 = (offset) => littleEndian ? data.readUInt16LE(offset) : data.readUInt16BE(offset)
  const read32 = (offset) => littleEndian ? data.readUInt32LE(offset) : data.readUInt32BE(offset)
  const directory = tiff + read32(tiff + 4)
  for (let entry = directory + 2; entry < directory + 2 + 12 * read16(directory); entry += 12) {
    if (read16(entry) === exifOrientationTag) return read16(entry + 8)
  }
  return 1
}

function jpegSize(data) {
  let quarterTurn = false
  for (let offset = 2; offset + 9 < data.length && data[offset] === 0xff; offset += 2 + data.readUInt16BE(offset + 2)) {
    const marker = data[offset + 1]
    if (marker === 0xe1 && data.toString("latin1", offset + 4, offset + 10) === "Exif\0\0") {
      quarterTurn = exifOrientation(data, offset + 10) >= 5
    }
    if (jpegFrameMarkers.has(marker)) {
      const width = data.readUInt16BE(offset + 7)
      const height = data.readUInt16BE(offset + 5)
      return quarterTurn ? naturalSize(height, width) : naturalSize(width, height)
    }
  }
}

function svgSize(text) {
  const root = (text.match(svgRootPattern) || [""])[0]
  const attribute = (name) => (root.match(new RegExp(`\\s${name}="([^"]*)"`)) || [])[1]
  const width = attribute("width")
  const height = attribute("height")
  if (svgPixelsPattern.test(width) && svgPixelsPattern.test(height)) return naturalSize(parseFloat(width), parseFloat(height))
  const relative = (length) => length === undefined || length.endsWith("%")
  const box = (attribute("viewBox") || "").trim().split(/[\s,]+/).map(Number)
  return relative(width) && relative(height) && box[2] > 0 && box[3] > 0 ? { ratio: [box[2], box[3]] } : undefined
}

function imageSize(file) {
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return undefined
  const data = fs.readFileSync(file)
  if (data.toString("latin1", 1, 4) === "PNG") return pngSize(data)
  if (data.toString("latin1", 0, 4) === "GIF8") return gifSize(data)
  if (data.toString("latin1", 0, 4) === "RIFF" && data.toString("latin1", 8, 12) === "WEBP") return webpSize(data)
  if (data[0] === 0xff && data[1] === 0xd8) return jpegSize(data)
  if (file.endsWith(".svg")) return svgSize(data.toString("utf8"))
}

module.exports = {
  imageSize,
}
