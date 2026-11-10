"""Every local link and picture in the README and the release docs points at a file that exists in the checkout,
headings included, and the README's pictures are the ones scripts/readme/make_readme_images.sh takes. Web addresses
aren't checked. GitHub shows a missing picture as a broken image."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
# The pages people read on GitHub and in a release. The handoff notes are working papers, so they aren't held to this.
PAGES = ['README.md', 'docs/RELEASING.md'] + sorted(p.relative_to(ROOT).as_posix() for p in ROOT.glob('docs/releases/*.md'))


def links(text):
    """Every link and picture target in Markdown and in inline HTML, web addresses left out."""
    found = re.findall(r'\]\(([^)\s]+)\)', text) + re.findall(r'\bsrc="([^"]+)"', text)
    for candidates in re.findall(r'\bsrcset="([^"]+)"', text):
        found += [candidate.split()[0] for candidate in candidates.split(',') if candidate.strip()]
    return [target for target in found if not re.match(r'[a-z][a-z0-9+.-]*:', target)]


def anchors(path):
    """The #anchors GitHub gives a page's headings. Lines in code blocks aren't headings."""
    names, fenced = set(), False
    for line in path.read_text(encoding='utf-8').split('\n'):
        if line.startswith('```'):
            fenced = not fenced
        elif not fenced and (heading := re.match(r'#{1,6}\s+(.*)', line)):
            names.add(re.sub(r'[^\w\- ]', '', heading.group(1).strip().lower()).replace(' ', '-'))
    return names


def pictures(page):
    """The files under docs/images that a page shows, from the repository's root."""
    source = ROOT / page
    found = set()
    for target in links(source.read_text(encoding='utf-8')):
        path = (source.parent / target.partition('#')[0]).resolve()
        if path.parent == ROOT / 'docs/images':
            found.add(path.relative_to(ROOT).as_posix())
    return found


class PublishedDocsTests(unittest.TestCase):
    def test_links_and_pictures_are_in_the_repository(self):
        for page in PAGES:
            source = ROOT / page
            for target in links(source.read_text(encoding='utf-8')):
                path, _, anchor = target.partition('#')
                destination = (source.parent / path) if path else source
                with self.subTest(page=page, target=target):
                    self.assertTrue(destination.exists(), f'{page} links to {target}, which is missing')
                    if anchor and destination.suffix == '.md':
                        self.assertIn(anchor, anchors(destination), f'{page} links to a heading that {path or page} lacks')

    def test_readme_pictures_are_the_ones_the_script_takes(self):
        script = (ROOT / 'scripts/readme/make_readme_images.sh').read_text(encoding='utf-8')
        steps = (ROOT / 'scripts/readme/readme_shots.txt').read_text(encoding='utf-8')
        framed = re.findall(r'^frame ([\w-]+)', script, re.M)
        self.assertTrue(framed, 'make_readme_images.sh frames no pictures')
        made = {f'docs/images/{name}.png' for name in framed} | set(re.findall(r'--out (docs/images/[\w.-]+)', script))
        self.assertEqual(pictures('README.md'), made)
        for name in framed:
            self.assertIn(f'@SHOTS@/{name}.png', steps, f'readme_shots.txt takes no capture for {name}')
        # A picture no page shows any more is left behind by a rename, as welcome-light.png once was.
        shown = set().union(*(pictures(page) for page in PAGES))
        kept = {path.relative_to(ROOT).as_posix() for path in (ROOT / 'docs/images').iterdir() if not path.name.startswith('.')}
        self.assertEqual(kept, shown)


if __name__ == '__main__':
    unittest.main()
