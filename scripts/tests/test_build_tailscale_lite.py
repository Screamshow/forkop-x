import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def executable(path, contents):
    path.write_text(contents)
    path.chmod(0o755)


@unittest.skipUnless(shutil.which('bash') and shutil.which('sha256sum'), 'requires Linux build tools')
class TailscaleLiteBuildPathTests(unittest.TestCase):
    def test_relative_output_is_anchored_at_invocation_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            source = work / 'checkout source'
            (source / 'tool').mkdir(parents=True)
            bin_dir = work / 'bin'
            bin_dir.mkdir()
            executable(bin_dir / 'git', '''#!/bin/sh
[ "$#" = 2 ] && [ "$1" = rev-parse ] && [ "$2" = HEAD ] || exit 1
printf '%s\\n' 8f2c8d6a14419e95fb9d02d6bf6113893daef5c3
''')
            executable(source / 'tool/go', '''#!/bin/sh
[ "$PWD" = "$FIXTURE_SOURCE" ] || exit 1
if [ "$1" = run ]; then
    printf '%s\\n' fixture
    exit 0
fi
[ "$1" = build ] || exit 1
while [ "$#" -gt 1 ]; do
    if [ "$1" = -o ]; then
        printf '%s\\n' "$GOOS/$GOARCH" > "$2"
        exit $?
    fi
    shift
done
exit 1
''')
            env = {**os.environ, 'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'],
                   'FIXTURE_SOURCE': str(source)}
            output = Path('dist') / 'lite binaries'
            result = subprocess.run(['bash', str(ROOT / 'scripts/build-tailscale-lite.sh'), source.name, str(output)],
                                    cwd=work, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for arch in ('amd64', 'arm64'):
                self.assertEqual((work / output / f'tailscale-lite-linux-{arch}').read_text(), f'linux/{arch}\n')
            self.assertFalse((source / output).exists())
