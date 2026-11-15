"""No key for a model provider is ever committed. This reads every file under Sources/, App/, Tests/ and scripts/
and fails on text shaped like a real key.

A key written for a test has to look made up, so that this can tell it from a real one: it holds a plain word such
as "test" or "fake", or it is a pattern such as abcdefgh, 01234567 or one character over and over. A real key is
neither. A finding names the file, the line and how the key starts, and never prints the key.

Usage: python3 -I -B -m unittest discover -s scripts -p 'test_no_keys_committed.py'
"""
import base64
import hashlib
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FOLDERS = ('Sources', 'App', 'Tests', 'scripts')

# How the providers' keys start, and the run of key characters that follows. Nothing that could be part of a key
# comes before the start, so `task-` and `risk-` don't count as `sk-`.
STARTS = re.compile(r'(?<![A-Za-z0-9_-])(?:(sk-|AIza)([A-Za-z0-9_-]{20,})|(xai-|gsk_|pplx-|hf_)([A-Za-z0-9]{20,}))')
# A key with no start of its own, in the header or the field that carries it.
CARRIED = re.compile(r'(?i)(?<![A-Za-z0-9])(bearer\s+|(?:x-api-key|x-goog-api-key|api[_-]?key|authorization)["\']?\s*[:=]\s*["\']?)'
                     r'([A-Za-z0-9._~+/=-]{24,})')
# Words that no run of random characters holds, as a made-up key is likely to: one of them is enough.
WORDS = ('test', 'fake', 'mock', 'stub', 'demo', 'dummy', 'sample', 'example', 'placeholder', 'redacted', 'helm',
         'made', 'real', 'your', 'here', 'token', 'secret', 'value', 'local', 'scripted', 'fixture', 'hidden', 'pasted',
         'shaped', 'wrong', 'saved', 'studio', 'ollama', 'claude', 'openai', 'gemini', 'provider', 'bearer', 'model')
PATTERN_LENGTH = 8


def made_up(body):
    """True for a key that says it is made up, or is plainly a pattern."""
    if any(word in body or word.upper() in body or word.capitalize() in body for word in WORDS):
        return True
    lower, run = body.lower(), 1
    for before, after in zip(lower, lower[1:]):
        steps = ord(after) - ord(before) in (0, 1) or before + after in ('za', '90')
        run = run + 1 if steps else 1
        if run >= PATTERN_LENGTH:
            return True
    return False


def keys_in(text):
    """Each key-shaped run in `text` that isn't made up: its line, how it starts and how long it is."""
    found = []
    for pattern in (STARTS, CARRIED):
        for match in pattern.finditer(text):
            groups = [group for group in match.groups() if group is not None]
            start, body = groups[0], groups[1]
            # A carried key that has a provider's start is found by its start.
            if pattern is CARRIED and STARTS.match(body):
                continue
            if not made_up(body):
                found.append((text.count('\n', 0, match.start()) + 1, ' '.join(start.split()), len(body)))
    return sorted(found)


def keys_under(root, folders=FOLDERS):
    found = []
    for folder in folders:
        for path in sorted((root / folder).rglob('*')):
            if path.is_file():
                # Every byte is a character this way, so no file is skipped for how it is encoded.
                text = path.read_bytes().decode('latin-1')
                found += [f'{path.relative_to(root).as_posix()}:{line}: looks like a real key: {start}… and {length} '
                          f'more characters' for line, start, length in keys_in(text)]
    return found


def random_looking(seed, length, hexadecimal=False):
    """Characters as a provider would issue them, worked out here so that no such run is written in this file."""
    digest = hashlib.sha512(seed.encode()).digest()
    text = digest.hex() if hexadecimal else base64.urlsafe_b64encode(digest + hashlib.sha512(digest).digest()).decode()
    return text.replace('=', '')[:length]


# (start, the rest), in the lengths the providers use.
ISSUED = [
    ('sk-', 'ant-api03-' + random_looking('claude', 93) + 'AA'),
    ('sk-', 'proj-' + random_looking('openai project', 150)),
    ('sk-', random_looking('openai', 48).replace('-', 'a').replace('_', 'b')),
    ('sk-', 'or-v1-' + random_looking('router', 64, hexadecimal=True)),
    ('AIza', random_looking('gemini', 35)),
    ('xai-', random_looking('grok', 80).replace('-', 'a').replace('_', 'b')),
    ('gsk_', random_looking('groq', 52).replace('-', 'a').replace('_', 'b')),
    ('pplx-', random_looking('perplexity', 48).replace('-', 'a').replace('_', 'b')),
    ('hf_', random_looking('hugging face', 34).replace('-', 'a').replace('_', 'b')),
]


class NoKeysCommittedTests(unittest.TestCase):
    def test_keys_as_providers_issue_them_are_found(self):
        for start, rest in ISSUED:
            key = start + rest
            self.assertFalse(made_up(rest), start)
            for text in [key, f'let key = "{key}"', f'{{"x-api-key": "{key}"}}', f'ANTHROPIC_API_KEY={key}\n',
                         f'curl -H "Authorization: Bearer {key}" api', f'first line\n  ai-key {key}\nlast line',
                         f'// {key}', f'({key})', f'key={key}&model=x']:
                found = keys_in(text)
                self.assertEqual(len(found), 1, f'{start}: {text[:24]}')
                self.assertEqual(found[0][1:], (start, len(rest)), start)
            self.assertEqual(keys_in('first line\nsecond line ' + key)[0][0], 2)

    def test_a_key_with_no_start_is_found_where_it_is_carried(self):
        token, plain = random_looking('other', 40), random_looking('other', 32, hexadecimal=True)
        for text in [f'Authorization: Bearer {token}', f'authorization: bearer {plain}', f'"Authorization": "Bearer {token}"',
                     f'x-api-key: {plain}', f'"x-api-key": "{token}"', f'x-goog-api-key: {token}', f'api_key = "{plain}"',
                     f'apiKey: {token}', f'"api-key":"{plain}"', f'OTHER_API_KEY={token}']:
            self.assertEqual(len(keys_in(text)), 1, text[:24])
        # On its own it is a checksum or an id as far as anyone can tell.
        self.assertEqual(keys_in(f'{plain}\n"sha256": "{plain}{plain}"\nid: {token}'), [])

    def test_made_up_keys_pass(self):
        for text in ['sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789', 'sk-proj-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                     'sk-ant-test-key-for-the-smoke-run-1', 'sk-ant-api03-THIS-IS-A-FAKE-KEY-00000000',
                     'sk-0123456789abcdef0123456789abcdef', 'sk-ant-NotARealKeyNotARealKeyNotARealKey',
                     'AIzaSyExampleExampleExampleExample0000', 'xai-abcdefghijklmnopqrstuvwxyzabcdef',
                     'gsk_helmhelmhelmhelmhelmhelm', 'hf_zzzzzzzzzzzzzzzzzzzzzzzzzzzz', 'pplx-9876543210987654321012345678',
                     'Authorization: Bearer scripted-key-for-the-loopback', 'x-api-key: local-model-token-for-lm-studio',
                     'api_key = "your-key-goes-here-your-key-goes-here"', 'Bearer 000000000000000000000000000000']:
            self.assertEqual(keys_in(text), [], text)

    def test_ordinary_text_passes(self):
        for text in ['com.helm.filemanager.ai-key', 'sk-ant-', 'sk-…', 'sk-ant-api03-short', 'AIzaShort', 'xai-short',
                     'the task-force-for-everything-and-more-of-it', 'a risk-assessment-of-everything-and-more',
                     'disk-utility-and-a-long-tail-of-words-here', 'request.setValue("Bearer \\(text)", forHTTPHeaderField: name)',
                     'let header = "Bearer " + secret.revealSecret()', 'Authorization: Bearer <key>', 'x-api-key: $KEY',
                     'key: AgentSecretID(provider: .claude, host: host, port: 443)', 'api_key: String',
                     'claude|api.anthropic.com:443', 'gsk_identifier_in_snake_case_and_long', 'hf_another_identifier_here',
                     '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92',
                     'F2B1E0C4-5A77-4C69-9D0B-3F1E2A6C8B47', 'msg_01XFDUDYJgAACzvnptvVoYEL', 'toolu_01A09q90qw90lq917835lq9']:
            self.assertEqual(keys_in(text), [], text)

    def test_a_finding_names_the_place_and_never_the_key(self):
        start, rest = ISSUED[0]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Tests/HelmAgentTests/Fixtures').mkdir(parents=True)
            (root / 'scripts/rebuild/smoke.d').mkdir(parents=True)
            (root / 'Tests/HelmAgentTests/Fixtures/turn.json').write_text('{"model": "x"}\n{"x-api-key": "' + start + rest + '"}\n')
            (root / 'scripts/rebuild/smoke.d/agent.txt').write_text('ai-key sk-ant-test-key-for-the-smoke-run-1\n')
            (root / 'scripts/icon.bin').write_bytes(bytes(range(256)) + (start + rest).encode() + bytes(range(256)))
            found = keys_under(root, ('Tests', 'scripts', 'Sources'))
        self.assertEqual(found, [f'Tests/HelmAgentTests/Fixtures/turn.json:2: looks like a real key: sk-… and {len(rest)} '
                                 'more characters',
                                 f'scripts/icon.bin:2: looks like a real key: sk-… and {len(rest)} more characters'])
        self.assertNotIn(rest[:12], ''.join(found))

    def test_no_key_in_the_tree(self):
        found = keys_under(ROOT)
        self.assertEqual(found, [], '\n' + '\n'.join(found) + '\nIf a key above is made up, make that plain: put "test" or '
                         '"fake" in it, or write it as a pattern such as abcdefgh. If it is real, it is no longer a secret: '
                         'remove it and make a new one.')


if __name__ == '__main__':
    unittest.main()
