"""End-to-end checks through the bundled, isolated adapter process."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'dist/Keynote动效工坊 P2.app/Contents/Resources'
FIXTURES_AVAILABLE = (ROOT / 'Fixtures').is_dir()


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

    @unittest.skipUnless(FIXTURES_AVAILABLE, '公开源码包不含本地 Keynote 样例')
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

    @unittest.skipUnless(FIXTURES_AVAILABLE, '公开源码包不含本地 Keynote 样例')
    def test_existing_output_is_never_replaced(self):
        source = ROOT / 'Fixtures/01_anchor.key'
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix='kmotion-existing-', dir='/private/tmp') as temp:
            output = Path(temp) / 'already.key'
            output.write_bytes(b'existing user document')
            result = request('validatedCopy', source=str(source), output=str(output), sha256=digest)
            self.assertFalse(result['ok'])
            self.assertEqual(output.read_bytes(), b'existing user document')

    @unittest.skipUnless(FIXTURES_AVAILABLE, '公开源码包不含本地 Keynote 样例')
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

    @unittest.skipUnless(FIXTURES_AVAILABLE, '公开源码包不含本地 Keynote 样例')
    def test_extract_route_returns_portable_cubics_and_selection_ids(self):
        source = ROOT / 'Fixtures/02_timing.key'
        scene = request('inspect', path=str(source))['result']
        roots = scene['slides'][0]['nodes']
        route = next(n for n in roots if n.get('curve'))
        target = next(n for n in roots
                      if n['id'] != route['id'] and n['kind'] in ('shape', 'image', 'movie'))
        result = request('extractRoute', path=str(source), slide=1,
                         curve=route['id'], target=target['id'])
        self.assertTrue(result['ok'], result)
        imported = result['result']
        self.assertEqual(imported['routeObjectID'], route['id'])
        self.assertEqual(imported['targetObjectID'], target['id'])
        self.assertGreaterEqual(len(imported['segments']), 1)
        self.assertEqual(set(imported['segments'][0]), {'p0', 'p1', 'p2', 'p3'})
        self.assertEqual(imported['canvas'], {'x': 1920.0, 'y': 1080.0})

    @unittest.skipUnless(FIXTURES_AVAILABLE, '公开源码包不含本地 Keynote 样例')
    def test_apply_motion_writes_a_new_verified_copy(self):
        source = ROOT / 'Fixtures/02_timing.key'
        before = source.read_bytes()
        scene = request('inspect', path=str(source))['result']
        roots = scene['slides'][0]['nodes']
        route = next(n for n in roots if n.get('curve'))
        target = next(n for n in roots
                      if n['id'] != route['id'] and n['kind'] in ('shape', 'image', 'movie'))
        with tempfile.TemporaryDirectory(prefix='kmotion-p2-', dir='/private/tmp') as temp:
            output = Path(temp) / 'p2-沿线动画.key'
            result = request('applyMotion', source=str(source), output=str(output),
                             sha256=scene['source']['sha256'], slide=1,
                             curve=route['id'], target=target['id'],
                             duration=1.5, draw=True, align=True)
            self.assertTrue(result['ok'], result)
            self.assertTrue(result['result']['verified'])
            self.assertTrue(output.exists())
            self.assertTrue(request('inspect', path=str(output))['ok'])
        self.assertEqual(source.read_bytes(), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
