"""End-to-end checks through the bundled, isolated adapter process."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'dist/Keynote动效工坊 P1.app/Contents/Resources'


def request(operation, **arguments):
    payload = {'protocol': 1, 'id': 'verification', 'operation': operation, 'arguments': arguments}
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(ROOT / 'build'),
           'PYTHONHOME': '/nonexistent', 'PYTHONPATH': '/nonexistent'}
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    run = subprocess.run([str(RESOURCES / 'runtime/bin/python3'), '-B', '-I', '-S',
                          str(RESOURCES / 'KeynoteAdapter/adapter.py')],
                         input=json.dumps(payload).encode(), capture_output=True,
                         timeout=30, env=env, check=True)
    if run.stderr:
        raise AssertionError(run.stderr.decode())
    response = json.loads(run.stdout)
    if response['id'] != 'verification' or response['protocol'] != 1:
        raise AssertionError(response)
    return response


class BundledAdapterChecks(unittest.TestCase):
    def test_runtime_ignores_external_python_environment(self):
        response = request('health')
        self.assertTrue(response['ok'])
        self.assertTrue(response['result']['isolated'])
        self.assertEqual(Path(response['result']['runtimePrefix']), RESOURCES / 'runtime')

    def test_nested_group_and_chinese_media_survive_copy(self):
        source = ROOT / 'Fixtures/03_group.key'
        before = source.read_bytes()
        scene = request('inspect', path=str(source))['result']
        group = next(n for n in scene['slides'][0]['nodes'] if n['kind'] == 'group')
        inner = next(n for n in group['children'] if n['kind'] == 'group')
        self.assertTrue(any(n['kind'] == 'image' for n in inner['children']))
        self.assertTrue(any('P0' in n['name'] for n in inner['children']))
        self.assertTrue(any(any(ord(c) > 127 for c in m['path']) for m in scene['media']))
        with tempfile.TemporaryDirectory(prefix='kmotion-copy-', dir='/private/tmp') as temp:
            output = Path(temp) / '中文图片_校验副本.key'
            result = request('validatedCopy', source=str(source), output=str(output),
                             sha256=scene['source']['sha256'])
            self.assertTrue(result['ok'], result)
            with zipfile.ZipFile(source) as a, zipfile.ZipFile(output) as b:
                self.assertEqual(set(a.namelist()), set(b.namelist()))
                for name in a.namelist():
                    self.assertEqual(a.read(name), b.read(name), name)
            self.assertTrue(request('inspect', path=str(output))['ok'])
        self.assertEqual(source.read_bytes(), before)

    def test_existing_output_is_never_replaced(self):
        source = ROOT / 'Fixtures/01_anchor.key'
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix='kmotion-existing-', dir='/private/tmp') as temp:
            output = Path(temp) / 'already.key'
            output.write_bytes(b'existing user document')
            result = request('validatedCopy', source=str(source), output=str(output), sha256=digest)
            self.assertFalse(result['ok'])
            self.assertEqual(output.read_bytes(), b'existing user document')

    def test_stale_source_blocks_output(self):
        source = ROOT / 'Fixtures/01_anchor.key'
        with tempfile.TemporaryDirectory(prefix='kmotion-stale-', dir='/private/tmp') as temp:
            output = Path(temp) / 'must-not-exist.key'
            result = request('validatedCopy', source=str(source), output=str(output), sha256='stale')
            self.assertFalse(result['ok'])
            self.assertFalse(output.exists())

    def test_unknown_operation_returns_protocol_error(self):
        result = request('unknownOperation')
        self.assertFalse(result['ok'])
        self.assertIn('error', result)


if __name__ == '__main__':
    unittest.main(verbosity=2)
