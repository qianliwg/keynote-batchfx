"""Project-level contracts and safe publication, independent of the app UI."""
import copy
import json
import math
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'KeynoteAdapter'))
from adapter import SceneDocument, extract_route, fingerprint
from motion_export import export_project, validate_recipe
from keynote_motion import refs, SHAPE
from iwa_codec import point, xy


def recipe(source, anchor=(.5, .5), orientation='fixed'):
    document = SceneDocument(source)
    roots = document.scene(document.slides[0])['nodes']
    route = next(n for n in roots if n.get('curve'))
    target = next(n for n in roots if not n.get('curve') and n['kind'] in ('group', 'shape', 'image'))
    imported = extract_route(source, str(document.slides[0]), route['id'], target['id'], fingerprint(source))
    return dict(formatVersion=1, projectID='test', source=imported['source'],
                slideID=imported['slideID'], routeObjectID=route['id'], targetObjectID=target['id'],
                canvas=imported['canvas'], segments=imported['segments'],
                target=dict(name=target['name'], size=dict(zip(('x', 'y'), target['size'])),
                            anchor=dict(zip(('x', 'y'), anchor)), rotationDegrees=37),
                orientation=orientation, spans=[dict(start=0, duration=4, **{'from':0, 'to':1})],
                drawLine=True, playback='once', fps=30)


class RecipeChecks(unittest.TestCase):
    def setUp(self):
        self.project = json.loads((ROOT/'ProjectFormat/example-project.kmotion.json').read_text())
        self.project['spans'] = [dict(start=0, duration=4, **{'from':0, 'to':1})]

    def test_rejects_unsupported_combinations_without_silently_dropping_settings(self):
        for field, value in [('playback', 'loop'), ('playback', 'ping-pong'), ('orientation', 'bad')]:
            with self.subTest(field=field, value=value):
                project = copy.deepcopy(self.project);project[field] = value
                with self.assertRaises(ValueError): validate_recipe(project)
        self.project['target']['anchor']['x'] = 1
        with self.assertRaises(ValueError): validate_recipe(self.project)
        self.project['orientation'] = 'fixed'
        self.assertEqual(validate_recipe(self.project)[1], (1, .5))

    def test_rejects_bad_durations_and_segmented_timing(self):
        for value in (True, float('nan'), float('inf'), 0, 601):
            self.project['spans'][0]['duration'] = value
            with self.subTest(value=value), self.assertRaises(ValueError): validate_recipe(self.project)
        self.project['spans'] = [dict(start=0, duration=2, **{'from':0, 'to':.5})]
        with self.assertRaises(ValueError): validate_recipe(self.project)


@unittest.skipUnless((ROOT/'Fixtures/03_group.key').is_file(), '本机 Keynote 样例未提供')
class NativePackageChecks(unittest.TestCase):
    def setUp(self):
        self.source = ROOT/'Fixtures/03_group.key'
        self.original = self.source.read_bytes()
        self.temp = tempfile.TemporaryDirectory(prefix='kmotion-project-test-', dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name)/'new.key'
        self.project = recipe(self.source, (.9, .2))

    def test_import_contract_includes_hash_path_rotation_and_group(self):
        p = self.project
        imported = extract_route(self.source, p['slideID'], p['routeObjectID'], p['targetObjectID'])
        self.assertEqual(imported['source']['relativePath'], str(self.source))
        self.assertEqual(imported['source']['sha256'], fingerprint(self.source))
        self.assertEqual(imported['target']['kind'], 'group')
        self.assertIn('rotationDegrees', imported['target'])
        with self.assertRaises(ValueError):
            extract_route(self.source, 1, p['routeObjectID'], p['targetObjectID'], 'stale')

    def test_group_export_preserves_children_media_and_matches_anchor(self):
        result = export_project(self.source, self.output, self.project, True)
        self.assertTrue(result['groupMotion'])
        before, after = SceneDocument(self.source), SceneDocument(self.output)
        target = int(self.project['targetObjectID'])
        descendants = []
        def visit(ident):
            for child in refs(before.objects[ident], 2) if before.types[ident] == 3008 else []:
                descendants.append(child);visit(child)
        visit(target)
        for ident in descendants:
            self.assertEqual(before.objects[ident].pack(), after.objects[ident].pack())
        for name, data in before.entries.items():
            if name.startswith('Data/'):self.assertEqual(data, after.entries[name])
        geometry = after.geometry(target)
        pos, size = xy(geometry.sub(1)), xy(geometry.sub(2))
        angle = math.radians(-geometry.f(4))
        dx, dy = (size[0]*.4, size[1]*-.3)
        anchor = (pos[0]+size[0]/2+math.cos(angle)*dx-math.sin(angle)*dy,
                  pos[1]+size[1]/2+math.sin(angle)*dx+math.cos(angle)*dy)
        start = self.project['segments'][0]['p0']
        self.assertAlmostEqual(anchor[0], start['x'], places=3)
        self.assertAlmostEqual(anchor[1], start['y'], places=3)
        self.assertEqual(self.original, self.source.read_bytes())

    def test_center_tangent_uses_original_route_direction(self):
        self.project['target']['anchor'] = dict(x=.5, y=.5)
        self.project['orientation'] = 'route-tangent'
        export_project(self.source, self.output, self.project, True)
        document = SceneDocument(self.output)
        sid, target = int(self.project['slideID']), int(self.project['targetObjectID'])
        builds = [document.objects[i] for i in refs(document.objects[sid], 2) if document.objects[i].sub(1).get(1) == target]
        self.assertEqual(len(builds), 1)
        self.assertEqual(builds[0].sub(4).get(37), 1)

    def test_conflicts_stale_source_changed_route_and_existing_output_publish_nothing(self):
        with self.assertRaises(ValueError):export_project(self.source, self.output, self.project)
        self.assertFalse(self.output.exists())
        bad = copy.deepcopy(self.project);bad['source']['sha256'] = 'stale'
        with self.assertRaises(ValueError):export_project(self.source, self.output, bad, True)
        bad = copy.deepcopy(self.project);bad['segments'][0]['p0']['x'] += 30
        with self.assertRaises(ValueError):export_project(self.source, self.output, bad, True)
        self.assertFalse(self.output.exists())
        self.output.write_bytes(b'existing document')
        with self.assertRaises(ValueError):export_project(self.source, self.output, self.project, True)
        self.assertEqual(self.output.read_bytes(), b'existing document')

    def test_source_change_and_validation_failure_leave_no_final_file(self):
        with patch('motion_export.fingerprint', side_effect=[self.project['source']['sha256'], 'changed']):
            with self.assertRaises(ValueError):export_project(self.source, self.output, self.project, True)
        self.assertFalse(self.output.exists())
        original_scene = SceneDocument.scene
        def fail_output(document, sid):
            if document.path != self.source:raise ValueError('output invalid')
            return original_scene(document, sid)
        with patch.object(SceneDocument, 'scene', fail_output):
            with self.assertRaises(ValueError):export_project(self.source, self.output, self.project, True)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(Path(self.temp.name).iterdir()), [])

    def test_concurrent_destination_creation_is_not_overwritten(self):
        import os
        real_link = os.link
        def race(source, destination):
            Path(destination).write_bytes(b'other writer')
            return real_link(source, destination)
        with patch('motion_export.os.link', race):
            with self.assertRaises(FileExistsError):export_project(self.source, self.output, self.project, True)
        self.assertEqual(self.output.read_bytes(), b'other writer')

    def test_unrelated_animation_is_preserved(self):
        source = ROOT/'Fixtures/02_timing.key'
        project = recipe(source)
        before = SceneDocument(source)
        sid = int(project['slideID'])
        untouched = {i: before.objects[i].pack() for i in refs(before.objects[sid], 2)
                     if before.objects[i].sub(1).get(1) not in (int(project['routeObjectID']), int(project['targetObjectID']))}
        export_project(source, self.output, project, True)
        after = SceneDocument(self.output)
        for ident, payload in untouched.items():
            self.assertIn(ident, refs(after.objects[sid], 2))
            self.assertEqual(payload, after.objects[ident].pack())


if __name__ == '__main__':
    unittest.main(verbosity=2)
