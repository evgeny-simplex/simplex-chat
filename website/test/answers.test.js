const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const siteAnswers = require('../site_answers');
const graph = require('../answers.json');

const site = siteAnswers(graph);
const nodes = new Map(graph.nodes.map((node) => [node.id, node]));
const choices = (node) => node.options.filter((option) => option.to);
const actions = (node) => node.options.filter((option) => option.action);
const texts = graph.nodes.flatMap((node) => [node.answer.title, node.answer.text, ...node.options.map((option) => option.label)]);
const sourceOf = (sitePath) => sitePath.startsWith('/blog/') ? path.join(__dirname, '../..', sitePath) : path.join(__dirname, '../src', sitePath);

test('answer ids are unique', () => {
  const ids = graph.nodes.map((node) => node.id);
  assert.deepStrictEqual(ids.filter((id, i) => ids.indexOf(id) !== i), []);
});

test('every option leads to an answer page', () => {
  const pages = new Set(site.pages.map((page) => page.id));
  const missing = graph.nodes.flatMap((node) => choices(node).filter(({ to }) => !pages.has(to)).map(({ to }) => `${node.id} -> ${to}`));
  assert.deepStrictEqual(missing, []);
});

test('every answer is reachable from the home answer', () => {
  const reached = new Set([graph.start]);
  for (const id of reached) choices(nodes.get(id)).forEach(({ to }) => nodes.has(to) && reached.add(to));
  assert.deepStrictEqual(graph.nodes.map((node) => node.id).filter((id) => !reached.has(id)), []);
});

test('the home offers at most 4 choices and every other answer at most 3', () => {
  assert.deepStrictEqual(graph.nodes.filter((node) => choices(node).length > (node.id === graph.start ? 4 : 3)).map((node) => node.id), []);
});

test('every answer but the home ends with one action and nothing else', () => {
  const wrong = graph.nodes.filter((node) => node.id !== graph.start).filter((node) => actions(node).length !== 1 || node.options[node.options.length - 1] !== actions(node)[0] || node.options.some((option) => !option.to && !option.action));
  assert.deepStrictEqual(wrong.map((node) => node.id), []);
});

test('every answer has a picture after inheritance', () => {
  assert.ok(site.home.answer.image);
  assert.deepStrictEqual(site.pages.filter((page) => !page.picture).map((page) => page.id), []);
});

test('every picture file exists', () => {
  const pictures = graph.nodes.flatMap((node) => node.answer.image ? [node.answer.image.src, node.answer.image.dark].filter(Boolean) : []);
  assert.deepStrictEqual(pictures.filter((picture) => !fs.existsSync(sourceOf(picture))), []);
});

test('Wefunder links are tagged with their answer', () => {
  const tagged = site.graph.nodes.flatMap((node) => node.options.filter(({ url }) => url && url.startsWith('https://wefunder.com/')).map(({ url }) => [node.id, new URL(url).searchParams]));
  assert.ok(tagged.length > 0);
  tagged.forEach(([id, params]) => {
    assert.ok(params.get('utm_source'), id);
    assert.strictEqual(params.get('utm_campaign'), id);
  });
});

test('answers avoid the investment terms the site never states', () => {
  const terms = [/\bSAFE\b/, /\bcap\b/i, /\bSPV\b/i, /\bconversion\b/i, /\bvaluation\b/i, /\braised\b/i, /\bclosing date\b/i, /\buse of (funds|proceeds)\b/i];
  assert.deepStrictEqual(texts.filter((text) => terms.some((term) => term.test(text))), []);
});

test('the name sale has no date: the only December date is December 10', () => {
  assert.deepStrictEqual(texts.filter((text) => /\bDecember (?!10\b)\d|\b\d+ December\b/.test(text)), []);
});
