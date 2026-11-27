import base64
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, unquote, urlsplit

SCRIPT = Path(__file__).resolve().parents[2] / 'amneziawg.sh'
PRIVATE = base64.b64encode(bytes(range(32))).decode()
PUBLIC = base64.b64encode(bytes(range(32, 64))).decode()
PSK = base64.b64encode(bytes(range(64, 96))).decode()
CONFIG = f'''[Interface]
PrivateKey = {PRIVATE}
Address = 10.9.0.2/32
DNS = 1.1.1.1, 8.8.8.8
MTU = 1280
Jc = 4
Jmin = 40
Jmax = 70
S1 = 15
S2 = 18
S3 = 0
S4 = 0
H1 = 100-200
H2 = 300
H3 = 400
H4 = 500
I1 = <b 0x1234><r 20>
I2 = <r 12>
I3 = <r 16>
I4 = <r 8>
I5 = <r 4>
[Peer]
PublicKey = {PUBLIC}
PresharedKey = {PSK}
Endpoint = 192.0.2.10:51820
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
PersistentKeepalive = 25
'''


class MenuTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.source = self.root / 'phone.conf'
        self.source.write_text(CONFIG)
        self.out = self.root / 'exports'
        self.server = self.root / 'server.conf'
        self.server.write_text('#_Name = phone\n')
        self.client_dir = self.root / 'clients'
        self.client_dir.mkdir()
        shutil.copyfile(self.source, self.client_dir / 'phone.conf')
        self.manager = self.client_dir / 'manage_amneziawg.sh'
        self.manager.write_text('#!/bin/bash\nexit 0\n')

    def tearDown(self):
        self.tmp.cleanup()

    def run_shell(self, code, *args, input=''):
        prefix = 'source "$1"; shift; '
        return subprocess.run(['bash', '-c', prefix + code, 'test', str(SCRIPT),
                               *map(str, args)], text=True, input=input,
                              capture_output=True, cwd=self.root)

    def convert(self, text=CONFIG, name='phone'):
        self.source.write_text(text)
        return self.run_shell('export_profile "$1" "$2" "$3"',
                              self.source, self.out, name)

    def test_keys_and_all_obfuscation_fields_survive_uri(self):
        result = self.convert()
        self.assertEqual(result.returncode, 0, result.stderr)
        uri = (self.out / 'phone.uri').read_text()
        parsed = urlsplit(uri)
        self.assertEqual(parsed.scheme, 'wireguard')
        self.assertEqual(unquote(parsed.username), PRIVATE)
        self.assertEqual(parsed.hostname, '192.0.2.10')
        self.assertEqual(parsed.port, 51820)
        self.assertEqual(parsed.fragment, 'phone')
        values = parse_qs(parsed.query)
        self.assertEqual(values['publickey'], [PUBLIC])
        self.assertEqual(values['presharedkey'], [PSK])
        self.assertEqual(values['address'], ['10.9.0.2/32'])
        self.assertEqual(values['allowedips'], ['0.0.0.0/0,::/0'])
        self.assertEqual(values['keepalive'], ['25'])
        for key in ('jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4',
                    'h1', 'h2', 'h3', 'h4', 'i1', 'i2', 'i3', 'i4', 'i5'):
            self.assertIn(key, values)
        self.assertEqual(values['h1'], ['100-200'])
        self.assertEqual(values['i1'], ['<b 0x1234><r 20>'])
        self.assertNotIn('\n', uri)
        self.assertEqual((self.out / 'phone.conf').read_text(), CONFIG)

    def test_credential_permissions(self):
        result = self.convert()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.out.stat().st_mode & 0o777, 0o700)
        for file in self.out.iterdir():
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def test_unknown_or_new_generation_parameters_rejected(self):
        for key in ('HeaderProtectionKey', 'ContentPaddingAddition', 'PostUp'):
            with self.subTest(key=key):
                result = self.convert(CONFIG.replace('[Peer]', f'{key} = value\n[Peer]'))
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(PRIVATE, result.stderr)
                self.assertFalse(self.out.exists())

    def test_multi_peer_rejected(self):
        self.assertNotEqual(self.convert(CONFIG + '\n[Peer]\nPublicKey = x\n').returncode, 0)

    def test_duplicate_key_rejected(self):
        self.assertNotEqual(self.convert(CONFIG.replace('MTU = 1280', 'MTU = 1280\nMTU = 1400')).returncode, 0)

    def test_bad_key_rejected_without_disclosure(self):
        result = self.convert(CONFIG.replace(PRIVATE, 'secret-invalid-key'))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('secret-invalid-key', result.stderr)
        self.assertFalse(self.out.exists())

    def test_ipv6_endpoint(self):
        result = self.convert(CONFIG.replace('192.0.2.10:51820', '[2001:db8::10]:51820'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(urlsplit((self.out / 'phone.uri').read_text()).hostname, '2001:db8::10')

    def test_bad_endpoints_rejected(self):
        for endpoint in ('192.0.2.10:70000', '192.0.2.10', 'bad host:51820',
                         'user@host:51820', 'host:51820/path', 'host:51820?x=y'):
            with self.subTest(endpoint=endpoint):
                self.assertNotEqual(self.convert(CONFIG.replace('192.0.2.10:51820', endpoint)).returncode, 0)

    def test_missing_field_rejected(self):
        self.assertNotEqual(self.convert(CONFIG.replace('Address = 10.9.0.2/32\n', '')).returncode, 0)

    def test_path_traversal_rejected(self):
        result = self.convert(name='../escape')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.out.exists())

    def test_symlink_output_rejected(self):
        other = self.root / 'other'
        other.mkdir()
        self.out.symlink_to(other)
        self.assertNotEqual(self.convert().returncode, 0)
        self.assertEqual(list(other.iterdir()), [])

    def test_shell_name_validation(self):
        for name in ('../escape', '-oops', '$(touch injected)', 'a b', 'x' * 33):
            with self.subTest(name=name):
                self.assertNotEqual(self.run_shell('valid_name "$1"', name).returncode, 0)
        self.assertEqual(self.run_shell('valid_name "$1"', 'phone_2-test').returncode, 0)

    def delete(self, input):
        return self.run_shell('CLIENT_DIR=$1; SERVER_CONF=$2; delete_client',
                              self.client_dir, self.server, input=input)

    def make_exports(self):
        directory = self.client_dir / 'exports'
        directory.mkdir()
        for suffix in ('conf', 'uri', 'node.png', 'native.png'):
            (directory / ('phone.' + suffix)).write_text('credential')
        (directory / 'other.conf').write_text('other device')
        return directory

    def test_delete_cancel_leaves_credentials(self):
        directory = self.make_exports()
        self.manager.write_text('touch manager-called\n')
        result = self.delete('phone\nno\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((directory / 'phone.conf').exists())
        self.assertFalse((self.root / 'manager-called').exists())

    def test_delete_success_calls_revoke_before_removing_exports(self):
        directory = self.make_exports()
        self.manager.write_text('printf "%s\\n" "$@" > manager-args\n')
        result = self.delete('phone\nphone\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'manager-args').read_text(), 'remove\nphone\n--yes\n')
        self.assertEqual([p.name for p in directory.iterdir()], ['other.conf'])

    def test_delete_failure_preserves_exports(self):
        directory = self.make_exports()
        self.manager.write_text('exit 7\n')
        result = self.delete('phone\nphone\n')
        self.assertEqual(result.returncode, 7)
        self.assertTrue((directory / 'phone.conf').exists())
        self.assertNotIn('客户端已撤销', result.stdout)

    def test_export_payloads_and_qr_inputs(self):
        # Fake qrencode records exact stdin, so this verifies wiring without
        # installing software or using real credentials/network state.
        mock = self.root / 'bin'
        mock.mkdir()
        qr = mock / 'qrencode'
        qr.write_text('#!/bin/bash\nout=""\nwhile (($#)); do\n'
                      'if [[ "$1" == -o ]]; then out=$2; shift 2; else shift; fi\n'
                      'done\nif [[ -n "$out" ]]; then cat > "$out"; else cat > /dev/null; fi\n')
        qr.chmod(0o700)
        result = self.run_shell('CLIENT_DIR=$1; SERVER_CONF=$2; PATH="$3:$PATH"; '
                                'dependencies() { :; }; export_client phone',
                                self.client_dir, self.server, mock)
        self.assertEqual(result.returncode, 0, result.stderr)
        directory = self.client_dir / 'exports'
        self.assertEqual((directory / 'phone.node.png').read_bytes(), (directory / 'phone.uri').read_bytes())
        self.assertEqual((directory / 'phone.native.png').read_text(), CONFIG)
        self.assertEqual((directory / 'phone.node.png').stat().st_mode & 0o777, 0o600)

    def test_existing_install_not_reinstalled(self):
        result = self.run_shell('SERVER_CONF=$1; CLIENT_DIR=$2; dependencies() { exit 99; }; setup', self.server, self.client_dir)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('不重复安装', result.stdout)

    def test_reboot_code_does_not_report_success(self):
        self.server.unlink()
        state = self.root / 'state'
        state.mkdir()
        (state / 'port').write_text('51820\n')
        engine = self.root / 'engine.sh'
        engine.write_text('printf "%s\\n" "$@" > engine-args\nexit 75\n')
        result = self.run_shell('SERVER_CONF=$1; HOME_DIR=$2; '
                                'dependencies() { :; }; '
                                'ENGINE=$3; installer() { printf "%s\\n" "$ENGINE"; }; setup',
                                self.server, state, engine)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('需要重启', result.stdout)
        self.assertNotIn('安装步骤完成', result.stdout)
        flags = (self.root / 'engine-args').read_text()
        self.assertIn('--no-reboot', flags)
        self.assertIn('--protocol=2.0', flags)

    def test_pending_install_with_server_config_is_resumed(self):
        (self.client_dir / 'setup_state').write_text('7\n')
        state = self.root / 'state'
        state.mkdir()
        (state / 'port').write_text('51820\n')
        engine = self.root / 'engine.sh'
        engine.write_text('touch resumed\nexit 75\n')
        result = self.run_shell('SERVER_CONF=$1; CLIENT_DIR=$2; HOME_DIR=$3; ENGINE=$4; '
                                'dependencies() { :; }; installer() { echo "$ENGINE"; }; setup',
                                self.server, self.client_dir, state, engine)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / 'resumed').exists())

    def test_checksum_mismatch_is_never_executed(self):
        state = self.root / 'state'
        state.mkdir()
        (state / 'upstream-install.sh').write_text('touch pwned\n')
        result = self.run_shell('HOME_DIR=$1; curl() { '
                                'while (($#)); do if [[ "$1" == -o ]]; then '
                                'printf "touch pwned\\n" > "$2"; return; fi; shift; done; }; installer', state)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SHA256', result.stderr)
        self.assertFalse((self.root / 'pwned').exists())
        self.assertFalse(list(state.glob('.installer.*')))

    def test_help_does_not_install(self):
        result = subprocess.run(['bash', str(SCRIPT), '--help'], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('中文管理', result.stdout)

    @unittest.skipUnless(shutil.which('qrencode') and
                         (shutil.which('zbarimg') or importlib.util.find_spec('zxingcpp')),
                         'real QR tools not installed')
    def test_real_qr_roundtrip(self):
        result = self.convert()
        self.assertEqual(result.returncode, 0, result.stderr)
        for suffix in ('uri', 'conf'):
            source = self.out / ('phone.' + suffix)
            png = self.out / (suffix + '.png')
            subprocess.run(['qrencode', '-l', 'L', '-s', '6', '-o', str(png)],
                           input=source.read_bytes(), check=True)
            if shutil.which('zbarimg'):
                decoded = subprocess.run(['zbarimg', '--quiet', '--raw', str(png)],
                                         capture_output=True, check=True).stdout
            else:
                import zxingcpp
                from PIL import Image
                with Image.open(png) as image:
                    decoded = zxingcpp.read_barcode(image.convert('RGB')).bytes
            self.assertEqual(decoded.rstrip(b'\n'), source.read_bytes().rstrip(b'\n'))


if __name__ == '__main__':
    unittest.main()
