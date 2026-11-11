"""Behavior tests, no block devices/mounts/WSL. Run with Python + Bash."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('TEST_BASH') or (
    str(Path(os.environ.get('ProgramFiles', 'C:/Program Files'))/'Git/bin/bash.exe')
    if os.name == 'nt' else shutil.which('bash'))
UUID = 'f7e561c4-7408-4107-874a-72bd117b24fc'

def bash_path(path):
    value = str(path).replace('\\', '/')
    return '/' + value[0].lower() + value[2:] if len(value) > 1 and value[1] == ':' else value

class ShellTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run([BASH, '--version'], check=True, capture_output=True)

    def probe(self, rows, expected=UUID, fail_inventory=False):
        # Intercept only block-device inspection; validate real selection logic.
        fixture = r'''
test() { if [[ ${1:-} == -b ]]; then return 0; fi; builtin test "$@"; }
lsblk() { if [[ $FAIL_INVENTORY == 1 ]]; then return 7; fi; printf '%s\n' "$ROWS" | cut -d' ' -f1,2; }
blkid() {
  local dev=${@: -1} field=3
  [[ " $* " != *' -s TYPE '* ]] || field=4
  printf '%s\n' "$ROWS" | awk -v d="$dev" -v f="$field" '$1==d {print $f}'
}
source "$1" "$2"
'''
        env = dict(os.environ, ROWS=rows, FAIL_INVENTORY=str(int(fail_inventory)))
        return subprocess.run([BASH, '-c', fixture, 'test', bash_path(ROOT/'scripts/Find-ArchVhdxDevice.sh'), expected],
                              env=env, text=True, capture_output=True)

    def test_one_whole_btrfs_disk(self):
        p=self.probe(f'/dev/sdc disk {UUID} btrfs'); self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(p.stdout.strip(),'/dev/sdc')

    def test_absent(self): self.assertEqual(self.probe('/dev/sda disk other ext4').returncode,1)
    def test_wrong_type(self): self.assertEqual(self.probe(f'/dev/sdc disk {UUID} ext4').returncode,4)
    def test_duplicate_disk(self):
        self.assertEqual(self.probe(f'/dev/sdc disk {UUID} btrfs\n/dev/sdd disk {UUID} btrfs').returncode,5)
    def test_duplicate_loop(self):
        self.assertEqual(self.probe(f'/dev/sdc disk {UUID} btrfs\n/dev/loop0 loop {UUID} btrfs').returncode,4)
    def test_loop_alone_is_not_missing(self):
        self.assertEqual(self.probe(f'/dev/loop0 loop {UUID} btrfs').returncode,4)
    def test_partition_rejected(self):
        self.assertEqual(self.probe(f'/dev/sdc1 part {UUID} btrfs').returncode,4)
    def test_malformed_uuid(self):
        self.assertEqual(self.probe('', '------------------------------------').returncode,2)
    def test_inventory_failure_not_absent(self):
        self.assertEqual(self.probe('', fail_inventory=True).returncode,3)

    def test_request_requires_apply(self):
        with tempfile.TemporaryDirectory() as d:
            marker=Path(d)/'called'
            stub=Path(d)/'schtasks'
            stub.write_text('#!/bin/bash\nprintf called >"$CALL_LOG"\n')
            stub.chmod(0o755)
            env=dict(os.environ, SCHTASKS=bash_path(stub), CALL_LOG=bash_path(marker), WSL_INTEROP='/fake/socket')
            script=bash_path(ROOT/'scripts/Request-Mount.sh')
            p=subprocess.run([BASH,script],env=env,capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stderr); self.assertFalse(marker.exists(),'dry-run ran a task')
            p=subprocess.run([BASH,script,'--apply'],env=env,capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stderr); self.assertTrue(marker.exists())
            marker.unlink(); env['WSL_INTEROP']=''
            p=subprocess.run([BASH,script,'--apply'],env=env,capture_output=True,text=True)
            self.assertNotEqual(p.returncode,0); self.assertFalse(marker.exists())

    def test_shell_syntax(self):
        scripts = sorted(ROOT.rglob('*.sh')) + [ROOT/'scripts/mount.archbtrfs']
        for script in scripts:
            with self.subTest(script=script.name):
                subprocess.run([BASH, '-n', bash_path(script)], check=True, capture_output=True)

if __name__ == '__main__': unittest.main(verbosity=2)
