"""Generate both shipping variants using offline dependency placeholders."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'ios/Dependencies'))
from ios_sources import copy_sources
from verify_app_store_project import verify_project


@unittest.skipUnless(shutil.which('xcodegen'), 'XcodeGen is required for project generation')
class AppStorePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tres-fort-packaging-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.ios = self.root / 'ios'
        self.manifest = copy_sources(ROOT / 'ios', self.ios)
        # Any accidental execution by the App Store variant fails closed. The
        # ordinary variant gets a separate harmless offline fixture below.
        (self.ios / 'Dependencies/setup_mediapipe.py').write_text(
            'raise RuntimeError("App Store must not prepare MediaPipe")\n')

    def generate(self, spec):
        subprocess.run(['xcodegen', 'generate', '--spec', spec], cwd=self.ios,
                       check=True, capture_output=True, text=True)
        return self.ios / 'TresFort.xcodeproj/project.pbxproj'

    def shipping_settings(self, project):
        raw = subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)])
        objects = json.loads(raw)['objects']
        result = []
        for target in objects.values():
            if target.get('isa') == 'PBXNativeTarget' and target['name'] in ('TresFort', 'TresFortWidgets'):
                configurations = objects[target['buildConfigurationList']]['buildConfigurations']
                result.extend(objects[item]['buildSettings'] for item in configurations)
        self.assertEqual(len(result), 4)
        return result

    def test_app_store_project_excludes_sdk_graph_model_and_notices_without_downloading(self):
        project = self.generate('project-app-store.yml')
        verify_project(project)
        text = project.read_text()
        self.assertNotIn('Notices', text)
        self.assertEqual([item['TARGETED_DEVICE_FAMILY'] for item in self.shipping_settings(project)], ['1'] * 4)
        self.assertIn('DEBUG APP_STORE_IPHONE_ONLY', text)
        self.assertIn('TresFortWidgets.appex in Embed Foundation Extensions', text)
        self.assertFalse((self.ios / '.dependencies').exists())

    def test_beta_project_retains_sdk_graph_model_notices_and_both_device_families(self):
        (self.ios / 'Dependencies/setup_mediapipe.py').write_text('pass\n')
        dependencies = self.ios / '.dependencies/mediapipe'
        for name in ('MediaPipeTasksVision', 'MediaPipeTasksCommon'):
            (dependencies / name / 'frameworks' / (name + '.xcframework')).mkdir(parents=True)
        (dependencies / 'Notices').mkdir()
        (dependencies / 'Notices/MediaPipe-LICENSE.txt').write_text('offline test license')
        (dependencies / 'pose_landmarker_full.task').write_bytes(b'offline test model')
        project = self.generate('project.yml')
        text = project.read_text()
        self.assertIn('MediaPipeTasksVision.xcframework in Frameworks', text)
        self.assertIn('MediaPipeTasksCommon.xcframework in Frameworks', text)
        self.assertIn('pose_landmarker_full.task in Resources', text)
        self.assertIn('Notices in Resources', text)
        self.assertIn('libMediaPipeTasksCommon_device_graph.a', text)
        self.assertIn('libMediaPipeTasksCommon_simulator_graph.a', text)
        self.assertEqual([item['TARGETED_DEVICE_FAMILY'] for item in self.shipping_settings(project)], ['1,2'] * 4)
        self.assertNotIn('APP_STORE_IPHONE_ONLY', text)
        with self.assertRaisesRegex(ValueError, 'retains Station SDK input'):
            verify_project(project)

    def test_source_snapshot_carries_the_variant_and_its_upload_guard(self):
        self.assertIn('project-app-store.yml', self.manifest)
        self.assertIn('Dependencies/verify_app_store_project.py', self.manifest)


if __name__ == '__main__':
    unittest.main()
